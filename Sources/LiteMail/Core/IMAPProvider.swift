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
    private var smtpServer: SMTPServer?
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
            try await server.authenticateXOAUTH2(email: emailAddress, accessToken: token)
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
        if let server = smtpServer {
            try? await server.disconnect()
            smtpServer = nil
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
        let imap = try await getIMAP()
        let folders = try await listFolders()

        for folder in folders where !Self.isSkippedFolder(folder.id) {
            try await syncFolder(imap: imap, folderId: folder.id)
        }
    }

    func performIncrementalSync() async throws {
        let imap = try await getIMAP()
        let folders = try await listFolders()

        for folder in folders where !Self.isSkippedFolder(folder.id) {
            try await incrementalSyncFolder(imap: imap, folderId: folder.id)
        }
    }

    /// Returns true for Gmail virtual folders that duplicate emails found in real folders.
    /// Syncing them would store the same messages twice under different folder names.
    private static func isSkippedFolder(_ folderId: String) -> Bool {
        let skipped: Set<String> = [
            "[Gmail]/All Mail",
            "[Gmail]/Important",
            "[Gmail]/Starred",   // also appears in INBOX with \Flagged
        ]
        return skipped.contains(folderId)
    }

    private func syncFolder(imap: IMAPServer, folderId: String) async throws {
        let selection = try await imap.selectMailbox(folderId)
        let messageCount = selection.messageCount
        guard messageCount > 0 else { return }

        let startSeq = UInt32(max(1, messageCount - 4999))
        let range = SequenceNumber(startSeq)...SequenceNumber(UInt32(messageCount))
        let headers = try await imap.fetchMessageInfos(sequenceRange: range)

        for info in headers {
            let record = Self.toEmailRecord(info, folder: folderId, accountId: accountId)
            _ = try? await store.insertEmail(record)
        }

        // Bodies are fetched on-demand when the user opens a message (fetchMessageBody).
        // Pre-fetching here is skipped: sequence-range fetches don't include UIDs,
        // causing FetchStructureCommand<UID> to fail on Gmail.

        let lastUid: Int? = headers.last?.uid.map { Int($0.value) }
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
            _ = try? await store.insertEmail(record)
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
        let uid = Self.parseUidRef(messageRef)

        guard let info = try await imap.fetchMessageInfo(for: uid) else {
            throw IMAPProviderError.messageNotFound
        }

        let message = try await imap.fetchMessage(from: info)
        return ProviderMessageBody(ref: messageRef, textBody: message.textBody, htmlBody: message.htmlBody)
    }

    // MARK: - Actions

    func markRead(messageRef: String, read: Bool) async throws {
        // Store-level action (IMAP flag sync deferred)
    }

    func markStarred(messageRef: String, starred: Bool) async throws {
        // Store-level action
    }

    func moveMessage(messageRef: String, toFolderId: String) async throws {
        // Store-level action
    }

    func deleteMessage(messageRef: String) async throws {
        // Store-level action (IMAP flag + expunge)
    }

    func fetchAttachment(messageRef: String, partId: String) async throws -> Data {
        let imap = try await getIMAP()
        let uid = Self.parseUidRef(messageRef)
        let section = Section(partId)
        return try await imap.fetchPart(section: section, of: uid)
    }

    // MARK: - Send

    func send(message: OutgoingMessage) async throws {
        let host = config.smtpHost ?? "smtp.gmail.com"
        let port = config.smtpPort ?? 465

        if smtpServer == nil {
            let server = SMTPServer(host: host, port: port)
            try await server.connect()

            switch config.authType {
            case .oauth2:
                let token = try await authManager.oauthAccessToken(accountId: accountId)
                try await server.authenticateXOAUTH2(email: emailAddress, accessToken: token)
            case .password:
                let password = authManager.getPassword(accountId: accountId) ?? ""
                try await server.login(username: loginUsername, password: password)
            case .bearer:
                break
            }
            smtpServer = server
        }

        let email = Email(
            senderName: nil,
            senderAddress: emailAddress,
            recipientNames: nil,
            recipientAddresses: message.to,
            subject: message.subject,
            textBody: message.bodyText
        )
        try await smtpServer?.sendEmail(email)
    }

    // MARK: - Helpers

    private func fetchAndStoreBody(imap: IMAPServer, info: MessageInfo) async {
        do {
            let message = try await imap.fetchMessage(from: info)
            if let messageIdStr = info.messageId?.description,
               let id = try await store.findEmailId(byMessageId: messageIdStr) {
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

    private static func detectRole(_ name: String) -> FolderRole? {
        switch name {
        case "INBOX": return .inbox
        case "[Gmail]/Sent Mail", "Sent": return .sent
        case "[Gmail]/Drafts", "Drafts": return .drafts
        case "[Gmail]/Trash", "Trash": return .trash
        case "[Gmail]/Starred": return .starred
        case "[Gmail]/All Mail": return .all
        case "[Gmail]/Spam", "Spam", "Junk": return .spam
        default: return nil
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
        default: return folder
        }
    }
}

enum IMAPProviderError: Error {
    case notConnected
    case messageNotFound
    case noCredentials
}
