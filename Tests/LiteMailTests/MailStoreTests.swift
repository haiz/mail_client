import XCTest
import GRDB
@testable import LiteMail

final class MailStoreTests: XCTestCase {

    private var store: MailStore!
    private var dbPath: String!
    private let testAccountId = "test-account"

    override func setUp() async throws {
        dbPath = NSTemporaryDirectory() + "litemail_test_\(UUID().uuidString).sqlite"
        store = try MailStore(path: dbPath)

        // Insert a test account for v2 schema
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

    // MARK: - Schema Tests

    func testFreshInstallCreatesAllTables() async throws {
        let count = try await store.emailCount()
        XCTAssertEqual(count, 0)
    }

    // MARK: - Account Tests

    func testInsertAndListAccounts() async throws {
        let accounts = try await store.listAccounts()
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.emailAddress, "test@example.com")
    }

    func testDeleteAccountCascadesEmails() async throws {
        let record = makeEmail(messageId: "<cascade@test.com>")
        _ = try await store.insertEmail(record)
        let countBefore = try await store.emailCount(accountId: testAccountId)
        XCTAssertEqual(countBefore, 1)

        try await store.deleteAccount(id: testAccountId)
        let remaining = try await store.emailCount(accountId: testAccountId)
        XCTAssertEqual(remaining, 0)

        let accounts = try await store.listAccounts()
        XCTAssertTrue(accounts.isEmpty)
    }

    // MARK: - Insert Tests

    func testInsertEmail() async throws {
        let record = makeEmail(messageId: "<test@example.com>")
        let id = try await store.insertEmail(record)
        XCTAssertGreaterThan(id, 0)

        let count = try await store.emailCount()
        XCTAssertEqual(count, 1)
    }

    func testDuplicateUidIsIgnoredAndReturnsExistingId() async throws {
        // Same (account_id, folder, uid) inserted twice must be silently ignored.
        // The second call returns the existing row's ID.
        let record = makeEmail(messageId: "<dup@example.com>", uid: 42)
        let id1 = try await store.insertEmail(record)
        XCTAssertGreaterThan(id1, 0)

        let id2 = try await store.insertEmail(record)
        XCTAssertEqual(id1, id2, "Second insert for same UID must return the existing row ID")

        let count = try await store.emailCount(accountId: testAccountId)
        XCTAssertEqual(count, 1, "Only one row should exist")
    }

    func testCrossAccountSameMessageIdAllowed() async throws {
        // The core bug: same message_id in two different accounts must both be stored.
        // e.g. hai@caodev.top's Sent and cthai83@gmail.com's INBOX share a message_id.
        let account2 = AccountRecord(
            id: "acct2",
            emailAddress: "other@example.com",
            protocolType: "imap",
            authType: "password",
            keychainRef: "k2",
            isDefault: false
        )
        try await store.insertAccount(account2)

        let sent = makeEmail(messageId: "<shared@example.com>", accountId: testAccountId, uid: 10)
        let inbox = makeEmail(messageId: "<shared@example.com>", accountId: "acct2", uid: 5)

        let id1 = try await store.insertEmail(sent)
        let id2 = try await store.insertEmail(inbox)

        XCTAssertGreaterThan(id1, 0)
        XCTAssertGreaterThan(id2, 0)
        XCTAssertNotEqual(id1, id2, "Each account stores its own copy of the email")

        let count1 = try await store.emailCount(accountId: testAccountId)
        let count2 = try await store.emailCount(accountId: "acct2")
        XCTAssertEqual(count1, 1)
        XCTAssertEqual(count2, 1)
    }

