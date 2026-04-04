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

    func testDuplicateMessageIdRejected() async throws {
        let record = makeEmail(messageId: "<dup@example.com>")
        _ = try await store.insertEmail(record)

        do {
            _ = try await store.insertEmail(record)
            XCTFail("Should have thrown on duplicate message_id")
        } catch {
            // Expected: UNIQUE constraint violation
        }
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
        let byEmail = try await store.lookupContacts(prefix: "bob", accountId: "acc1")
        XCTAssertEqual(byEmail.count, 1)
        XCTAssertEqual(byEmail.first?.name, "Bob Smith")

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

    // MARK: - Helpers

    private func makeEmail(
        messageId: String,
        subject: String? = "Test Subject",
        senderName: String? = nil,
        accountId: String? = nil
    ) -> EmailRecord {
        EmailRecord(
            messageId: messageId,
            folder: "INBOX",
            senderEmail: "sender@example.com",
            subject: subject,
            date: Int(Date().timeIntervalSince1970),
            isRead: false,
            isStarred: false,
            isDeleted: false,
            hasAttachments: false,
            accountId: accountId ?? testAccountId
        )
    }
}
