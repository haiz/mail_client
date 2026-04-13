# Bulk Email Operations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add multi-select checkboxes, batch operations (delete, archive, mark read/unread, star, move), undo toast with 10-second countdown, and thread-aware batch expansion to LiteMail.

**Architecture:** Vertical slice through every layer: MailStore batch SQL → MailProvider batch protocol → IMAPProvider/JMAPProvider implementations → AccountManager cross-account routing → MailAction enum → GUI (checkboxes, toolbar, undo toast, detail summary, animations). Optimistic UI: local DB updates immediately, server sync fires in background Tasks.

**Tech Stack:** Swift 5.9, AppKit, GRDB (SQLite), SwiftMail (IMAP), swift-jmap-client (JMAP)

**Design Doc:** `~/.gstack/projects/mail_client/haicao-main-design-20260409-232535.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `Sources/LiteMail/Core/MailStore.swift` | Modify | Add 7 batch SQL methods + fix fetchThread filter |
| `Sources/LiteMail/Core/MailProvider.swift` | Modify | Add 4 batch protocol methods |
| `Sources/LiteMail/Core/IMAPProvider.swift` | Modify | Add 4 batch IMAP implementations |
| `Sources/LiteMail/Core/JMAPProvider.swift` | Modify | Add batch emailSetBatch helper + 4 implementations |
| `Sources/LiteMail/Core/AccountManager.swift` | Modify | Add 5 batch routing methods + resolveArchiveFolder |
| `Sources/LiteMail/Core/MailEngineProtocol.swift` | Modify | Add 5 batch protocol methods |
| `Sources/LiteMail/GUI/MainWindowController.swift` | Modify | Add 6 batch MailAction cases + keyboard dispatch |
| `Sources/LiteMail/GUI/MessageListView.swift` | Modify | Add checkbox column, checkedIds tracking |
| `Sources/LiteMail/GUI/BulkActionBar.swift` | Create | Contextual toolbar with action buttons |
| `Sources/LiteMail/GUI/UndoToastView.swift` | Create | Undo toast + UndoableBatchAction struct |
| `Sources/LiteMail/GUI/DetailView.swift` | Modify | Add bulk summary state |
| `Sources/LiteMail/App/AppDelegate.swift` | Modify | Wire batch action dispatch + undo lifecycle |
| `Tests/LiteMailTests/MailStoreBatchTests.swift` | Create | Unit tests for batch SQL methods |
| `Tests/LiteMailIntegrationTests/MockMailProvider.swift` | Modify | Add batch call recording |
| `Tests/LiteMailIntegrationTests/BatchActionTests.swift` | Create | Integration tests for cross-account routing |
| `Tests/LiteMailGUITests/BulkSelectionTests.swift` | Create | GUI tests for checkbox/toolbar/undo |

---

### Task 1: Fix fetchThread to filter is_deleted

**Files:**
- Modify: `Sources/LiteMail/Core/MailStore.swift:386-393`
- Test: `Tests/LiteMailTests/MailStoreBatchTests.swift`

- [ ] **Step 1: Create test file with failing test**

```swift
// Tests/LiteMailTests/MailStoreBatchTests.swift
import XCTest
import GRDB
@testable import LiteMail

final class MailStoreBatchTests: XCTestCase {

    private var store: MailStore!
    private var dbPath: String!
    private let testAccountId = "test-account"

