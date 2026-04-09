import Foundation
@testable import LiteMail

enum TestData {

    static func makeAccountConfig(
        id: String = "test-account",
        email: String = "test@example.com",
        protocolType: AccountConfig.ProtocolType = .imap,
        imapHost: String? = "imap.example.com",
        imapPort: Int? = 993,
        smtpHost: String? = "smtp.example.com",
        smtpPort: Int? = 587
    ) -> AccountConfig {
        AccountConfig(
            id: id,
            emailAddress: email,
            displayName: nil,
            protocolType: protocolType,
            imapUsername: email,
            imapHost: imapHost,
            imapPort: imapPort,
            smtpHost: smtpHost,
            smtpPort: smtpPort,
            jmapUrl: protocolType == .jmap ? "https://jmap.example.com/.well-known/jmap" : nil,
            authType: .password,
            keychainRef: "test-keychain-\(id)",
            isDefault: true
        )
    }

    static func makeEmailRecord(
        messageId: String = "<msg-1@test>",
        threadId: String? = "thread-1",
        folder: String = "INBOX",
        senderEmail: String = "sender@example.com",
        senderName: String? = "Sender",
        subject: String? = "Test Subject",
        accountId: String = "test-account",
        uid: Int? = 1,
        isRead: Bool = false,
        isStarred: Bool = false,
        hasAttachments: Bool = false
    ) -> EmailRecord {
        var record = EmailRecord(
            messageId: messageId,
            folder: folder,
            senderEmail: senderEmail,
            subject: subject,
            date: Int(Date().timeIntervalSince1970),
            isRead: isRead,
            isStarred: isStarred,
            isDeleted: false,
            hasAttachments: hasAttachments,
            accountId: accountId
        )
        record.threadId = threadId
        record.senderName = senderName
        record.uid = uid
        return record
    }

    static func makeOutgoingMessage(
        to: [String] = ["recipient@example.com"],
        subject: String = "Test Subject",
        bodyText: String = "Test body",
        inReplyTo: String? = nil
    ) -> OutgoingMessage {
        OutgoingMessage(
            to: to,
            cc: [],
            bcc: [],
            subject: subject,
            bodyText: bodyText,
            inReplyTo: inReplyTo
        )
    }

    static let standardFolders: [ProviderFolder] = [
        ProviderFolder(id: "INBOX", name: "INBOX", totalCount: 10, unreadCount: 5, role: .inbox),
        ProviderFolder(id: "[Gmail]/Sent Mail", name: "Sent Mail", totalCount: 20, unreadCount: 0, role: .sent),
        ProviderFolder(id: "[Gmail]/Drafts", name: "Drafts", totalCount: 2, unreadCount: 0, role: .drafts),
        ProviderFolder(id: "[Gmail]/Trash", name: "Trash", totalCount: 0, unreadCount: 0, role: .trash),
        ProviderFolder(id: "[Gmail]/All Mail", name: "All Mail", totalCount: 100, unreadCount: 0, role: .all),
    ]
}

/// Creates an AccountManager with a MockMailProvider wired up for a single test account.
func makeTestAccountManager(
    accountId: String = "test-account",
    email: String = "test@example.com"
) async throws -> (AccountManager, MockMailProvider, MailStore) {
    let store = try MailStore(path: ":memory:")
    let authManager = AuthManager()

    let mockProvider = MockMailProvider(accountId: accountId, emailAddress: email)

    let manager = AccountManager(store: store, authManager: authManager) { config, _, _ in
        return mockProvider
    }

    return (manager, mockProvider, store)
}
