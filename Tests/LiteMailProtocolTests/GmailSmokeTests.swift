import XCTest
@testable import LiteMail

/// Smoke tests against a real Gmail account.
/// Set env vars to run:
///   LITEMAIL_GMAIL_TEST=1
///   LITEMAIL_GMAIL_EMAIL=test@gmail.com
///   LITEMAIL_GMAIL_PASSWORD=app-password-here
final class GmailSmokeTests: XCTestCase {

    private var store: MailStore!
    private var authManager: AuthManager!
    private var provider: IMAPProvider!

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LITEMAIL_GMAIL_TEST"] != nil,
            "Gmail smoke tests disabled. Set LITEMAIL_GMAIL_TEST=1 to enable."
        )

        let email = try XCTUnwrap(ProcessInfo.processInfo.environment["LITEMAIL_GMAIL_EMAIL"])
        let password = try XCTUnwrap(ProcessInfo.processInfo.environment["LITEMAIL_GMAIL_PASSWORD"])

        store = try MailStore(path: ":memory:")
        authManager = AuthManager()

        let config = AccountConfig(
            id: "gmail-smoke",
            emailAddress: email,
            displayName: nil,
            protocolType: .imap,
            imapUsername: email,
            imapHost: "imap.gmail.com",
            imapPort: 993,
            smtpHost: "smtp.gmail.com",
            smtpPort: 587,
            jmapUrl: nil,
            authType: .password,
            keychainRef: "gmail-smoke-key",
            isDefault: true
        )

        try await store.insertAccount(AccountRecord(
            id: "gmail-smoke",
            emailAddress: email,
            protocolType: "imap",
            imapUsername: email,
            imapHost: "imap.gmail.com",
            imapPort: 993,
            smtpHost: "smtp.gmail.com",
            smtpPort: 587,
            authType: "password",
            keychainRef: "gmail-smoke-key",
            isDefault: true
        ))

        authManager.storePassword(accountId: config.id, password: password)
        provider = IMAPProvider(config: config, authManager: authManager, store: store)
    }

    override func tearDown() async throws {
        try? await provider?.disconnect()
        
    }

    func testGmailConnect() async throws {
        try await provider.connect()
        let connected = await provider.isConnected
        XCTAssertTrue(connected)
    }

    func testGmailInitialSync() async throws {
        try await provider.connect()
        try await provider.performInitialSync()

        let folders = try await provider.listFolders()
        XCTAssertTrue(folders.contains(where: { $0.role == .inbox }))

        let headers = try await store.fetchHeaders(accountId: "gmail-smoke", folder: "INBOX", offset: 0, limit: 10)
        XCTAssertGreaterThan(headers.count, 0, "Gmail INBOX should have emails")
    }

    func testGmailSearch() async throws {
        try await provider.connect()
        try await provider.performInitialSync()

        let results = try await store.search(query: "the", accountId: "gmail-smoke")
        XCTAssertGreaterThan(results.count, 0)
    }

    func testGmailFolders() async throws {
        try await provider.connect()
        let folders = try await provider.listFolders()

        let folderNames = folders.map(\.name)
        XCTAssertTrue(folders.contains(where: { $0.role == .inbox }), "Missing INBOX. Folders: \(folderNames)")
        XCTAssertTrue(folders.contains(where: { $0.role == .sent }), "Missing Sent. Folders: \(folderNames)")
    }
}