    override func setUp() async throws {
        dbPath = NSTemporaryDirectory() + "litemail_batch_test_\(UUID().uuidString).sqlite"
        store = try MailStore(path: dbPath)
        let account = AccountRecord(
            id: testAccountId,
            emailAddress: "test@example.com",
            protocolType: "imap",
            authType: "password",
            keychainRef: "test-keychain",
            isDefault: true
        )
        try await store.insertAccount(account)
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    // MARK: - fetchThread filter

    func testFetchThreadExcludesDeletedEmails() async throws {
        // Insert 3 emails in the same thread
        for i in 1...3 {
            var record = EmailRecord(
                messageId: "msg-\(i)@test.com",
                threadId: "thread-1",
                folder: "INBOX",
                senderEmail: "sender@test.com",
                date: 1000 + i,
                isRead: false, isStarred: false, isDeleted: false, hasAttachments: false,
                accountId: testAccountId
            )
            try await store.insertEmail(&record)
        }

        // Soft-delete one email
        let all = try store.fetchThread(threadId: "thread-1")
        XCTAssertEqual(all.count, 3)
        try store.markDeleted(emailId: all[0].id!)

        // fetchThread should now return only 2
        let afterDelete = try store.fetchThread(threadId: "thread-1")
        XCTAssertEqual(afterDelete.count, 2)
        XCTAssertFalse(afterDelete.contains(where: { $0.id == all[0].id }))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MailStoreBatchTests/testFetchThreadExcludesDeletedEmails`
Expected: FAIL — fetchThread returns 3 (doesn't filter is_deleted)

- [ ] **Step 3: Fix fetchThread**

In `Sources/LiteMail/Core/MailStore.swift`, replace lines 386-393:

```swift
func fetchThread(threadId: String) throws -> [EmailRecord] {
    try dbPool.read { db in
        try EmailRecord
            .filter(Column("thread_id") == threadId)
            .filter(Column("is_deleted") == false)
            .order(Column("date").asc)
            .fetchAll(db)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MailStoreBatchTests/testFetchThreadExcludesDeletedEmails`
Expected: PASS

- [ ] **Step 5: Run all existing tests to verify no regression**

Run: `swift test --filter LiteMailTests`
Expected: All pass

- [ ] **Step 6: Commit**

```bash
git add Sources/LiteMail/Core/MailStore.swift Tests/LiteMailTests/MailStoreBatchTests.swift
git commit -m "fix: fetchThread excludes soft-deleted emails"
```

---

### Task 2: Add batch methods to MailStore

**Files:**
- Modify: `Sources/LiteMail/Core/MailStore.swift:447` (after existing moveEmail method)
- Test: `Tests/LiteMailTests/MailStoreBatchTests.swift`

- [ ] **Step 1: Write failing tests for all batch methods**

Append to `Tests/LiteMailTests/MailStoreBatchTests.swift`:

```swift
    // MARK: - Batch Operations

    private func insertTestEmails(count: Int, folder: String = "INBOX") async throws -> [Int64] {
        var ids: [Int64] = []
        for i in 1...count {
            var record = EmailRecord(
                messageId: "batch-\(UUID().uuidString)@test.com",
                threadId: nil,
                folder: folder,
                senderEmail: "sender\(i)@test.com",
                date: 1000 + i,
                isRead: false, isStarred: false, isDeleted: false, hasAttachments: false,
                accountId: testAccountId
            )
            try await store.insertEmail(&record)
            ids.append(record.id!)
        }
        return ids
    }

    func testMarkReadBatch() async throws {
        let ids = try await insertTestEmails(count: 5)
        try store.markReadBatch(emailIds: ids, read: true)
        for id in ids {
            let record = try store.fetchEmailRecord(id: id)
            XCTAssertTrue(record!.isRead, "Email \(id) should be marked read")
        }
    }

    func testMarkReadBatchEmptyArray() async throws {
        // Should not crash
        try store.markReadBatch(emailIds: [], read: true)
    }

    func testMarkStarredBatch() async throws {
        let ids = try await insertTestEmails(count: 3)
        try store.markStarredBatch(emailIds: ids, starred: true)
        for id in ids {
            let record = try store.fetchEmailRecord(id: id)
            XCTAssertTrue(record!.isStarred)
        }
    }

    func testMarkDeletedBatch() async throws {
        let ids = try await insertTestEmails(count: 4)
        try store.markDeletedBatch(emailIds: ids)
        for id in ids {
            let record = try store.fetchEmailRecord(id: id)
            XCTAssertTrue(record!.isDeleted)
        }
    }

    func testUnmarkDeletedBatch() async throws {
        let ids = try await insertTestEmails(count: 3)
        try store.markDeletedBatch(emailIds: ids)
        try store.unmarkDeletedBatch(emailIds: ids)
        for id in ids {
            let record = try store.fetchEmailRecord(id: id)
            XCTAssertFalse(record!.isDeleted)
        }
    }

    func testMoveEmailBatch() async throws {
        let ids = try await insertTestEmails(count: 3, folder: "INBOX")
        try store.moveEmailBatch(emailIds: ids, toFolder: "Archive")
        for id in ids {
            let record = try store.fetchEmailRecord(id: id)
            XCTAssertEqual(record!.folder, "Archive")
        }
    }

    func testBatchWithNonexistentIds() async throws {
        let ids = try await insertTestEmails(count: 2)
        // Include a nonexistent ID — should not crash, just ignore it
        try store.markReadBatch(emailIds: ids + [99999], read: true)
        for id in ids {
            let record = try store.fetchEmailRecord(id: id)
            XCTAssertTrue(record!.isRead)
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MailStoreBatchTests`
Expected: FAIL — batch methods don't exist

- [ ] **Step 3: Implement batch methods**

In `Sources/LiteMail/Core/MailStore.swift`, add after the `moveEmail` method (after line 447):

```swift
    // MARK: - Batch Actions

    func markReadBatch(emailIds: [Int64], read: Bool) throws {
        guard !emailIds.isEmpty else { return }
        try dbPool.write { db in
            let placeholders = databaseQuestionMarks(count: emailIds.count)
            let args: [DatabaseValueConvertible] = [read ? 1 : 0] + emailIds.map { $0 as DatabaseValueConvertible }
            try db.execute(sql: "UPDATE emails SET is_read = ? WHERE id IN (\(placeholders))", arguments: StatementArguments(args))
        }
    }

    func markStarredBatch(emailIds: [Int64], starred: Bool) throws {
        guard !emailIds.isEmpty else { return }
        try dbPool.write { db in
            let placeholders = databaseQuestionMarks(count: emailIds.count)
            let args: [DatabaseValueConvertible] = [starred ? 1 : 0] + emailIds.map { $0 as DatabaseValueConvertible }
            try db.execute(sql: "UPDATE emails SET is_starred = ? WHERE id IN (\(placeholders))", arguments: StatementArguments(args))
        }
    }

    func markDeletedBatch(emailIds: [Int64]) throws {
        guard !emailIds.isEmpty else { return }
        try dbPool.write { db in
            let placeholders = databaseQuestionMarks(count: emailIds.count)
            let args: [DatabaseValueConvertible] = emailIds.map { $0 as DatabaseValueConvertible }
            try db.execute(sql: "UPDATE emails SET is_deleted = 1 WHERE id IN (\(placeholders))", arguments: StatementArguments(args))
        }
    }

    func unmarkDeletedBatch(emailIds: [Int64]) throws {
        guard !emailIds.isEmpty else { return }
        try dbPool.write { db in
            let placeholders = databaseQuestionMarks(count: emailIds.count)
            let args: [DatabaseValueConvertible] = emailIds.map { $0 as DatabaseValueConvertible }
            try db.execute(sql: "UPDATE emails SET is_deleted = 0 WHERE id IN (\(placeholders))", arguments: StatementArguments(args))
        }
    }

    func moveEmailBatch(emailIds: [Int64], toFolder: String) throws {
        guard !emailIds.isEmpty else { return }
        try dbPool.write { db in
            let placeholders = databaseQuestionMarks(count: emailIds.count)
            let args: [DatabaseValueConvertible] = [toFolder as DatabaseValueConvertible] + emailIds.map { $0 as DatabaseValueConvertible }
            try db.execute(sql: "UPDATE emails SET folder = ? WHERE id IN (\(placeholders))", arguments: StatementArguments(args))
        }
    }

    /// Fetch account_id and folder for a batch of email IDs. Used by AccountManager for cross-account routing.
    func fetchEmailRecords(ids: [Int64]) throws -> [EmailRecord] {
        guard !ids.isEmpty else { return [] }
        return try dbPool.read { db in
            let placeholders = databaseQuestionMarks(count: ids.count)
            return try EmailRecord.fetchAll(db, sql: "SELECT * FROM emails WHERE id IN (\(placeholders))", arguments: StatementArguments(ids.map { $0 as DatabaseValueConvertible }))
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MailStoreBatchTests`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/LiteMail/Core/MailStore.swift Tests/LiteMailTests/MailStoreBatchTests.swift
git commit -m "feat: add batch methods to MailStore (markRead, markStarred, markDeleted, move, unmarkDeleted)"
```

---

### Task 3: Add batch methods to MailProvider protocol

**Files:**
- Modify: `Sources/LiteMail/Core/MailProvider.swift:62-63` (after existing deleteMessage)

- [ ] **Step 1: Add batch protocol methods**

In `Sources/LiteMail/Core/MailProvider.swift`, add after line 63 (after `deleteMessage`):

```swift
    // MARK: - Batch Actions

    func markReadBatch(messageRefs: [String], read: Bool) async throws
    func markStarredBatch(messageRefs: [String], starred: Bool) async throws
    func moveMessageBatch(messageRefs: [String], toFolderId: String) async throws
    func deleteMessageBatch(messageRefs: [String]) async throws
```

- [ ] **Step 2: Verify build fails (providers don't conform yet)**

Run: `swift build 2>&1 | head -20`
Expected: Build fails — IMAPProvider and JMAPProvider don't implement new methods

- [ ] **Step 3: Commit (protocol only, implementations in next tasks)**

```bash
git add Sources/LiteMail/Core/MailProvider.swift
git commit -m "feat: add batch method signatures to MailProvider protocol"
```

---

### Task 4: Implement batch methods on IMAPProvider

**Files:**
- Modify: `Sources/LiteMail/Core/IMAPProvider.swift:331` (after existing deleteMessage)

- [ ] **Step 1: Implement batch IMAP methods**

In `Sources/LiteMail/Core/IMAPProvider.swift`, add after the `deleteMessage` method (after line 331):

```swift
    // MARK: - Batch Actions

    func markReadBatch(messageRefs: [String], read: Bool) async throws {
        guard !messageRefs.isEmpty else { return }
        let imap = try await getIMAP()
        let grouped = Self.groupRefsByFolder(messageRefs)
        for (folder, uids) in grouped {
            if let folder { _ = try await imap.selectMailbox(folder) }
            let uidSet = MessageIdentifierSet<UID>(uids)
            try await imap.store(flags: [.seen], on: uidSet, operation: read ? .add : .remove)
        }
    }

    func markStarredBatch(messageRefs: [String], starred: Bool) async throws {
        guard !messageRefs.isEmpty else { return }
        let imap = try await getIMAP()
        let grouped = Self.groupRefsByFolder(messageRefs)
        for (folder, uids) in grouped {
            if let folder { _ = try await imap.selectMailbox(folder) }
            let uidSet = MessageIdentifierSet<UID>(uids)
            try await imap.store(flags: [.flagged], on: uidSet, operation: starred ? .add : .remove)
        }
    }

    func moveMessageBatch(messageRefs: [String], toFolderId: String) async throws {
        guard !messageRefs.isEmpty else { return }
        let imap = try await getIMAP()
        let grouped = Self.groupRefsByFolder(messageRefs)
        for (folder, uids) in grouped {
            if let folder { _ = try await imap.selectMailbox(folder) }
            // SwiftMail's move() takes single UID, so loop within the selected mailbox
            for uid in uids {
                try await imap.move(message: uid, to: toFolderId)
            }
        }
    }

    func deleteMessageBatch(messageRefs: [String]) async throws {
        guard !messageRefs.isEmpty else { return }
        let imap = try await getIMAP()
        let grouped = Self.groupRefsByFolder(messageRefs)
        for (folder, uids) in grouped {
            if let folder { _ = try await imap.selectMailbox(folder) }
            let uidSet = MessageIdentifierSet<UID>(uids)
            try await imap.store(flags: [.deleted], on: uidSet, operation: .add)
            try await imap.expunge()
        }
    }

    /// Group messageRefs by folder for batch IMAP operations.
    private static func groupRefsByFolder(_ refs: [String]) -> [(folder: String?, uids: [UID])] {
        var groups: [String: [UID]] = [:]
        var noFolder: [UID] = []
        for ref in refs {
            let (folder, uid) = parseFolderAndUidRef(ref)
            if let folder {
                groups[folder, default: []].append(uid)
            } else {
                noFolder.append(uid)
            }
        }
        var result: [(folder: String?, uids: [UID])] = groups.map { (folder: $0.key, uids: $0.value) }
        if !noFolder.isEmpty {
            result.append((folder: nil, uids: noFolder))
        }
        return result
    }
```

- [ ] **Step 2: Verify build succeeds for IMAPProvider**

Run: `swift build 2>&1 | grep -c error`
Expected: Still fails (JMAPProvider not done yet), but no IMAPProvider errors

- [ ] **Step 3: Commit**

```bash
git add Sources/LiteMail/Core/IMAPProvider.swift
git commit -m "feat: implement batch IMAP operations (store UID sets, per-folder grouping)"
```

---

### Task 5: Implement batch methods on JMAPProvider

**Files:**
- Modify: `Sources/LiteMail/Core/JMAPProvider.swift:261` (after existing deleteMessage)

- [ ] **Step 1: Implement batch JMAP methods**

In `Sources/LiteMail/Core/JMAPProvider.swift`, add after the `deleteMessage` method (after line 261):

```swift
    // MARK: - Batch Actions

    func markReadBatch(messageRefs: [String], read: Bool) async throws {
        try await emailSetBatch(messageRefs: messageRefs, update: ["keywords/$seen": read])
    }

    func markStarredBatch(messageRefs: [String], starred: Bool) async throws {
        try await emailSetBatch(messageRefs: messageRefs, update: ["keywords/$flagged": starred])
    }

    func moveMessageBatch(messageRefs: [String], toFolderId: String) async throws {
        try await emailSetBatch(messageRefs: messageRefs, update: ["mailboxIds": [toFolderId: true]])
    }

    func deleteMessageBatch(messageRefs: [String]) async throws {
        let jmap = try await getClient()
        guard let trashMailbox = try await jmap.getMailbox(byRole: .trash) else {
            throw JMAPProviderError.notImplemented
        }
        try await emailSetBatch(messageRefs: messageRefs, update: ["mailboxIds": [trashMailbox.id: true]])
    }

    /// Batch helper: one Email/set with multiple IDs in the update dict.
    private func emailSetBatch(messageRefs: [String], update: [String: Any]) async throws {
        guard !messageRefs.isEmpty else { return }
        let jmap = try await getClient()
        guard let jmapAccountId = jmap.currentAccountId else {
            throw JMAPProviderError.notAuthenticated
        }
        var updateDict: [String: Any] = [:]
        for ref in messageRefs {
            updateDict[ref] = update
        }
        let request = JMAPRequest(
            using: ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
            methodCalls: [
                JMAPMethodCall(
                    method: "Email/set",
                    arguments: [
                        "accountId": jmapAccountId,
                        "update": updateDict
                    ],
                    clientId: "batchSync"
                )
            ]
        )
        _ = try await jmap.makeRequest(request)
    }
```

- [ ] **Step 2: Verify build succeeds**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/LiteMail/Core/JMAPProvider.swift
git commit -m "feat: implement batch JMAP operations (single Email/set with multiple IDs)"
```

---

### Task 6: Add batch methods to MockMailProvider

**Files:**
- Modify: `Tests/LiteMailIntegrationTests/MockMailProvider.swift`

- [ ] **Step 1: Add batch call recording and implementations**

In `Tests/LiteMailIntegrationTests/MockMailProvider.swift`, add after the existing call recording properties (after line 28):

```swift
    private(set) var markReadBatchCalls: [(refs: [String], read: Bool)] = []
    private(set) var markStarredBatchCalls: [(refs: [String], starred: Bool)] = []
    private(set) var moveBatchCalls: [(refs: [String], toFolderId: String)] = []
    private(set) var deleteBatchCalls: [[String]] = []
```

Add implementations after the existing `send` method (after line 150):

```swift
    // MARK: - Batch Actions

    func markReadBatch(messageRefs: [String], read: Bool) async throws {
        calls.append("markReadBatch:\(messageRefs.count)")
        markReadBatchCalls.append((refs: messageRefs, read: read))
        if let error = stubbedError { throw error }
    }

    func markStarredBatch(messageRefs: [String], starred: Bool) async throws {
        calls.append("markStarredBatch:\(messageRefs.count)")
        markStarredBatchCalls.append((refs: messageRefs, starred: starred))
        if let error = stubbedError { throw error }
    }

    func moveMessageBatch(messageRefs: [String], toFolderId: String) async throws {
        calls.append("moveMessageBatch:\(messageRefs.count):\(toFolderId)")
        moveBatchCalls.append((refs: messageRefs, toFolderId: toFolderId))
        if let error = stubbedError { throw error }
    }

    func deleteMessageBatch(messageRefs: [String]) async throws {
        calls.append("deleteMessageBatch:\(messageRefs.count)")
        deleteBatchCalls.append(messageRefs)
        if let error = stubbedError { throw error }
    }
```

- [ ] **Step 2: Verify build succeeds**

Run: `swift build --build-tests`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Tests/LiteMailIntegrationTests/MockMailProvider.swift
git commit -m "feat: add batch call recording to MockMailProvider"
```

---

### Task 7: Add batch methods to MailEngineProtocol + AccountManager

**Files:**
- Modify: `Sources/LiteMail/Core/MailEngineProtocol.swift:37` (after existing move)
- Modify: `Sources/LiteMail/Core/AccountManager.swift:253` (after existing move)
- Test: `Tests/LiteMailIntegrationTests/BatchActionTests.swift`

- [ ] **Step 1: Write failing integration tests**

Create `Tests/LiteMailIntegrationTests/BatchActionTests.swift`:

```swift
import XCTest
@testable import LiteMail

final class BatchActionTests: XCTestCase {

    private var store: MailStore!
    private var dbPath: String!
    private var mockProvider: MockMailProvider!
    private var accountManager: AccountManager!

    override func setUp() async throws {
        dbPath = NSTemporaryDirectory() + "litemail_batch_int_\(UUID().uuidString).sqlite"
        store = try MailStore(path: dbPath)

        let account = AccountRecord(
            id: "acct-1",
            emailAddress: "test@example.com",
            protocolType: "imap",
            authType: "password",
            keychainRef: "test-keychain",
            isDefault: true
        )
        try await store.insertAccount(account)

        mockProvider = MockMailProvider(accountId: "acct-1")
        accountManager = AccountManager(store: store, providerFactory: { _ in self.mockProvider })
        try await accountManager.addProvider(mockProvider, for: "acct-1")
    }

    override func tearDown() async throws {
        accountManager = nil
        store = nil
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    private func insertTestEmails(count: Int, accountId: String = "acct-1") async throws -> [Int64] {
        var ids: [Int64] = []
        for i in 1...count {
            var record = EmailRecord(
                messageId: "batch-\(UUID().uuidString)@test.com",
                threadId: nil,
                folder: "INBOX",
                senderEmail: "sender@test.com",
                date: 1000 + i,
                isRead: false, isStarred: false, isDeleted: false, hasAttachments: false,
                uid: UInt32(100 + i),
                accountId: accountId
            )
            try await store.insertEmail(&record)
            ids.append(record.id!)
        }
        return ids
    }

    func testDeleteBatchUpdatesStoreAndDispatchesProvider() async throws {
        let ids = try await insertTestEmails(count: 3)
        try await accountManager.deleteBatch(emailIds: ids)

        // Verify store: all marked deleted
        for id in ids {
            let record = try store.fetchEmailRecord(id: id)
            XCTAssertTrue(record!.isDeleted)
        }

        // Give background Task a moment to dispatch
        try await Task.sleep(nanoseconds: 100_000_000)
        let batchCalls = await mockProvider.deleteBatchCalls
        XCTAssertEqual(batchCalls.count, 1)
        XCTAssertEqual(batchCalls[0].count, 3)
    }

    func testMarkReadBatchUpdatesStore() async throws {
        let ids = try await insertTestEmails(count: 5)
        try await accountManager.markReadBatch(emailIds: ids, read: true)

        for id in ids {
            let record = try store.fetchEmailRecord(id: id)
            XCTAssertTrue(record!.isRead)
        }
    }

    func testBatchWithEmptyArray() async throws {
        // Should not crash
        try await accountManager.deleteBatch(emailIds: [])
        try await accountManager.markReadBatch(emailIds: [], read: true)
    }

    func testStaleSelectionGuard() async throws {
        let ids = try await insertTestEmails(count: 3)
        // Delete one from the store directly (simulating concurrent sync removal)
        try store.markDeleted(emailId: ids[0])

        // Batch should handle the stale ID gracefully
        try await accountManager.markReadBatch(emailIds: ids, read: true)

        // The remaining 2 should be marked read
        let record1 = try store.fetchEmailRecord(id: ids[1])
        XCTAssertTrue(record1!.isRead)
        let record2 = try store.fetchEmailRecord(id: ids[2])
        XCTAssertTrue(record2!.isRead)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BatchActionTests`
Expected: FAIL — batch methods don't exist on MailEngineProtocol/AccountManager

- [ ] **Step 3: Add batch methods to MailEngineProtocol**

In `Sources/LiteMail/Core/MailEngineProtocol.swift`, add after line 37 (after `move`):

```swift
    // MARK: - Batch Actions

    func deleteBatch(emailIds: [Int64]) async throws
    func archiveBatch(emailIds: [Int64]) async throws
    func markReadBatch(emailIds: [Int64], read: Bool) async throws
    func markStarredBatch(emailIds: [Int64], starred: Bool) async throws
    func moveBatch(emailIds: [Int64], toFolder: String) async throws
```

- [ ] **Step 4: Implement batch methods on AccountManager**

In `Sources/LiteMail/Core/AccountManager.swift`, add after the `move` method (after line 253):

```swift
    // MARK: - Batch Actions

    func deleteBatch(emailIds: [Int64]) async throws {
        guard !emailIds.isEmpty else { return }
        // Optimistic: update local store immediately
        try await store.markDeletedBatch(emailIds: emailIds)
        // Group by account and dispatch to providers
        let groups = try await groupByAccount(emailIds: emailIds)
        for (provider, refs) in groups {
            Task { try? await provider.deleteMessageBatch(messageRefs: refs) }
        }
    }

    func archiveBatch(emailIds: [Int64]) async throws {
        guard !emailIds.isEmpty else { return }
        // Group by account to resolve archive folder per-account
        let records = try store.fetchEmailRecords(ids: emailIds)
        let byAccount = Dictionary(grouping: records, by: { $0.accountId ?? "default" })

        for (accountId, accountRecords) in byAccount {
            let archiveFolder = try await resolveArchiveFolder(for: accountId)
            let accountIds = accountRecords.compactMap { $0.id }
            try store.moveEmailBatch(emailIds: accountIds, toFolder: archiveFolder)

            if let provider = providers[accountId] {
                let refs = try buildRefs(for: accountRecords, accountId: accountId)
                Task { try? await provider.moveMessageBatch(messageRefs: refs, toFolderId: archiveFolder) }
            }
        }
    }

    func markReadBatch(emailIds: [Int64], read: Bool) async throws {
        guard !emailIds.isEmpty else { return }
        try store.markReadBatch(emailIds: emailIds, read: read)
        let groups = try await groupByAccount(emailIds: emailIds)
        for (provider, refs) in groups {
            Task { try? await provider.markReadBatch(messageRefs: refs, read: read) }
        }
    }

    func markStarredBatch(emailIds: [Int64], starred: Bool) async throws {
        guard !emailIds.isEmpty else { return }
        try store.markStarredBatch(emailIds: emailIds, starred: starred)
        let groups = try await groupByAccount(emailIds: emailIds)
        for (provider, refs) in groups {
            Task { try? await provider.markStarredBatch(messageRefs: refs, starred: starred) }
        }
    }

    func moveBatch(emailIds: [Int64], toFolder: String) async throws {
        guard !emailIds.isEmpty else { return }
        // Capture original folders before moving (for undo)
        let records = try store.fetchEmailRecords(ids: emailIds)
        try store.moveEmailBatch(emailIds: emailIds, toFolder: toFolder)
        let groups = try await groupByAccount(emailIds: emailIds, records: records)
        for (provider, refs) in groups {
            Task { try? await provider.moveMessageBatch(messageRefs: refs, toFolderId: toFolder) }
        }
    }

    // MARK: - Batch Helpers

    /// Resolve the archive folder for an account (Gmail uses [Gmail]/All Mail, others use Archive).
    private func resolveArchiveFolder(for accountId: String) async throws -> String {
        guard let provider = providers[accountId] else { return "Archive" }
        let folders = try await provider.listFolders()
        // Look for a folder with Archive role/attribute
        if let archiveFolder = folders.first(where: { $0.name.lowercased() == "archive" || $0.id.lowercased().contains("archive") }) {
            return archiveFolder.id
        }
        // Gmail convention
        if let gmailAll = folders.first(where: { $0.id == "[Gmail]/All Mail" }) {
            return gmailAll.id
        }
        return "Archive"
    }

    /// Group emailIds by account, returning (provider, [messageRef]) pairs.
    private func groupByAccount(emailIds: [Int64], records: [EmailRecord]? = nil) async throws -> [(any MailProvider, [String])] {
        let recs = try records ?? store.fetchEmailRecords(ids: emailIds)
        let byAccount = Dictionary(grouping: recs, by: { $0.accountId ?? "default" })
        var result: [(any MailProvider, [String])] = []
        for (accountId, accountRecords) in byAccount {
            guard let provider = providers[accountId] else { continue }
            let refs = try buildRefs(for: accountRecords, accountId: accountId)
            result.append((provider, refs))
        }
        return result
    }

    /// Build messageRefs from records. IMAP: "folder:<name>:uid:<N>". JMAP: messageId.
    private func buildRefs(for records: [EmailRecord], accountId: String) throws -> [String] {
        let config = try store.getAccountSync(id: accountId)
        let isJMAP = config?.protocolType == "jmap"
        return records.compactMap { record -> String? in
            if isJMAP {
                return record.messageId
            } else {
                guard let uid = record.uid else { return nil }
                return "folder:\(record.folder):uid:\(uid)"
            }
        }
    }
```

Note: `getAccountSync` may need to be added as a synchronous version of `getAccount`. If it doesn't exist, use the existing async version within an appropriate context, or add a simple synchronous wrapper:

```swift
    func getAccountSync(id: String) throws -> AccountRecord? {
        try dbPool.read { db in
            try AccountRecord.fetchOne(db, key: id)
        }
    }
```

Add this to MailStore if it doesn't already exist.

- [ ] **Step 5: Also add batch stubs to MockMailEngine (for GUI tests)**

Check if `Tests/LiteMailGUITests/MockMailEngine.swift` exists. If it does, add batch method stubs that record calls, matching the pattern of existing stubs.

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter BatchActionTests`
Expected: All PASS

- [ ] **Step 7: Run all tests to verify no regression**

Run: `swift test`
Expected: All pass

- [ ] **Step 8: Commit**

```bash
git add Sources/LiteMail/Core/MailEngineProtocol.swift Sources/LiteMail/Core/AccountManager.swift Sources/LiteMail/Core/MailStore.swift Tests/LiteMailIntegrationTests/BatchActionTests.swift
git commit -m "feat: add batch routing to AccountManager with cross-account grouping + resolveArchiveFolder"
```

---

### Task 8: Add batch MailAction cases + keyboard dispatch

**Files:**
- Modify: `Sources/LiteMail/GUI/MainWindowController.swift:230-242` (MailAction enum)
- Modify: `Sources/LiteMail/GUI/MainWindowController.swift:153-181` (keyboard handler)
- Modify: `Sources/LiteMail/App/AppDelegate.swift:267-316` (handleAction)

- [ ] **Step 1: Add batch cases to MailAction enum**

In `Sources/LiteMail/GUI/MainWindowController.swift`, add to the MailAction enum (after line 242):

```swift
    case batchDelete([Int64])
    case batchArchive([Int64])
    case batchMarkRead([Int64])
    case batchMarkUnread([Int64])
    case batchToggleStar([Int64])
    case batchMove([Int64], String)
```

- [ ] **Step 2: Update keyboard handler to dispatch batch actions when checkboxes are checked**

In `Sources/LiteMail/GUI/MainWindowController.swift`, modify the keyboard handler cases. Replace the `"e"`, `"s"`, `"r"` cases (lines 160-174) with:

```swift
        case "e":
            let checkedIds = Array(messageListView.checkedIds)
            if !checkedIds.isEmpty {
                onAction?(.batchArchive(checkedIds))
            } else if let selected = messageListView.selectedHeader {
                onAction?(.archive(selected.id))
            }
            return nil
        case "s":
            let checkedIds = Array(messageListView.checkedIds)
            if !checkedIds.isEmpty {
                onAction?(.batchToggleStar(checkedIds))
            } else if let selected = messageListView.selectedHeader {
                onAction?(.toggleStar(selected.id))
            }
            return nil
        case "r":
            let checkedIds = Array(messageListView.checkedIds)
            if !checkedIds.isEmpty {
                onAction?(.batchMarkRead(checkedIds))
            } else if let selected = messageListView.selectedHeader {
                onAction?(.markRead(selected.id))
            }
            return nil
```

Also add Delete key handling (after the Escape handler, around line 188):

```swift
        // Delete key → batch delete or single delete
        if event.keyCode == 51 { // Delete/Backspace
            let checkedIds = Array(messageListView.checkedIds)
            if !checkedIds.isEmpty {
                onAction?(.batchDelete(checkedIds))
            } else if let selected = messageListView.selectedHeader {
                onAction?(.delete(selected.id))
            }
            return nil
        }
```

- [ ] **Step 3: Wire batch actions in AppDelegate.handleAction**

In `Sources/LiteMail/App/AppDelegate.swift`, add batch cases to the switch in `handleAction` (before the `default:` case at line 309):

```swift
                case .batchDelete(let ids) where !ids.isEmpty:
                    try await accountManager.deleteBatch(emailIds: ids)
                    windowController?.messageListView.clearCheckedIds()
                    loadMessages()
                case .batchArchive(let ids) where !ids.isEmpty:
                    try await accountManager.archiveBatch(emailIds: ids)
                    windowController?.messageListView.clearCheckedIds()
                    loadMessages()
                case .batchMarkRead(let ids) where !ids.isEmpty:
                    try await accountManager.markReadBatch(emailIds: ids, read: true)
                    windowController?.messageListView.clearCheckedIds()
                    loadMessages()
                case .batchMarkUnread(let ids) where !ids.isEmpty:
                    try await accountManager.markReadBatch(emailIds: ids, read: false)
                    windowController?.messageListView.clearCheckedIds()
                    loadMessages()
                case .batchToggleStar(let ids) where !ids.isEmpty:
                    try await accountManager.markStarredBatch(emailIds: ids, starred: true)
                    windowController?.messageListView.clearCheckedIds()
                    loadMessages()
                case .batchMove(let ids, let folder) where !ids.isEmpty:
                    try await accountManager.moveBatch(emailIds: ids, toFolder: folder)
                    windowController?.messageListView.clearCheckedIds()
                    loadMessages()
```

Note: `clearCheckedIds()` will be added to MessageListView in Task 9.

- [ ] **Step 4: Verify build succeeds (may need MessageListView stubs)**

Run: `swift build 2>&1 | head -20`
Expected: May fail on `checkedIds` and `clearCheckedIds` — that's OK, those come in Task 9.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiteMail/GUI/MainWindowController.swift Sources/LiteMail/App/AppDelegate.swift
git commit -m "feat: add batch MailAction cases + keyboard dispatch for bulk operations"
```

---

### Task 9: Add checkbox selection to MessageListView

**Files:**
- Modify: `Sources/LiteMail/GUI/MessageListView.swift`

- [ ] **Step 1: Add checkedIds property and checkbox to cell view**

In `Sources/LiteMail/GUI/MessageListView.swift`, add to the `MessageListView` class (after line 26):

```swift
    /// IDs checked via checkbox (independent of row highlight selection).
    private(set) var checkedIds: Set<Int64> = []
    var onCheckedIdsChanged: ((Set<Int64>) -> Void)?

    func clearCheckedIds() {
        checkedIds.removeAll()
        tableView.reloadData()
        onCheckedIdsChanged?(checkedIds)
    }

    func toggleChecked(emailId: Int64) {
        if checkedIds.contains(emailId) {
            checkedIds.remove(emailId)
        } else {
            checkedIds.insert(emailId)
        }
        tableView.reloadData()
        onCheckedIdsChanged?(checkedIds)
    }
```

In the `MessageCellView` class, add a checkbox (in `setupViews`, after line 228):

```swift
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
```

Add the checkbox to the subview list and layout. Modify the `setupViews` method to include the checkbox:

```swift
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    var onCheckboxToggled: (() -> Void)?
```

Add in `setupViews` (after existing subview additions):

```swift
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)
        checkbox.target = self
        checkbox.action = #selector(checkboxClicked)
        checkbox.setContentHuggingPriority(.required, for: .horizontal)
```

Add checkbox constraints — position it at the left edge (replacing unreadDot position when visible):

```swift
        // Checkbox at leading edge
        checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
        checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
```

Shift the unreadDot to anchor off the checkbox:

```swift
        unreadDot.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 2),
```

Add the handler:

```swift
    @objc private func checkboxClicked() {
        onCheckboxToggled?()
    }
```

Update `configure` to accept checked state:

```swift
    func configure(with header: EmailHeader, threadCount: Int = 1, isChecked: Bool = false, showCheckbox: Bool = false) {
        // ... existing configure code ...
        checkbox.state = isChecked ? .on : .off
        checkbox.isHidden = !showCheckbox
    }
```

- [ ] **Step 2: Update tableView delegate to wire checkbox callbacks**

In the `NSTableViewDelegate` extension, update `tableView(_:viewFor:row:)` to pass the checkbox state:

```swift
    let group = threadGroups[row]
    let anyChecked = !checkedIds.isEmpty
    cell.configure(
        with: group.primaryHeader,
        threadCount: group.count,
        isChecked: checkedIds.contains(group.primaryHeader.id),
        showCheckbox: anyChecked || cell.isMouseInside // show all if any checked
    )
    cell.onCheckboxToggled = { [weak self] in
        self?.toggleChecked(emailId: group.primaryHeader.id)
    }
```

Note: `isMouseInside` requires adding tracking area to the cell for hover detection. For v1, show checkboxes always when `anyChecked`, otherwise hidden. Hover behavior can be polished later.

- [ ] **Step 3: Verify build succeeds**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Sources/LiteMail/GUI/MessageListView.swift
git commit -m "feat: add checkbox selection to MessageListView with checkedIds tracking"
```

---

### Task 10: Build BulkActionBar

**Files:**
- Create: `Sources/LiteMail/GUI/BulkActionBar.swift`
- Modify: `Sources/LiteMail/GUI/MainWindowController.swift` (wire into layout)

- [ ] **Step 1: Create BulkActionBar**

Create `Sources/LiteMail/GUI/BulkActionBar.swift`:

```swift
import AppKit

/// Contextual toolbar that appears when emails are checked.
/// Shows "N selected" + action buttons (Archive, Delete, Mark Read, Star, Move).
final class BulkActionBar: NSView {

    private let countLabel = NSTextField(labelWithString: "")
    private let archiveButton: NSButton
    private let deleteButton: NSButton
    private let markReadButton: NSButton
    private let starButton: NSButton
    private let moveButton: NSButton
    private let deselectButton: NSButton

    var onArchive: (() -> Void)?
    var onDelete: (() -> Void)?
    var onMarkRead: (() -> Void)?
    var onStar: (() -> Void)?
    var onMove: (() -> Void)?
    var onDeselectAll: (() -> Void)?

    override init(frame frameRect: NSRect) {
        archiveButton = NSButton(image: NSImage(systemSymbolName: "archivebox", accessibilityDescription: "Archive")!, target: nil, action: nil)
        deleteButton = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")!, target: nil, action: nil)
        markReadButton = NSButton(image: NSImage(systemSymbolName: "envelope.open", accessibilityDescription: "Mark Read")!, target: nil, action: nil)
        starButton = NSButton(image: NSImage(systemSymbolName: "star", accessibilityDescription: "Star")!, target: nil, action: nil)
        moveButton = NSButton(image: NSImage(systemSymbolName: "folder", accessibilityDescription: "Move")!, target: nil, action: nil)
        deselectButton = NSButton(title: "Deselect All", target: nil, action: nil)

        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let topBorder = NSBox()
        topBorder.boxType = .separator
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBorder)

        countLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        countLabel.textColor = .labelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        for button in [archiveButton, deleteButton, markReadButton, starButton, moveButton] {
            button.bezelStyle = .toolbar
            button.isBordered = false
        }

        deselectButton.bezelStyle = .inline
        deselectButton.font = .systemFont(ofSize: 11)
        deselectButton.contentTintColor = .linkColor

        archiveButton.target = self
        archiveButton.action = #selector(archiveClicked)
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        markReadButton.target = self
        markReadButton.action = #selector(markReadClicked)
        starButton.target = self
        starButton.action = #selector(starClicked)
        moveButton.target = self
        moveButton.action = #selector(moveClicked)
        deselectButton.target = self
        deselectButton.action = #selector(deselectClicked)

        let buttonStack = NSStackView(views: [archiveButton, deleteButton, markReadButton, starButton, moveButton])
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        let mainStack = NSStackView(views: [countLabel, buttonStack, deselectButton])
        mainStack.spacing = 16
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainStack)

        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),

            mainStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            mainStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),

            heightAnchor.constraint(equalToConstant: 36),
        ])

        isHidden = true
    }

    func update(selectedCount: Int) {
        if selectedCount > 0 {
            countLabel.stringValue = "\(selectedCount) selected"
            if isHidden {
                isHidden = false
                alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    animator().alphaValue = 1
                }
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                animator().alphaValue = 0
            }, completionHandler: {
                self.isHidden = true
            })
        }
    }

    @objc private func archiveClicked() { onArchive?() }
    @objc private func deleteClicked() { onDelete?() }
    @objc private func markReadClicked() { onMarkRead?() }
    @objc private func starClicked() { onStar?() }
    @objc private func moveClicked() { onMove?() }
    @objc private func deselectClicked() { onDeselectAll?() }
}
```

- [ ] **Step 2: Wire BulkActionBar into MainWindowController layout**

In `Sources/LiteMail/GUI/MainWindowController.swift`, add a `bulkActionBar` property and insert it above the message list in the layout. Wire `messageListView.onCheckedIdsChanged` to update the bar:

```swift
    let bulkActionBar = BulkActionBar(frame: .zero)
    bulkActionBar.translatesAutoresizingMaskIntoConstraints = false
```

Wire callbacks from bulkActionBar to dispatch batch MailActions using `checkedIds`.

- [ ] **Step 3: Verify build succeeds and toolbar appears**

Run: `swift build && swift run LiteMail`
Expected: App launches. Checking emails shows the toolbar.

- [ ] **Step 4: Commit**

```bash
git add Sources/LiteMail/GUI/BulkActionBar.swift Sources/LiteMail/GUI/MainWindowController.swift
git commit -m "feat: add BulkActionBar contextual toolbar for bulk operations"
```

---

### Task 11: Build UndoToastView

**Files:**
- Create: `Sources/LiteMail/GUI/UndoToastView.swift`
- Modify: `Sources/LiteMail/App/AppDelegate.swift` (wire undo lifecycle)

- [ ] **Step 1: Create UndoToastView + UndoableBatchAction**

Create `Sources/LiteMail/GUI/UndoToastView.swift`:

```swift
import AppKit

/// Captures a batch action that can be undone within a countdown period.
struct UndoableBatchAction {
    let description: String
    let reverseOperation: @Sendable () async throws -> Void
    let emailIds: [Int64]
    var isUndone: Bool = false
}

/// Floating toast with "Archived N conversations - Undo (Xs)" + countdown bar.
@MainActor
final class UndoToastView: NSView {

    private let messageLabel = NSTextField(labelWithString: "")
    private let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    private let progressBar = NSView()
    private var countdownTimer: Timer?
    private var serverSyncTask: Task<Void, Never>?
    private var currentAction: UndoableBatchAction?
    private var remainingSeconds: Int = 10

    var onUndo: (([Int64]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 6
        shadow = NSShadow()
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.15)
        shadow?.shadowOffset = NSSize(width: 0, height: -2)
        shadow?.shadowBlurRadius = 4

        messageLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        messageLabel.textColor = .labelColor
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        undoButton.bezelStyle = .inline
        undoButton.font = .systemFont(ofSize: 11, weight: .semibold)
        undoButton.contentTintColor = .linkColor
        undoButton.target = self
        undoButton.action = #selector(undoClicked)
        undoButton.translatesAutoresizingMaskIntoConstraints = false

        progressBar.wantsLayer = true
        progressBar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        addSubview(messageLabel)
        addSubview(undoButton)
        addSubview(progressBar)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),

            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            undoButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            undoButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: undoButton.leadingAnchor, constant: -8),

            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2),
        ])

        isHidden = true
    }

    /// Show the toast and start countdown. Calls `onExpire` after countdown.
    func show(action: UndoableBatchAction, onExpire: @escaping () async -> Void) {
        // Commit any previous action immediately
        commitCurrentAction()

        currentAction = action
        remainingSeconds = 10
        messageLabel.stringValue = "\(action.description) — Undo (\(remainingSeconds)s)"

        // Reset progress bar
        progressBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 2)

        isHidden = false
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.animator().alphaValue = 1
        }

        // VoiceOver announcement
        NSAccessibility.post(element: self, notification: .announcementRequested,
                            userInfo: [.announcementKey: "\(action.description). Press Command Z to undo."])

        // Start countdown
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }

        // Schedule server sync
        serverSyncTask = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await MainActor.run {
                guard self.currentAction != nil, !(self.currentAction?.isUndone ?? true) else { return }
                Task { await onExpire() }
                self.dismiss()
            }
        }
    }

    private func tick() {
        remainingSeconds -= 1
        if remainingSeconds <= 0 {
            countdownTimer?.invalidate()
            return
        }
        messageLabel.stringValue = "\(currentAction?.description ?? "") — Undo (\(remainingSeconds)s)"

        // Animate progress bar width
        let fraction = CGFloat(remainingSeconds) / 10.0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 1.0
            progressBar.animator().frame = NSRect(x: 0, y: 0, width: bounds.width * fraction, height: 2)
        }
    }

    @objc private func undoClicked() {
        performUndo()
    }

    func performUndo() {
        guard var action = currentAction, !action.isUndone else { return }
        action.isUndone = true
        currentAction = action

        serverSyncTask?.cancel()
        countdownTimer?.invalidate()

        Task {
            try? await action.reverseOperation()
            onUndo?(action.emailIds)
        }

        dismiss()
    }

    /// Commit the current action (fire server sync immediately, stop countdown).
    func commitCurrentAction() {
        guard currentAction != nil, !(currentAction?.isUndone ?? true) else { return }
        serverSyncTask?.cancel()
        countdownTimer?.invalidate()
        // Server sync was already dispatched as fire-and-forget by AccountManager
        dismiss()
    }

    private func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            animator().alphaValue = 0
        }, completionHandler: {
            self.isHidden = true
            self.currentAction = nil
        })
    }
}
```

- [ ] **Step 2: Wire into AppDelegate**

In `Sources/LiteMail/App/AppDelegate.swift`, modify the batch action handlers to create `UndoableBatchAction` structs and show the toast instead of calling `loadMessages()` directly. The toast's `onExpire` callback triggers the server sync (already handled by AccountManager's background Tasks). The toast's `onUndo` callback calls the reverse operations.

Example for batchDelete:

```swift
case .batchDelete(let ids) where !ids.isEmpty:
    try await accountManager.deleteBatch(emailIds: ids)
    windowController?.messageListView.clearCheckedIds()
    loadMessages()
    let action = UndoableBatchAction(
        description: "Deleted \(ids.count) conversations",
        reverseOperation: { [weak self] in
            try self?.accountManager?.store.unmarkDeletedBatch(emailIds: ids)
        },
        emailIds: ids
    )
    windowController?.undoToastView.show(action: action, onExpire: { /* already synced */ })