    func testNilUidNeverConflicts() async throws {
        // Emails with uid=nil are not covered by the partial index.
        // Two nil-uid emails with the same message_id can coexist (edge case: demo/offline data).
        let r1 = makeEmail(messageId: "<no-uid@example.com>", uid: nil)
        let r2 = makeEmail(messageId: "<no-uid@example.com>", uid: nil)

        let id1 = try await store.insertEmail(r1)
        let id2 = try await store.insertEmail(r2)

        XCTAssertGreaterThan(id1, 0)
        XCTAssertGreaterThan(id2, 0)
        // Both rows stored — no UID to deduplicate on
        let count = try await store.emailCount(accountId: testAccountId)
        XCTAssertEqual(count, 2, "Both nil-uid rows should be stored independently")
    }

    func testSameMessageIdInDifferentFoldersAllowed() async throws {
        // Gmail multi-label model: same message can appear in INBOX and a label folder
        let inboxRecord = makeEmail(messageId: "<multi@example.com>", folder: "INBOX")
        let labelRecord = makeEmail(messageId: "<multi@example.com>", folder: "Work")
        let id1 = try await store.insertEmail(inboxRecord)
        let id2 = try await store.insertEmail(labelRecord)
        XCTAssertGreaterThan(id1, 0)
        XCTAssertGreaterThan(id2, 0)
        XCTAssertNotEqual(id1, id2)
    }

    // MARK: - Search Tests

