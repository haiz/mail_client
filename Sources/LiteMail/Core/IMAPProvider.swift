import Foundation
import SwiftMail

/// IMAP implementation of MailProvider.
/// Handles connection, sync, IDLE, and all IMAP-specific operations.
actor IMAPProvider: MailProvider {

    let accountId: String
    let emailAddress: String

    private let config: AccountConfig
    private let authManager: AuthManager
    private let store: MailStore

    private var imapServer: IMAPServer?
    private var reconnectAttempts = 0
    private let maxReconnectDelay: TimeInterval = 60

    var isConnected: Bool { imapServer != nil }

    /// Username for IMAP login. Uses imapUsername if set, otherwise email address.
    private var loginUsername: String { config.imapUsername ?? emailAddress }

    init(config: AccountConfig, authManager: AuthManager, store: MailStore) {
        self.accountId = config.id
        self.emailAddress = config.emailAddress
        self.config = config
        self.authManager = authManager
        self.store = store
    }

    // MARK: - Connection

    func connect() async throws {
        let host = config.imapHost ?? "imap.gmail.com"
        let port = config.imapPort ?? 993

        let server = IMAPServer(host: host, port: port)
        try await server.connect()

        switch config.authType {
        case .oauth2:
            let token = try await authManager.oauthAccessToken(accountId: accountId)
            do {
                try await server.authenticateXOAUTH2(email: emailAddress, accessToken: token)
            } catch {
                throw IMAPProviderError.authFailed(error.localizedDescription)
            }
        case .password:
            guard let password = authManager.getPassword(accountId: accountId), !password.isEmpty else {
                throw IMAPProviderError.noCredentials
            }
            // Try AUTHENTICATE PLAIN first (required by Stalwart, Dovecot, etc.)
            // Fall back to LOGIN if PLAIN is not supported
            do {
                try await server.authenticatePlain(username: loginUsername, password: password)
            } catch {
                try await server.login(username: loginUsername, password: password)
            }
        case .bearer:
            break // JMAP-only, not used for IMAP
        }

        reconnectAttempts = 0
        imapServer = server
    }

    func disconnect() async throws {
        if let server = imapServer {
            try? await server.logout()
            imapServer = nil
        }

    }

    private func getIMAP() async throws -> IMAPServer {
        if let server = imapServer { return server }
        try await connect()
        guard let server = imapServer else { throw IMAPProviderError.notConnected }
        return server
    }

    // MARK: - Sync

    func performInitialSync() async throws {
        var imap = try await getIMAP()
        let folders = try await listFolders()

        for folder in folders where !Self.isSkippedFolder(folder.id) {
            do {
                try await syncFolder(imap: imap, folderId: folder.id)
            } catch {
                // If the connection died mid-sync (e.g. server dropped it and SwiftMail's
                // internal PLAIN re-auth failed), clear imapServer so the next call to
                // getIMAP() reconnects via connect() which has the PLAIN→LOGIN fallback.
                imapServer = nil
                // Reconnect so subsequent folders can still be synced.
                imap = try await getIMAP()
            }
        }
    }

    func performIncrementalSync() async throws {
        var imap = try await getIMAP()
        let folders = try await listFolders()

        for folder in folders where !Self.isSkippedFolder(folder.id) {
            do {
                try await incrementalSyncFolder(imap: imap, folderId: folder.id)
            } catch {
                // Same as above: clear stale connection on any per-folder failure,
                // then reconnect for remaining folders.
                imapServer = nil
                imap = try await getIMAP()
            }
        }
    }

    /// Returns true for Gmail virtual folders that duplicate emails found in real folders.
    /// Syncing them would store the same messages twice under different folder names.
    /// Also skips namespace-only entries like "[Gmail]" / "[Google Mail]" which are not
    /// real mailboxes and cause SELECT failures.
    private static func isSkippedFolder(_ folderId: String) -> Bool {
        let skipped: Set<String> = [
            "[Gmail]",
            "[Google Mail]",
            "[Gmail]/All Mail",
            "[Gmail]/Important",
            "[Gmail]/Starred",
            "[Google Mail]/All Mail",
            "[Google Mail]/Important",
            "[Google Mail]/Starred",
        ]
        return skipped.contains(folderId)
    }

    private func syncFolder(imap: IMAPServer, folderId: String) async throws {
        let selection = try await imap.selectMailbox(folderId)
        let messageCount = selection.messageCount
        guard messageCount > 0 else { return }

        let startSeq = UInt32(max(1, messageCount - 4999))
        let range = SequenceNumber(startSeq)...SequenceNumber(UInt32(messageCount))
        let seqSet = SequenceNumberSet(range)

        // Use the chunked streaming API (batches of 50) to avoid
        // hitting the 10-second per-command timeout on large folders.
        var lastUid: Int?
        let stream = imap.fetchMessageInfos(using: seqSet)
        for try await info in stream {
            let record = Self.toEmailRecord(info, folder: folderId, accountId: accountId)
            if let emailId = try? await store.insertEmail(record) {
                await storeAttachmentMetadata(info: info, emailId: emailId)
            }
            if let uid = info.uid {
                lastUid = Int(uid.value)
            }
        }

        // Bodies are fetched on-demand when the user opens a message (fetchMessageBody).
        // Pre-fetching here is skipped: sequence-range fetches don't include UIDs,
        // causing FetchStructureCommand<UID> to fail on Gmail.

        let syncState = SyncStateRecord(
            accountId: accountId,
            folder: folderId,
            uidValidity: Int(selection.uidValidity.value),
            lastUid: lastUid,
            lastSync: Int(Date().timeIntervalSince1970)
        )
        try await store.updateSyncState(syncState)
    }

    private func incrementalSyncFolder(imap: IMAPServer, folderId: String) async throws {
        guard let syncState = try await store.getSyncState(accountId: accountId, folder: folderId),
              let lastUid = syncState.lastUid else {
            try await syncFolder(imap: imap, folderId: folderId)
            return
        }

        let selection = try await imap.selectMailbox(folderId)

        if let storedValidity = syncState.uidValidity,
           storedValidity != Int(selection.uidValidity.value) {
            try await syncFolder(imap: imap, folderId: folderId)
            return
        }

        let startUid = UID(UInt32(lastUid + 1))
        let newHeaders: [MessageInfo]
        do {
            newHeaders = try await imap.fetchMessageInfos(uidRange: startUid...)
        } catch {
            return
        }

        guard !newHeaders.isEmpty else { return }

        for info in newHeaders {
            let record = Self.toEmailRecord(info, folder: folderId, accountId: accountId)
            if let emailId = try? await store.insertEmail(record) {
                await storeAttachmentMetadata(info: info, emailId: emailId)
            }
            await fetchAndStoreBody(imap: imap, info: info)
        }

        let newLastUid: Int = newHeaders.last?.uid.map { Int($0.value) } ?? lastUid
        let updatedState = SyncStateRecord(
            accountId: accountId,
            folder: folderId,
            uidValidity: syncState.uidValidity,
            lastUid: newLastUid,
            lastSync: Int(Date().timeIntervalSince1970)
        )
        try await store.updateSyncState(updatedState)

        // Reconcile any pending_delete rows in this folder against server state.
        await reconcilePendingDeletes(imap: imap, folderId: folderId)
    }

    // MARK: - Reconciliation

    /// Compares local pending_delete rows for this folder against server UIDs.
    /// UIDs absent on server → hard-delete locally (server already expunged).
    /// UIDs still present → leave alone; worker will retry.
    /// Best-effort: errors are caught and logged, never fail the sync.
    private func reconcilePendingDeletes(imap: IMAPServer, folderId: String) async {
        let pending: [(emailId: Int64, uid: Int)]
        do {
            pending = try await store.fetchPendingDeleteUids(accountId: accountId, folder: folderId)
        } catch {
            return
        }
        guard !pending.isEmpty else { return }

        // Fetch the UID range that covers our pending UIDs. UIDs present on server
        // are returned; missing ones were already expunged.
        let uids = pending.map { $0.uid }
        let minUid = UID(UInt32(uids.min()!))
        let maxUid = UID(UInt32(uids.max()!))
        let found: Set<Int>
        do {
            let infos = try await imap.fetchMessageInfos(uidRange: minUid...maxUid)
            found = Set(infos.compactMap { $0.uid.map { Int($0.value) } })
        } catch {
            print("DeleteWorker reconciliation: UID fetch failed for \(folderId): \(error)")
            return
        }

        let missing = pending.filter { !found.contains($0.uid) }.map(\.emailId)
        if !missing.isEmpty {
            try? await store.confirmDeletesByEmailIds(missing)
        }
    }

    // MARK: - Push

    func startPushNotifications(onNewMessage: @escaping @Sendable () async -> Void) async throws {
        let imap = try await getIMAP()
        let session = try await imap.idle(on: "INBOX")

        Task {
            for await event in session.events {
                if case .exists = event {
                    await onNewMessage()
                }
            }
        }
    }

    func stopPushNotifications() async throws {
        // IDLE session stops when the task is cancelled
    }

    // MARK: - Folders

    func createFolder(name: String) async throws {
        let imap = try await getIMAP()
        try await imap.createMailbox(name)
    }

    func listFolders() async throws -> [ProviderFolder] {
        let imap = try await getIMAP()
        let mailboxes = try await imap.listMailboxes()

        return mailboxes.compactMap { mailbox in
            let role = Self.detectRole(mailbox.name)
            return ProviderFolder(
                id: mailbox.name,
                name: Self.displayName(for: mailbox.name),
                totalCount: 0,
                unreadCount: 0,
                role: role
            )
        }
    }

    // MARK: - Messages

    func fetchMessages(folderId: String, cursor: String?, limit: Int) async throws -> (messages: [ProviderMessage], nextCursor: String?) {
        let imap = try await getIMAP()
        let selection = try await imap.selectMailbox(folderId)
        let total = selection.messageCount

        let end: Int
        if let cursor, let cursorVal = Int(cursor) {
            end = cursorVal
        } else {
            end = total
        }

        let start = max(1, end - limit + 1)
        guard start <= end, end > 0 else { return (messages: [], nextCursor: nil) }

        let range = SequenceNumber(UInt32(start))...SequenceNumber(UInt32(end))
        let infos = try await imap.fetchMessageInfos(sequenceRange: range)

        let messages = infos.map { Self.toProviderMessage($0) }
        let nextCursor = start > 1 ? "\(start - 1)" : nil

        return (messages: messages.reversed(), nextCursor: nextCursor)
    }

    func fetchMessageBody(messageRef: String) async throws -> ProviderMessageBody {
        let imap = try await getIMAP()
        let (folder, uid) = Self.parseFolderAndUidRef(messageRef)

        // Select the correct mailbox before fetching by UID.
        // Without this, IMAP fetches from whichever folder is currently selected
        // (typically INBOX after sync), returning wrong/missing content for Sent, etc.
        if let folder {
            _ = try await imap.selectMailbox(folder)
        }

        guard let info = try await imap.fetchMessageInfo(for: uid) else {
            throw IMAPProviderError.messageNotFound
        }

        let message = try await imap.fetchMessage(from: info)
        return ProviderMessageBody(ref: messageRef, textBody: message.textBody, htmlBody: message.htmlBody)
    }

    // MARK: - Actions

    func markRead(messageRef: String, read: Bool) async throws {
        let imap = try await getIMAP()
        let (folder, uid) = Self.parseFolderAndUidRef(messageRef)
        if let folder { _ = try await imap.selectMailbox(folder) }
        let uidSet = MessageIdentifierSet<UID>(uid)
        try await imap.store(flags: [.seen], on: uidSet, operation: read ? .add : .remove)
    }

    func markStarred(messageRef: String, starred: Bool) async throws {
        let imap = try await getIMAP()
        let (folder, uid) = Self.parseFolderAndUidRef(messageRef)
        if let folder { _ = try await imap.selectMailbox(folder) }
        let uidSet = MessageIdentifierSet<UID>(uid)
        try await imap.store(flags: [.flagged], on: uidSet, operation: starred ? .add : .remove)
    }

    func moveMessage(messageRef: String, toFolderId: String) async throws {
        let imap = try await getIMAP()
        let (folder, uid) = Self.parseFolderAndUidRef(messageRef)
        if let folder { _ = try await imap.selectMailbox(folder) }
        try await imap.move(message: uid, to: toFolderId)
    }

    func deleteMessage(messageRef: String) async throws {
        let imap = try await getIMAP()
        let (folder, uid) = Self.parseFolderAndUidRef(messageRef)
        if let folder { _ = try await imap.selectMailbox(folder) }
        let uidSet = MessageIdentifierSet<UID>(uid)
        try await imap.store(flags: [.deleted], on: uidSet, operation: .add)
        try await imap.expunge()
    }

    // MARK: - Batch Actions

    func markReadBatch(messageRefs: [String], read: Bool) async throws {
        guard !messageRefs.isEmpty else { return }
        let imap = try await getIMAP()
        for (folder, uids) in Self.groupRefsByFolder(messageRefs) {
            if let folder { _ = try await imap.selectMailbox(folder) }
            let uidSet = MessageIdentifierSet<UID>(uids)
            try await imap.store(flags: [.seen], on: uidSet, operation: read ? .add : .remove)
        }
    }

    func markStarredBatch(messageRefs: [String], starred: Bool) async throws {
        guard !messageRefs.isEmpty else { return }
        let imap = try await getIMAP()
        for (folder, uids) in Self.groupRefsByFolder(messageRefs) {
            if let folder { _ = try await imap.selectMailbox(folder) }
            let uidSet = MessageIdentifierSet<UID>(uids)
            try await imap.store(flags: [.flagged], on: uidSet, operation: starred ? .add : .remove)
        }
    }

    func moveMessageBatch(messageRefs: [String], toFolderId: String) async throws {
        guard !messageRefs.isEmpty else { return }
        let imap = try await getIMAP()
        for (folder, uids) in Self.groupRefsByFolder(messageRefs) {
            if let folder { _ = try await imap.selectMailbox(folder) }
            for uid in uids {
                try await imap.move(message: uid, to: toFolderId)
            }
        }
    }

    func deleteMessageBatch(messageRefs: [String]) async throws {
        guard !messageRefs.isEmpty else { return }
        let imap = try await getIMAP()
        for (folder, uids) in Self.groupRefsByFolder(messageRefs) {
            if let folder { _ = try await imap.selectMailbox(folder) }
            let uidSet = MessageIdentifierSet<UID>(uids)
            try await imap.store(flags: [.deleted], on: uidSet, operation: .add)
            try await imap.expunge()
        }
    }

    /// Group messageRefs by folder for batch IMAP operations.
    private static func groupRefsByFolder(_ refs: [String]) -> [(folder: String?, uids: [UID])] {
        var groups: [String: [UID]] = [:]
        var noFolder: [UID] = []
        for ref in refs {
            let (folder, uid) = parseFolderAndUidRef(ref)
            if let folder {
                groups[folder, default: []].append(uid)
            } else {
                noFolder.append(uid)
            }
        }
        var result: [(folder: String?, uids: [UID])] = groups.map { (folder: $0.key, uids: $0.value) }
        if !noFolder.isEmpty {
            result.append((folder: nil, uids: noFolder))
        }
        return result
    }

    func fetchAttachment(messageRef: String, partId: String) async throws -> Data {
        let imap = try await getIMAP()
        let uid = Self.parseUidRef(messageRef)
        let section = Section(partId)
        return try await imap.fetchPart(section: section, of: uid)
    }

    // MARK: - Send

    /// Send an email via SMTP. All actor-state reads happen here (on the actor),
    /// then the actual SMTP work is dispatched through a nonisolated static method
    /// so it never competes with ongoing IMAP operations on this actor.
    func send(message: OutgoingMessage) async throws {
        // --- Read all actor state before leaving the actor ---
        let host     = config.smtpHost ?? "smtp.gmail.com"
        let port     = config.smtpPort ?? 465
        let user     = loginUsername
        let from     = emailAddress
        let authType = config.authType

        // OAuth2 token fetch is async but still fast (cached / refresh).
        let credential: String
        switch authType {
        case .oauth2:
            credential = try await authManager.oauthAccessToken(accountId: accountId)
        case .password:
            credential = authManager.getPassword(accountId: accountId) ?? ""
        case .bearer:
            credential = ""
        }

        // Delegate to a nonisolated static function so withThrowingTaskGroup
        // tasks run off this actor's executor — no actor contention, reliable timeout.
        try await Self.smtpSend(
            host: host, port: port,
            user: user, from: from,
            authType: authType, credential: credential,
            message: message
        )

        // After SMTP succeeds, save a copy to the Sent folder via IMAP APPEND.
        // Non-fatal: a failed append should not roll back a successful send.
        let email = Email(
            sender: EmailAddress(name: nil, address: from),
            recipients: message.to.map { EmailAddress(name: nil, address: $0) },
            ccRecipients: message.cc.map { EmailAddress(name: nil, address: $0) },
            subject: message.subject,
            textBody: message.bodyText,
            htmlBody: message.bodyHtml
        )
        try? await saveSentCopy(email: email, message: message)
    }

    /// Appends a sent message to the Sent IMAP folder, then immediately writes
    /// it to the local store so the Sent folder populates without waiting for
    /// the next sync cycle.
    private func saveSentCopy(email: Email, message: OutgoingMessage) async throws {
        let imap = try await getIMAP()
        let sentFolder = try await resolveSentFolder(imap: imap)
        let result = try await imap.append(email: email, to: sentFolder, flags: [.seen])

        // Use the server-assigned UID to fetch the real MessageInfo (includes the
        // Message-ID assigned by the server). This lets us write a properly keyed
        // EmailRecord so subsequent incremental syncs deduplicate correctly.
        guard let uid = result.firstUID else { return }
        _ = try await imap.selectMailbox(sentFolder)
        guard let info = try await imap.fetchMessageInfo(for: uid) else { return }

        let record = Self.toEmailRecord(info, folder: sentFolder, accountId: accountId)
        if let emailId = try? await store.insertEmail(record) {
            try? await store.insertBody(emailId: emailId, text: message.bodyText, html: message.bodyHtml)
        }
    }

    /// Returns the name of the Sent folder, creating it if it doesn't exist.
    private func resolveSentFolder(imap: IMAPServer) async throws -> String {
        let mailboxes = try await imap.listMailboxes()
        let sentNames: [String] = ["Sent", "Sent Items", "Sent Messages", "[Gmail]/Sent Mail"]
        for name in sentNames {
            if mailboxes.contains(where: { $0.name == name }) {
                return name
            }
        }
        // No Sent folder found — create one.
        try await imap.createMailbox("Sent")
        return "Sent"
    }

    /// Nonisolated SMTP helper. Runs entirely on the cooperative thread pool.
    /// Uses CheckedContinuation so the timeout returns IMMEDIATELY without
    /// waiting for SwiftMail's internal NIO command timeouts to fire.
    private static func smtpSend(
        host: String, port: Int,
        user: String, from: String,
        authType: AccountConfig.AuthType, credential: String,
        message: OutgoingMessage
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let once = SMTPOnceFlag()

            // Task 1: do the SMTP work
            let sendTask = Task.detached {
                do {
                    let smtp = SMTPServer(host: host, port: port)
                    try await smtp.connect()

                    switch authType {
                    case .oauth2:
                        try await smtp.authenticateXOAUTH2(email: from, accessToken: credential)
                    case .password:
                        try await smtp.login(username: user, password: credential)
                    case .bearer:
                        break
                    }

                    let swiftMailAttachments: [Attachment]? = message.attachments.isEmpty ? nil :
                        message.attachments.map { Attachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) }
                    let email = Email(
                        sender: EmailAddress(name: nil, address: from),
                        recipients: message.to.map { EmailAddress(name: nil, address: $0) },
                        ccRecipients: message.cc.map { EmailAddress(name: nil, address: $0) },
                        bccRecipients: message.bcc.map { EmailAddress(name: nil, address: $0) },
                        subject: message.subject,
                        textBody: message.bodyText,
                        htmlBody: message.bodyHtml,
                        attachments: swiftMailAttachments
                    )
                    try await smtp.sendEmail(email)
                    once.resume(continuation, with: .success(()))
                } catch {
                    print("[SMTP] send failed: \(error)")
                    once.resume(continuation, with: .failure(error))
                }
            }

            // Task 2: 30-second hard deadline
            Task.detached {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                once.resume(continuation, with: .failure(IMAPProviderError.smtpTimeout))
                sendTask.cancel()   // best-effort; NIO ignores it but stops future Swift hops
            }
        }
    }

    // MARK: - Helpers

    /// Extract attachment metadata from MessageInfo parts and store in the DB.
    private func storeAttachmentMetadata(info: MessageInfo, emailId: Int64) async {
        let attachmentParts = info.parts.filter { $0.disposition == "attachment" }
        guard !attachmentParts.isEmpty else { return }

        let records = attachmentParts.map { part in
            AttachmentRecord(
                emailId: emailId,
                partId: part.section.description,
                filename: part.filename ?? part.suggestedFilename,
                mimeType: part.contentType,
                sizeBytes: part.data?.count,
                contentId: part.contentId
            )
        }
        try? await store.insertAttachments(records)
    }

    private func fetchAndStoreBody(imap: IMAPServer, info: MessageInfo) async {
        do {
            let message = try await imap.fetchMessage(from: info)
            if let messageIdStr = info.messageId?.description,
               let id = try await store.findEmailId(byMessageId: messageIdStr, accountId: accountId) {
                try await store.insertBody(emailId: id, text: message.textBody, html: message.htmlBody)
            }
        } catch {
            // Non-fatal
        }
    }

    static func toEmailRecord(_ info: MessageInfo, folder: String, accountId: String) -> EmailRecord {
        let threadId = info.references?.first?.description ?? info.messageId?.description
        let flags = info.flags

        return EmailRecord(
            messageId: info.messageId?.description ?? UUID().uuidString,
            threadId: threadId,
            folder: folder,
            senderName: nil,
            senderEmail: info.from ?? "unknown@unknown.com",
            recipients: (try? String(data: JSONEncoder().encode(info.to), encoding: .utf8)),
            subject: info.subject,
            date: Int(info.date?.timeIntervalSince1970 ?? info.internalDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970),
            isRead: flags.contains(.seen),
            isStarred: flags.contains(.flagged),
            isDeleted: flags.contains(.deleted),
            hasAttachments: !info.parts.filter { $0.disposition == "attachment" }.isEmpty,
            uid: info.uid.map { Int($0.value) },
            flags: flags.map(\.description).joined(separator: ","),
            referencesHeader: info.references?.map(\.description).joined(separator: " "),
            inReplyTo: info.inReplyTo?.description,
            accountId: accountId
        )
    }

    static func toProviderMessage(_ info: MessageInfo) -> ProviderMessage {
        let ref = info.uid.map { "uid:\($0.value)" } ?? "seq:\(info.sequenceNumber.value)"
        return ProviderMessage(
            ref: ref,
            messageId: info.messageId?.description,
            threadId: info.references?.first?.description ?? info.messageId?.description,
            senderName: nil,
            senderEmail: info.from ?? "",
            recipients: info.to,
            cc: info.cc,
            subject: info.subject,
            date: info.date ?? info.internalDate ?? Date(),
            isRead: info.flags.contains(.seen),
            isStarred: info.flags.contains(.flagged),
            hasAttachments: !info.parts.filter { $0.disposition == "attachment" }.isEmpty,
            referencesHeader: info.references?.map(\.description).joined(separator: " "),
            inReplyTo: info.inReplyTo?.description
        )
    }

    private static func parseUidRef(_ ref: String) -> UID {
        let parts = ref.split(separator: ":")
        if parts.count == 2, parts[0] == "uid", let val = UInt32(parts[1]) {
            return UID(val)
        }
        return UID(1) // fallback
    }

    /// Parse extended ref format "folder:<name>:uid:<N>" used when folder context is needed.
    /// Falls back to plain "uid:<N>" for backward compatibility.
    private static func parseFolderAndUidRef(_ ref: String) -> (folder: String?, uid: UID) {
        if ref.hasPrefix("folder:"), let uidRange = ref.range(of: ":uid:") {
            let folderStart = ref.index(ref.startIndex, offsetBy: "folder:".count)
            let folder = String(ref[folderStart..<uidRange.lowerBound])
            let uidStr = String(ref[uidRange.upperBound...])
            if let val = UInt32(uidStr) {
                return (folder: folder, uid: UID(val))
            }
        }
        return (folder: nil, uid: parseUidRef(ref))
    }

    private static func detectRole(_ name: String) -> FolderRole? {
        switch name {
        case "INBOX": return .inbox
        case "[Gmail]/Sent Mail", "Sent": return .sent
        case "[Gmail]/Drafts", "Drafts": return .drafts
        case "[Gmail]/Trash", "Trash": return .trash
        case "[Gmail]/Starred": return .starred
        case "[Gmail]/All Mail": return .all
        case "[Gmail]/Spam", "Spam", "Junk": return .spam
        default:
            if name.hasPrefix("[Gmail]/Category/") { return .category }
            return nil
        }
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
            // Gmail categories: strip "[Gmail]/Category/" prefix
            if folder.hasPrefix("[Gmail]/Category/") {
                return String(folder.dropFirst("[Gmail]/Category/".count))
            }
            // Decode Modified UTF-7, then show only the leaf label name.
            // "Cá nhân/ACE" → "ACE" (the parent "Cá nhân" is a separate folder entry)
            let decoded = decodeModifiedUTF7(folder)
            return decoded.split(separator: "/").last.map(String.init) ?? decoded
        }
    }

    /// Decodes IMAP Modified UTF-7 folder names (RFC 3501 §5.1.3).
    /// Non-ASCII characters are encoded as &<base64>- sequences.
    /// E.g. "Ca&AwE- nh&AOI-n/ACE" → "Các nhãn/ACE"
    private static func decodeModifiedUTF7(_ input: String) -> String {
        var result = ""
        var i = input.startIndex
        while i < input.endIndex {
            if input[i] == "&" {
                let start = input.index(after: i)
                if let end = input[start...].firstIndex(of: "-") {
                    let encoded = String(input[start..<end])
                    if encoded.isEmpty {
                        result += "&"  // "&-" is the escape for literal "&"
                    } else {
                        // Modified UTF-7: uses "," instead of "/" in base64
                        let base64 = encoded.replacingOccurrences(of: ",", with: "/")
                        // Base64 must be padded to a multiple of 4
                        let padded = base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)
                        if let data = Data(base64Encoded: padded),
                           let decoded = String(data: data, encoding: .utf16BigEndian) {
                            result += decoded
                        } else {
                            result += "&\(encoded)-"  // fallback: keep original
                        }
                    }
                    i = input.index(after: end)
                    continue
                }
            }
            result.append(input[i])
            i = input.index(after: i)
        }
        return result
    }
}

/// Thread-safe once-flag used to ensure a CheckedContinuation is resumed exactly once.
private final class SMTPOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<Void, Error>, with result: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(with: result)
    }
}

enum IMAPProviderError: Error, LocalizedError {
    case notConnected
    case messageNotFound
    case noCredentials
    case authFailed(String)
    case smtpTimeout

    var errorDescription: String? {
        switch self {
        case .notConnected: return "IMAP not connected."
        case .messageNotFound: return "Message not found."
        case .noCredentials: return "No credentials found. Please re-add the account."
        case .authFailed(let detail): return "Authentication failed: \(detail)"
        case .smtpTimeout: return "Send timed out after 30 seconds. Check your SMTP server settings (host, port, credentials)."
        }
    }
}