```

Wire `Cmd+Z` to `undoToastView.performUndo()` in the keyboard handler.

- [ ] **Step 3: Verify build succeeds**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Sources/LiteMail/GUI/UndoToastView.swift Sources/LiteMail/App/AppDelegate.swift
git commit -m "feat: add UndoToastView with countdown, VoiceOver announcement, and Cmd+Z undo"
```

---

### Task 12: Add detail view bulk summary state

**Files:**
- Modify: `Sources/LiteMail/GUI/DetailView.swift`

- [ ] **Step 1: Add bulk summary view elements**

In `Sources/LiteMail/GUI/DetailView.swift`, add a summary container (similar to the existing `emptyContainer`):

```swift
    // Bulk summary state
    private let summaryContainer = NSView()
    private let summaryIcon = NSImageView()
    private let summaryTitle = NSTextField(labelWithString: "")
    private let summaryList = NSTextField(wrappingLabelWithString: "")
```

Layout: centered, same pattern as `emptyContainer`. `summaryIcon` uses SF Symbol `checkmark.circle`, `summaryTitle` shows "N conversations selected" in 18pt `.title2`, `summaryList` shows first 5 subjects in 13pt.

Add a method:

```swift
    func showBulkSummary(headers: [EmailHeader]) {
        // Hide email content, show summary
        summaryTitle.stringValue = "\(headers.count) conversations selected"
        let subjects = headers.prefix(5).map { "• \($0.senderName ?? $0.senderEmail): \($0.subject ?? "(no subject)")" }.joined(separator: "\n")
        summaryList.stringValue = headers.count > 5 ? subjects + "\n• ..." : subjects
        summaryContainer.isHidden = false
        // Hide body views
    }

    func hideBulkSummary() {
        summaryContainer.isHidden = true
    }
```

