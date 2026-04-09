import Foundation

/// Owns all accounts and their mail providers.
/// Routes operations to the correct account's provider.
/// Conforms to MailEngineProtocol for the GUI layer.
actor AccountManager: MailEngineProtocol {

    let store: MailStore
    let authManager: AuthManager

    typealias ProviderFactory = @Sendable (AccountConfig, AuthManager, MailStore) -> any MailProvider

    private var providers: [String: any MailProvider] = [:]
    private var syncTasks: [String: Task<Void, Never>] = [:]
    private let providerFactory: ProviderFactory?

    init(store: MailStore, authManager: AuthManager, providerFactory: ProviderFactory? = nil) {
        self.store = store
        self.authManager = authManager
        self.providerFactory = providerFactory
    }

    /// Loads providers for all stored accounts.
    func loadAccounts() async throws {
        let accounts = try await store.listAccounts()
        for account in accounts {
            let config = Self.toConfig(account)
            // Skip IMAP accounts with no host configured (e.g. demo/offline accounts).
            // Without a real host there is nothing to connect to and auth will always fail.
            if config.protocolType == .imap && config.imapHost == nil { continue }
            let provider = createProvider(for: config)
            providers[account.id] = provider
        }
    }

    // MARK: - Accounts

    func listAccounts() async throws -> [AccountConfig] {
        let records = try await store.listAccounts()
        return records.map(Self.toConfig)
    }

    func addAccount(_ config: AccountConfig) async throws {
        let record = AccountRecord(
            id: config.id,
            emailAddress: config.emailAddress,
            displayName: config.displayName,
            protocolType: config.protocolType.rawValue,
            imapUsername: config.imapUsername,
            imapHost: config.imapHost,
            imapPort: config.imapPort,
            smtpHost: config.smtpHost,
            smtpPort: config.smtpPort,
            jmapUrl: config.jmapUrl,
            authType: config.authType.rawValue,
            keychainRef: config.keychainRef,
            isDefault: config.isDefault,
            createdAt: Int(Date().timeIntervalSince1970)
        )
        try await store.insertAccount(record)

        let provider = createProvider(for: config)
        providers[config.id] = provider
    }

    func removeAccount(id: String) async throws {
        // Stop sync
        syncTasks[id]?.cancel()
        syncTasks.removeValue(forKey: id)

        // Disconnect provider
        if let provider = providers[id] {
            try? await provider.disconnect()
        }
        providers.removeValue(forKey: id)

        // Remove credentials
        authManager.removeCredentials(accountId: id)

        // Delete from store (cascade deletes emails, sync state, outbox)
        try await store.deleteAccount(id: id)
    }

    func getProvider(for accountId: String) -> (any MailProvider)? {
        providers[accountId]
    }

    // MARK: - Sync

    func performInitialSync(accountId: String) async throws {
        guard let provider = providers[accountId] else { return }
        try await provider.connect()
        try await provider.performInitialSync()
        try await store.warmSearchCache()
    }

    func performIncrementalSync(accountId: String) async throws {
        guard let provider = providers[accountId] else { return }
        try await provider.performIncrementalSync()
    }

    func syncAllAccounts() async throws {
        for (accountId, provider) in providers {
            do {
                if await !provider.isConnected {
                    try await provider.connect()
                }
                try await provider.performIncrementalSync()
            } catch {
                // Log but don't block other accounts
                print("Sync failed for account \(accountId): \(error)")
            }
        }
    }

    /// Starts periodic sync for all accounts.
    func startPeriodicSync(interval: TimeInterval = 300) {
        for (accountId, provider) in providers {
            let task = Task {
                while !Task.isCancelled {
                    do {
                        if await !provider.isConnected {
                            try await provider.connect()
                        }
                        try await provider.performIncrementalSync()
                    } catch {
                        // Silent retry
                    }
                    try? await Task.sleep(for: .seconds(interval))
                }
            }
            syncTasks[accountId] = task
        }
    }

    func stopAllSync() {
        for task in syncTasks.values {
            task.cancel()
        }
        syncTasks.removeAll()
    }

    // MARK: - Search

    func search(query: String, accountId: String? = nil) async throws -> [EmailHeader] {
        let records = try await store.search(query: query, accountId: accountId)
        return records.map(Self.recordToHeader)
    }

    // MARK: - Read

    func fetchHeaders(accountId: String, folder: String, offset: Int, limit: Int) async throws -> [EmailHeader] {
        let records = try await store.fetchHeaders(accountId: accountId, folder: folder, offset: offset, limit: limit)
        return records.map(Self.recordToHeader)
    }

    func fetchBody(emailId: Int64) async throws -> EmailBody? {
        // Try local cache first (covers INBOX messages and any previously loaded body).
        if let body = try await store.fetchBody(emailId: emailId) {
            return EmailBody(emailId: emailId, textBody: body.text, htmlBody: body.html)
        }

        // Body not cached — fetch from the provider using the email's folder + UID (IMAP)
        // or the JMAP email ID.
        guard let record = try await store.fetchEmailRecord(id: emailId),
              let accountId = record.accountId,
              let provider = providers[accountId] else {
            return nil
        }

        let config = try await store.getAccount(id: accountId)
        let messageRef: String
        if config?.protocolType == "jmap" {
            messageRef = record.messageId
        } else {
            guard let uid = record.uid else { return nil }
            messageRef = "folder:\(record.folder):uid:\(uid)"
        }
        guard let providerBody = try? await provider.fetchMessageBody(messageRef: messageRef) else {
            return nil
        }

        // Cache so future opens are instant.
        try? await store.insertBody(emailId: emailId, text: providerBody.textBody, html: providerBody.htmlBody)

        return EmailBody(emailId: emailId, textBody: providerBody.textBody, htmlBody: providerBody.htmlBody)
    }

    func fetchThread(threadId: String) async throws -> [EmailHeader] {
        let records = try await store.fetchThread(threadId: threadId)
        return records.map(Self.recordToHeader)
    }

    func listFolders(accountId: String) async throws -> [MailFolder] {
        let folders = try await store.listFolders(accountId: accountId)
        return folders.map { MailFolder(id: $0.folder, name: Self.displayName(for: $0.folder), unreadCount: $0.unreadCount, role: Self.folderRole(for: $0.folder)) }
    }

    // MARK: - Actions

    func markRead(emailId: Int64, read: Bool) async throws {
        try await store.markRead(emailId: emailId, read: read)
        if let (provider, ref) = try await providerAndRef(for: emailId) {
            Task { try? await provider.markRead(messageRef: ref, read: read) }
        }
    }

    func markStarred(emailId: Int64, starred: Bool) async throws {
        try await store.markStarred(emailId: emailId, starred: starred)
        if let (provider, ref) = try await providerAndRef(for: emailId) {
            Task { try? await provider.markStarred(messageRef: ref, starred: starred) }
        }
    }

    func archive(emailId: Int64) async throws {
        let originalFolder = try await store.fetchEmailRecord(id: emailId)?.folder
        try await store.moveEmail(emailId: emailId, toFolder: "[Gmail]/All Mail")
        if let (provider, ref) = try await providerAndRef(for: emailId, folderOverride: originalFolder) {
            Task { try? await provider.moveMessage(messageRef: ref, toFolderId: "[Gmail]/All Mail") }
        }
    }

    func delete(emailId: Int64) async throws {
        try await store.markDeleted(emailId: emailId)
        if let (provider, ref) = try await providerAndRef(for: emailId) {
            Task { try? await provider.deleteMessage(messageRef: ref) }
        }
    }

    func move(emailId: Int64, toFolder: String) async throws {
        let originalFolder = try await store.fetchEmailRecord(id: emailId)?.folder
        try await store.moveEmail(emailId: emailId, toFolder: toFolder)
        if let (provider, ref) = try await providerAndRef(for: emailId, folderOverride: originalFolder) {
            Task { try? await provider.moveMessage(messageRef: ref, toFolderId: toFolder) }
        }
    }

    /// Look up the provider and build a messageRef for server-side sync.
    /// For IMAP: "folder:<name>:uid:<N>". For JMAP: the JMAP email ID (messageId).
    /// `folderOverride` is used when the local folder was already updated before this call.
    private func providerAndRef(for emailId: Int64, folderOverride: String? = nil) async throws -> (any MailProvider, String)? {
        guard let record = try await store.fetchEmailRecord(id: emailId),
              let accountId = record.accountId,
              let provider = providers[accountId] else {
            return nil
        }
        let config = try await store.getAccount(id: accountId)
        let isJMAP = config?.protocolType == "jmap"

        if isJMAP {
            // JMAP uses the email's messageId (which is the JMAP email ID)
            return (provider, record.messageId)
        } else {
            // IMAP uses folder:uid format
            guard let uid = record.uid else { return nil }
            let folder = folderOverride ?? record.folder
            return (provider, "folder:\(folder):uid:\(uid)")
        }
    }

    // MARK: - Folders

    func createFolder(name: String, accountId: String) async throws {
        guard let provider = providers[accountId] else {
            throw AccountManagerError.accountNotFound
        }
        try await provider.createFolder(name: name)
    }

    // MARK: - Labels

    func addLabel(emailId: Int64, label: String) async throws {
        try await store.addLabel(emailId: emailId, label: label)
    }

    func removeLabel(emailId: Int64, label: String) async throws {
        try await store.removeLabel(emailId: emailId, label: label)
    }

    func fetchLabels(emailId: Int64) async throws -> [String] {
        try await store.fetchLabels(emailId: emailId)
    }

    func allLabels(accountId: String) async throws -> [String] {
        try await store.allLabels(accountId: accountId)
    }

    // MARK: - Attachments

    func listAttachments(emailId: Int64) async throws -> [AttachmentInfo] {
        let records = try await store.fetchAttachments(emailId: emailId)
        return records.compactMap { rec in
            guard let partId = rec.partId else { return nil }
            return AttachmentInfo(
                id: partId,
                partId: partId,
                filename: rec.filename,
                mimeType: rec.mimeType,
                sizeBytes: rec.sizeBytes
            )
        }
    }

    func fetchAttachmentData(emailId: Int64, partId: String) async throws -> Data {
        guard let (provider, ref) = try await providerAndRef(for: emailId) else {
            throw AccountManagerError.accountNotFound
        }
        return try await provider.fetchAttachment(messageRef: ref, partId: partId)
    }

    // MARK: - Compose

    func send(message: OutgoingMessage, fromAccountId: String) async throws {
        guard let provider = providers[fromAccountId] else {
            throw AccountManagerError.accountNotFound
        }
        try await provider.send(message: message)
    }

    func saveDraft(_ draft: OutgoingMessage, accountId: String) async throws {
        let outbox = OutboxRecord(
            toRecipients: Self.encodeJSON(draft.to),
            ccRecipients: Self.encodeJSON(draft.cc),
            bccRecipients: Self.encodeJSON(draft.bcc),
            subject: draft.subject,
            bodyText: draft.bodyText,
            bodyHtml: draft.bodyHtml,
            inReplyTo: draft.inReplyTo,
            status: "draft",
            accountId: accountId
        )
        _ = try await store.queueOutgoing(outbox)
    }

    // MARK: - Helpers

    private func createProvider(for config: AccountConfig) -> any MailProvider {
        if let factory = providerFactory {
            return factory(config, authManager, store)
        }
        switch config.protocolType {
        case .imap:
            return IMAPProvider(config: config, authManager: authManager, store: store)
        case .jmap:
            return JMAPProvider(config: config, authManager: authManager, store: store)
        }
    }

    private static func recordToHeader(_ r: EmailRecord) -> EmailHeader {
        EmailHeader(
            id: r.id ?? 0,
            accountId: r.accountId ?? "default",
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

    private static func toConfig(_ record: AccountRecord) -> AccountConfig {
        AccountConfig(
            id: record.id,
            emailAddress: record.emailAddress,
            displayName: record.displayName,
            protocolType: AccountConfig.ProtocolType(rawValue: record.protocolType) ?? .imap,
            imapUsername: record.imapUsername,
            imapHost: record.imapHost,
            imapPort: record.imapPort,
            smtpHost: record.smtpHost,
            smtpPort: record.smtpPort,
            jmapUrl: record.jmapUrl,
            authType: AccountConfig.AuthType(rawValue: record.authType) ?? .password,
            keychainRef: record.keychainRef,
            isDefault: record.isDefault
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
        case "[Gmail]/Spam": return "Spam"
        default:
            if folder.hasPrefix("[Gmail]/Category/") {
                return String(folder.dropFirst("[Gmail]/Category/".count))
            }
            return folder.split(separator: "/").last.map(String.init) ?? folder
        }
    }

    static func folderRole(for folderId: String) -> FolderRole? {
        switch folderId {
        case "INBOX": return .inbox
        case "[Gmail]/Sent Mail", "Sent": return .sent
        case "[Gmail]/Drafts", "Drafts": return .drafts
        case "[Gmail]/Trash", "Trash": return .trash
        case "[Gmail]/Starred": return .starred
        case "[Gmail]/All Mail": return .all
        case "[Gmail]/Spam", "Spam", "Junk": return .spam
        default:
            if folderId.hasPrefix("[Gmail]/Category/") { return .category }
            return nil
        }
    }

    private static func encodeJSON(_ strings: [String]) -> String {
        (try? String(data: JSONEncoder().encode(strings), encoding: .utf8)) ?? "[]"
    }
}

enum AccountManagerError: Error {
    case accountNotFound
}
