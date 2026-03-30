import Foundation

/// Async interface for the mail engine. GUI (@MainActor) and future MCP server
/// both call through this protocol. Enables clean separation of transport from
/// presentation and makes the MCP bolt-on in Phase 4 a thin wrapper.
protocol MailEngineProtocol: Sendable {

    // MARK: - Authentication

    /// Initiates OAuth2 authentication flow. Returns true if authenticated.
    func authenticate() async throws -> Bool

    /// Whether the engine currently has valid credentials.
    var isAuthenticated: Bool { get async }

    // MARK: - Sync

    /// Performs initial sync: all headers + bodies for latest N messages.
    func performInitialSync(recentBodyCount: Int) async throws

    /// Fetches new messages since last sync.
    func performIncrementalSync() async throws

    /// Starts IMAP IDLE for real-time push notifications.
    func startIdleWatch() async throws

    /// Stops IMAP IDLE.
    func stopIdleWatch() async throws

    // MARK: - Search

    /// Full-text search across indexed emails. Returns matching email IDs.
    func search(query: String) async throws -> [EmailHeader]

    // MARK: - Read

    /// Fetches email headers for a folder, paginated.
    func fetchHeaders(folder: String, offset: Int, limit: Int) async throws -> [EmailHeader]

    /// Fetches the full body for a specific email.
    func fetchBody(emailId: Int64) async throws -> EmailBody?

    /// Fetches all messages in a thread, ordered chronologically.
    func fetchThread(threadId: String) async throws -> [EmailHeader]

    /// Lists available folders/labels.
    func listFolders() async throws -> [MailFolder]

    // MARK: - Actions

    /// Marks an email as read/unread.
    func markRead(emailId: Int64, read: Bool) async throws

    /// Stars/unstars an email.
    func markStarred(emailId: Int64, starred: Bool) async throws

    /// Archives an email (moves to All Mail).
    func archive(emailId: Int64) async throws

    /// Deletes an email (moves to Trash).
    func delete(emailId: Int64) async throws

    /// Moves an email to a different folder.
    func move(emailId: Int64, toFolder: String) async throws

    // MARK: - Compose

    /// Sends an email. If offline, queues in outbox.
    func send(message: OutgoingMessage) async throws

    /// Saves a draft.
    func saveDraft(_ draft: OutgoingMessage) async throws
}

// MARK: - Data Types

struct EmailHeader: Sendable, Identifiable {
    let id: Int64
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