- [ ] **Step 2: Wire in AppDelegate**

When `checkedIds` changes, if count >= 2, call `detailView.showBulkSummary(headers:)` with the checked headers. When count drops below 2, call `hideBulkSummary()`.

- [ ] **Step 3: Verify build succeeds**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Sources/LiteMail/GUI/DetailView.swift Sources/LiteMail/App/AppDelegate.swift
git commit -m "feat: add bulk summary state to DetailView when multiple emails checked"
```

---

### Task 13: Add message list empty state

**Files:**
- Modify: `Sources/LiteMail/GUI/MessageListView.swift`

- [ ] **Step 1: Add empty state view**

In `Sources/LiteMail/GUI/MessageListView.swift`, add an empty state overlay:

```swift
    private let emptyStateView = NSView()
    private let emptyTitle = NSTextField(labelWithString: "All caught up")
    private let emptySubtitle = NSTextField(labelWithString: "")
```

Setup: centered in the scroll view area. Title: 16pt `.title3`. Subtitle: 13pt, `.secondaryLabelColor`, shows "No emails in [folder name]".

Update `updateMessages` to show/hide:

```swift
    func updateMessages(_ headers: [EmailHeader], folderName: String = "") {
        messages = headers
        threadGroups = groupByThread(headers)
        tableView.reloadData()

        emptyStateView.isHidden = !threadGroups.isEmpty
        emptySubtitle.stringValue = folderName.isEmpty ? "" : "No emails in \(folderName)"
    }