    func testSearchFindsMatchingEmail() async throws {
        let record = makeEmail(messageId: "<search-test@example.com>", subject: "API migration timeline", senderName: "Charlie")
        let id = try await store.insertEmail(record)
        try await store.insertBody(emailId: id, text: "The new endpoints are ready for review.", html: nil)

        let results = try await store.search(query: "migration")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.subject, "API migration timeline")
    }

    func testSearchBodyText() async throws {
        let record = makeEmail(messageId: "<body-search@example.com>", subject: "Meeting notes")
        let id = try await store.insertEmail(record)
        try await store.insertBody(emailId: id, text: "We discussed the Kubernetes deployment strategy.", html: nil)

        let results = try await store.search(query: "Kubernetes")
        XCTAssertEqual(results.count, 1)
    }

    func testSearchEmptyQueryReturnsNothing() async throws {
        let results = try await store.search(query: "")
        XCTAssertTrue(results.isEmpty)
    }

    func testSearchNoResultsReturnsEmpty() async throws {
        let results = try await store.search(query: "nonexistent")
        XCTAssertTrue(results.isEmpty)
    }

    func testCrossAccountSearch() async throws {
        // Add second account
        let account2 = AccountRecord(id: "acct2", emailAddress: "user2@example.com", protocolType: "imap", authType: "password", keychainRef: "k2", isDefault: false)
        try await store.insertAccount(account2)

        let r1 = makeEmail(messageId: "<acct1@test.com>", subject: "Kubernetes deploy", accountId: testAccountId)
        let r2 = makeEmail(messageId: "<acct2@test.com>", subject: "Kubernetes cluster", accountId: "acct2")
        let id1 = try await store.insertEmail(r1)
        let id2 = try await store.insertEmail(r2)
        try await store.insertBody(emailId: id1, text: "Deploy to production", html: nil)
        try await store.insertBody(emailId: id2, text: "Cluster management", html: nil)

        // Cross-account search (nil accountId)
        let allResults = try await store.search(query: "Kubernetes", accountId: nil)
        XCTAssertEqual(allResults.count, 2)

        // Account-specific search
        let acct1Results = try await store.search(query: "Kubernetes", accountId: testAccountId)
        XCTAssertEqual(acct1Results.count, 1)
    }

    // MARK: - Thread Tests

    func testFetchThread() async throws {
        let now = Int(Date().timeIntervalSince1970)
        for i in 0..<3 {
            var record = makeEmail(messageId: "<thread-\(i)@example.com>")
            record.threadId = "thread-abc"
            record.date = now + i
            _ = try await store.insertEmail(record)
        }

        let thread = try await store.fetchThread(threadId: "thread-abc")
        XCTAssertEqual(thread.count, 3)
        XCTAssertTrue(thread[0].date <= thread[1].date)
    }

    func testFetchMissingThreadReturnsEmpty() async throws {
        let thread = try await store.fetchThread(threadId: "nonexistent")
        XCTAssertTrue(thread.isEmpty)
    }

    // MARK: - Action Tests

    func testMarkRead() async throws {
        let record = makeEmail(messageId: "<read-test@example.com>")
        let id = try await store.insertEmail(record)
        try await store.markRead(emailId: id, read: true)

        let headers = try await store.fetchHeaders(accountId: testAccountId, folder: "INBOX", offset: 0, limit: 10)
        XCTAssertTrue(headers.first?.isRead ?? false)
    }

    // MARK: - Outbox Tests

    func testQueueAndFetchOutgoing() async throws {
        let outgoing = OutboxRecord(
            toRecipients: "[\"bob@example.com\"]",
            subject: "Test send",
            bodyText: "Hello from outbox",
            status: "queued",
            accountId: testAccountId
        )
        _ = try await store.queueOutgoing(outgoing)
        let pending = try await store.fetchPendingOutbox()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.subject, "Test send")
    }

    func testOutboxStatusTransition() async throws {
        let outgoing = OutboxRecord(
            toRecipients: "[\"carol@example.com\"]",
            subject: "Status test",
            status: "queued",
            accountId: testAccountId
        )
        let id = try await store.queueOutgoing(outgoing)
        try await store.updateOutboxStatus(id: id, status: "sending")
        try await store.updateOutboxStatus(id: id, status: "sent")

        let pending = try await store.fetchPendingOutbox()
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - Contacts Tests

    func testContactsTableExists() async throws {
        let store = try MailStore(path: ":memory:")
        try await store.insertAccount(AccountRecord(id: "acc1", emailAddress: "acc1@test.com", protocolType: "imap", authType: "oauth2", keychainRef: "k1", isDefault: false))
        try await store.upsertContacts([
            ContactRecord(id: "people/c1", accountId: "acc1", name: "Alice", email: "alice@gmail.com", photoURL: nil, syncedAt: 1000)
        ])
        let results = try await store.lookupContacts(prefix: "ali", accountId: "acc1")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.email, "alice@gmail.com")
    }

    func testContactLookupIsPrefixMatchOnEmailAndName() async throws {
        let store = try MailStore(path: ":memory:")
        try await store.insertAccount(AccountRecord(id: "acc1", emailAddress: "acc1@test.com", protocolType: "imap", authType: "oauth2", keychainRef: "k1", isDefault: false))
        try await store.upsertContacts([
            ContactRecord(id: "c1", accountId: "acc1", name: "Bob Smith", email: "bob@example.com", photoURL: nil, syncedAt: 1000),
            ContactRecord(id: "c2", accountId: "acc1", name: "Alice Jones", email: "alice@example.com", photoURL: nil, syncedAt: 1000),
        ])
        let byEmail = try await store.lookupContacts(prefix: "bob", accountId: "acc1")
        XCTAssertEqual(byEmail.count, 1)
        XCTAssertEqual(byEmail.first?.name, "Bob Smith")

        let byName = try await store.lookupContacts(prefix: "Alice", accountId: "acc1")
        XCTAssertEqual(byName.count, 1)
        XCTAssertEqual(byName.first?.email, "alice@example.com")
    }

    func testContactsAreAccountScoped() async throws {
        let store = try MailStore(path: ":memory:")
        try await store.insertAccount(AccountRecord(id: "acc1", emailAddress: "acc1@test.com", protocolType: "imap", authType: "oauth2", keychainRef: "k1", isDefault: false))
        try await store.upsertContacts([
            ContactRecord(id: "c1", accountId: "acc1", name: "Alice", email: "alice@gmail.com", photoURL: nil, syncedAt: 1000),
        ])
        let acc2Results = try await store.lookupContacts(prefix: "alice", accountId: "acc2")
        XCTAssertTrue(acc2Results.isEmpty)
    }

    // MARK: - Migration Tests

    func testV7MigrationAddsDeleteStateAndDeleteJobs() async throws {
        let path = NSTemporaryDirectory() + "litemail_v7_\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MailStore(path: path)

        let columns: [String] = try await store.concurrentReader.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(emails)").compactMap { $0["name"] as String? }
        }
        XCTAssertTrue(columns.contains("delete_state"), "emails.delete_state missing")

        let hasTable: Int = try await store.concurrentReader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='delete_jobs'") ?? 0
        }
        XCTAssertEqual(hasTable, 1, "delete_jobs table missing")

        let defaultState: String? = try await store.concurrentReader.read { db in
            try String.fetchOne(db, sql: """
                SELECT dflt_value FROM pragma_table_info('emails') WHERE name='delete_state'
            """)
        }
        XCTAssertEqual(defaultState, "'synced'")
    }

    // MARK: - DeleteState Tests

    func testEmailRecordRoundTripsDeleteState() async throws {
        let path = NSTemporaryDirectory() + "litemail_estate_\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MailStore(path: path)
        let acc = AccountRecord(id: "a1", emailAddress: "x@y.z", protocolType: "imap",
                                authType: "password", keychainRef: "k", isDefault: true)
        try await store.insertAccount(acc)

        var rec = EmailRecord(
            messageId: "m1@x", folder: "INBOX", senderEmail: "s@x", date: 1,
            isRead: false, isStarred: false, isDeleted: false, hasAttachments: false,
            uid: 10, accountId: "a1"
        )
        rec.deleteState = "pending_delete"
        let id = try await store.insertEmail(rec)
        XCTAssertGreaterThan(id, 0)

        let fetched: EmailRecord? = try await store.concurrentReader.read { db in
            try EmailRecord.fetchOne(db, key: id)
        }
        XCTAssertEqual(fetched?.deleteState, "pending_delete")
    }

    // MARK: - DeleteJobRecord Tests

    func testDeleteJobRecordRoundTrip() async throws {
        let path = NSTemporaryDirectory() + "litemail_djr_\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MailStore(path: path)
        let acc = AccountRecord(id: "a1", emailAddress: "x@y.z", protocolType: "imap",
                                authType: "password", keychainRef: "k", isDefault: true)
        try await store.insertAccount(acc)
        let em = EmailRecord(messageId: "m@x", folder: "INBOX", senderEmail: "s@x",
                             date: 0, isRead: false, isStarred: false, isDeleted: false,
                             hasAttachments: false, uid: 1, accountId: "a1")
        let emailId = try await store.insertEmail(em)

        let job = DeleteJobRecord(
            id: nil, accountId: "a1", emailId: emailId, folder: "INBOX", uid: 1,
            state: "queued", attempts: 0, lastError: nil,
            nextAttemptAt: 100, createdAt: 100
        )
        let saved: DeleteJobRecord = try await store.insertDeleteJob(job)
        XCTAssertNotNil(saved.id)
        XCTAssertEqual(saved.folder, "INBOX")
        XCTAssertEqual(saved.uid, 1)
        XCTAssertEqual(saved.state, "queued")
    }

    // MARK: - Helpers

    private func makeEmail(
        messageId: String,
        subject: String? = "Test Subject",
        senderName: String? = nil,
        accountId: String? = nil,
        folder: String = "INBOX",
        uid: Int? = nil
    ) -> EmailRecord {
        var record = EmailRecord(
            messageId: messageId,
            folder: folder,
            senderEmail: "sender@example.com",
            subject: subject,
            date: Int(Date().timeIntervalSince1970),
            isRead: false,
            isStarred: false,
            isDeleted: false,
            hasAttachments: false,
            accountId: accountId ?? testAccountId
        )
        record.uid = uid
        return record
    }
}
