import XCTest
@testable import LiteMail

/// Tests require GreenMail running: docker compose -f docker-compose.test.yml up -d
final class IMAPConnectionTests: XCTestCase {

    override func setUp() async throws {
        try XCTSkipUnless(DockerHelper.isGreenMailRunning(), "GreenMail not running. Start with: docker compose -f docker-compose.test.yml up -d")
    }

    func testConnectWithValidCredentials() async throws {
        let store = try MailStore(path: ":memory:")
        let authManager = AuthManager()

        let config = AccountConfig(
            id: "docker-test",
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
            keychainRef: "docker-test-key",
            isDefault: true
        )

        authManager.storePassword(accountId: config.keychainRef, password: DockerHelper.testPassword)
        

        let provider = IMAPProvider(config: config, authManager: authManager, store: store)

        try await provider.connect()
        let connected = await provider.isConnected
        XCTAssertTrue(connected)

        try await provider.disconnect()
        let disconnected = await provider.isConnected
        XCTAssertFalse(disconnected)
    }

    func testConnectWithBadCredentials() async throws {
        let store = try MailStore(path: ":memory:")
        let authManager = AuthManager()

        let config = AccountConfig(
            id: "bad-creds",
            emailAddress: DockerHelper.testEmail,
            displayName: nil,
            protocolType: .imap,
            imapUsername: DockerHelper.testEmail,
            imapHost: DockerHelper.imapHost,
            imapPort: DockerHelper.imapPort,
            smtpHost: nil,
            smtpPort: nil,
            jmapUrl: nil,
            authType: .password,
            keychainRef: "bad-creds-key",
            isDefault: true
        )

        authManager.storePassword(accountId: config.keychainRef, password: "wrong-password")
        

        let provider = IMAPProvider(config: config, authManager: authManager, store: store)

        do {
            try await provider.connect()
            XCTFail("Expected auth error")
        } catch {
            // Expected
        }
    }

    func testDisconnectCleanTeardown() async throws {
        let store = try MailStore(path: ":memory:")
        let authManager = AuthManager()

        let config = AccountConfig(
            id: "disconnect-test",
            emailAddress: DockerHelper.testEmail,
            displayName: nil,
            protocolType: .imap,
            imapUsername: DockerHelper.testEmail,
            imapHost: DockerHelper.imapHost,
            imapPort: DockerHelper.imapPort,
            smtpHost: nil,
            smtpPort: nil,
            jmapUrl: nil,
            authType: .password,
            keychainRef: "disconnect-key",
            isDefault: true
        )

        authManager.storePassword(accountId: config.keychainRef, password: DockerHelper.testPassword)
        

        let provider = IMAPProvider(config: config, authManager: authManager, store: store)

        try await provider.connect()
        try await provider.disconnect()

        // Double disconnect should not crash
        try await provider.disconnect()

        let connected = await provider.isConnected
        XCTAssertFalse(connected)
    }
}
