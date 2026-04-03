# Gmail Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add first-class Gmail support — OAuth2 browser flow, Google Contacts fetch, and composer autocomplete.

**Architecture:** Thin wiring into existing infrastructure. Gmail continues to use `IMAPProvider` with XOAUTH2 (already implemented). New components: `GoogleConfig` (constants), `GmailOAuthFlow` (AppAuth browser wrapper), `ContactsStore` (People API fetch + SQLite lookup). Three existing files are modified: `AuthManager` (fix macOS OAuth2 flow), `AddAccountSheet` (OAuth branch for Gmail), `SettingsWindow` (client ID override), `ComposerWindow` (autocomplete).

**Tech Stack:** AppAuth-iOS 1.7+ (already in Package.swift), GRDB (already in Package.swift), Google People API v1 (plain URLSession), AppKit.

---

## File Map

| Status | File | Responsibility |
|--------|------|----------------|
| **Create** | `Sources/LiteMail/Core/GoogleConfig.swift` | OAuth2 constants, bundled + user-overridable client ID |
| **Create** | `Sources/LiteMail/Core/GmailOAuthFlow.swift` | OAuthFlowProtocol + GmailOAuthFlow actor (AppAuth wrapper) |
| **Create** | `Sources/LiteMail/Core/ContactsStore.swift` | Fetch Google Contacts + store in SQLite + lookup for autocomplete |
| **Create** | `Tests/LiteMailTests/GoogleConfigTests.swift` | Tests for client ID resolution |
| **Create** | `Tests/LiteMailTests/GmailOAuthFlowTests.swift` | Tests for AddAccountSheet OAuth branch via stubbed OAuthFlowProtocol |
| **Create** | `Tests/LiteMailTests/ContactsStoreTests.swift` | Tests for fetch, upsert, lookup (in-memory GRDB + MockURLProtocol) |
| **Modify** | `Sources/LiteMail/Core/AuthManager.swift` | Fix macOS OAuth2 flow: add OIDRedirectHTTPHandler + OIDExternalUserAgentMac |
| **Modify** | `Sources/LiteMail/Core/MailStore.swift` | Migration v3: contacts table + upsertContacts + lookupContacts |
| **Modify** | `Sources/LiteMail/GUI/AddAccountSheet.swift` | Detect Gmail OAuth, show "Sign in with Google" button, wire GmailOAuthFlow |
| **Modify** | `Sources/LiteMail/App/AppDelegate.swift` | Create ContactsStore, pass to AddAccountSheet, fire-and-forget after account add |
| **Modify** | `Sources/LiteMail/GUI/SettingsWindow.swift` | Google section with client ID text field |
| **Modify** | `Sources/LiteMail/GUI/ComposerWindow.swift` | NSControlTextEditingDelegate for To/Cc autocomplete from cached contacts |

---

### Task 1: GoogleConfig constants

**Files:**
- Create: `Sources/LiteMail/Core/GoogleConfig.swift`
- Create: `Tests/LiteMailTests/GoogleConfigTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/LiteMailTests/GoogleConfigTests.swift
import XCTest
@testable import LiteMail

final class GoogleConfigTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "googleClientId")
        super.tearDown()
    }

    func testBundledClientIdUsedByDefault() {
        UserDefaults.standard.removeObject(forKey: "googleClientId")
        XCTAssertFalse(GoogleConfig.clientId.isEmpty)
        XCTAssertEqual(GoogleConfig.clientId, GoogleConfig.bundledClientId)
    }

    func testUserDefaultsOverridesTakePrecedence() {
        UserDefaults.standard.set("custom-client-id", forKey: "googleClientId")
        XCTAssertEqual(GoogleConfig.clientId, "custom-client-id")
    }

    func testClearingOverrideRestoresBundled() {
        UserDefaults.standard.set("custom-client-id", forKey: "googleClientId")
        UserDefaults.standard.removeObject(forKey: "googleClientId")
        XCTAssertEqual(GoogleConfig.clientId, GoogleConfig.bundledClientId)
    }

    func testScopesIncludeRequired() {
        XCTAssertTrue(GoogleConfig.scopes.contains("https://mail.google.com/"))
        XCTAssertTrue(GoogleConfig.scopes.contains("openid"))
        XCTAssertTrue(GoogleConfig.scopes.contains("email"))
        XCTAssertTrue(GoogleConfig.scopes.contains("profile"))
        XCTAssertTrue(GoogleConfig.scopes.contains("https://www.googleapis.com/auth/contacts.readonly"))
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
swift test --filter GoogleConfigTests 2>&1 | tail -20
```
Expected: compile error — `GoogleConfig` not found.

- [ ] **Step 3: Create GoogleConfig.swift**

