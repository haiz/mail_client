# E2E Testing Design — LiteMail

**Date:** 2026-04-09
**Status:** Approved

## Overview

Comprehensive E2E testing for LiteMail across three layers: integration tests with mock providers, protocol tests against real IMAP servers (Docker + real accounts), and GUI tests with programmatic AppKit interaction + screenshot regression.

## Goals

1. Test all ~30+ features through realistic workflows
2. Catch regressions in core logic, protocol handling, and UI
3. Keep fast tests fast (integration <2s, GUI <10s) and isolate slow tests (protocol <30s)
4. Enable CI-safe testing (Docker layer skippable via env vars)

## Non-Goals

- XCUITest (requires separate UI test target, accessibility IDs, heavy infrastructure)
- Testing third-party library internals (GRDB, SwiftMail, AppAuth)
- 100% line coverage — focus on workflow coverage

---

## Architecture

### Test Targets

```
Tests/
├── LiteMailTests/              # Existing unit tests (unchanged)
├── LiteMailIntegrationTests/   # Core workflow E2E with mock providers
├── LiteMailProtocolTests/      # Real IMAP/JMAP server tests
└── LiteMailGUITests/           # AppKit programmatic + screenshot regression
```

### Dependency Graph

```
Integration:  MockMailProvider → AccountManager → MailStore(:memory:) → assertions
Protocol:     IMAPProvider → Docker GreenMail (localhost:3143) → assertions
              IMAPProvider → Real Gmail (manual smoke) → assertions
GUI:          MainWindowController + MockMailEngine → simulate interactions → assert state
              UIReviewRunner → capture screenshots → diff against baselines
```

### Running Tests

```bash
swift test --filter LiteMailTests              # Existing unit tests (~1s)
swift test --filter LiteMailIntegrationTests    # Core E2E with mocks (~2s)
swift test --filter LiteMailGUITests            # AppKit + screenshots (~10s)
swift test --filter LiteMailProtocolTests       # Requires Docker (~30s)
swift test                                      # All of the above
```

---

## Layer 1: Integration Tests

Test `AccountManager` → `MailStore` workflows using `MockMailProvider`. Real `:memory:` SQLite database — no mock store.

### Mock Infrastructure

**`MockMailProvider`** — actor conforming to `MailProvider`:
- Pre-configured responses: folders, messages, bodies, attachments
- Call recording (spy pattern) for assertion
- Configurable failures: throw on connect, fail mid-sync, timeout
- Simulated latency and partial results

### Test Suites

#### Suite 1: Account Lifecycle
| Test | Description |
|------|-------------|
| `testAddAccount` | Add account → verify stored in DB + provider instantiated |
| `testMultipleAccounts` | Add 2 accounts → verify isolation (different providers) |
| `testRemoveAccountCascade` | Remove account → cascade delete emails, sync state, outbox, labels, attachments |
| `testAddAccountDiscoveryFailure` | Auto-discovery failure → graceful error |

#### Suite 2: Sync Workflows
| Test | Description |
|------|-------------|
| `testInitialSync` | Folders created + headers stored + FTS indexed |
| `testIncrementalSync` | Only new messages fetched, existing untouched |
| `testSyncUidDedup` | Same UID in same folder ignored |
| `testSyncAccountIsolation` | Messages isolated by account_id |
| `testSyncFailureMidway` | Partial data preserved, no corruption |
| `testGmailMultiLabel` | Same message in multiple folders allowed |

#### Suite 3: Email Read Operations
| Test | Description |
|------|-------------|
| `testFetchHeadersPagination` | Offset/limit pagination works correctly |
| `testFetchBodyCaching` | First fetch hits provider, second hits DB cache |
| `testFetchThread` | Returns all messages in thread, ordered |
| `testSearchFTS5` | Matches subject, body, sender |
| `testCrossAccountSearch` | Returns results from all accounts |
| `testSearchEmpty` | Empty query returns nothing |

#### Suite 4: Email Actions
| Test | Description |
|------|-------------|
| `testMarkReadUnread` | DB updated + provider called |
| `testMarkStarred` | DB updated + provider called |
| `testArchive` | Moved to All Mail + provider called |
| `testDelete` | Marked deleted + provider called |
| `testMoveToFolder` | Folder updated + provider called |
| `testAddRemoveLabel` | DB updated + provider called |

#### Suite 5: Compose & Send
| Test | Description |
|------|-------------|
| `testComposeSend` | provider.send() called with correct OutgoingMessage |
| `testSaveDraft` | Outbox entry with status "drafted" |
| `testDraftStatusTransitions` | drafted → sending → sent |
| `testReply` | inReplyTo header set, recipients pre-filled |
| `testForward` | Body includes original, attachments carried over |
| `testSendFailure` | Outbox status "failed", message preserved |

