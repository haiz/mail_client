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
    @discardableResult
    func performIncrementalSync(accountId: String) async throws -> Bool
    func syncAllAccounts() async throws

    // MARK: - Unified Inbox

    func fetchUnifiedInbox(offset: Int, limit: Int) async throws -> [EmailHeader]

    // MARK: - Search (cross-account)

    func search(query: String, accountId: String?) async throws -> [EmailHeader]

    // MARK: - Saved Searches

    func listSavedSearches(accountId: String?) async throws -> [MailStore.SavedSearchRecord]
    func saveSearch(accountId: String?, name: String, query: String) async throws -> Int64
    func deleteSavedSearch(id: Int64) async throws

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

    // MARK: - Snooze

    func snooze(emailId: Int64, until: Date) async throws
    func unsnooze(emailId: Int64) async throws
    func listSnoozed(accountId: String) async throws -> [EmailHeader]

    // MARK: - Spam

    func markSpam(emailId: Int64) async throws
    func markSpamBatch(emailIds: [Int64]) async throws

    // MARK: - Batch Actions

    func deleteBatch(emailIds: [Int64]) async throws
    func archiveBatch(emailIds: [Int64]) async throws
    func markReadBatch(emailIds: [Int64], read: Bool) async throws
    func markStarredBatch(emailIds: [Int64], starred: Bool) async throws
    func moveBatch(emailIds: [Int64], toFolder: String) async throws

    // MARK: - Folders

    func createFolder(name: String, accountId: String) async throws

    // MARK: - Labels

    func addLabel(emailId: Int64, label: String) async throws
    func removeLabel(emailId: Int64, label: String) async throws
    func fetchLabels(emailId: Int64) async throws -> [String]
    func allLabels(accountId: String) async throws -> [String]

    // MARK: - Attachments

    func listAttachments(emailId: Int64) async throws -> [AttachmentInfo]
    func fetchAttachmentData(emailId: Int64, partId: String) async throws -> Data

    // MARK: - Compose

    func send(message: OutgoingMessage, fromAccountId: String) async throws
    func saveDraft(_ draft: OutgoingMessage, accountId: String) async throws

    // MARK: - Signature

    func signature(accountId: String) async throws -> String?
    func setSignature(accountId: String, html: String?) async throws

    // MARK: - Scheduled Send

    func scheduleSend(_ msg: OutgoingMessage, fromAccountId: String, sendAt: Date) async throws -> Int64
    func listScheduled(accountId: String) async throws -> [ScheduledMessage]
    func cancelScheduled(outboxId: Int64) async throws -> OutboxRecord?
}

// MARK: - Data Types (used by GUI)

/// A message queued for future delivery. Used by the Scheduled virtual folder.
struct ScheduledMessage: Sendable, Identifiable {
    let id: Int64        // outbox row id
    let to: [String]
    let subject: String?
    let sendAfter: Date
    let bodyText: String?
    let accountId: String
}

struct AttachmentInfo: Sendable, Identifiable {
    let id: String  // partId or DB id
    let partId: String
    let filename: String?
    let mimeType: String?
    let sizeBytes: Int?
    let contentId: String?
    let isInline: Bool

    init(id: String, partId: String, filename: String?, mimeType: String?,
         sizeBytes: Int?, contentId: String? = nil, isInline: Bool = false) {
        self.id = id; self.partId = partId; self.filename = filename
        self.mimeType = mimeType; self.sizeBytes = sizeBytes
        self.contentId = contentId; self.isInline = isInline
    }
}

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
    let recipients: String?
    let deleteState: String
}

struct EmailBody: Sendable {
    let emailId: Int64
    let textBody: String?
    let htmlBody: String?
}

struct MailFolder: Sendable, Identifiable {
    let id: String
    let name: String
    let totalCount: Int
    let unreadCount: Int
    var hasUnread: Bool { unreadCount > 0 }
    let role: FolderRole?
}

struct OutgoingAttachment: Sendable {
    let filename: String
    let mimeType: String
    let data: Data
    let contentId: String?
    let isInline: Bool

    init(filename: String, mimeType: String, data: Data,
         contentId: String? = nil, isInline: Bool = false) {
        self.filename = filename; self.mimeType = mimeType; self.data = data
        self.contentId = contentId; self.isInline = isInline
    }
}

struct OutgoingMessage: Sendable {
    let to: [String]
    let cc: [String]
    let bcc: [String]
    let subject: String
    let bodyText: String
    let bodyHtml: String?
    let inReplyTo: String?
    let attachments: [OutgoingAttachment]

    init(to: [String], cc: [String], bcc: [String], subject: String,
         bodyText: String, bodyHtml: String? = nil, inReplyTo: String? = nil,
         attachments: [OutgoingAttachment] = []) {
        self.to = to; self.cc = cc; self.bcc = bcc; self.subject = subject
        self.bodyText = bodyText; self.bodyHtml = bodyHtml; self.inReplyTo = inReplyTo
        self.attachments = attachments
    }
}
