# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
swift build                          # Build debug
swift run LiteMail                   # Run the app
swift run LiteMail --ui-review       # UI screenshot capture mode
swift test                           # Run all tests
swift test --filter MailStoreTests   # Run specific test class
```

- **Runtime:** macOS 14.0+, Swift 5.9+
- **Database:** `~/Library/Application Support/LiteMail/mail.sqlite`
- **Keychain service:** `com.litemail.auth`

## Architecture

LiteMail is a 3-pane macOS mail client (~5,600 LOC) using AppKit + Swift actors + GRDB + IMAP/JMAP.

```
GUI (AppKit) → AccountManager (MailEngineProtocol) → IMAPProvider / JMAPProvider
                                                    → MailStore (SQLite/GRDB)
                                                    → AuthManager (Keychain/OAuth2)
```

### Layers

| Layer | Location | Role |
|-------|----------|------|
| GUI | `Sources/LiteMail/GUI/` | AppKit views, 3-pane layout, WKWebView for HTML |
| App | `Sources/LiteMail/App/` | Entry point, AppDelegate, UIReviewRunner |
| Core | `Sources/LiteMail/Core/` | Mail engine, providers, storage, auth |

### Key Types

- **`MailEngineProtocol`** — high-level interface the GUI layer calls; implemented by `AccountManager`
- **`MailProvider`** — transport-agnostic actor protocol; implemented by `IMAPProvider` and `JMAPProvider`
- **`MailStore`** — SQLite actor (GRDB) with WAL mode; FTS5 full-text search; schema migrations v1→v2
- **`AuthManager`** — per-account Keychain storage; OAuth2 token refresh
- **`AutoDiscovery`** — provider presets → JMAP well-known → Mozilla autoconfig → manual fallback

### Data Model

- `EmailHeader` — lightweight (list view); `EmailBody` — lazy-loaded (detail view)
- Multi-account: all DB rows keyed by `account_id`; `AccountManager` routes by account
- SQLite tables: `emails`, `email_bodies`, `email_fts` (FTS5), `accounts`, `sync_state`, `outbox`, `labels`, `attachments`

### Concurrency

All Core types are Swift `actor`s. GUI callbacks are dispatched on `MainActor`. All I/O is async/await.

## Dependencies (Package.swift)

- **GRDB.swift** — SQLite with WAL + FTS5
- **SwiftMail** — IMAP/SMTP protocol
- **AppAuth-iOS** — OAuth2
- **swift-jmap-client** — JMAP (RFC 8620/8621) for Fastmail/Stalwart/Cyrus

## Tests

- `Tests/LiteMailTests/` — Unit tests: schema, email CRUD, search, contacts, OAuth, config
- `Tests/LiteMailIntegrationTests/` — Integration: AccountManager workflows with mock providers
- `Tests/LiteMailProtocolTests/` — Protocol: IMAP against Docker GreenMail + real account smoke
- `Tests/LiteMailGUITests/` — GUI: AppKit programmatic tests (sidebar, list, detail, composer, palette)

```bash
swift test --filter LiteMailTests               # Unit tests (~1s)
swift test --filter LiteMailIntegrationTests     # Integration (~2s)
swift test --filter LiteMailGUITests             # GUI (~5s)
swift test --filter LiteMailProtocolTests        # Protocol / requires Docker (~30s)
```

### Docker (for protocol tests)
```bash
docker compose -f docker-compose.test.yml up -d   # Start GreenMail
docker compose -f docker-compose.test.yml down     # Stop GreenMail
```

### Real account smoke tests
```bash
LITEMAIL_GMAIL_TEST=1 LITEMAIL_GMAIL_EMAIL=... LITEMAIL_GMAIL_PASSWORD=... swift test --filter GmailSmokeTests
LITEMAIL_JMAP_TEST=1 LITEMAIL_JMAP_EMAIL=... LITEMAIL_JMAP_URL=... LITEMAIL_JMAP_TOKEN=... swift test --filter JMAPSmokeTests
```
## Skill routing

When the user's request matches an available skill, ALWAYS invoke it using the Skill
tool as your FIRST action. Do NOT answer directly, do NOT use other tools first.
The skill has specialized workflows that produce better results than ad-hoc answers.

Key routing rules:
- Product ideas, "is this worth building", brainstorming → invoke office-hours
- Bugs, errors, "why is this broken", 500 errors → invoke investigate
- Ship, deploy, push, create PR → invoke ship
- QA, test the site, find bugs → invoke qa
- Code review, check my diff → invoke review
- Update docs after shipping → invoke document-release
- Weekly retro → invoke retro
- Design system, brand → invoke design-consultation
- Visual audit, design polish → invoke design-review
- Architecture review → invoke plan-eng-review
- Save progress, checkpoint, resume → invoke checkpoint
- Code quality, health check → invoke health