#### Suite 6: Attachments
| Test | Description |
|------|-------------|
| `testListAttachments` | Returns correct metadata |
| `testFetchAttachmentData` | Provider called with correct partId |
| `testNoAttachments` | Returns empty list |

#### Suite 7: Folders & Labels
| Test | Description |
|------|-------------|
| `testListFolders` | Standard + custom folders with unread counts |
| `testCreateFolder` | Stored in DB |
| `testAllLabels` | Returns full list for account |
| `testFetchLabelsForEmail` | Returns correct labels |

---

## Layer 2: Protocol Tests

### Docker Infrastructure

**GreenMail** (Java-based test mail server):

```yaml
# docker-compose.test.yml
services:
  greenmail:
    image: greenmail/standalone:2.0.1
    ports:
      - "3143:3143"   # IMAP
      - "3025:3025"   # SMTP
    environment:
      - GREENMAIL_OPTS=-Dgreenmail.setup.test.all -Dgreenmail.users=test@localhost.com:password123
```

### Test Helpers

- **`DockerHelper`** — starts/stops GreenMail container, waits for port availability
- **`SMTPSeeder`** — sends test emails into GreenMail via SMTP for test setup
- Credentials loaded from env vars, never hardcoded

### Test Suites

#### Suite 1: IMAP Connection & Auth
| Test | Description |
|------|-------------|
| `testConnectValid` | Valid credentials → isConnected = true |
| `testConnectBadCredentials` | Bad password → throws auth error |
| `testConnectWrongHost` | Wrong host → throws connection error |
| `testDisconnect` | Clean teardown, isConnected = false |

#### Suite 2: IMAP Sync
| Test | Description |
|------|-------------|
| `testInitialSyncEmpty` | Empty mailbox → zero messages, folders exist |
| `testInitialSyncWithEmails` | Seed 10 via SMTP → sync → 10 headers in store |
| `testIncrementalSync` | 5 new emails after initial → only 5 new fetched |
| `testUidValidityChange` | UID validity change → full re-sync |

#### Suite 3: IMAP Operations
| Test | Description |
|------|-------------|
| `testFetchBody` | Returns text/html parts |
| `testMarkRead` | \Seen flag updated on server |
| `testMarkStarred` | \Flagged flag updated on server |
| `testMoveMessage` | COPY + DELETE on server |
| `testDeleteMessage` | \Deleted + EXPUNGE |
| `testSendViaSMTP` | Message appears in recipient INBOX |

#### Suite 4: IMAP Edge Cases
| Test | Description |
|------|-------------|
| `testLargeAttachment` | >1MB fetch succeeds |
| `testConnectionDropReconnect` | Drop mid-sync → reconnect + resume |
| `testConcurrentFolderSync` | Multiple folders sync in parallel |
| `testUTF7FolderNames` | Special characters handled |

### Real Account Smoke Tests

Guarded by environment variable — skipped in CI:

```swift
func testRealGmailSync() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["LITEMAIL_GMAIL_TEST"] != nil)
}
```

#### Gmail Smoke
| Test | Description |
|------|-------------|
| `testGmailOAuthSync` | OAuth connect → initial sync → verify real folders |
| `testGmailSearch` | FTS5 results match real emails |
| `testGmailSend` | Send test email → appears in Sent |
| `testGmailLabels` | Multi-label messages handled correctly |

#### JMAP Smoke (Fastmail/Stalwart)
| Test | Description |
|------|-------------|
| `testJMAPSync` | Connect → initial sync → verify folders |
| `testJMAPDeltaSync` | State token delta sync |

---

## Layer 3: GUI Tests

### Mock Infrastructure

**`MockMailEngine`** — implements `MailEngineProtocol`:
- Pre-loaded accounts, folders, headers, bodies
- Call recording (spy) for action verification
- Configurable delays/failures

### Programmatic AppKit Tests

Instantiate real AppKit views with `MockMailEngine`, assert state changes.

#### Suite 1: Sidebar Interactions
| Test | Description |
|------|-------------|
| `testSidebarShowsAccounts` | 2 accounts → both visible in sidebar |
| `testSelectFolder` | Select folder → message list refreshes |
| `testComposeButton` | Click → composer window opens |
| `testRefreshButton` | Click → syncAllAccounts() called |
| `testAuthErrorIndicator` | Auth error → "fix sign-in" visible |

#### Suite 2: Message List
| Test | Description |
|------|-------------|
| `testLoadEmails` | 50 emails → 50 rows in table |
| `testSelectEmail` | Select → detail view populated |
| `testSearchField` | Input → search() called, results displayed |
| `testEmptyFolder` | Empty state message shown |
| `testThreadGrouping` | Collapsed rows with count badge |

