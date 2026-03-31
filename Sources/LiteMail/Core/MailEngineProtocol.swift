import Foundation

/// High-level interface used by the GUI layer.
/// AccountManager conforms to this. The GUI doesn't know about MailProvider,
/// accounts, or protocols — it just calls these methods.
protocol MailEngineProtocol: Sendable {

    // MARK: - Accounts

    func listAccounts() async throws -> [AccountConfig]
    func addAccount(_ config: AccountConfig) async throws
    func removeAccount(id: String) async throws

    // MARK: - Sync

    func performInitialSync(accountId: String) async throws
    func performIncrementalSync(accountId: String) async throws
    func syncAllAccounts() async throws

    // MARK: - Search (cross-account)

    func search(query: String, accountId: String?) async throws -> [EmailHeader]

    // MARK: - Read

    func fetchHeaders(accountId: String, folder: String, offset: Int, limit: Int) async throws -> [EmailHeader]
    func fetchBody(emailId: Int64) async throws -> EmailBody?
    func fetchThread(threadId: String) async throws -> [EmailHeader]
    func listFolders(accountId: String) async throws -> [MailFolder]

    // MARK: - Actions

    func markRead(emailId: Int64, read: Bool) async throws
    func markStarred(emailId: Int64, starred: Bool) async throws
    func archive(emailId: Int64) async throws
    func delete(emailId: Int64) async throws
    func move(emailId: Int64, toFolder: String) async throws

    // MARK: - Compose

    func send(message: OutgoingMessage, fromAccountId: String) async throws
    func saveDraft(_ draft: OutgoingMessage, accountId: String) async throws
}

// MARK: - Data Types (used by GUI)

struct EmailHeader: Sendable, Identifiable {
    let id: Int64
    let accountId: String
    let messageId: String
    let threadId: String?
    let folder: String
    let senderName: String?
    let senderEmail: String
    let subject: String?
    let date: Date
    let isRead: Bool
    let isStarred: Bool
    let hasAttachments: Bool
    let snippet: String?
}

struct EmailBody: Sendable {
    let emailId: Int64
    let textBody: String?
    let htmlBody: String?
}

struct MailFolder: Sendable, Identifiable {
    let id: String
    let name: String
    let unreadCount: Int
}

struct OutgoingMessage: Sendable {
    let to: [String]
    let cc: [String]
    let bcc: [String]
    let subject: String
    let bodyText: String
    let bodyHtml: String?
    let inReplyTo: String?
}
