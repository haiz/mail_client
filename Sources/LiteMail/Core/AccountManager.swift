import Foundation

/// Owns all accounts and their mail providers.
/// Routes operations to the correct account's provider.
/// Conforms to MailEngineProtocol for the GUI layer.
actor AccountManager: MailEngineProtocol {

    let store: MailStore
    let authManager: AuthManager

    private var providers: [String: any MailProvider] = [:]
    private var syncTasks: [String: Task<Void, Never>] = [:]

    init(store: MailStore, authManager: AuthManager) {
        self.store = store
        self.authManager = authManager
    }

    /// Loads providers for all stored accounts.
    func loadAccounts() async throws {
        let accounts = try await store.listAccounts()
        for account in accounts {
            let config = Self.toConfig(account)
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
        guard let body = try await store.fetchBody(emailId: emailId) else { return nil }
        return EmailBody(emailId: emailId, textBody: body.text, htmlBody: body.html)
    }

    func fetchThread(threadId: String) async throws -> [EmailHeader] {
        let records = try await store.fetchThread(threadId: threadId)
        return records.map(Self.recordToHeader)
    }

    func listFolders(accountId: String) async throws -> [MailFolder] {
        let folders = try await store.listFolders(accountId: accountId)
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
        default: return folder
        }
    }

    private static func encodeJSON(_ strings: [String]) -> String {
        (try? String(data: JSONEncoder().encode(strings), encoding: .utf8)) ?? "[]"
    }
}

enum AccountManagerError: Error {
    case accountNotFound
}