```

- [ ] **Step 2: Verify build succeeds**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/LiteMail/GUI/MessageListView.swift
git commit -m "feat: add empty state to MessageListView ('All caught up')"
```

---

### Task 14: Add row animations for batch operations

**Files:**
- Modify: `Sources/LiteMail/App/AppDelegate.swift`

- [ ] **Step 1: Replace reloadData with animated row removal for delete/archive**

In the batch action handlers in `AppDelegate.handleAction`, replace `loadMessages()` with:

```swift
// For delete/archive: animate row removal
let indices = windowController?.messageListView.indicesForIds(ids)
windowController?.messageListView.removeCheckedRows(at: indices ?? [])
```

Add helper to MessageListView:

```swift
    func indicesForIds(_ ids: [Int64]) -> IndexSet {
        var indexSet = IndexSet()
        for (i, group) in threadGroups.enumerated() {
            if ids.contains(group.primaryHeader.id) {
                indexSet.insert(i)
            }
        }
        return indexSet
    }

    func removeCheckedRows(at indices: IndexSet) {
        // Update data source first
        var remaining = threadGroups
        for i in indices.sorted().reversed() {
            remaining.remove(at: i)
        }
        threadGroups = remaining
        checkedIds.removeAll()

        // Animate
        tableView.beginUpdates()
        tableView.removeRows(at: indices, withAnimation: .effectFade)
        tableView.endUpdates()

        onCheckedIdsChanged?(checkedIds)
    }
```

