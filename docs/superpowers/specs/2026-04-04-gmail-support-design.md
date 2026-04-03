# Gmail Support Design

**Date:** 2026-04-04  
**Status:** Approved  
**Scope:** OAuth2 account setup, contacts fetch + storage, composer autocomplete

---

## Overview

Add first-class Gmail support to LiteMail. The IMAP transport and XOAUTH2 authentication are already implemented; the gap is wiring a real OAuth2 browser consent flow into account setup, fetching Google Contacts after auth, and surfacing contacts in the composer.

Approach: thin wiring into existing infrastructure — no new provider type. Gmail continues to use `IMAPProvider` with `authType: .oauth2`.

---

## New Components

### `GoogleConfig.swift` (Core/)

Constants and runtime config for Google OAuth2.

```swift
enum GoogleConfig {
    // Bundled client ID registered under LiteMail's Google Cloud project.
    // Override via UserDefaults key "googleClientId" (Settings UI).
    static var clientId: String {
        UserDefaults.standard.string(forKey: "googleClientId") ?? bundledClientId
    }

    private static let bundledClientId = "<REGISTERED_CLIENT_ID>"

    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let redirectScheme = "com.litemail"
    static let redirectURI = "com.litemail:/oauth2callback"

    static let scopes = [
        "https://mail.google.com/",
        "openid",
        "email",
        "profile",
        "https://www.googleapis.com/auth/contacts.readonly"
    ]
}
```

The bundled client ID is registered in Google Cloud Console with the redirect URI `com.litemail:/oauth2callback`. The custom URL scheme `com.litemail` is registered in `Info.plist` so macOS routes the callback back to the app.

Power users can supply their own client ID via Settings → Accounts → "Google Client ID" text field, which writes to `UserDefaults`.

---

### `GmailOAuthFlow.swift` (Core/)

Actor that runs the AppAuth browser consent flow and stores the resulting token via `AuthManager`.

```swift
protocol OAuthFlowProtocol {
    func authenticate(accountId: String, email: String, window: NSWindow) async throws
}

actor GmailOAuthFlow: OAuthFlowProtocol {
    private let authManager: AuthManager

    func authenticate(accountId: String, email: String, window: NSWindow) async throws
    // Errors: OAuthError.cancelled, OAuthError.failed(String)
}

enum OAuthError: Error {
    case cancelled
    case failed(String)
}
```

**Flow:**
1. Build `OIDAuthorizationRequest` using `GoogleConfig` endpoints, scopes, and `clientId`.
2. Use `OIDAuthState.authState(byPresenting:presenting:callback:)` to open the system browser.
3. macOS routes `com.litemail:/oauth2callback` back to the app via `NSAppleEventManager` / `AppDelegate`.
4. On success, call `authManager.storeOAuthState(accountId:state:)`.
5. On cancellation or error, throw `OAuthError`.

`AppDelegate` registers a URL event handler for `com.litemail` scheme and forwards the callback URL to the in-flight `OIDExternalUserAgentSession`.

---

### `ContactsStore.swift` (Core/)

Actor that fetches Google People API contacts after OAuth and stores them in SQLite for composer autocomplete.

```swift
actor ContactsStore {
    private let mailStore: MailStore
    private let authManager: AuthManager

    // Called once after successful OAuth. Non-fatal on failure.
    func fetchAndStore(accountId: String) async

    // Returns contacts matching the prefix, ordered by name.
    func lookup(prefix: String, accountId: String) async throws -> [Contact]
}

struct Contact: Sendable {
    let email: String
    let name: String?
    let photoURL: URL?
}
```

**Fetch logic:**
1. Get access token via `authManager.oauthAccessToken(accountId:)`.
2. Call `https://people.googleapis.com/v1/people/me/connections?personFields=names,emailAddresses,photos&pageSize=1000`, paginating via `nextPageToken` until exhausted.
3. Upsert rows into `contacts` table keyed on `(account_id, email)`.
4. Store `synced_at` timestamp; future re-sync can use `syncToken` for incremental updates (out of scope for this iteration).

Failure is logged and swallowed — account creation proceeds without contacts.

