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

    private func insertTestEmail(folder: String = "INBOX", uid: Int? = nil) async throws -> Int64 {
        let rec = EmailRecord(
            messageId: "msg-\(UUID().uuidString)@test",
            folder: folder, senderEmail: "s@test",
            date: Int(Date().timeIntervalSince1970),
            isRead: false, isStarred: false, isDeleted: false,
            hasAttachments: false, uid: uid, accountId: testAccountId
        )
        return try await store.insertEmail(rec)
    }

    private func insertTestEmails(count: Int, folder: String = "INBOX") async throws -> [Int64] {
        var ids: [Int64] = []
        for i in 1...count {
            let id = try await insertTestEmail(folder: folder, uid: 1000 + i)
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

    // MARK: - Enqueue Deletes

    func testEnqueueDeletesSetsStateAndCreatesJobsAtomically() async throws {
        let ids = try await insertTestEmails(count: 3, folder: "INBOX")
        let recs = try await store.fetchEmailRecords(ids: ids)
        // Fill folder/uid that fetchEmailRecords already has
        try await store.enqueueDeletes(records: recs, now: 1000)

        let states: [String] = try await store.concurrentReader.read { db in
            try String.fetchAll(db, sql: "SELECT delete_state FROM emails WHERE id IN (?,?,?)",
                                arguments: [ids[0], ids[1], ids[2]])
        }
        XCTAssertEqual(Set(states), ["pending_delete"])

        let jobCount: Int = try await store.concurrentReader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM delete_jobs") ?? -1
        }
        XCTAssertEqual(jobCount, 3)
    }

    func testEnqueueDeletesSkipsRecordsWithoutUid() async throws {
        // A record missing uid can't be deleted server-side; skip it and don't mark pending.
        let id = try await insertTestEmail(folder: "INBOX", uid: nil)
        let recs = try await store.fetchEmailRecords(ids: [id])
        try await store.enqueueDeletes(records: recs, now: 1000)

        let state: String? = try await store.concurrentReader.read { db in
            try String.fetchOne(db, sql: "SELECT delete_state FROM emails WHERE id=?", arguments: [id])
        }
        XCTAssertEqual(state, "synced")
        let jobCount: Int = try await store.concurrentReader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM delete_jobs") ?? -1
        }
        XCTAssertEqual(jobCount, 0)
    }
}
