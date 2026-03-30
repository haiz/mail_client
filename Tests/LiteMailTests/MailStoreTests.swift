import XCTest
import GRDB
@testable import LiteMail

final class MailStoreTests: XCTestCase {

    private var store: MailStore!
    private var dbPath: String!

    override func setUp() async throws {
        dbPath = NSTemporaryDirectory() + "litemail_test_\(UUID().uuidString).sqlite"
        store = try MailStore(path: dbPath)
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    // MARK: - Schema Tests

    func testFreshInstallCreatesAllTables() async throws {
        // The store was just created in setUp, so all tables should exist
        let count = try await store.emailCount()
        XCTAssertEqual(count, 0)
    }

    // MARK: - Insert Tests

    func testInsertEmail() async throws {
        let record = EmailRecord(
            messageId: "<test@example.com>",
            threadId: "thread-1",
            folder: "INBOX",
            senderName: "Alice",
            senderEmail: "alice@example.com",
            subject: "Hello World",
            date: Int(Date().timeIntervalSince1970),
            isRead: false,
            isStarred: false,
            isDeleted: false,
            hasAttachments: false
        )

        let id = try await store.insertEmail(record)
        XCTAssertGreaterThan(id, 0)

        let count = try await store.emailCount()
        XCTAssertEqual(count, 1)
    }

    func testDuplicateMessageIdRejected() async throws {
        let record = EmailRecord(
            messageId: "<dup@example.com>",
            folder: "INBOX",
            senderEmail: "bob@example.com",
            date: Int(Date().timeIntervalSince1970),
            isRead: false,
            isStarred: false,
            isDeleted: false,
            hasAttachments: false
        )

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
        let record = EmailRecord(
            messageId: "<search-test@example.com>",
            folder: "INBOX",
            senderName: "Charlie",
            senderEmail: "charlie@example.com",
            subject: "API migration timeline",
            date: Int(Date().timeIntervalSince1970),
            isRead: false,
            isStarred: false,
            isDeleted: false,
            hasAttachments: false
        )

        let id = try await store.insertEmail(record)
        try await store.insertBody(emailId: id, text: "The new endpoints are ready for review.", html: nil)

        let results = try await store.search(query: "migration")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.subject, "API migration timeline")
    }

    func testSearchBodyText() async throws {
        let record = EmailRecord(
            messageId: "<body-search@example.com>",
            folder: "INBOX",
            senderEmail: "dave@example.com",
            subject: "Meeting notes",
            date: Int(Date().timeIntervalSince1970),
            isRead: false,
            isStarred: false,
            isDeleted: false,
            hasAttachments: false
        )

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

    // MARK: - Thread Tests

    func testFetchThread() async throws {
        let now = Int(Date().timeIntervalSince1970)

        for i in 0..<3 {
            let record = EmailRecord(
                messageId: "<thread-\(i)@example.com>",
                threadId: "thread-abc",
                folder: "INBOX",
                senderEmail: "alice@example.com",
                subject: "Thread subject",
                date: now + i,
                isRead: false,
                isStarred: false,
                isDeleted: false,
                hasAttachments: false
            )
            _ = try await store.insertEmail(record)
        }

        let thread = try await store.fetchThread(threadId: "thread-abc")
        XCTAssertEqual(thread.count, 3)
        // Should be chronological order
        XCTAssertTrue(thread[0].date <= thread[1].date)
        XCTAssertTrue(thread[1].date <= thread[2].date)
    }

    func testFetchMissingThreadReturnsEmpty() async throws {
        let thread = try await store.fetchThread(threadId: "nonexistent")
        XCTAssertTrue(thread.isEmpty)
    }

    // MARK: - Action Tests

    func testMarkRead() async throws {
        let record = EmailRecord(
            messageId: "<read-test@example.com>",
            folder: "INBOX",
            senderEmail: "eve@example.com",
            date: Int(Date().timeIntervalSince1970),
            isRead: false,
            isStarred: false,
            isDeleted: false,
            hasAttachments: false
        )

        let id = try await store.insertEmail(record)
        try await store.markRead(emailId: id, read: true)

        let headers = try await store.fetchHeaders(folder: "INBOX", offset: 0, limit: 10)
        XCTAssertTrue(headers.first?.isRead ?? false)
    }

    // MARK: - Outbox Tests

    func testQueueAndFetchOutgoing() async throws {
        let outgoing = OutboxRecord(
            toRecipients: "[\"bob@example.com\"]",
            subject: "Test send",
            bodyText: "Hello from outbox",
            status: "queued"
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
            status: "queued"
        )

        let id = try await store.queueOutgoing(outgoing)
        try await store.updateOutboxStatus(id: id, status: "sending")
        try await store.updateOutboxStatus(id: id, status: "sent")

        let pending = try await store.fetchPendingOutbox()
        XCTAssertTrue(pending.isEmpty)
    }
}
