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
}
