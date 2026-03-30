import Foundation

/// Concrete implementation of MailEngineProtocol.
/// Wires together MailStore, MailTransport, SyncEngine, and GmailAuth.
final class MailEngine: MailEngineProtocol, @unchecked Sendable {

    let store: MailStore
    let auth: GmailAuth
    let transport: MailTransport
    let syncEngine: SyncEngine

    init(dbPath: String, clientId: String, redirectURI: URL, userEmail: String) throws {
        self.store = try MailStore(path: dbPath)
        self.auth = GmailAuth(clientId: clientId, redirectURI: redirectURI)
        self.transport = MailTransport(auth: auth, userEmail: userEmail)
        self.syncEngine = SyncEngine(transport: transport, store: store)
    }

    // MARK: - Authentication

    func authenticate() async throws -> Bool {
        try await auth.authenticate()
        return auth.isAuthenticated
    }

    var isAuthenticated: Bool {
        get async { auth.isAuthenticated }
    }

    // MARK: - Sync

    func performInitialSync(recentBodyCount: Int) async throws {
        try await syncEngine.performInitialSync(recentBodyCount: recentBodyCount)
        // Pre-warm FTS5 cache after sync
        try await store.warmSearchCache()
    }

    func performIncrementalSync() async throws {
        try await syncEngine.performIncrementalSync()
    }

    func startIdleWatch() async throws {
        try await syncEngine.startIdleWatch {
            // On new message, do an incremental sync
            try? await self.syncEngine.performIncrementalSync()
        }
    }

    func stopIdleWatch() async throws {
        // IDLE session stops when the task is cancelled
    }

    // MARK: - Search

    func search(query: String) async throws -> [EmailHeader] {
        let records = try await store.search(query: query)
        return records.map(Self.recordToHeader)
    }

    // MARK: - Read

    func fetchHeaders(folder: String, offset: Int, limit: Int) async throws -> [EmailHeader] {
        let records = try await store.fetchHeaders(folder: folder, offset: offset, limit: limit)
        return records.map(Self.recordToHeader)
    }

    func fetchBody(emailId: Int64) async throws -> EmailBody? {
        guard let body = try await store.fetchBody(emailId: emailId) else { return nil }
        return EmailBody(emailId: emailId, textBody: body.text, htmlBody: body.html)
    }

    func fetchThread(threadId: String) async throws -> [EmailHeader] {
        let records = try await store.fetchThread(threadId: threadId)
        return records.map(Self.recordToHeader)
    }

    func listFolders() async throws -> [MailFolder] {
        let folders = try await store.listFolders()
        return folders.map { MailFolder(id: $0.folder, name: Self.displayName(for: $0.folder), unreadCount: $0.unreadCount) }
    }

    // MARK: - Actions

    func markRead(emailId: Int64, read: Bool) async throws {
        try await store.markRead(emailId: emailId, read: read)
    }

    func markStarred(emailId: Int64, starred: Bool) async throws {
        try await store.markStarred(emailId: emailId, starred: starred)
    }

    func archive(emailId: Int64) async throws {
        try await store.moveEmail(emailId: emailId, toFolder: "[Gmail]/All Mail")
    }

    func delete(emailId: Int64) async throws {
        try await store.markDeleted(emailId: emailId)
    }

    func move(emailId: Int64, toFolder: String) async throws {
        try await store.moveEmail(emailId: emailId, toFolder: toFolder)
    }

    // MARK: - Compose

    func send(message: OutgoingMessage) async throws {
        let outbox = OutboxRecord(
            toRecipients: Self.encodeJSON(message.to),
            ccRecipients: Self.encodeJSON(message.cc),
            bccRecipients: Self.encodeJSON(message.bcc),
            subject: message.subject,
            bodyText: message.bodyText,
            bodyHtml: message.bodyHtml,
            inReplyTo: message.inReplyTo,
            status: "queued"
        )
        _ = try await store.queueOutgoing(outbox)
        // TODO: Phase 3 — actually send via SMTP
    }

    func saveDraft(_ draft: OutgoingMessage) async throws {
        // TODO: Phase 3 — save to drafts folder
    }

    // MARK: - Helpers

    private static func recordToHeader(_ r: EmailRecord) -> EmailHeader {
        EmailHeader(
            id: r.id ?? 0,
            messageId: r.messageId,
            threadId: r.threadId,
            folder: r.folder,
            senderName: r.senderName,
            senderEmail: r.senderEmail,
            subject: r.subject,
            date: Date(timeIntervalSince1970: TimeInterval(r.date)),
            isRead: r.isRead,
            isStarred: r.isStarred,
            hasAttachments: r.hasAttachments,
            snippet: nil
        )
    }

    private static func displayName(for folder: String) -> String {
        switch folder {
        case "INBOX": return "Inbox"
        case "[Gmail]/Sent Mail": return "Sent"
        case "[Gmail]/Drafts": return "Drafts"
        case "[Gmail]/Trash": return "Trash"
        case "[Gmail]/Starred": return "Starred"
        case "[Gmail]/All Mail": return "All Mail"
        default: return folder
        }
    }

    private static func encodeJSON(_ strings: [String]) -> String {
        (try? String(data: JSONEncoder().encode(strings), encoding: .utf8)) ?? "[]"
    }
}
