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

    func testFetchThreadExcludesDeletedEmails() async throws {
        for i in 1...3 {
            var record = EmailRecord(
                messageId: "msg-\(i)@test.com",
                folder: "INBOX",
                senderEmail: "sender@test.com",
                date: 1000 + i,
                isRead: false,
                isStarred: false,
                isDeleted: false,
                hasAttachments: false,
                accountId: testAccountId
            )
            record.threadId = "thread-1"
            _ = try await store.insertEmail(record)
        }

        let all = try await store.fetchThread(threadId: "thread-1")
        XCTAssertEqual(all.count, 3)
        try await store.markDeleted(emailId: all[0].id!)

        let afterDelete = try await store.fetchThread(threadId: "thread-1")
        XCTAssertEqual(afterDelete.count, 2)
        XCTAssertFalse(afterDelete.contains(where: { $0.id == all[0].id }))
    }

    // MARK: - Helpers

    private func insertTestEmails(count: Int, folder: String = "INBOX") async throws -> [Int64] {
        var ids: [Int64] = []
        for i in 1...count {
            let record = EmailRecord(
                messageId: "batch-\(UUID().uuidString)@test.com",
                folder: folder,
                senderEmail: "sender\(i)@test.com",
                date: 1000 + i,
                isRead: false,
                isStarred: false,
                isDeleted: false,
                hasAttachments: false,
                accountId: testAccountId
            )
            let id = try await store.insertEmail(record)
            ids.append(id)
        }
        return ids
    }

    // MARK: - Batch Operations

    func testMarkReadBatch() async throws {
        let ids = try await insertTestEmails(count: 5)
        try await store.markReadBatch(emailIds: ids, read: true)
        for id in ids {
            let record = try await store.fetchEmailRecord(id: id)
            XCTAssertTrue(record!.isRead)
        }
    }

    func testMarkReadBatchEmptyArray() async throws {
        try await store.markReadBatch(emailIds: [], read: true)
    }

    func testMarkStarredBatch() async throws {
        let ids = try await insertTestEmails(count: 3)
        try await store.markStarredBatch(emailIds: ids, starred: true)
        for id in ids {
            let record = try await store.fetchEmailRecord(id: id)
            XCTAssertTrue(record!.isStarred)
        }
    }

    func testMarkDeletedBatch() async throws {
        let ids = try await insertTestEmails(count: 4)
        try await store.markDeletedBatch(emailIds: ids)
        for id in ids {
            let record = try await store.fetchEmailRecord(id: id)
            XCTAssertTrue(record!.isDeleted)
        }
    }

    func testUnmarkDeletedBatch() async throws {
        let ids = try await insertTestEmails(count: 3)
        try await store.markDeletedBatch(emailIds: ids)
        try await store.unmarkDeletedBatch(emailIds: ids)
        for id in ids {
            let record = try await store.fetchEmailRecord(id: id)
            XCTAssertFalse(record!.isDeleted)
        }
    }

    func testMoveEmailBatch() async throws {
        let ids = try await insertTestEmails(count: 3, folder: "INBOX")
        try await store.moveEmailBatch(emailIds: ids, toFolder: "Archive")
        for id in ids {
            let record = try await store.fetchEmailRecord(id: id)
            XCTAssertEqual(record!.folder, "Archive")
        }
    }

    func testFetchEmailRecords() async throws {
        let ids = try await insertTestEmails(count: 3)
        let records = try await store.fetchEmailRecords(ids: ids)
        XCTAssertEqual(records.count, 3)
    }

    func testBatchWithNonexistentIds() async throws {
        let ids = try await insertTestEmails(count: 2)
        try await store.markReadBatch(emailIds: ids + [99999], read: true)
        for id in ids {
            let record = try await store.fetchEmailRecord(id: id)
            XCTAssertTrue(record!.isRead)
        }
    }
}