- [ ] **Step 2: Verify animations work**

Run: `swift run LiteMail`
Expected: Checked emails fade out when deleted/archived.

- [ ] **Step 3: Commit**

```bash
git add Sources/LiteMail/GUI/MessageListView.swift Sources/LiteMail/App/AppDelegate.swift
git commit -m "feat: add animated row removal for batch delete/archive operations"
```

---

### Task 15: Wire thread expansion for batch operations

**Files:**
- Modify: `Sources/LiteMail/App/AppDelegate.swift`

- [ ] **Step 1: Expand thread groups before dispatching batch actions**

In AppDelegate, before dispatching any batch action, expand the checked IDs to include all thread members:

```swift
    private func expandThreadIds(_ checkedIds: [Int64]) async throws -> [Int64] {
        guard let accountManager else { return checkedIds }
        var expanded: Set<Int64> = []
        for id in checkedIds {
            // Find the thread group for this ID
            if let group = windowController?.messageListView.threadGroups.first(where: { $0.primaryHeader.id == id }),
               let threadId = group.threadId {
                let threadMembers = try await accountManager.fetchThread(threadId: threadId)
                for header in threadMembers {
                    expanded.insert(header.id)
                }
            } else {
                expanded.insert(id)
            }
        }
        return Array(expanded)
    }
```