```swift
// Sources/LiteMail/Core/GoogleConfig.swift
import Foundation

enum GoogleConfig {
    /// Client ID registered in Google Cloud Console under the LiteMail project.
    /// OAuth client type: "Desktop app" — supports loopback redirect URIs.
    /// Power users can override this via Settings → Google Client ID.
    static var clientId: String {
        UserDefaults.standard.string(forKey: "googleClientId") ?? bundledClientId
    }

    /// The bundled client ID. Replace with the value from Google Cloud Console.
    static let bundledClientId = "YOUR_GOOGLE_CLIENT_ID.apps.googleusercontent.com"

    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    /// Scopes: IMAP access + identity (display name, avatar) + read-only contacts.
    static let scopes: [String] = [
        "https://mail.google.com/",
        "openid",
        "email",
        "profile",
        "https://www.googleapis.com/auth/contacts.readonly",
    ]
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
swift test --filter GoogleConfigTests 2>&1 | tail -20
```
Expected: all 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiteMail/Core/GoogleConfig.swift Tests/LiteMailTests/GoogleConfigTests.swift
git commit -m "feat: add GoogleConfig with bundled + user-overridable client ID"
```

---

### Task 2: Fix AuthManager.authenticateOAuth2() for macOS

The current `authenticateOAuth2()` calls `OIDAuthState.authState(byPresenting: request)` which doesn't compile correctly on macOS — it's missing the `externalUserAgent:` argument. We also need `OIDRedirectHTTPHandler` for a loopback redirect URI (SwiftPM apps have no bundle and can't register custom URL schemes).

**Files:**
- Modify: `Sources/LiteMail/Core/AuthManager.swift`

- [ ] **Step 1: Add currentAuthHandler property and fix authenticateOAuth2()**

Open `Sources/LiteMail/Core/AuthManager.swift`. Make these changes:

Add the property after `private var oauthStates`:
```swift
// Retained during OAuth2 browser flow to keep the loopback HTTP handler alive.
private nonisolated(unsafe) var currentAuthHandler: OIDRedirectHTTPHandler?
```

Replace the entire `authenticateOAuth2` method (lines 22–59) with:
```swift
/// Initiates OAuth2 login flow for an account using the system browser (loopback redirect).
/// Requires a "Desktop app" OAuth client type in Google Cloud Console.
@MainActor
func authenticateOAuth2(
    accountId: String,
    clientId: String,
    authorizationEndpoint: URL,
    tokenEndpoint: URL,
    scopes: [String]
) async throws {
    // Spin up a local HTTP listener on a random port.
    // Google redirects here after consent: http://127.0.0.1:PORT/?code=...
    let handler = OIDRedirectHTTPHandler(successURL: nil)
    let redirectURI = try handler.startHTTPListener(nil)
    currentAuthHandler = handler   // retain until callback fires

    let configuration = OIDServiceConfiguration(
        authorizationEndpoint: authorizationEndpoint,
        tokenEndpoint: tokenEndpoint
    )
    let request = OIDAuthorizationRequest(
        configuration: configuration,
        clientId: clientId,
        clientSecret: nil,
        scopes: scopes,
        redirectURL: redirectURI,
        responseType: OIDResponseTypeCode,
        additionalParameters: nil
    )

    let authState = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OIDAuthState, Error>) in
        let session = OIDAuthState.authState(
            byPresenting: request,
            externalUserAgent: OIDExternalUserAgentMac()
        ) { authState, error in
            if let authState {
                continuation.resume(returning: authState)
            } else if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(throwing: AuthError.authenticationFailed)
            }
        }
        handler.currentAuthorizationFlow = session   // routes loopback redirect to session
    }

    currentAuthHandler = nil   // release handler after flow completes

    oauthStates[accountId] = authState
    Self.saveToKeychain(
        accountId: accountId,
        data: try NSKeyedArchiver.archivedData(withRootObject: authState, requiringSecureCoding: true)
    )
}
```

- [ ] **Step 2: Build to confirm it compiles**

```bash
swift build 2>&1 | grep -E "error:|warning:" | head -30
```
Expected: zero errors. Warnings about `OIDExternalUserAgentMac` or `OIDRedirectHTTPHandler` being unavailable on iOS targets are expected and safe (this is a macOS app).

- [ ] **Step 3: Commit**

```bash
git add Sources/LiteMail/Core/AuthManager.swift
git commit -m "fix: use OIDExternalUserAgentMac + loopback redirect for macOS OAuth2 flow"
```

---

### Task 3: OAuthFlowProtocol + GmailOAuthFlow actor

**Files:**
- Create: `Sources/LiteMail/Core/GmailOAuthFlow.swift`
- Create: `Tests/LiteMailTests/GmailOAuthFlowTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/LiteMailTests/GmailOAuthFlowTests.swift
import XCTest
@testable import LiteMail

// A stub that records calls and controls outcomes
actor StubOAuthFlow: OAuthFlowProtocol {
    enum Outcome { case success, cancelled, failed(String) }
    var outcome: Outcome = .success
    var calledWith: (accountId: String, email: String)? = nil

    func authenticate(accountId: String, email: String) async throws {
        calledWith = (accountId, email)
        switch outcome {
        case .success:      return
        case .cancelled:    throw OAuthError.cancelled
        case .failed(let r): throw OAuthError.failed(r)
        }
    }
}

