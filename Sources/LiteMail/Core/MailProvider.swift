import Foundation

// ┌─────────────────────────────────────────────────────┐
// │              MailProvider Protocol                    │
// │  Transport-agnostic interface for IMAP / JMAP        │
// │                                                       │
// │  IMAPProvider ──┐                                     │
// │                 ├──▶ MailProvider ──▶ MailStore        │
// │  JMAPProvider ──┘         (future PR2)                │
// └─────────────────────────────────────────────────────┘

/// Transport-agnostic mail provider protocol.
/// IMAP and JMAP (future) both conform to this.
/// The GUI and AccountManager never know which protocol is being used.
///
/// All identifiers are String:
/// - IMAP wraps UIDs as "uid:<N>"
/// - JMAP uses native IDs like "Mxyz123"
/// The MailStore maps between provider refs and local int64 IDs.
protocol MailProvider: Actor {
    /// Unique account identifier (matches accounts table id).
    var accountId: String { get }

    /// Email address for this account.
    var emailAddress: String { get }

    // MARK: - Connection Lifecycle

    func connect() async throws
    func disconnect() async throws
    var isConnected: Bool { get }

    // MARK: - Sync

    /// Initial sync: fetch headers + recent bodies.
    func performInitialSync() async throws

    /// Incremental sync: fetch new messages since last sync.
    func performIncrementalSync() async throws

    /// Start push notifications. IMAP uses IDLE, JMAP uses EventSource.
    func startPushNotifications(onNewMessage: @escaping @Sendable () async -> Void) async throws

    /// Stop push notifications.
    func stopPushNotifications() async throws

    // MARK: - Folders

    func createFolder(name: String) async throws
    func listFolders() async throws -> [ProviderFolder]

    // MARK: - Messages (cursor-based pagination)

    func fetchMessages(folderId: String, cursor: String?, limit: Int) async throws -> (messages: [ProviderMessage], nextCursor: String?)
    func fetchMessageBody(messageRef: String) async throws -> ProviderMessageBody

    // MARK: - Actions

    func markRead(messageRef: String, read: Bool) async throws
    func markStarred(messageRef: String, starred: Bool) async throws
    func moveMessage(messageRef: String, toFolderId: String) async throws
    /// IMAP: flag + expunge. JMAP: move to Trash.
    func deleteMessage(messageRef: String) async throws

    // MARK: - Batch Actions

    func markReadBatch(messageRefs: [String], read: Bool) async throws
    func markStarredBatch(messageRefs: [String], starred: Bool) async throws
    func moveMessageBatch(messageRefs: [String], toFolderId: String) async throws
    func deleteMessageBatch(messageRefs: [String]) async throws
    func markSpamBatch(messageRefs: [String]) async throws

    // MARK: - Attachments

    func fetchAttachment(messageRef: String, partId: String) async throws -> Data

    // MARK: - Send

    func send(message: OutgoingMessage) async throws
}

// MARK: - Provider Data Types

/// Folder as reported by the provider (IMAP mailbox or JMAP mailbox).
struct ProviderFolder: Sendable {
    let id: String          // IMAP: folder path, JMAP: mailbox ID
    let name: String        // Display name
    let totalCount: Int
    let unreadCount: Int
    let role: FolderRole?
}

enum FolderRole: String, Sendable {
    case inbox, sent, drafts, trash, starred, archive, spam, all
    case category   // Gmail Categories (Promotions, Social, Updates, Forums, Purchases)
    case scheduled  // Virtual "Scheduled" outbox folder
    case snoozed    // Virtual "Snoozed" folder
}

/// Message header as reported by the provider.
struct ProviderMessage: Sendable {
    let ref: String         // IMAP: "uid:<N>", JMAP: native ID
    let messageId: String?  // RFC 822 Message-ID
    let threadId: String?   // References-based or provider-native
    let senderName: String?
    let senderEmail: String
    let recipients: [String]
    let cc: [String]
    let subject: String?
    let date: Date
    let isRead: Bool
    let isStarred: Bool
    let hasAttachments: Bool
    let referencesHeader: String?
    let inReplyTo: String?
}

/// Message body as reported by the provider.
struct ProviderMessageBody: Sendable {
    let ref: String
    let textBody: String?
    let htmlBody: String?
}

// MARK: - Account Configuration

/// Stored account configuration (maps to accounts table row).
struct AccountConfig: Sendable {
    let id: String
    let emailAddress: String
    let displayName: String?
    let protocolType: ProtocolType
    let imapUsername: String?       // If different from email (e.g. "hai" instead of "hai@domain.com")
    let imapHost: String?
    let imapPort: Int?
    let smtpHost: String?
    let smtpPort: Int?
    let jmapUrl: String?
    let authType: AuthType
    let keychainRef: String
    let isDefault: Bool

    enum ProtocolType: String, Sendable {
        case imap, jmap
    }

    enum AuthType: String, Sendable {
        case oauth2, password, bearer
    }
}
