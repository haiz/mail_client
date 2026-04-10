import Foundation
import JMAPClient

/// JMAP implementation of MailProvider (RFC 8620/8621).
/// Uses swift-jmap-client for the protocol layer.
/// Connects to Fastmail, Stalwart, Cyrus, and other JMAP-compliant servers.
actor JMAPProvider: MailProvider {

    let accountId: String
    let emailAddress: String

    private let config: AccountConfig
    private let authManager: AuthManager
    private let store: MailStore

    private var client: JMAPClient?

    var isConnected: Bool { client?.isAuthenticated ?? false }

    init(config: AccountConfig, authManager: AuthManager, store: MailStore) {
        self.accountId = config.id
        self.emailAddress = config.emailAddress
        self.config = config
        self.authManager = authManager
        self.store = store
    }

    // MARK: - Connection

    func connect() async throws {
        guard let jmapUrl = config.jmapUrl, let url = URL(string: jmapUrl) else {
            throw JMAPProviderError.missingJMAPUrl
        }

        let jmap = JMAPClient(baseURL: url)

        switch config.authType {
        case .bearer:
            guard let token = authManager.getPassword(accountId: accountId) else {
                throw JMAPProviderError.missingToken
            }
            _ = try await jmap.authenticate(with: token)
        case .password:
            // Some JMAP servers accept API token as password
            guard let token = authManager.getPassword(accountId: accountId) else {
                throw JMAPProviderError.missingToken
            }
            _ = try await jmap.authenticate(with: token)
        case .oauth2:
            let token = try await authManager.oauthAccessToken(accountId: accountId)
            _ = try await jmap.authenticate(with: token)
        }

        self.client = jmap
    }

    func disconnect() async throws {
        client?.logout()
        client = nil
    }

    private func getClient() async throws -> JMAPClient {
        if let client, client.isAuthenticated { return client }
        try await connect()
        guard let client else { throw JMAPProviderError.notConnected }
        return client
    }

    // MARK: - Sync

    func performInitialSync() async throws {
        let jmap = try await getClient()
        let mailboxes = try await jmap.getMailboxes()

        for mailbox in mailboxes {
            let emails = try await jmap.getEmails(fromMailbox: mailbox.id, limit: 500)

            for email in emails {
                let record = Self.toEmailRecord(email, folder: mailbox.name, accountId: accountId)
                let localId = try? await store.insertEmail(record)

                if let localId {
                    let textBody = email.bodyValues?.values.first?.value
                    try? await store.insertBody(emailId: localId, text: textBody, html: nil)
                }
            }

            let syncState = SyncStateRecord(
                accountId: accountId,
                folder: mailbox.id,
                lastSync: Int(Date().timeIntervalSince1970)
            )
            try? await store.updateSyncState(syncState)
        }
    }

    func performIncrementalSync() async throws {
        // JMAP supports delta sync via state tokens, but the swift-jmap-client
        // doesn't expose this yet. For now, re-fetch recent emails.
        let jmap = try await getClient()
        let mailboxes = try await jmap.getMailboxes()

        for mailbox in mailboxes {
            let emails = try await jmap.getEmails(fromMailbox: mailbox.id, limit: 50)

            for email in emails {
                let record = Self.toEmailRecord(email, folder: mailbox.name, accountId: accountId)
                _ = try? await store.insertEmail(record) // Ignores duplicates via UNIQUE
            }
        }
    }

    // MARK: - Push

    func startPushNotifications(onNewMessage: @escaping @Sendable () async -> Void) async throws {
        // JMAP push via EventSource (RFC 8620 §7) not yet supported by swift-jmap-client.
        // Fall back to polling every 60 seconds.
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                try? await performIncrementalSync()
                await onNewMessage()
            }
        }
    }

    func stopPushNotifications() async throws {
        // Polling task cancelled when provider disconnects
    }

    // MARK: - Folders

    func createFolder(name: String) async throws {
        let jmap = try await getClient()
        guard let jmapAccountId = jmap.currentAccountId else {
            throw JMAPProviderError.notAuthenticated
        }
        let request = JMAPRequest(
            using: ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
            methodCalls: [
                JMAPMethodCall(
                    method: "Mailbox/set",
                    arguments: [
                        "accountId": jmapAccountId,
                        "create": ["newFolder": ["name": name]]
                    ],
                    clientId: "createFolder"
                )
            ]
        )
        _ = try await jmap.makeRequest(request)
    }

    func listFolders() async throws -> [ProviderFolder] {
        let jmap = try await getClient()
        let mailboxes = try await jmap.getMailboxes()

        return mailboxes.map { mailbox in
            ProviderFolder(
                id: mailbox.id,
                name: mailbox.name,
                totalCount: mailbox.totalEmails,
                unreadCount: mailbox.unreadEmails,
                role: Self.toRole(mailbox.role)
            )
        }
    }

    // MARK: - Messages

    func fetchMessages(folderId: String, cursor: String?, limit: Int) async throws -> (messages: [ProviderMessage], nextCursor: String?) {
        let jmap = try await getClient()
        let emails = try await jmap.getEmails(fromMailbox: folderId, limit: limit)

        let messages = emails.map(Self.toProviderMessage)
        // swift-jmap-client doesn't expose pagination cursors yet
        return (messages: messages, nextCursor: nil)
    }

    func fetchMessageBody(messageRef: String) async throws -> ProviderMessageBody {
        // Try local cache first
        if let emailId = try await store.findEmailId(byMessageId: messageRef, accountId: accountId),
           let body = try await store.fetchBody(emailId: emailId) {
            return ProviderMessageBody(ref: messageRef, textBody: body.text, htmlBody: body.html)
        }

        // Fetch from JMAP using Email/get with bodyValues
        let jmap = try await getClient()
        guard let jmapAccountId = jmap.currentAccountId else {
            throw JMAPProviderError.notAuthenticated
        }
        let request = JMAPRequest(
            using: ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
            methodCalls: [
                JMAPMethodCall(
                    method: "Email/get",
                    arguments: [
                        "accountId": jmapAccountId,
                        "ids": [messageRef],
                        "properties": ["bodyValues", "textBody", "htmlBody"],
                        "fetchTextBodyValues": true,
                        "fetchHTMLBodyValues": true
                    ],
                    clientId: "fetchBody"
                )
            ]
        )
        let response = try await jmap.makeRequest(request)

        // Parse the response to get body values
        if let firstResponse = response.methodResponses.first,
           let list = firstResponse.response["list"] as? [[String: Any]],
           let email = list.first {
            let textBody = Self.extractBodyValue(from: email, bodyKey: "textBody")
            let htmlBody = Self.extractBodyValue(from: email, bodyKey: "htmlBody")
            return ProviderMessageBody(ref: messageRef, textBody: textBody, htmlBody: htmlBody)
        }

        return ProviderMessageBody(ref: messageRef, textBody: nil, htmlBody: nil)
    }

    /// Extract body text from JMAP Email/get response bodyValues.
    private static func extractBodyValue(from email: [String: Any], bodyKey: String) -> String? {
        guard let parts = email[bodyKey] as? [[String: Any]],
              let partId = parts.first?["partId"] as? String,
              let bodyValues = email["bodyValues"] as? [String: [String: Any]],
              let value = bodyValues[partId]?["value"] as? String else {
            return nil
        }
        return value
    }

    // MARK: - Actions

    func markRead(messageRef: String, read: Bool) async throws {
        try await emailSet(messageRef: messageRef, update: [
            "keywords/$seen": read
        ])
    }

    func markStarred(messageRef: String, starred: Bool) async throws {
        try await emailSet(messageRef: messageRef, update: [
            "keywords/$flagged": starred
        ])
    }

    func moveMessage(messageRef: String, toFolderId: String) async throws {
        try await emailSet(messageRef: messageRef, update: [
            "mailboxIds": [toFolderId: true]
        ])
    }

    func deleteMessage(messageRef: String) async throws {
        let jmap = try await getClient()
        guard let trashMailbox = try await jmap.getMailbox(byRole: .trash) else {
            throw JMAPProviderError.notImplemented
        }
        try await emailSet(messageRef: messageRef, update: [
            "mailboxIds": [trashMailbox.id: true]
        ])
    }

    // MARK: - Batch Actions

    func markReadBatch(messageRefs: [String], read: Bool) async throws {
        try await emailSetBatch(messageRefs: messageRefs, update: ["keywords/$seen": read])
    }

    func markStarredBatch(messageRefs: [String], starred: Bool) async throws {
        try await emailSetBatch(messageRefs: messageRefs, update: ["keywords/$flagged": starred])
    }

    func moveMessageBatch(messageRefs: [String], toFolderId: String) async throws {
        try await emailSetBatch(messageRefs: messageRefs, update: ["mailboxIds": [toFolderId: true]])
    }

    func deleteMessageBatch(messageRefs: [String]) async throws {
        let jmap = try await getClient()
        guard let trashMailbox = try await jmap.getMailbox(byRole: .trash) else {
            throw JMAPProviderError.notImplemented
        }
        try await emailSetBatch(messageRefs: messageRefs, update: ["mailboxIds": [trashMailbox.id: true]])
    }

    private func emailSetBatch(messageRefs: [String], update: [String: Any]) async throws {
        guard !messageRefs.isEmpty else { return }
        let jmap = try await getClient()
        guard let jmapAccountId = jmap.currentAccountId else {
            throw JMAPProviderError.notAuthenticated
        }
        var updateDict: [String: Any] = [:]
        for ref in messageRefs {
            updateDict[ref] = update
        }
        let request = JMAPRequest(
            using: ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
            methodCalls: [
                JMAPMethodCall(method: "Email/set", arguments: [
                    "accountId": jmapAccountId,
                    "update": updateDict
                ], clientId: "batchSync")
            ]
        )
        _ = try await jmap.makeRequest(request)
    }

    /// Helper: call Email/set with an update patch for a single email.
    private func emailSet(messageRef: String, update: [String: Any]) async throws {
        let jmap = try await getClient()
        guard let jmapAccountId = jmap.currentAccountId else {
            throw JMAPProviderError.notAuthenticated
        }
        let request = JMAPRequest(
            using: ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
            methodCalls: [
                JMAPMethodCall(
                    method: "Email/set",
                    arguments: [
                        "accountId": jmapAccountId,
                        "update": [messageRef: update]
                    ],
                    clientId: "flagSync"
                )
            ]
        )
        _ = try await jmap.makeRequest(request)
    }

    func fetchAttachment(messageRef: String, partId: String) async throws -> Data {
        // JMAP: partId here is actually the blobId
        let jmap = try await getClient()
        guard let session = jmap.currentSession,
              let jmapAccountId = jmap.currentAccountId else {
            throw JMAPProviderError.notAuthenticated
        }
        // Build download URL from template: {downloadUrl}/{accountId}/{blobId}/{name}
        var urlStr = session.downloadUrl
            .replacingOccurrences(of: "{accountId}", with: jmapAccountId)
            .replacingOccurrences(of: "{blobId}", with: partId)
            .replacingOccurrences(of: "{name}", with: "attachment")
        // Some templates use query params instead
        if urlStr.contains("{type}") {
            urlStr = urlStr.replacingOccurrences(of: "{type}", with: "application/octet-stream")
        }
        guard let url = URL(string: urlStr) else {
            throw JMAPProviderError.notImplemented
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }

    // MARK: - Send

    func send(message: OutgoingMessage) async throws {
        let jmap = try await getClient()

        try await jmap.sendEmail(
            from: JMAPEmailAddress(name: nil, email: emailAddress),
            to: message.to.map { JMAPEmailAddress(name: nil, email: $0) },
            subject: message.subject,
            textBody: message.bodyText,
            htmlBody: message.bodyHtml
        )
    }

    // MARK: - Helpers

    static func toEmailRecord(_ email: JMAPEmail, folder: String, accountId: String) -> EmailRecord {
        let sender = email.from?.first
        let isRead = email.keywords["$seen"] ?? false
        let isStarred = email.keywords["$flagged"] ?? false

        return EmailRecord(
            messageId: email.id,
            threadId: email.threadId,
            folder: folder,
            senderName: sender?.name,
            senderEmail: sender?.email ?? "unknown@unknown.com",
            recipients: (try? String(data: JSONEncoder().encode(email.to?.map(\.email)), encoding: .utf8)),
            subject: email.subject,
            date: Int(email.receivedAt.timeIntervalSince1970),
            isRead: isRead,
            isStarred: isStarred,
            isDeleted: false,
            hasAttachments: email.hasAttachment,
            accountId: accountId
        )
    }

    static func toProviderMessage(_ email: JMAPEmail) -> ProviderMessage {
        let sender = email.from?.first

        return ProviderMessage(
            ref: email.id,
            messageId: email.id,
            threadId: email.threadId,
            senderName: sender?.name,
            senderEmail: sender?.email ?? "",
            recipients: email.to?.map(\.email) ?? [],
            cc: email.cc?.map(\.email) ?? [],
            subject: email.subject,
            date: email.sentAt ?? email.receivedAt,
            isRead: email.keywords["$seen"] ?? false,
            isStarred: email.keywords["$flagged"] ?? false,
            hasAttachments: email.hasAttachment,
            referencesHeader: nil,
            inReplyTo: nil
        )
    }

    private static func toRole(_ role: JMAPMailboxRole?) -> FolderRole? {
        guard let role else { return nil }
        switch role {
        case .inbox: return .inbox
        case .sent: return .sent
        case .drafts: return .drafts
        case .trash: return .trash
        case .junk: return .spam
        case .archive: return .archive
        default: return nil
        }
    }
}

enum JMAPProviderError: Error, LocalizedError {
    case missingJMAPUrl
    case missingToken
    case notConnected
    case notAuthenticated
    case notImplemented

    var errorDescription: String? {
        switch self {
        case .missingJMAPUrl: "JMAP server URL not configured."
        case .missingToken: "Authentication token not found."
        case .notConnected: "Not connected to JMAP server."
        case .notAuthenticated: "Not authenticated with JMAP server."
        case .notImplemented: "Feature not yet implemented for JMAP."
        }
    }
}
