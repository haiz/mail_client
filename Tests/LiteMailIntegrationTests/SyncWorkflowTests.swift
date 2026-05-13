import XCTest
@testable import LiteMail

final class SyncWorkflowTests: XCTestCase {

    func testInitialSyncCallsProvider() async throws {
        let (manager, mockProvider, store) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        for i in 1...5 {
            _ = try await store.insertEmail(
                TestData.makeEmailRecord(messageId: "<sync-\(i)@test>", accountId: "test-account", uid: i)
            )
        }

        try await manager.performInitialSync(accountId: "test-account")

        let calls = await mockProvider.calls
        XCTAssertTrue(calls.contains("performInitialSync"))

        let headers = try await store.fetchHeaders(accountId: "test-account", folder: "INBOX", offset: 0, limit: 100)
        XCTAssertEqual(headers.count, 5)
    }

    func testIncrementalSyncCallsProvider() async throws {
        let (manager, mockProvider, _) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        try await manager.performIncrementalSync(accountId: "test-account")

        let calls = await mockProvider.calls
        XCTAssertTrue(calls.contains("performIncrementalSync"))
    }

    func testSyncUidDedup() async throws {
        // v14: dedup is by message_id. Inserting the same message_id twice (simulating a
        // re-sync of the same folder) returns the same email_id and produces one row.
        let (manager, _, store) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        let id1 = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<dup@test>", accountId: "test-account", uid: 42)
        )
        let id2 = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<dup@test>", accountId: "test-account", uid: 42)
        )

        XCTAssertEqual(id1, id2, "Re-syncing same message_id returns the existing row id")

        let headers = try await store.fetchHeaders(accountId: "test-account", folder: "INBOX", offset: 0, limit: 100)
        XCTAssertEqual(headers.count, 1, "Re-sync does not create a duplicate")
    }

    func testSyncAccountIsolation() async throws {
        let store = try MailStore(path: ":memory:")
        let authManager = AuthManager()

        let mock1 = MockMailProvider(accountId: "acc1")
        let mock2 = MockMailProvider(accountId: "acc2")

        let manager = AccountManager(store: store, authManager: authManager) { config, _, _ in
            if config.id == "acc1" { return mock1 }
            return mock2
        }

        try await manager.addAccount(TestData.makeAccountConfig(id: "acc1", email: "a@test.com"))
        try await manager.addAccount(TestData.makeAccountConfig(id: "acc2", email: "b@test.com"))

        for i in 1...3 {
            _ = try await store.insertEmail(
                TestData.makeEmailRecord(messageId: "<acc1-\(i)@test>", accountId: "acc1", uid: i)
            )
        }
        for i in 1...2 {
            _ = try await store.insertEmail(
                TestData.makeEmailRecord(messageId: "<acc2-\(i)@test>", accountId: "acc2", uid: i)
            )
        }

        let acc1Headers = try await store.fetchHeaders(accountId: "acc1", folder: "INBOX", offset: 0, limit: 100)
        let acc2Headers = try await store.fetchHeaders(accountId: "acc2", folder: "INBOX", offset: 0, limit: 100)

        XCTAssertEqual(acc1Headers.count, 3)
        XCTAssertEqual(acc2Headers.count, 2)
    }

    func testSyncFailureMidway() async throws {
        let (manager, mockProvider, store) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        _ = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<partial-1@test>", accountId: "test-account", uid: 1)
        )
        _ = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<partial-2@test>", accountId: "test-account", uid: 2)
        )

        await mockProvider.setStubbedError(NSError(domain: "IMAP", code: -1, userInfo: [NSLocalizedDescriptionKey: "Connection reset"]))

        do {
            try await manager.performIncrementalSync(accountId: "test-account")
        } catch {
            // Expected
        }

        let headers = try await store.fetchHeaders(accountId: "test-account", folder: "INBOX", offset: 0, limit: 100)
        XCTAssertEqual(headers.count, 2, "Pre-existing data should survive sync failure")
    }

    func testGmailMultiLabelSameMessage() async throws {
        // v14: same message_id in different Gmail label folders → one canonical email row,
        // two email_folders entries. Both folder views return the same email.
        let (manager, _, store) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        let id1 = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<multi@gmail>", folder: "INBOX", accountId: "test-account", uid: 100)
        )
        let id2 = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<multi@gmail>", folder: "[Gmail]/Important", accountId: "test-account", uid: 200)
        )

        XCTAssertEqual(id1, id2, "Same message_id deduplicates to one canonical row")

        let inbox = try await store.fetchHeaders(accountId: "test-account", folder: "INBOX", offset: 0, limit: 100)
        let important = try await store.fetchHeaders(accountId: "test-account", folder: "[Gmail]/Important", offset: 0, limit: 100)
        XCTAssertEqual(inbox.count, 1, "INBOX view shows the email once")
        XCTAssertEqual(important.count, 1, "Important view shows the same email once")
        XCTAssertEqual(inbox.first?.id, important.first?.id, "Both views reference the same email row")
        // Each view shows its own folder-specific uid
        XCTAssertEqual(inbox.first?.uid, 100)
        XCTAssertEqual(important.first?.uid, 200)
    }

    func testSyncAllAccounts() async throws {
        let store = try MailStore(path: ":memory:")
        let authManager = AuthManager()

        let mock1 = MockMailProvider(accountId: "acc1")
        let mock2 = MockMailProvider(accountId: "acc2")

        let manager = AccountManager(store: store, authManager: authManager) { config, _, _ in
            if config.id == "acc1" { return mock1 }
            return mock2
        }

        try await manager.addAccount(TestData.makeAccountConfig(id: "acc1", email: "a@test.com"))
        try await manager.addAccount(TestData.makeAccountConfig(id: "acc2", email: "b@test.com"))

        try await manager.syncAllAccounts()

        let calls1 = await mock1.calls
        let calls2 = await mock2.calls
        XCTAssertTrue(calls1.contains("performIncrementalSync") || calls1.contains("performInitialSync"))
        XCTAssertTrue(calls2.contains("performIncrementalSync") || calls2.contains("performInitialSync"))
    }
}
