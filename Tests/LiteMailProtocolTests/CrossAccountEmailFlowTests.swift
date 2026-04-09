import XCTest
@testable import LiteMail

/// E2E cross-account email flow tests.
/// Tests sending from IMAP account to Gmail and vice versa, then verifying delivery.
///
/// Required env vars:
///   LITEMAIL_CROSS_TEST=1
///   LITEMAIL_IMAP_EMAIL=hai@caodev.top
///   LITEMAIL_IMAP_PASSWORD=changeme123
///   LITEMAIL_IMAP_HOST=mail.caodev.top
///   LITEMAIL_IMAP_PORT=993
///   LITEMAIL_SMTP_HOST=mail.caodev.top
///   LITEMAIL_SMTP_PORT=587
///   LITEMAIL_GMAIL_EMAIL=aiworld.nf@gmail.com
///   LITEMAIL_GMAIL_PASSWORD=qvutwcewmbnmvpfr
final class CrossAccountEmailFlowTests: XCTestCase {

    private var imapStore: MailStore!
    private var gmailStore: MailStore!
    private var authManager: AuthManager!
    private var imapProvider: IMAPProvider!
    private var gmailProvider: IMAPProvider!

    private var imapEmail: String!
    private var gmailEmail: String!

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LITEMAIL_CROSS_TEST"] != nil,
            "Cross-account tests disabled. Set LITEMAIL_CROSS_TEST=1 to enable."
        )

        imapEmail = ProcessInfo.processInfo.environment["LITEMAIL_IMAP_EMAIL"] ?? "hai@caodev.top"
        let imapPassword = ProcessInfo.processInfo.environment["LITEMAIL_IMAP_PASSWORD"] ?? "changeme123"
        let imapHost = ProcessInfo.processInfo.environment["LITEMAIL_IMAP_HOST"] ?? "mail.caodev.top"
        let imapPort = Int(ProcessInfo.processInfo.environment["LITEMAIL_IMAP_PORT"] ?? "993") ?? 993
        let smtpHost = ProcessInfo.processInfo.environment["LITEMAIL_SMTP_HOST"] ?? "mail.caodev.top"
        let smtpPort = Int(ProcessInfo.processInfo.environment["LITEMAIL_SMTP_PORT"] ?? "587") ?? 587

        gmailEmail = ProcessInfo.processInfo.environment["LITEMAIL_GMAIL_EMAIL"] ?? "aiworld.nf@gmail.com"
        let gmailPassword = ProcessInfo.processInfo.environment["LITEMAIL_GMAIL_PASSWORD"] ?? "qvutwcewmbnmvpfr"

        authManager = AuthManager()

        // --- IMAP account (hai@caodev.top) ---
        imapStore = try MailStore(path: ":memory:")
        let imapConfig = AccountConfig(
            id: "imap-cross",
            emailAddress: imapEmail,
            displayName: nil,
            protocolType: .imap,
            imapUsername: imapEmail,
            imapHost: imapHost,
            imapPort: imapPort,
            smtpHost: smtpHost,
            smtpPort: smtpPort,
            jmapUrl: nil,
            authType: .password,
            keychainRef: "imap-cross-key",
            isDefault: true
        )
        try await imapStore.insertAccount(AccountRecord(
            id: "imap-cross",
            emailAddress: imapEmail,
            protocolType: "imap",
            imapUsername: imapEmail,
            imapHost: imapHost,
            imapPort: imapPort,
            smtpHost: smtpHost,
            smtpPort: smtpPort,
            authType: "password",
            keychainRef: "imap-cross-key",
            isDefault: true
        ))
        authManager.storePassword(accountId: imapConfig.id, password: imapPassword)
        imapProvider = IMAPProvider(config: imapConfig, authManager: authManager, store: imapStore)

        // --- Gmail account (aiworld.nf@gmail.com) ---
        gmailStore = try MailStore(path: ":memory:")
        let gmailConfig = AccountConfig(
            id: "gmail-cross",
            emailAddress: gmailEmail,
            displayName: nil,
            protocolType: .imap,
            imapUsername: gmailEmail,
            imapHost: "imap.gmail.com",
            imapPort: 993,
            smtpHost: "smtp.gmail.com",
            smtpPort: 587,
            jmapUrl: nil,
            authType: .password,
            keychainRef: "gmail-cross-key",
            isDefault: true
        )
        try await gmailStore.insertAccount(AccountRecord(
            id: "gmail-cross",
            emailAddress: gmailEmail,
            protocolType: "imap",
            imapUsername: gmailEmail,
            imapHost: "imap.gmail.com",
            imapPort: 993,
            smtpHost: "smtp.gmail.com",
            smtpPort: 587,
            authType: "password",
            keychainRef: "gmail-cross-key",
            isDefault: true
        ))
        authManager.storePassword(accountId: gmailConfig.id, password: gmailPassword)
        gmailProvider = IMAPProvider(config: gmailConfig, authManager: authManager, store: gmailStore)

        // Connect both
        try await imapProvider.connect()
        try await gmailProvider.connect()
    }

    override func tearDown() async throws {
        try? await imapProvider?.disconnect()
        try? await gmailProvider?.disconnect()
    }

    // MARK: - Test: IMAP → Gmail

    /// Send email from hai@caodev.top → aiworld.nf@gmail.com, then verify Gmail received it.
    func testSendFromIMAPToGmail() async throws {
        let uniqueSubject = "LiteMail E2E Test IMAP→Gmail \(UUID().uuidString.prefix(8))"

        // 1. Send from IMAP account
        let message = OutgoingMessage(
            to: [gmailEmail],
            cc: [],
            bcc: [],
            subject: uniqueSubject,
            bodyText: "This is an automated E2E test email sent from \(imapEmail!) to \(gmailEmail!)."
        )
        try await imapProvider.send(message: message)

        // 2. Poll Gmail inbox until the email arrives (up to 60s)
        let received = try await pollForEmail(
            store: gmailStore, provider: gmailProvider,
            accountId: "gmail-cross", subject: uniqueSubject, timeoutSeconds: 60
        )
        XCTAssertNotNil(received, "Gmail should have received email with subject: \(uniqueSubject)")
        XCTAssertEqual(received?.senderEmail, imapEmail)
    }

    // MARK: - Test: Gmail → IMAP

    /// Send email from aiworld.nf@gmail.com → hai@caodev.top, then verify IMAP received it.
    func testSendFromGmailToIMAP() async throws {
        let uniqueSubject = "LiteMail E2E Test Gmail→IMAP \(UUID().uuidString.prefix(8))"

        // 1. Send from Gmail account
        let message = OutgoingMessage(
            to: [imapEmail],
            cc: [],
            bcc: [],
            subject: uniqueSubject,
            bodyText: "This is an automated E2E test email sent from \(gmailEmail!) to \(imapEmail!)."
        )
        try await gmailProvider.send(message: message)

        // 2. Poll IMAP inbox until the email arrives (up to 60s)
        let received = try await pollForEmail(
            store: imapStore, provider: imapProvider,
            accountId: "imap-cross", subject: uniqueSubject, timeoutSeconds: 60
        )
        XCTAssertNotNil(received, "IMAP should have received email with subject: \(uniqueSubject)")
        XCTAssertEqual(received?.senderEmail, gmailEmail)
    }

    // MARK: - Test: Send + Read body

    /// Send from IMAP → Gmail, then fetch the full body to verify content.
    func testSendAndReadBody() async throws {
        let uniqueSubject = "LiteMail E2E Body Test \(UUID().uuidString.prefix(8))"
        let bodyContent = "Hello from LiteMail E2E test! Timestamp: \(Date())"

        // 1. Send
        let message = OutgoingMessage(
            to: [gmailEmail],
            cc: [],
            bcc: [],
            subject: uniqueSubject,
            bodyText: bodyContent
        )
        try await imapProvider.send(message: message)

        // 2. Poll until email arrives
        let received = try await pollForEmail(
            store: gmailStore, provider: gmailProvider,
            accountId: "gmail-cross", subject: uniqueSubject, timeoutSeconds: 60
        )
        XCTAssertNotNil(received, "Should find email with subject: \(uniqueSubject)")

        guard let emailRecord = received,
              let emailId = emailRecord.id else {
            XCTFail("Could not find received email")
            return
        }
        let storedRecord = try await gmailStore.fetchEmailRecord(id: emailId)
        guard let uid = storedRecord?.uid else {
            XCTFail("Could not get UID for received email")
            return
        }

        // 4. Fetch body via provider
        let ref = "folder:INBOX:uid:\(uid)"
        let body = try await gmailProvider.fetchMessageBody(messageRef: ref)
        XCTAssertNotNil(body.textBody, "Body should have text content")
        XCTAssertTrue(
            body.textBody?.contains("Hello from LiteMail E2E test!") == true,
            "Body should contain our test message. Got: \(body.textBody ?? "nil")"
        )
    }

    // MARK: - Helpers

    /// Poll for an email with a given subject. Syncs every 10s up to timeout.
    /// Checks INBOX first, then Spam/Junk folders (emails from low-reputation
    /// domains may be classified as spam by Gmail).
    private func pollForEmail(
        store: MailStore,
        provider: IMAPProvider,
        accountId: String,
        subject: String,
        timeoutSeconds: Int
    ) async throws -> EmailRecord? {
        let foldersToCheck = [
            "INBOX",
            "[Gmail]/Spam", "[Google Mail]/Spam", "Spam", "Junk",
        ]
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < Double(timeoutSeconds) {
            do {
                try await provider.performInitialSync()
            } catch {
                // Sync errors are non-fatal for polling
            }

            for folder in foldersToCheck {
                let headers = try await store.fetchHeaders(
                    accountId: accountId, folder: folder, offset: 0, limit: 500
                )
                if let found = headers.first(where: { $0.subject == subject }) {
                    if folder != "INBOX" {
                        print("[pollForEmail] Found in '\(folder)' instead of INBOX (likely spam-classified)")
                    }
                    return found
                }
            }

            try await Task.sleep(nanoseconds: 10_000_000_000)
        }
        return nil
    }

    // MARK: - Test: Reply flow

    /// Send from IMAP → Gmail, then reply from Gmail → IMAP, verify both sides.
    func testReplyFlow() async throws {
        let originalSubject = "LiteMail Reply Test \(UUID().uuidString.prefix(8))"

        // 1. Send original from IMAP → Gmail
        let original = OutgoingMessage(
            to: [gmailEmail],
            cc: [],
            bcc: [],
            subject: originalSubject,
            bodyText: "Original message for reply test."
        )
        try await imapProvider.send(message: original)

        // 2. Poll Gmail until original arrives
        let receivedOriginal = try await pollForEmail(
            store: gmailStore, provider: gmailProvider,
            accountId: "gmail-cross", subject: originalSubject, timeoutSeconds: 60
        )
        XCTAssertNotNil(receivedOriginal, "Gmail should have received original email")

        // 3. Reply from Gmail → IMAP
        let replySubject = "Re: \(originalSubject)"
        let reply = OutgoingMessage(
            to: [imapEmail],
            cc: [],
            bcc: [],
            subject: replySubject,
            bodyText: "This is the reply from Gmail.",
            inReplyTo: receivedOriginal?.messageId
        )
        try await gmailProvider.send(message: reply)

        // 4. Poll IMAP until reply arrives
        let receivedReply = try await pollForEmail(
            store: imapStore, provider: imapProvider,
            accountId: "imap-cross", subject: replySubject, timeoutSeconds: 60
        )
        XCTAssertNotNil(receivedReply, "IMAP should have received reply email with subject: \(replySubject)")
        XCTAssertEqual(receivedReply?.senderEmail, gmailEmail)
    }
}
