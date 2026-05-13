import Foundation
import GRDB

/// Owns all accounts and their mail providers.
/// Routes operations to the correct account's provider.
/// Conforms to MailEngineProtocol for the GUI layer.
actor AccountManager: MailEngineProtocol {

    let store: MailStore
    let authManager: AuthManager
    let categoriesRefresher: CategoriesRefresher?

    typealias ProviderFactory = @Sendable (AccountConfig, AuthManager, MailStore) -> any MailProvider

    private var providers: [String: any MailProvider] = [:]
    private var syncTasks: [String: Task<Void, Never>] = [:]
    private let providerFactory: ProviderFactory?
    let deleteWorker: DeleteWorker

    init(
        store: MailStore,
        authManager: AuthManager,
        providerFactory: ProviderFactory? = nil,
        categoriesRefresher: CategoriesRefresher? = nil
    ) {
        self.store = store
        self.authManager = authManager
        self.providerFactory = providerFactory
        self.categoriesRefresher = categoriesRefresher
        // providerLookup is a temporary no-op; replaced in startDeleteWorker().
        self.deleteWorker = DeleteWorker(
            store: store,
            providerLookup: { _ in nil }
        )
    }

    /// Configures the delete worker's provider lookup and starts the tick loop.
    /// Must be called once after init (e.g. in loadAccounts or applicationDidFinishLaunching).
    func startDeleteWorker() async {
        await deleteWorker.setProviderLookup { [weak self] accountId in
            await self?.providers[accountId]
        }
        try? await store.resetRunningDeleteJobs()
        await deleteWorker.start()
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
        await refreshCategoriesIfApplicable(accountId: accountId)
    }

    /// Returns `true` when a provider was found and sync was attempted.
    @discardableResult
    func performIncrementalSync(accountId: String) async throws -> Bool {
        guard let provider = providers[accountId] else { return false }
        try await provider.performIncrementalSync()
        await refreshCategoriesIfApplicable(accountId: accountId)
        return true
    }

    func syncAllAccounts() async throws {
        for (accountId, provider) in providers {
            do {
                if await !provider.isConnected {
                    try await provider.connect()
                }
                try await provider.performIncrementalSync()
                await refreshCategoriesIfApplicable(accountId: accountId)
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

    static let unifiedAccountId = "__unified__"

    func fetchUnifiedInbox(offset: Int, limit: Int) async throws -> [EmailHeader] {
        let accountIds = try await store.listAccounts().map(\.id)
        let records = try await store.fetchInboxesAcrossAccounts(accountIds: accountIds, offset: offset, limit: limit)
        return records.map(Self.recordToHeader)
    }

    func search(query: String, accountId: String? = nil) async throws -> [EmailHeader] {
        let parsed = SearchQueryParser.parse(query)
        if !parsed.predicates.isEmpty {
            let records = try await store.search(parsed: parsed, accountId: accountId)
            return records.map(Self.recordToHeader)
        }
        let records = try await store.search(query: query, accountId: accountId)
        return records.map(Self.recordToHeader)
    }

    func listSavedSearches(accountId: String? = nil) async throws -> [MailStore.SavedSearchRecord] {
        try await store.fetchSavedSearches(accountId: accountId)
    }

    func saveSearch(accountId: String?, name: String, query: String) async throws -> Int64 {
        try await store.insertSavedSearch(accountId: accountId, name: name, query: query)
    }

    func deleteSavedSearch(id: Int64) async throws {
        try await store.deleteSavedSearch(id: id)
    }

    // MARK: - Read

    func fetchHeaders(accountId: String, folder: String, offset: Int, limit: Int) async throws -> [EmailHeader] {
        var resolvedFolder = folder
        if folder == "INBOX", try await isGmailAccount(accountId: accountId) {
            resolvedFolder = GmailCategory.personal.virtualFolderId
        }
        let records = try await store.fetchHeaders(
            accountId: accountId, folder: resolvedFolder,
            offset: offset, limit: limit
        )
        return records.map(Self.recordToHeader)
    }

    func fetchBody(emailId: Int64) async throws -> EmailBody? {
        // Use concurrent reader so we don't block behind sync writes on the actor.
        let cached = try store.concurrentReader.read { db -> (text: String?, html: String?)? in
            let row = try Row.fetchOne(db, sql: "SELECT body_text, body_html FROM email_bodies WHERE email_id = ?", arguments: [emailId])
            guard let row else { return nil }
            return (text: row["body_text"], html: row["body_html"])
        }
        if let body = cached {
            return EmailBody(emailId: emailId, textBody: body.text, htmlBody: body.html)
        }

        // Body not cached — fetch from the provider using the email's folder + UID (IMAP)
        // or the JMAP email ID.
        let record = try store.concurrentReader.read { db in
            try EmailRecord.fetchOne(db, key: emailId)
        }
        guard let record, let accountId = record.accountId,
              let provider = providers[accountId] else {
            return nil
        }

        let config = try store.concurrentReader.read { db in
            try AccountRecord.fetchOne(db, key: accountId)
        }
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
        var result = folders.map { MailFolder(id: $0.folder, name: Self.displayName(for: $0.folder), totalCount: $0.totalCount, unreadCount: $0.unreadCount, role: Self.folderRole(for: $0.folder)) }
        let scheduledCount = (try? await store.scheduledCount(accountId: accountId)) ?? 0
        let scheduled = MailFolder(id: "__scheduled__", name: "Scheduled",
                                   totalCount: scheduledCount, unreadCount: 0, role: .scheduled)
        if let draftsIdx = result.firstIndex(where: { $0.role == .drafts }) {
            result.insert(scheduled, at: draftsIdx + 1)
        } else {
            result.append(scheduled)
        }

        let snoozedCount = (try? await store.snoozedCount(accountId: accountId)) ?? 0
        let snoozed = MailFolder(id: "__snoozed__", name: "Snoozed",
                                 totalCount: snoozedCount, unreadCount: 0, role: .snoozed)
        result.append(snoozed)

        // Synthesize Gmail category virtual folders for Gmail accounts only.
        if (try? await isGmailAccount(accountId: accountId)) == true {
            let counts = (try? await store.gmailCategoryCounts(accountId: accountId)) ?? [:]
            let categoryEntries: [MailFolder] = GmailCategory.allCases.compactMap { cat -> MailFolder? in
                guard cat != .personal else { return nil }
                let c = counts[cat.rawValue] ?? (total: 0, unread: 0)
                return MailFolder(
                    id: cat.virtualFolderId,
                    name: Self.displayNameForCategory(cat),
                    totalCount: c.total,
                    unreadCount: c.unread,
                    role: .category
                )
            }
            result.append(contentsOf: categoryEntries)

            // Override the existing INBOX entry's count with Primary-only count.
            let primary = counts[GmailCategory.personal.rawValue] ?? (total: 0, unread: 0)
            if let inboxIdx = result.firstIndex(where: { $0.id == "INBOX" }) {
                let original = result[inboxIdx]
                result[inboxIdx] = MailFolder(
                    id: original.id,
                    name: original.name,
                    totalCount: primary.total,
                    unreadCount: primary.unread,
                    role: original.role
                )
            }
        }

        return result
    }

    // MARK: - Scheduled Send

    func scheduleSend(_ msg: OutgoingMessage, fromAccountId: String, sendAt: Date) async throws -> Int64 {
        let rec = OutboxRecord(
            toRecipients: Self.encodeJSON(msg.to),
            ccRecipients: Self.encodeJSON(msg.cc),
            bccRecipients: Self.encodeJSON(msg.bcc),
            subject: msg.subject,
            bodyText: msg.bodyText,
            bodyHtml: msg.bodyHtml,
            inReplyTo: msg.inReplyTo,
            createdAt: Int(Date().timeIntervalSince1970),
            status: "scheduled",
            accountId: fromAccountId,
            sendAfter: Int(sendAt.timeIntervalSince1970)
        )
        return try await store.enqueueOutgoing(rec)
    }

    func listScheduled(accountId: String) async throws -> [ScheduledMessage] {
        let records = try await store.listScheduled(accountId: accountId)
        return records.compactMap { rec in
            guard let id = rec.id, let sendAfterInt = rec.sendAfter else { return nil }
            let msg = rec.toOutgoingMessage()
            return ScheduledMessage(
                id: id,
                to: msg.to,
                subject: rec.subject,
                sendAfter: Date(timeIntervalSince1970: TimeInterval(sendAfterInt)),
                bodyText: rec.bodyText,
                accountId: rec.accountId ?? accountId
            )
        }
    }

    func cancelScheduled(outboxId: Int64) async throws -> OutboxRecord? {
        try await store.cancelOutgoing(id: outboxId)
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

    // MARK: - Snooze

    func snooze(emailId: Int64, until: Date) async throws {
        guard let rec = try await store.fetchEmailRecord(id: emailId) else { return }
        let accountId = rec.accountId ?? "default"
        let originalFolder = rec.folder
        try await store.insertSnooze(emailId: emailId, accountId: accountId,
                                     until: until, originalFolder: originalFolder)
        // Archive locally so the email disappears from the inbox
        try await store.markDeleted(emailId: emailId)
        if let (provider, ref) = try await providerAndRef(for: emailId, folderOverride: originalFolder) {
            let archiveFolderName = try await archiveFolderName(provider: provider, accountId: accountId)
            Task { try? await provider.moveMessage(messageRef: ref, toFolderId: archiveFolderName) }
        }
    }

    func unsnooze(emailId: Int64) async throws {
        guard let rec = try await store.fetchEmailRecord(id: emailId) else { return }
        try await store.deleteSnooze(emailId: emailId)
        try await store.restoreEmail(emailId: emailId)
        if let (provider, ref) = try await providerAndRef(for: emailId, folderOverride: nil) {
            let originalFolder = rec.folder
            Task { try? await provider.moveMessage(messageRef: ref, toFolderId: originalFolder) }
        }
    }

    func listSnoozed(accountId: String) async throws -> [EmailHeader] {
        let records = try await store.listSnoozed(accountId: accountId)
        return records.map { Self.recordToHeader($0) }
    }

    private func archiveFolderName(provider: any MailProvider, accountId: String) async throws -> String {
        let folders = try await provider.listFolders()
        return folders.first(where: { $0.role == .archive })?.id
            ?? folders.first(where: { $0.role == .inbox })?.id
            ?? "INBOX"
    }

    // MARK: - Spam

    func markSpam(emailId: Int64) async throws {
        let originalFolder = try await store.fetchEmailRecord(id: emailId)?.folder
        try await store.markDeleted(emailId: emailId)
        if let (provider, ref) = try await providerAndRef(for: emailId, folderOverride: originalFolder) {
            Task { try? await provider.markSpamBatch(messageRefs: [ref]) }
        }
    }

    func markSpamBatch(emailIds: [Int64]) async throws {
        guard !emailIds.isEmpty else { return }
        let records = try await store.fetchEmailRecords(ids: emailIds)
        for rec in records { if let id = rec.id { try await store.markDeleted(emailId: id) } }
        let groups = try await buildAccountGroups(records: records)
        for (provider, refs) in groups {
            Task { try? await provider.markSpamBatch(messageRefs: refs) }
        }
    }

    // MARK: - Image Allowlist

    func allowImages(accountId: String, sender: String) async throws {
        try await store.allowImages(accountId: accountId, sender: sender)
    }

    func isImageAllowed(accountId: String, sender: String) async throws -> Bool {
        try await store.isImageAllowed(accountId: accountId, sender: sender)
    }

    // MARK: - Batch Actions

    func deleteBatch(emailIds: [Int64]) async throws {
        guard !emailIds.isEmpty else { return }
        let records = try await store.fetchEmailRecords(ids: emailIds)
        try await store.enqueueDeletes(records: records)
        await deleteWorker.kick()
    }

    func archiveBatch(emailIds: [Int64]) async throws {
        guard !emailIds.isEmpty else { return }
        let archiveFolder = "[Gmail]/All Mail"
        // Capture original folders before moving (needed for IMAP ref building)
        let records = try await store.fetchEmailRecords(ids: emailIds)
        try await store.moveEmailBatch(emailIds: emailIds, toFolder: archiveFolder)
        let groups = try await buildAccountGroups(records: records)
        for (provider, refs) in groups {
            Task { try? await provider.moveMessageBatch(messageRefs: refs, toFolderId: archiveFolder) }
        }
    }

    func markReadBatch(emailIds: [Int64], read: Bool) async throws {
        guard !emailIds.isEmpty else { return }
        try await store.markReadBatch(emailIds: emailIds, read: read)
        let groups = try await groupByAccount(emailIds: emailIds)
        for (provider, refs) in groups {
            Task { try? await provider.markReadBatch(messageRefs: refs, read: read) }
        }
    }

    func markStarredBatch(emailIds: [Int64], starred: Bool) async throws {
        guard !emailIds.isEmpty else { return }
        try await store.markStarredBatch(emailIds: emailIds, starred: starred)
        let groups = try await groupByAccount(emailIds: emailIds)
        for (provider, refs) in groups {
            Task { try? await provider.markStarredBatch(messageRefs: refs, starred: starred) }
        }
    }

    func retryFailedDeletes(accountId: String, folder: String) async throws {
        try await store.requeueFailedDeleteJobs(
            accountId: accountId, folder: folder,
            now: Int(Date().timeIntervalSince1970)
        )
        await deleteWorker.kick()
    }

    func moveBatch(emailIds: [Int64], toFolder: String) async throws {
        guard !emailIds.isEmpty else { return }
        // Capture records before the move so we have the original folder for IMAP refs
        let records = try await store.fetchEmailRecords(ids: emailIds)
        try await store.moveEmailBatch(emailIds: emailIds, toFolder: toFolder)
        let groups = try await buildAccountGroups(records: records)
        for (provider, refs) in groups {
            Task { try? await provider.moveMessageBatch(messageRefs: refs, toFolderId: toFolder) }
        }
    }

    // MARK: - Batch Helpers

    /// Fetch email records for the given IDs, group by account, and return (provider, [messageRef]) pairs.
    /// Uses the *current* folder stored in the DB to build IMAP refs.
    private func groupByAccount(emailIds: [Int64]) async throws -> [(any MailProvider, [String])] {
        let records = try await store.fetchEmailRecords(ids: emailIds)
        return try await buildAccountGroups(records: records)
    }

    /// Build (provider, [messageRef]) pairs from a set of already-fetched EmailRecords.
    /// Groups by accountId; skips records missing accountId, uid (for IMAP), or provider.
    private func buildAccountGroups(records: [EmailRecord]) async throws -> [(any MailProvider, [String])] {
        // Group records by accountId
        var byAccount: [String: [EmailRecord]] = [:]
        for record in records {
            guard let accountId = record.accountId else { continue }
            byAccount[accountId, default: []].append(record)
        }

        var result: [(any MailProvider, [String])] = []
        for (accountId, accountRecords) in byAccount {
            guard let provider = providers[accountId] else { continue }
            let accountConfig = try await store.getAccount(id: accountId)
            let isJMAP = accountConfig?.protocolType == "jmap"

            var refs: [String] = []
            for record in accountRecords {
                if isJMAP {
                    refs.append(record.messageId)
                } else {
                    guard let uid = record.uid else { continue }
                    refs.append("folder:\(record.folder):uid:\(uid)")
                }
            }
            if !refs.isEmpty {
                result.append((provider, refs))
            }
        }
        return result
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
                sizeBytes: rec.sizeBytes,
                contentId: rec.contentId,
                isInline: rec.contentId != nil
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

    func signature(accountId: String) async throws -> String? {
        try await store.signature(accountId: accountId)
    }

    func setSignature(accountId: String, html: String?) async throws {
        try await store.setSignature(accountId: accountId, html: html)
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

    /// Queue a message for delayed sending. Returns the outbox row id.
    /// The outbox worker will pick it up once `now >= sendAfter`.
    func enqueueSend(_ msg: OutgoingMessage, fromAccountId: String, delaySeconds: Int) async throws -> Int64 {
        let sendAfter = Int(Date().timeIntervalSince1970) + delaySeconds
        let rec = OutboxRecord(
            toRecipients: Self.encodeJSON(msg.to),
            ccRecipients: Self.encodeJSON(msg.cc),
            bccRecipients: Self.encodeJSON(msg.bcc),
            subject: msg.subject,
            bodyText: msg.bodyText,
            bodyHtml: msg.bodyHtml,
            inReplyTo: msg.inReplyTo,
            createdAt: Int(Date().timeIntervalSince1970),
            status: "queued",
            accountId: fromAccountId,
            sendAfter: sendAfter
        )
        return try await store.enqueueOutgoing(rec)
    }

    /// Cancel a queued send. Returns the OutboxRecord if it was still in "queued" state,
    /// nil if it already fired.
    func cancelSend(outboxId: Int64) async throws -> OutboxRecord? {
        try await store.cancelOutgoing(id: outboxId)
    }

    // MARK: - Outbox Worker

    /// Starts the background 1-second outbox processing loop.
    /// Call once after account setup (in startDeleteWorker or AppDelegate).
    func startOutboxWorker() {
        Task.detached { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self?.processOutbox()
            }
        }
    }

    private func processOutbox() async {
        let due = (try? await store.dueOutgoing(now: Date())) ?? []
        for rec in due {
            guard let id = rec.id, let accountId = rec.accountId else { continue }
            guard (try? await store.atomicClaimForSending(id: id)) == true else { continue }
            do {
                try await send(message: rec.toOutgoingMessage(), fromAccountId: accountId)
                try? await store.updateOutboxStatus(id: id, status: "sent")
            } catch {
                try? await store.setOutgoingError(id: id, error: "\(error)")
            }
        }
    }

    // MARK: - Helpers

    /// Best-effort Gmail category refresh. Errors are swallowed so sync
    /// success is never gated on categorization.
    private func refreshCategoriesIfApplicable(accountId: String) async {
        guard let refresher = categoriesRefresher else { return }
        guard (try? await isGmailAccount(accountId: accountId)) == true else { return }
        do {
            try await refresher.refresh(accountId: accountId)
        } catch {
            // Service-level errors are already logged inside the refresher.
            // Sync success is independent of categorization.
        }
    }

    private func isGmailAccount(accountId: String) async throws -> Bool {
        guard let record = try await store.getAccount(id: accountId) else { return false }
        let email = record.emailAddress.lowercased()
        let isGmailDomain = email.hasSuffix("@gmail.com") || email.hasSuffix("@googlemail.com")
        return isGmailDomain && record.authType == "oauth2"
    }

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
            snippet: r.snippet,
            recipients: r.recipients,
            deleteState: r.deleteState
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

    private static func displayNameForCategory(_ category: GmailCategory) -> String {
        switch category {
        case .personal:   return "Primary"
        case .promotions: return "Promotions"
        case .social:     return "Social"
        case .updates:    return "Updates"
        case .forums:     return "Forums"
        case .purchases:  return "Purchases"
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
            if GmailCategory(virtualFolderId: folderId) != nil { return .category }
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
