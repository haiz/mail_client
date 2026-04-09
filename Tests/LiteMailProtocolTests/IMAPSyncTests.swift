import XCTest
@testable import LiteMail

final class IMAPSyncTests: XCTestCase {

    private var store: MailStore!
    private var authManager: AuthManager!
    private var provider: IMAPProvider!

    override func setUp() async throws {
        try XCTSkipUnless(DockerHelper.isGreenMailRunning(), "GreenMail not running")

        store = try MailStore(path: ":memory:")
        authManager = AuthManager()

        let config = AccountConfig(
            id: "sync-test",
            emailAddress: DockerHelper.testEmail,
            displayName: nil,
            protocolType: .imap,
            imapUsername: DockerHelper.testEmail,
            imapHost: DockerHelper.imapHost,
            imapPort: DockerHelper.imapPort,
            smtpHost: DockerHelper.smtpHost,
            smtpPort: DockerHelper.smtpPort,
            jmapUrl: nil,
            authType: .password,
            keychainRef: "sync-test-key",
            isDefault: true
        )

        try await store.insertAccount(AccountRecord(
            id: "sync-test",
            emailAddress: DockerHelper.testEmail,
            protocolType: "imap",
            imapUsername: DockerHelper.testEmail,
            imapHost: DockerHelper.imapHost,
            imapPort: DockerHelper.imapPort,
            smtpHost: DockerHelper.smtpHost,
            smtpPort: DockerHelper.smtpPort,
            authType: "password",
            keychainRef: "sync-test-key",
            isDefault: true
        ))

        authManager.storePassword(accountId: config.id, password: DockerHelper.testPassword)

        provider = IMAPProvider(config: config, authManager: authManager, store: store)
        try await provider.connect()
    }

    override func tearDown() async throws {
        try? await provider?.disconnect()
        
    }

    func testInitialSyncOnEmptyMailbox() async throws {
        try await provider.performInitialSync()

        let folders = try await provider.listFolders()
        XCTAssertTrue(folders.count > 0, "Should have at least INBOX")
        XCTAssertTrue(folders.contains(where: { $0.role == .inbox }))
    }

    func testInitialSyncWithSeededEmails() async throws {
        try SMTPSeeder.seedEmails(count: 10)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        try await provider.performInitialSync()

        let headers = try await store.fetchHeaders(accountId: "sync-test", folder: "INBOX", offset: 0, limit: 100)
        XCTAssertGreaterThanOrEqual(headers.count, 10)
    }

    func testIncrementalSyncPicksUpNewEmails() async throws {
        try await provider.performInitialSync()

        let beforeCount = try await store.fetchHeaders(accountId: "sync-test", folder: "INBOX", offset: 0, limit: 1000).count

        try SMTPSeeder.seedEmails(count: 5)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        try await provider.performIncrementalSync()

        let afterCount = try await store.fetchHeaders(accountId: "sync-test", folder: "INBOX", offset: 0, limit: 1000).count
        XCTAssertEqual(afterCount, beforeCount + 5)
    }
}
