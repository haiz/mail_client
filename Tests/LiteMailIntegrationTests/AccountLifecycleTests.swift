import XCTest
@testable import LiteMail

final class AccountLifecycleTests: XCTestCase {

    func testAddAccount() async throws {
        let (manager, _, store) = try await makeTestAccountManager()
        let config = TestData.makeAccountConfig()

        try await manager.addAccount(config)

        let accounts = try await manager.listAccounts()
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.emailAddress, "test@example.com")

        let dbAccounts = try await store.listAccounts()
        XCTAssertEqual(dbAccounts.count, 1)
    }

    func testMultipleAccountsIsolation() async throws {
        let store = try MailStore(path: ":memory:")
        let authManager = AuthManager()

        let mock1 = MockMailProvider(accountId: "acc1", emailAddress: "user1@test.com")
        let mock2 = MockMailProvider(accountId: "acc2", emailAddress: "user2@test.com")

        let manager = AccountManager(store: store, authManager: authManager) { config, _, _ in
            if config.id == "acc1" { return mock1 }
            return mock2
        }

        try await manager.addAccount(TestData.makeAccountConfig(id: "acc1", email: "user1@test.com"))
        try await manager.addAccount(TestData.makeAccountConfig(id: "acc2", email: "user2@test.com"))

        let accounts = try await manager.listAccounts()
        XCTAssertEqual(accounts.count, 2)

        let emails = Set(accounts.map(\.emailAddress))
        XCTAssertTrue(emails.contains("user1@test.com"))
        XCTAssertTrue(emails.contains("user2@test.com"))
    }

    func testRemoveAccountCascade() async throws {
        let (manager, _, store) = try await makeTestAccountManager()
        let config = TestData.makeAccountConfig()
        try await manager.addAccount(config)

        let emailId = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<cascade@test>", accountId: "test-account")
        )
        try await store.addLabel(emailId: emailId, label: "important")
        try await store.insertAttachments([
            AttachmentRecord(emailId: emailId, partId: "1", filename: "doc.pdf", mimeType: "application/pdf", sizeBytes: 1024)
        ])
        try await store.insertBody(emailId: emailId, text: "body text", html: nil)

        try await manager.removeAccount(id: "test-account")

        let accounts = try await manager.listAccounts()
        XCTAssertEqual(accounts.count, 0)

        let headers = try await store.fetchHeaders(accountId: "test-account", folder: "INBOX", offset: 0, limit: 100)
        XCTAssertEqual(headers.count, 0)
    }

    func testAddAccountWithDiscoveryFailure() async throws {
        let store = try MailStore(path: ":memory:")
        let authManager = AuthManager()

        let failingProvider = MockMailProvider(accountId: "fail-acc")

        let manager = AccountManager(store: store, authManager: authManager) { _, _, _ in
            return failingProvider
        }

        let config = TestData.makeAccountConfig(id: "fail-acc", email: "fail@test.com")
        try await manager.addAccount(config)

        let accounts = try await manager.listAccounts()
        XCTAssertEqual(accounts.count, 1)
    }
}