#### Suite 3: Detail View
| Test | Description |
|------|-------------|
| `testPlainTextEmail` | NSTextView shows body |
| `testHTMLEmail` | WKWebView loads content |
| `testEmptyState` | "No message selected" shown |
| `testReplyButton` | Composer opens with pre-filled fields |
| `testForwardButton` | Composer opens with original body |
| `testArchiveButton` | archive() called on engine |
| `testDeleteButton` | delete() called on engine |
| `testAttachmentBar` | Attachment chips visible |

#### Suite 4: Composer
| Test | Description |
|------|-------------|
| `testNewCompose` | Empty fields, From dropdown shows accounts |
| `testReplyCompose` | To/Subject/inReplyTo pre-filled |
| `testForwardCompose` | Subject "Fwd:" prefix, body includes original |
| `testSendButton` | send() called with correct OutgoingMessage |
| `testCloseWithoutSending` | Draft saved to outbox |

#### Suite 5: Command Palette
| Test | Description |
|------|-------------|
| `testOpenPalette` | Cmd+K → palette appears |
| `testSearchFilter` | Type → results filtered |
| `testExecuteAction` | Select → action executed on engine |

### Screenshot Regression

Extends existing `UIReviewRunner` with automated diffing.

**Baseline Management:**
```bash
# Capture new baselines
swift test --filter LiteMailGUITests -- --update-baselines
```
Saves PNGs to `Tests/LiteMailGUITests/Baselines/`.

**Regression Check:**
- Capture current screenshot for each state
- Pixel-diff against baseline (tolerance: 1% for anti-aliasing variations)
- On mismatch: save diff image + fail test with path to diff

**Screenshot States:**
| State | Description |
|-------|-------------|
| `empty_window` | No accounts configured |
| `three_pane_plaintext` | Full layout with plain text email selected |
| `three_pane_html` | Full layout with HTML email selected |
| `composer_new` | New compose window |
| `composer_reply` | Reply compose window |
| `composer_forward` | Forward compose window |
| `settings_window` | Settings panel |
| `command_palette` | Command palette open |
| `empty_message_list` | Folder with no emails |
| `sidebar_multi_account` | Multiple accounts in sidebar |

---

## Priority Order

1. **Integration tests** — highest value, fastest feedback loop
2. **Protocol tests (Docker)** — catches real IMAP bugs
3. **GUI programmatic tests** — catches interaction regressions
4. **Screenshot regression** — catches visual regressions
5. **Real account smoke tests** — manual validation

---

## Test Count Summary

| Layer | Suites | Test Cases |
|-------|--------|------------|
| Integration | 7 | 30 |
| Protocol (Docker) | 4 | 14 |
| Protocol (Smoke) | 2 | 6 |
| GUI Programmatic | 5 | 21 |
| GUI Screenshot | 1 | 10 |
| **Total** | **19** | **81** |

---

## Files to Create/Modify

### New Files
- `Tests/LiteMailIntegrationTests/MockMailProvider.swift`
- `Tests/LiteMailIntegrationTests/AccountLifecycleTests.swift`
- `Tests/LiteMailIntegrationTests/SyncWorkflowTests.swift`
- `Tests/LiteMailIntegrationTests/EmailReadTests.swift`
- `Tests/LiteMailIntegrationTests/EmailActionTests.swift`
- `Tests/LiteMailIntegrationTests/ComposeTests.swift`
- `Tests/LiteMailIntegrationTests/AttachmentTests.swift`
- `Tests/LiteMailIntegrationTests/FolderLabelTests.swift`
- `Tests/LiteMailProtocolTests/DockerHelper.swift`
- `Tests/LiteMailProtocolTests/SMTPSeeder.swift`
- `Tests/LiteMailProtocolTests/IMAPConnectionTests.swift`
- `Tests/LiteMailProtocolTests/IMAPSyncTests.swift`
- `Tests/LiteMailProtocolTests/IMAPOperationTests.swift`
- `Tests/LiteMailProtocolTests/IMAPEdgeCaseTests.swift`
- `Tests/LiteMailProtocolTests/GmailSmokeTests.swift`
- `Tests/LiteMailProtocolTests/JMAPSmokeTests.swift`
- `Tests/LiteMailGUITests/MockMailEngine.swift`
- `Tests/LiteMailGUITests/SidebarTests.swift`
- `Tests/LiteMailGUITests/MessageListTests.swift`
- `Tests/LiteMailGUITests/DetailViewTests.swift`
- `Tests/LiteMailGUITests/ComposerTests.swift`
- `Tests/LiteMailGUITests/CommandPaletteTests.swift`
- `Tests/LiteMailGUITests/ScreenshotRegressionTests.swift`
- `Tests/LiteMailGUITests/ScreenshotDiffer.swift`
- `Tests/LiteMailGUITests/Baselines/` (directory for baseline PNGs)
- `docker-compose.test.yml`

### Modified Files
- `Package.swift` — add 3 new test targets