Update each batch handler to call `expandThreadIds` first:

```swift
case .batchDelete(let ids) where !ids.isEmpty:
    let expandedIds = try await expandThreadIds(ids)
    try await accountManager.deleteBatch(emailIds: expandedIds)
    // ... rest of handler with expandedIds
```

- [ ] **Step 2: Update undo toast description to show expanded count**

```swift
    let description = expandedIds.count != ids.count
        ? "Deleted \(ids.count) conversations (\(expandedIds.count) messages)"
        : "Deleted \(ids.count) conversations"
```

- [ ] **Step 3: Verify thread expansion works**

Run: `swift run LiteMail`
Expected: Deleting a thread group deletes all messages in the thread.

- [ ] **Step 4: Commit**

```bash
git add Sources/LiteMail/App/AppDelegate.swift
git commit -m "feat: expand thread groups before batch dispatch (thread-aware bulk operations)"
```

---

### Task 16: GUI tests for bulk operations

**Files:**
- Create: `Tests/LiteMailGUITests/BulkSelectionTests.swift`

- [ ] **Step 1: Write GUI tests**

Create `Tests/LiteMailGUITests/BulkSelectionTests.swift` with tests for:
- Checkbox toggle adds/removes from checkedIds
- BulkActionBar appears when checkedIds >= 1
- BulkActionBar disappears when checkedIds drops to 0
- clearCheckedIds resets everything
- Keyboard shortcut dispatches batch action when checkboxes are checked

Follow the pattern from existing GUI tests in `Tests/LiteMailGUITests/`.

- [ ] **Step 2: Run GUI tests**

Run: `swift test --filter LiteMailGUITests`
Expected: All pass

- [ ] **Step 3: Run ALL tests**

Run: `swift test`
Expected: All pass (unit + integration + GUI)

- [ ] **Step 4: Commit**

```bash
git add Tests/LiteMailGUITests/BulkSelectionTests.swift
git commit -m "feat: add GUI tests for bulk selection, toolbar, and keyboard dispatch"
```

---

### Task 17: Final integration test + cleanup

- [ ] **Step 1: Run full test suite**

Run: `swift test`
Expected: All tests pass

- [ ] **Step 2: Build and smoke test**

Run: `swift build && swift run LiteMail`
Manual verification:
- Click checkboxes → toolbar appears
- Hit Delete → rows fade out → undo toast appears
- Press Cmd+Z → rows reappear
- Check emails from different accounts → batch dispatches per-account

- [ ] **Step 3: Final commit**

```bash
git add -A
git commit -m "chore: final cleanup for bulk email operations feature"
```