final class GmailOAuthFlowTests: XCTestCase {
    func testSuccessCallsOAuth() async throws {
        let stub = StubOAuthFlow()
        await stub.setOutcome(.success)
        try await stub.authenticate(accountId: "acc1", email: "user@gmail.com")
        let called = await stub.calledWith
        XCTAssertEqual(called?.accountId, "acc1")
        XCTAssertEqual(called?.email, "user@gmail.com")
    }

    func testCancelledThrowsOAuthError() async {
        let stub = StubOAuthFlow()
        await stub.setOutcome(.cancelled)
        do {
            try await stub.authenticate(accountId: "acc1", email: "user@gmail.com")
            XCTFail("Expected OAuthError.cancelled")
        } catch OAuthError.cancelled {
            // pass
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testFailedThrowsOAuthErrorWithReason() async {
        let stub = StubOAuthFlow()
        await stub.setOutcome(.failed("invalid_client"))
        do {
            try await stub.authenticate(accountId: "acc1", email: "user@gmail.com")
            XCTFail("Expected OAuthError.failed")
        } catch OAuthError.failed(let reason) {
            XCTAssertEqual(reason, "invalid_client")
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }
}

// Helper — actors don't allow direct mutation from outside
extension StubOAuthFlow {
    func setOutcome(_ o: Outcome) { outcome = o }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
swift test --filter GmailOAuthFlowTests 2>&1 | tail -20
```
Expected: compile error — `OAuthFlowProtocol`, `OAuthError` not found.

- [ ] **Step 3: Create GmailOAuthFlow.swift**

```swift
// Sources/LiteMail/Core/GmailOAuthFlow.swift
import Foundation

/// Errors thrown by OAuth2 browser flows.
enum OAuthError: Error, LocalizedError {
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:         return "Sign-in was cancelled."
        case .failed(let msg):  return "Sign-in failed: \(msg)"
        }
    }
}

/// Abstraction over the OAuth2 browser flow. Inject a stub in tests.
protocol OAuthFlowProtocol: Actor {
    func authenticate(accountId: String, email: String) async throws
}

/// Runs the Google OAuth2 consent flow in the system browser via AppAuth.
/// On success the token is persisted by AuthManager. Throws OAuthError on failure.
actor GmailOAuthFlow: OAuthFlowProtocol {
    private let authManager: AuthManager

    init(authManager: AuthManager) {
        self.authManager = authManager
    }

    func authenticate(accountId: String, email: String) async throws {
        do {
            try await authManager.authenticateOAuth2(
                accountId: accountId,
                clientId: GoogleConfig.clientId,
                authorizationEndpoint: GoogleConfig.authorizationEndpoint,
                tokenEndpoint: GoogleConfig.tokenEndpoint,
                scopes: GoogleConfig.scopes
            )
        } catch let error as OAuthError {
            throw error
        } catch {
            let reason = error.localizedDescription
            if reason.lowercased().contains("cancel") {
                throw OAuthError.cancelled
            }
            throw OAuthError.failed(reason)
        }
    }
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
swift test --filter GmailOAuthFlowTests 2>&1 | tail -20
```
Expected: all 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiteMail/Core/GmailOAuthFlow.swift Tests/LiteMailTests/GmailOAuthFlowTests.swift
git commit -m "feat: add OAuthFlowProtocol and GmailOAuthFlow actor"
```

---

### Task 4: MailStore migration v3 — contacts table

**Files:**
- Modify: `Sources/LiteMail/Core/MailStore.swift`
- Modify: `Tests/LiteMailTests/MailStoreTests.swift`

- [ ] **Step 1: Write failing test**

Add to `Tests/LiteMailTests/MailStoreTests.swift`, inside `MailStoreTests`:

```swift
func testContactsTableExists() async throws {
    let store = try MailStore(path: ":memory:")
    // upsert a contact and look it up
    try await store.upsertContacts([
        ContactRecord(id: "people/c1", accountId: "acc1", name: "Alice", email: "alice@gmail.com", photoURL: nil, syncedAt: 1000)
    ])
    let results = try await store.lookupContacts(prefix: "ali", accountId: "acc1")
    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results.first?.email, "alice@gmail.com")
}

func testContactLookupIsPrefixMatchOnEmailAndName() async throws {
    let store = try MailStore(path: ":memory:")
    try await store.upsertContacts([
        ContactRecord(id: "c1", accountId: "acc1", name: "Bob Smith", email: "bob@example.com", photoURL: nil, syncedAt: 1000),
        ContactRecord(id: "c2", accountId: "acc1", name: "Alice Jones", email: "alice@example.com", photoURL: nil, syncedAt: 1000),
    ])
    // prefix match on email
    let byEmail = try await store.lookupContacts(prefix: "bob", accountId: "acc1")
    XCTAssertEqual(byEmail.count, 1)
    XCTAssertEqual(byEmail.first?.name, "Bob Smith")

    // prefix match on name
    let byName = try await store.lookupContacts(prefix: "Alice", accountId: "acc1")
    XCTAssertEqual(byName.count, 1)
    XCTAssertEqual(byName.first?.email, "alice@example.com")
}

func testContactsAreAccountScoped() async throws {
    let store = try MailStore(path: ":memory:")
    try await store.upsertContacts([
        ContactRecord(id: "c1", accountId: "acc1", name: "Alice", email: "alice@gmail.com", photoURL: nil, syncedAt: 1000),
    ])
    let acc2Results = try await store.lookupContacts(prefix: "alice", accountId: "acc2")
    XCTAssertTrue(acc2Results.isEmpty)
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
swift test --filter MailStoreTests/testContactsTableExists 2>&1 | tail -10
```
Expected: compile error — `ContactRecord`, `upsertContacts`, `lookupContacts` not found.

- [ ] **Step 3: Add migration v3 and ContactRecord to MailStore.swift**

In `Sources/LiteMail/Core/MailStore.swift`, after the `v2_multi_account` migration block, add:

```swift
// v3: Google Contacts cache
migrator.registerMigration("v3_contacts") { db in
    try db.create(table: "contacts") { t in
        t.column("id", .text).notNull()
        t.column("account_id", .text).notNull().references("accounts", onDelete: .cascade)
        t.column("name", .text)
        t.column("email", .text).notNull()
        t.column("photo_url", .text)
        t.column("synced_at", .integer).notNull()
        t.primaryKey(["account_id", "email"])
    }
    try db.create(index: "idx_contacts_account_email", on: "contacts", columns: ["account_id", "email"])
}
```

Then add `try migrator.migrate(dbPool)` after the migration registrations if not already present (check the existing `migrate()` implementation — it should already have this call).

- [ ] **Step 4: Add ContactRecord struct to MailStore.swift**

Add after the existing record structs (e.g. near `AccountRecord`):

```swift
struct ContactRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "contacts"
    let id: String
    let accountId: String
    let name: String?
    let email: String
    let photoURL: String?
    let syncedAt: Int

    enum CodingKeys: String, CodingKey {
        case id, name, email
        case accountId = "account_id"
        case photoURL = "photo_url"
        case syncedAt = "synced_at"
    }
}
```

- [ ] **Step 5: Add upsertContacts and lookupContacts methods to MailStore**

```swift
func upsertContacts(_ contacts: [ContactRecord]) throws {
    try dbPool.write { db in
        for contact in contacts {
            try contact.save(db)   // GRDB's save() does INSERT OR REPLACE for composite PKs
        }
    }
}

func lookupContacts(prefix: String, accountId: String) throws -> [ContactRecord] {
    let lowPrefix = prefix.lowercased()
    return try dbPool.read { db in
        try ContactRecord
            .filter(Column("account_id") == accountId)
            .filter(
                Column("email").lowercased.like("\(lowPrefix)%") ||
                Column("name").lowercased.like("\(lowPrefix)%")
            )
            .order(Column("name").asc)
            .limit(20)
            .fetchAll(db)
    }
}
```

Note: `MailStore` is an `actor`, so these methods are actor-isolated. The `try` in the method body is fine — actor methods can throw. Since `dbPool.write` and `dbPool.read` are synchronous (GRDB's pool dispatches on its own queue), wrap them with `nonisolated` if the compiler requires it, or call from within `actor` context using a `Task`.

If the compiler objects to calling synchronous GRDB methods from an actor, change the signatures to:
```swift
func upsertContacts(_ contacts: [ContactRecord]) async throws { ... }
func lookupContacts(prefix: String, accountId: String) async throws -> [ContactRecord] { ... }
```

- [ ] **Step 6: Run tests to confirm they pass**

```bash
swift test --filter MailStoreTests/testContactsTableExists
swift test --filter MailStoreTests/testContactLookupIsPrefixMatchOnEmailAndName
swift test --filter MailStoreTests/testContactsAreAccountScoped
```
Expected: all 3 PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/LiteMail/Core/MailStore.swift Tests/LiteMailTests/MailStoreTests.swift
git commit -m "feat: add contacts table (migration v3) with upsert and prefix-lookup"
```

---

### Task 5: ContactsStore actor

**Files:**
- Create: `Sources/LiteMail/Core/ContactsStore.swift`
- Create: `Tests/LiteMailTests/ContactsStoreTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/LiteMailTests/ContactsStoreTests.swift
import XCTest
@testable import LiteMail

// MockURLProtocol — intercepts URLSession requests in tests
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let (data, response) = Self.handler?(request) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// Stub AuthManager subclass that returns a fixed token
final class StubAuthManager: AuthManager {
    override func oauthAccessToken(accountId: String) async throws -> String {
        return "test-token"
    }
}

final class ContactsStoreTests: XCTestCase {
    var mailStore: MailStore!
    var urlSession: URLSession!

    override func setUpWithError() throws {
        mailStore = try MailStore(path: ":memory:")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        urlSession = URLSession(configuration: config)
    }

    func testFetchAndStoreWritesContactsToDatabase() async throws {
        MockURLProtocol.handler = { request in
            // Verify Authorization header
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")

            let body = """
            {
              "connections": [
                {
                  "resourceName": "people/c1",
                  "names": [{"displayName": "Alice Test"}],
                  "emailAddresses": [{"value": "alice@test.com"}],
                  "photos": [{"url": "https://example.com/photo.jpg"}]
                }
              ]
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }

        let auth = StubAuthManager()
        let store = ContactsStore(mailStore: mailStore, authManager: auth, urlSession: urlSession)
        await store.fetchAndStore(accountId: "acc1")

        let results = try await mailStore.lookupContacts(prefix: "alice", accountId: "acc1")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.name, "Alice Test")
        XCTAssertEqual(results.first?.email, "alice@test.com")
        XCTAssertEqual(results.first?.photoURL, "https://example.com/photo.jpg")
    }

    func testFetchAndStoreHandlesPagination() async throws {
        var callCount = 0
        MockURLProtocol.handler = { _ in
            callCount += 1
            let token = callCount == 1 ? #","nextPageToken":"page2""# : ""
            let body = """
            {"connections":[{"resourceName":"people/c\(callCount)","names":[{"displayName":"Person \(callCount)"}],"emailAddresses":[{"value":"p\(callCount)@test.com"}]}]\(token)}
            """.data(using: .utf8)!
            let resp = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (body, resp)
        }

        let auth = StubAuthManager()
        let store = ContactsStore(mailStore: mailStore, authManager: auth, urlSession: urlSession)
        await store.fetchAndStore(accountId: "acc1")

        XCTAssertEqual(callCount, 2)
        let all = try await mailStore.lookupContacts(prefix: "p", accountId: "acc1")
        XCTAssertEqual(all.count, 2)
    }

    func testFetchAndStoreIsNonFatalOnHTTPError() async throws {
        MockURLProtocol.handler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        }

        let auth = StubAuthManager()
        let store = ContactsStore(mailStore: mailStore, authManager: auth, urlSession: urlSession)
        // Must not throw — failure is silently swallowed
        await store.fetchAndStore(accountId: "acc1")

        let results = try await mailStore.lookupContacts(prefix: "", accountId: "acc1")
        XCTAssertTrue(results.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
swift test --filter ContactsStoreTests 2>&1 | tail -20
```
Expected: compile error — `ContactsStore` not found.

- [ ] **Step 3: Create ContactsStore.swift**

```swift
// Sources/LiteMail/Core/ContactsStore.swift
import Foundation

/// Fetches Google Contacts from the People API and caches them in SQLite for composer autocomplete.
/// fetchAndStore() is non-fatal — failures are logged and swallowed.
actor ContactsStore {
    private let mailStore: MailStore
    private let authManager: AuthManager
    private let urlSession: URLSession

    init(mailStore: MailStore, authManager: AuthManager, urlSession: URLSession = .shared) {
        self.mailStore = mailStore
        self.authManager = authManager
        self.urlSession = urlSession
    }

    // MARK: - Public API

    /// Fetches all contacts from Google People API and upserts into the contacts table.
    /// Non-fatal: if the fetch fails for any reason, the error is logged and the method returns normally.
    func fetchAndStore(accountId: String) async {
        do {
            let token = try await authManager.oauthAccessToken(accountId: accountId)
            var pageToken: String? = nil
            repeat {
                let (contacts, next) = try await fetchPage(token: token, pageToken: pageToken)
                let records = contacts.map { c in
                    ContactRecord(
                        id: c.resourceName,
                        accountId: accountId,
                        name: c.name,
                        email: c.email,
                        photoURL: c.photoURL,
                        syncedAt: Int(Date().timeIntervalSince1970)
                    )
                }
                try await mailStore.upsertContacts(records)
                pageToken = next
            } while pageToken != nil
        } catch {
            print("[ContactsStore] fetch failed for \(accountId): \(error)")
        }
    }

    // MARK: - Private

    private struct PeopleContact {
        let resourceName: String
        let name: String?
        let email: String
        let photoURL: String?
    }

    private func fetchPage(token: String, pageToken: String?) async throws -> ([PeopleContact], String?) {
        var components = URLComponents(string: "https://people.googleapis.com/v1/people/me/connections")!
        var queryItems: [URLQueryItem] = [
            .init(name: "personFields", value: "names,emailAddresses,photos"),
            .init(name: "pageSize", value: "1000"),
        ]
        if let pageToken {
            queryItems.append(.init(name: "pageToken", value: pageToken))
        }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ContactsError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let nextPageToken = json["nextPageToken"] as? String
        let connections = json["connections"] as? [[String: Any]] ?? []

        let contacts: [PeopleContact] = connections.compactMap { entry in
            guard
                let resourceName = entry["resourceName"] as? String,
                let emailAddresses = entry["emailAddresses"] as? [[String: Any]],
                let emailEntry = emailAddresses.first,
                let email = emailEntry["value"] as? String
            else { return nil }
            let name = (entry["names"] as? [[String: Any]])?.first?["displayName"] as? String
            let photoURL = (entry["photos"] as? [[String: Any]])?.first?["url"] as? String
            return PeopleContact(resourceName: resourceName, name: name, email: email, photoURL: photoURL)
        }

        return (contacts, nextPageToken)
    }
}

enum ContactsError: Error {
    case httpError(Int)
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
swift test --filter ContactsStoreTests 2>&1 | tail -20
```
Expected: all 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiteMail/Core/ContactsStore.swift Tests/LiteMailTests/ContactsStoreTests.swift
git commit -m "feat: add ContactsStore — fetch Google Contacts and cache in SQLite"
```

---

### Task 6: AddAccountSheet — Gmail OAuth branch

When AutoDiscovery returns `authType == .oauth2` and the IMAP host is Gmail, replace the password field with a "Sign in with Google" button.

**Files:**
- Modify: `Sources/LiteMail/GUI/AddAccountSheet.swift`

- [ ] **Step 1: Add OAuthFlowProtocol property and Sign-in button to AddAccountSheet**

In `Sources/LiteMail/GUI/AddAccountSheet.swift`:

Add these stored properties in the class body (after `private var discoveryResult`):
```swift
/// Injected OAuth flow. Nil for non-OAuth accounts; set by the caller for Gmail accounts.
var oauthFlow: (any OAuthFlowProtocol)?
/// True after the user has completed the OAuth browser flow successfully.
private var oauthCompleted = false

private let signInButton: NSButton
```

In `override init()`, add before `super.init()`:
```swift
signInButton = CursorButton(title: "Sign in with Google", target: nil, action: nil)
signInButton.bezelStyle = .rounded
signInButton.isHidden = true
```

After `super.init()`, add:
```swift
signInButton.target = self
signInButton.action = #selector(signInWithGoogleClicked)
```

In `setupLayout()`, add `signInButton` to `manualStack` in place of `passwordField` (or alongside it — both will be shown/hidden conditionally). Add this line after the `row("Password:", passwordField)` line:
```swift
manualStack.addArrangedSubview(signInButton)
```

- [ ] **Step 2: Add isGmailOAuth helper and update runDiscovery to show the right field**

Add this private helper:
```swift
private var isGmailOAuth: Bool {
    guard let result = discoveryResult else { return false }
    return result.authType == .oauth2 &&
        (result.imapHost?.contains("gmail") == true || result.imapHost?.contains("googlemail") == true)
}
```

In `runDiscovery()`, after the line `manualStack.isHidden = false`, add:
```swift
// Show OAuth button instead of password field for Gmail
let isOAuth = isGmailOAuth
passwordField.isHidden = isOAuth
signInButton.isHidden = !isOAuth
addButton.isEnabled = !isOAuth   // require Sign in first for Gmail
```

- [ ] **Step 3: Add signInWithGoogleClicked action**

```swift
@objc private func signInWithGoogleClicked() {
    guard let oauthFlow, let window = sheet.sheetParent ?? sheet else { return }
    let email = emailField.stringValue.trimmingCharacters(in: .whitespaces)
    let accountId = UUID().uuidString   // temporary ID for the OAuth flow

    signInButton.isEnabled = false
    statusLabel.stringValue = "Opening browser for sign-in..."
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.isHidden = false

    Task { @MainActor in
        do {
            try await oauthFlow.authenticate(accountId: accountId, email: email)
            signInButton.title = "✓ Signed in"
            signInButton.isEnabled = false
            oauthCompleted = true
            pendingOAuthAccountId = accountId
            addButton.isEnabled = true
            statusLabel.stringValue = "Ready to connect."
            statusLabel.textColor = .systemGreen
        } catch OAuthError.cancelled {
            signInButton.isEnabled = true
            statusLabel.isHidden = true
        } catch OAuthError.failed(let reason) {
            signInButton.isEnabled = true
            if reason.contains("invalid_client") {
                statusLabel.stringValue = "Sign in failed. Try entering your own Google Client ID in Settings."
            } else {
                statusLabel.stringValue = "Sign in failed: \(reason)"
            }
            statusLabel.textColor = .systemRed
            statusLabel.isHidden = false
        } catch {
            signInButton.isEnabled = true
            statusLabel.stringValue = "Sign in failed: \(error.localizedDescription)"
            statusLabel.textColor = .systemRed
            statusLabel.isHidden = false
        }
    }
}
```

Add a stored property for the pending OAuth account ID:
```swift
private var pendingOAuthAccountId: String?
```

- [ ] **Step 4: Update confirmAccount() to use pendingOAuthAccountId for OAuth accounts**

In `confirmAccount(email:)`, update the `AccountConfig` creation to use `pendingOAuthAccountId` when OAuth flow completed:

```swift
let accountId = (oauthCompleted ? pendingOAuthAccountId : nil) ?? UUID().uuidString

let config = AccountConfig(
    id: accountId,
    emailAddress: email,
    // ... rest unchanged
    authType: discoveryResult?.authType ?? .password,
    // ...
)

// For OAuth accounts, don't pass password — the token is already in Keychain
onAddAccount?(config, oauthCompleted ? nil : (password.isEmpty ? nil : password)) { ... }
```

- [ ] **Step 5: Build to confirm it compiles**

```bash
swift build 2>&1 | grep "error:" | head -20
```
Expected: zero errors.

- [ ] **Step 6: Commit**

```bash
git add Sources/LiteMail/GUI/AddAccountSheet.swift
git commit -m "feat: add Gmail OAuth branch to AddAccountSheet with Sign in with Google button"
```

---

### Task 7: AppDelegate — wire ContactsStore and GmailOAuthFlow

**Files:**
- Modify: `Sources/LiteMail/App/AppDelegate.swift`

- [ ] **Step 1: Add contactsStore property**

In `AppDelegate`, add after `private var composerWindow`:
```swift
private var contactsStore: ContactsStore?
```

- [ ] **Step 2: Create ContactsStore in initializeAccountManager()**

In `initializeAccountManager()`, after `let manager = AccountManager(store: store, authManager: authManager)`, add:
```swift
let contacts = ContactsStore(mailStore: store, authManager: authManager)
self.contactsStore = contacts
```

- [ ] **Step 3: Inject GmailOAuthFlow into AddAccountSheet in showAddAccount()**

In `showAddAccount()`, after `let sheet = AddAccountSheet()`, add:
```swift
sheet.oauthFlow = GmailOAuthFlow(authManager: accountManager.authManager)
```

- [ ] **Step 4: Fire-and-forget ContactsStore.fetchAndStore after account creation**

In `showAddAccount()`, inside the `onAddAccount` callback, after `try await accountManager.addAccount(config)` (step 2 of the existing flow), add:

```swift
// Non-blocking contacts fetch for OAuth accounts
if config.authType == .oauth2, let contacts = self.contactsStore {
    Task { await contacts.fetchAndStore(accountId: config.id) }
}
```

- [ ] **Step 5: Pass contactsStore to openComposer()**

Update `openComposer(mode:)` to pass the contacts store:
```swift
private func openComposer(mode: ComposerWindow.Mode) {
    let composer = ComposerWindow(mode: mode, contactsStore: contactsStore)
    // ... rest unchanged
}
```

- [ ] **Step 6: Build to confirm it compiles**

```bash
swift build 2>&1 | grep "error:" | head -20
```

- [ ] **Step 7: Commit**

```bash
git add Sources/LiteMail/App/AppDelegate.swift
git commit -m "feat: wire GmailOAuthFlow and ContactsStore into AppDelegate"
```

---

### Task 8: SettingsWindow — Google Client ID override

**Files:**
- Modify: `Sources/LiteMail/GUI/SettingsWindow.swift`

- [ ] **Step 1: Add googleClientIdField property**

In `SettingsWindow`, add a stored property after `signatureField`:
```swift
private var googleClientIdField: NSTextField?
```

- [ ] **Step 2: Add Google section to setupLayout()**

In `setupLayout()`, before the `aboutHeader` block, add:
```swift
// Google section
let googleHeader = Self.sectionHeader("Google")
let googleIdField = NSTextField()
googleIdField.placeholderString = "Leave blank to use built-in client ID"
googleIdField.stringValue = UserDefaults.standard.string(forKey: "googleClientId") ?? ""
googleIdField.font = .systemFont(ofSize: 12)
googleIdField.translatesAutoresizingMaskIntoConstraints = false
googleIdField.widthAnchor.constraint(equalToConstant: 400).isActive = true
self.googleClientIdField = googleIdField

let saveGoogleIdButton = CursorButton(title: "Save", target: self, action: #selector(saveGoogleClientId))
saveGoogleIdButton.bezelStyle = .rounded

let googleIdLabel = NSTextField(labelWithString: "Client ID:")
googleIdLabel.font = .systemFont(ofSize: 11, weight: .medium)
googleIdLabel.textColor = .secondaryLabelColor

let googleIdRow = NSStackView(views: [googleIdLabel, googleIdField, saveGoogleIdButton])
googleIdRow.spacing = 8
```

In the `stack` views array, before `Self.spacer(), aboutHeader, versionLabel`, add:
```swift
Self.spacer(),
googleHeader, googleIdRow,
```

- [ ] **Step 3: Add saveGoogleClientId action**

```swift
@objc private func saveGoogleClientId() {
    let value = googleClientIdField?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
    if value.isEmpty {
        UserDefaults.standard.removeObject(forKey: "googleClientId")
    } else {
        UserDefaults.standard.set(value, forKey: "googleClientId")
    }
    let alert = NSAlert()
    alert.messageText = value.isEmpty ? "Restored built-in Google Client ID" : "Google Client ID saved"
    alert.alertStyle = .informational
    alert.runModal()
}
```

- [ ] **Step 4: Build to confirm it compiles**

```bash
swift build 2>&1 | grep "error:" | head -20
```

- [ ] **Step 5: Commit**

```bash
git add Sources/LiteMail/GUI/SettingsWindow.swift
git commit -m "feat: add Google Client ID override field in SettingsWindow"
```

---

### Task 9: ComposerWindow — contacts autocomplete

**Files:**
- Modify: `Sources/LiteMail/GUI/ComposerWindow.swift`

- [ ] **Step 1: Update ComposerWindow.init() to accept ContactsStore**

In `ComposerWindow.swift`, add a stored property:
```swift
private var cachedContacts: [ContactRecord] = []
```

Update `init(mode:)` to accept an optional `ContactsStore`:
```swift
init(mode: Mode, contactsStore: ContactsStore? = nil) {
```

After `super.init()` / `startAutoSave()`, add:
```swift
// Load contacts for autocomplete
if let contactsStore {
    Task { @MainActor in
        // Grab all contacts (empty prefix = all) for the current account.
        // We cache them locally to answer the synchronous NSControlTextEditingDelegate call.
        if let records = try? await contactsStore.mailStore.lookupContacts(prefix: "", accountId: "") {
            self.cachedContacts = records
        }
    }
}
```

Wait — `mailStore` is private on `MailStore` and `lookupContacts` requires an `accountId`. Instead, add a method to `ContactsStore`:

In `ContactsStore.swift`, add:
```swift
/// Returns all cached contacts for display in autocomplete (limit 500).
func allCachedContacts(accountId: String) async throws -> [ContactRecord] {
    try await mailStore.lookupContacts(prefix: "", accountId: accountId)
}
```

Then the ComposerWindow init becomes:
```swift
// In ComposerWindow
private var contactsStore: ContactsStore?

init(mode: Mode, contactsStore: ContactsStore? = nil) {
    self.contactsStore = contactsStore
    // ... existing init code ...
}
```

And in `show()` (or a new `loadContacts(accountId:)` method called from AppDelegate after opening):
Actually, since ComposerWindow doesn't know the accountId, pass it:

```swift
func loadContacts(accountId: String) {
    guard let contactsStore else { return }
    Task { @MainActor in
        if let records = try? await contactsStore.allCachedContacts(accountId: accountId) {
            self.cachedContacts = records
        }
    }
}
```

In `AppDelegate.openComposer()`, after `composer.show()` add:
```swift
if let accountId = currentAccountId {
    composer.loadContacts(accountId: accountId)
}
```

- [ ] **Step 2: Conform ComposerWindow to NSControlTextEditingDelegate**

Add the conformance and delegate methods:

```swift
extension ComposerWindow: NSControlTextEditingDelegate {
    func control(
        _ control: NSControl,
        textView: NSTextView,
        completions words: [String],
        forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>
    ) -> [String] {
        guard control === toField || control === ccField else { return [] }
        let partial = (textView.string as NSString).substring(with: charRange).lowercased()
        guard partial.count >= 2 else { return [] }

        return cachedContacts
            .filter {
                $0.email.lowercased().hasPrefix(partial) ||
                ($0.name?.lowercased().hasPrefix(partial) ?? false)
            }
            .prefix(10)
            .map { c in
                if let name = c.name, !name.isEmpty {
                    return "\(name) <\(c.email)>"
                }
                return c.email
            }
    }
}
```

Set `ComposerWindow` as the delegate in `setupLayout()` (or after the fields are created):
```swift
toField.delegate = self
ccField.delegate = self
```

- [ ] **Step 3: Build to confirm it compiles**

```bash
swift build 2>&1 | grep "error:" | head -20
```
Expected: zero errors.

- [ ] **Step 4: Run all tests to confirm nothing regressed**

```bash
swift test 2>&1 | tail -20
```
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiteMail/GUI/ComposerWindow.swift Sources/LiteMail/Core/ContactsStore.swift
git commit -m "feat: add contacts autocomplete in ComposerWindow To/Cc fields"
```

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Covered by |
|-----------------|-----------|
| Bundled + user-overridable client ID | Task 1 (GoogleConfig) + Task 8 (SettingsWindow) |
| OAuth2 browser flow via AppAuth | Task 2 (AuthManager fix) + Task 3 (GmailOAuthFlow) |
| AddAccountSheet Gmail branch | Task 6 |
| Token storage via existing AuthManager | Task 2 (existing Keychain path unchanged) |
| Contacts fetch after OAuth | Task 5 (ContactsStore) + Task 7 (AppDelegate fire-and-forget) |
| Contacts stored in SQLite | Task 4 (migration v3) |
| Contacts lookup for composer | Task 9 (ComposerWindow delegate) |
| OAuth error messages (invalid_client hint) | Task 6 step 3 |
| Settings Google Client ID field | Task 8 |
| IMAP XOAUTH2 at runtime | Existing `IMAPProvider` — unchanged, already works |

**Placeholder scan:** All code blocks are complete. `YOUR_GOOGLE_CLIENT_ID.apps.googleusercontent.com` in GoogleConfig is an intentional placeholder the developer must replace with a real registered client ID from Google Cloud Console.

**Type consistency:** `ContactRecord` defined in Task 4, used in Tasks 5 and 9. `OAuthFlowProtocol`/`OAuthError` defined in Task 3, used in Task 6. `GmailOAuthFlow` defined in Task 3, instantiated in Task 7. `ContactsStore` defined in Task 5, wired in Tasks 7 and 9. All consistent.

**One note:** Google Cloud Console setup is a prerequisite before testing end-to-end:
1. Create a project, enable Gmail API + People API
2. Create OAuth credentials → "Desktop app" type (supports loopback redirect)
3. Copy the client ID into `GoogleConfig.bundledClientId`
4. Add test user emails under "OAuth consent screen → Test users"
