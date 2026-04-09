import XCTest
@testable import LiteMail

/// Smoke tests against a real JMAP server (e.g., Fastmail).
/// Set env vars to run:
///   LITEMAIL_JMAP_TEST=1
///   LITEMAIL_JMAP_EMAIL=test@fastmail.com
///   LITEMAIL_JMAP_URL=https://api.fastmail.com/.well-known/jmap
///   LITEMAIL_JMAP_TOKEN=bearer-token-here
final class JMAPSmokeTests: XCTestCase {

    private var store: MailStore!
    private var authManager: AuthManager!
    private var provider: JMAPProvider!

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LITEMAIL_JMAP_TEST"] != nil,
            "JMAP smoke tests disabled. Set LITEMAIL_JMAP_TEST=1 to enable."
        )

        let email = try XCTUnwrap(ProcessInfo.processInfo.environment["LITEMAIL_JMAP_EMAIL"])
        let url = try XCTUnwrap(ProcessInfo.processInfo.environment["LITEMAIL_JMAP_URL"])
        let token = try XCTUnwrap(ProcessInfo.processInfo.environment["LITEMAIL_JMAP_TOKEN"])

        store = try MailStore(path: ":memory:")
        authManager = AuthManager()

        let config = AccountConfig(
            id: "jmap-smoke",
            emailAddress: email,
            displayName: nil,
            protocolType: .jmap,
            imapUsername: nil,
            imapHost: nil,
            imapPort: nil,
            smtpHost: nil,
            smtpPort: nil,
            jmapUrl: url,
            authType: .bearer,
            keychainRef: "jmap-smoke-key",
            isDefault: true
        )

        try await store.insertAccount(AccountRecord(
            id: "jmap-smoke",
            emailAddress: email,
            protocolType: "jmap",
            jmapUrl: url,
            authType: "bearer",
            keychainRef: "jmap-smoke-key",
            isDefault: true
        ))

        authManager.storePassword(accountId: config.id, password: token)
        provider = JMAPProvider(config: config, authManager: authManager, store: store)
    }

    override func tearDown() async throws {
        try? await provider?.disconnect()
        
    }

    func testJMAPConnect() async throws {
        try await provider.connect()
        let connected = await provider.isConnected
        XCTAssertTrue(connected)
    }

    func testJMAPInitialSync() async throws {
        try await provider.connect()
        try await provider.performInitialSync()

        let folders = try await provider.listFolders()
        XCTAssertTrue(folders.contains(where: { $0.role == .inbox }))

        let headers = try await store.fetchHeaders(accountId: "jmap-smoke", folder: "INBOX", offset: 0, limit: 10)
        XCTAssertGreaterThan(headers.count, 0, "JMAP INBOX should have emails")
    }

    func testJMAPIncrementalSync() async throws {
        try await provider.connect()
        try await provider.performInitialSync()
        try await provider.performIncrementalSync()

        let count = try await store.emailCount(accountId: "jmap-smoke")
        XCTAssertGreaterThan(count, 0)
    }
}
