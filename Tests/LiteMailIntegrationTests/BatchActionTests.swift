import XCTest
@testable import LiteMail

final class BatchActionTests: XCTestCase {

    // MARK: - deleteBatch

    func testDeleteBatchEnqueuesAndWorkerDrainsToProvider() async throws {
        let (manager, mockProvider, store) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())
        await manager.startDeleteWorker()

        let id1 = try await store.insertEmail(TestData.makeEmailRecord(messageId: "<del-b-1@test>", uid: 100))
        let id2 = try await store.insertEmail(TestData.makeEmailRecord(messageId: "<del-b-2@test>", uid: 101))
        let id3 = try await store.insertEmail(TestData.makeEmailRecord(messageId: "<del-b-3@test>", uid: 102))

        try await manager.deleteBatch(emailIds: [id1, id2, id3])

        // kick() inside deleteBatch runs the worker once; if the mock succeeds,
        // the emails should be hard-deleted by now.
        let remaining = try await store.fetchEmailRecords(ids: [id1, id2, id3])
        XCTAssertTrue(remaining.isEmpty, "success path: emails hard-deleted after worker drain")

        let deleteCalls = await mockProvider.deleteCalls
        XCTAssertEqual(deleteCalls.count, 3)
    }

    // MARK: - markReadBatch

    func testMarkReadBatchUpdatesStore() async throws {
        let (manager, mockProvider, store) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        var ids: [Int64] = []
        for i in 1...5 {
            let id = try await store.insertEmail(
                TestData.makeEmailRecord(messageId: "<read-b-\(i)@test>", uid: 200 + i, isRead: false)
            )
            ids.append(id)
        }

        try await manager.markReadBatch(emailIds: ids, read: true)

        for id in ids {
            let record = try await store.fetchEmailRecord(id: id)
            XCTAssertEqual(record?.isRead, true, "email \(id) should be marked read")
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        let readCalls = await mockProvider.markReadCalls
        XCTAssertEqual(readCalls.count, 5, "provider should receive 5 markRead refs")
        XCTAssertTrue(readCalls.allSatisfy { $0.read == true })
    }

    func testMarkReadBatchUnread() async throws {
        let (manager, _, store) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        let id1 = try await store.insertEmail(TestData.makeEmailRecord(messageId: "<unread-b-1@test>", uid: 300, isRead: true))
        let id2 = try await store.insertEmail(TestData.makeEmailRecord(messageId: "<unread-b-2@test>", uid: 301, isRead: true))

        try await manager.markReadBatch(emailIds: [id1, id2], read: false)

        for id in [id1, id2] {
            let record = try await store.fetchEmailRecord(id: id)
            XCTAssertEqual(record?.isRead, false, "email \(id) should be marked unread")
        }
    }

    // MARK: - markStarredBatch

    func testMarkStarredBatchUpdatesStore() async throws {
        let (manager, mockProvider, store) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        let id1 = try await store.insertEmail(TestData.makeEmailRecord(messageId: "<star-b-1@test>", uid: 400, isStarred: false))
        let id2 = try await store.insertEmail(TestData.makeEmailRecord(messageId: "<star-b-2@test>", uid: 401, isStarred: false))

        try await manager.markStarredBatch(emailIds: [id1, id2], starred: true)

        for id in [id1, id2] {
            let record = try await store.fetchEmailRecord(id: id)
            XCTAssertEqual(record?.isStarred, true, "email \(id) should be starred")
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        let starCalls = await mockProvider.markStarredCalls
        XCTAssertEqual(starCalls.count, 2)
        XCTAssertTrue(starCalls.allSatisfy { $0.starred == true })
    }

    // MARK: - moveBatch

    func testMoveBatchUpdatesStoreAndDispatchesProvider() async throws {
        let (manager, mockProvider, store) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        let id1 = try await store.insertEmail(TestData.makeEmailRecord(messageId: "<move-b-1@test>", folder: "INBOX", uid: 500))
        let id2 = try await store.insertEmail(TestData.makeEmailRecord(messageId: "<move-b-2@test>", folder: "INBOX", uid: 501))

        try await manager.moveBatch(emailIds: [id1, id2], toFolder: "[Gmail]/Trash")

        for id in [id1, id2] {
            let record = try await store.fetchEmailRecord(id: id)
            XCTAssertEqual(record?.folder, "[Gmail]/Trash", "email \(id) should be in Trash")
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        let moveCalls = await mockProvider.moveCalls
        XCTAssertEqual(moveCalls.count, 2)
        XCTAssertTrue(moveCalls.allSatisfy { $0.toFolderId == "[Gmail]/Trash" })
    }

    // MARK: - archiveBatch

    func testArchiveBatchUpdatesStoreAndDispatchesProvider() async throws {
        let (manager, mockProvider, store) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        let id1 = try await store.insertEmail(TestData.makeEmailRecord(messageId: "<arch-b-1@test>", folder: "INBOX", uid: 600))
        let id2 = try await store.insertEmail(TestData.makeEmailRecord(messageId: "<arch-b-2@test>", folder: "INBOX", uid: 601))

        try await manager.archiveBatch(emailIds: [id1, id2])

        for id in [id1, id2] {
            let record = try await store.fetchEmailRecord(id: id)
            XCTAssertEqual(record?.folder, "[Gmail]/All Mail", "email \(id) should be archived")
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        let moveCalls = await mockProvider.moveCalls
        XCTAssertEqual(moveCalls.count, 2)
        XCTAssertTrue(moveCalls.allSatisfy { $0.toFolderId == "[Gmail]/All Mail" })
    }

    // MARK: - Empty array edge cases

    func testBatchWithEmptyArrayDoesNotCrash() async throws {
        let (manager, mockProvider, _) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        // None of these should throw or crash
        try await manager.deleteBatch(emailIds: [])
        try await manager.archiveBatch(emailIds: [])
        try await manager.markReadBatch(emailIds: [], read: true)
        try await manager.markStarredBatch(emailIds: [], starred: true)
        try await manager.moveBatch(emailIds: [], toFolder: "INBOX")

        try await Task.sleep(nanoseconds: 50_000_000)

        // No provider calls should have been made
        let deleteCalls = await mockProvider.deleteCalls
        let moveCalls = await mockProvider.moveCalls
        let readCalls = await mockProvider.markReadCalls
        let starCalls = await mockProvider.markStarredCalls
        XCTAssertEqual(deleteCalls.count, 0)
        XCTAssertEqual(moveCalls.count, 0)
        XCTAssertEqual(readCalls.count, 0)
        XCTAssertEqual(starCalls.count, 0)
    }

    // MARK: - Cross-account batch

    func testDeleteBatchAcrossTwoAccounts() async throws {
        let store = try MailStore(path: ":memory:")
        let authManager = AuthManager()

        let providerA = MockMailProvider(accountId: "account-a", emailAddress: "a@example.com")
        let providerB = MockMailProvider(accountId: "account-b", emailAddress: "b@example.com")

        let providers: [String: MockMailProvider] = [
            "account-a": providerA,
            "account-b": providerB,
        ]

        let manager = AccountManager(store: store, authManager: authManager) { config, _, _ in
            providers[config.id]!
        }

        // Add both accounts
        try await manager.addAccount(TestData.makeAccountConfig(id: "account-a", email: "a@example.com"))
        try await manager.addAccount(TestData.makeAccountConfig(id: "account-b", email: "b@example.com"))
        await manager.startDeleteWorker()

        // Insert emails for each account
        let idA1 = try await store.insertEmail(TestData.makeEmailRecord(messageId: "<xa-1@test>", accountId: "account-a", uid: 700))
        let idA2 = try await store.insertEmail(TestData.makeEmailRecord(messageId: "<xa-2@test>", accountId: "account-a", uid: 701))
        let idB1 = try await store.insertEmail(TestData.makeEmailRecord(messageId: "<xb-1@test>", accountId: "account-b", uid: 702))

        try await manager.deleteBatch(emailIds: [idA1, idA2, idB1])

        // Worker drain via kick() hard-deletes all three
        let remaining = try await store.fetchEmailRecords(ids: [idA1, idA2, idB1])
        XCTAssertTrue(remaining.isEmpty, "all emails hard-deleted after worker drain")

        // Each provider gets only its own refs
        let deleteA = await providerA.deleteCalls
        let deleteB = await providerB.deleteCalls
        XCTAssertEqual(deleteA.count, 2, "account-a provider should receive 2 delete refs")
        XCTAssertEqual(deleteB.count, 1, "account-b provider should receive 1 delete ref")
    }
}