---

## Modified Components

### `MailStore.swift` — Migration v3

New `contacts` table added in schema migration v3:

```sql
CREATE TABLE contacts (
    id          TEXT    NOT NULL,
    account_id  TEXT    NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    name        TEXT,
    email       TEXT    NOT NULL,
    photo_url   TEXT,
    synced_at   INTEGER NOT NULL,
    PRIMARY KEY (account_id, email)
);
CREATE INDEX contacts_account_prefix ON contacts(account_id, email);
```

---

### `AddAccountSheet.swift` — OAuth branch

When `AutoDiscovery` returns `authType == .oauth2` and the provider is Gmail (host contains `gmail.com` or `googlemail.com`):

- Hide the password field.
- Show a "Sign in with Google" button.
- On tap: call `GmailOAuthFlow.authenticate(accountId:email:window:)`.
- On success: disable the button, show a checkmark, enable the "Add Account" confirm button.
- On `OAuthError.cancelled`: restore button, no error shown.
- On `OAuthError.failed(let reason)`:
  - If reason contains `invalid_client`: show "Sign in failed. Try entering your own Google Client ID in Settings."
  - Otherwise: show "Sign in failed: \(reason)"

After the user confirms account creation, `ContactsStore.fetchAndStore(accountId:)` is called in the background (fire-and-forget).

---

### `SettingsWindow.swift` — Client ID override

Add a "Google" section with a labeled text field:

```
Google Client ID  [_________________________]  (leave blank to use built-in)
```

Reads/writes `UserDefaults` key `"googleClientId"`. Change takes effect on the next sign-in attempt.

---

## Data Flow

### Account setup (Gmail)

```
AddAccountSheet
  → AutoDiscovery.discover(email:)             // authType: .oauth2, imapHost: imap.gmail.com
  → GmailOAuthFlow.authenticate(...)           // opens browser
      → OIDAuthorizationRequest (AppAuth)
      → system browser → Google consent screen
      → com.litemail:/oauth2callback
      → AppDelegate routes URL to OIDExternalUserAgentSession
      → AuthManager.storeOAuthState()          // persists to Keychain
  → AccountManager.addAccount(config:)         // creates IMAPProvider with authType .oauth2
  → ContactsStore.fetchAndStore(accountId:)    // background, non-fatal
```

### Runtime mail (unchanged)

```
IMAPProvider.connect()
  → AuthManager.oauthAccessToken(accountId:)   // auto-refreshes via AppAuth
  → server.authenticateXOAUTH2(email:accessToken:)
```

### Composer autocomplete

```
ComposerWindow (To/Cc field keystroke)
  → ContactsStore.lookup(prefix:accountId:)
  → display dropdown of matching contacts
```

---

## Error Handling

| Scenario | Behavior |
|----------|----------|
| User cancels browser consent | `OAuthError.cancelled` — button restored, no error shown |
| OAuth fails (network, bad client ID) | Inline error in AddAccountSheet; `invalid_client` gets actionable message pointing to Settings |
| Contacts fetch fails | Logged, swallowed — account created without contacts |
| Token expired at runtime | `AuthManager.oauthAccessToken()` auto-refreshes; `IMAPProvider` reconnect loop handles refresh failure |
| User supplies invalid custom client ID | Google returns `invalid_client`; same actionable error path |

---

## Testing

- **`GmailOAuthFlowTests`**: inject a stub `OAuthFlowProtocol` that returns success/cancellation/failure; verify `AddAccountSheet` state transitions.
- **`ContactsStoreTests`**: in-memory GRDB database (same pattern as `MailStoreTests`); stub HTTP responses for People API; verify upsert and lookup.
- **`GoogleConfigTests`**: verify `UserDefaults` override takes precedence over bundled ID; verify reset behavior.
- **Integration**: manual test with a real Google account in dev (requires a registered test client ID in Google Cloud Console).

---

## Out of Scope

- Gmail label sync (beyond existing `[Gmail]/` folder role mapping)
- Incremental contacts sync (`syncToken` pagination)
- Outlook OAuth (same pattern, separate feature)
- Re-sync contacts button in Settings
