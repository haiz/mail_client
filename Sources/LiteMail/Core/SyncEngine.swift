import Foundation
import SwiftMail

/// Actor responsible for IMAP synchronization.
/// Handles initial sync, incremental sync, body backfill, and IDLE monitoring.
actor SyncEngine {

    private let transport: MailTransport
    private let store: MailStore

    /// Folders to sync. Gmail core folders.
    private let syncFolders = ["INBOX", "[Gmail]/Sent Mail", "[Gmail]/Drafts", "[Gmail]/Trash", "[Gmail]/Starred"]

    init(transport: MailTransport, store: MailStore) {
        self.transport = transport
        self.store = store
    }

    // MARK: - Initial Sync

    /// Performs initial sync: fetches all headers, plus bodies for the latest N messages.
    func performInitialSync(recentBodyCount: Int = 500) async throws {
        let imap = try await transport.connectIMAP()

        for folder in syncFolders {
            try await syncFolder(imap: imap, folder: folder, recentBodyCount: recentBodyCount)
        }
    }

    private func syncFolder(imap: IMAPServer, folder: String, recentBodyCount: Int) async throws {
        let selection = try await imap.selectMailbox(folder)
        let messageCount = Int(selection.messageCount)

        guard messageCount > 0 else { return }

        // Fetch all message headers via sequence number range
        let startSeq = UInt32(max(1, messageCount - 4999)) // Fetch up to 5000 most recent
        let range = SequenceNumber(startSeq)...SequenceNumber(UInt32(messageCount))
        let headers = try await imap.fetchMessageInfos(sequenceRange: range)

        // Store headers
        for info in headers {
            let record = Self.messageInfoToRecord(info, folder: folder)
            _ = try? await store.insertEmail(record)
        }

        // Fetch bodies for the most recent N messages
        let recentHeaders = headers.suffix(recentBodyCount)
        for info in recentHeaders {
            await fetchAndStoreBody(imap: imap, info: info)
        }

        // Update sync state
        let lastUid: Int? = headers.last?.uid.map { Int($0.value) }
        let syncState = SyncStateRecord(
            folder: folder,
            uidValidity: Int(selection.uidValidity.value),
            lastUid: lastUid,
            lastSync: Int(Date().timeIntervalSince1970)
        )
        try await store.updateSyncState(syncState)
    }

    // MARK: - Incremental Sync

    /// Fetches new messages since last sync.
    func performIncrementalSync() async throws {
        let imap = try await transport.connectIMAP()

        for folder in syncFolders {
            try await incrementalSyncFolder(imap: imap, folder: folder)
        }
    }

    private func incrementalSyncFolder(imap: IMAPServer, folder: String) async throws {
        guard let syncState = try await store.getSyncState(folder: folder),
              let lastUid = syncState.lastUid else {
            // No prior sync state — do a full sync of this folder
            try await syncFolder(imap: imap, folder: folder, recentBodyCount: 100)
            return
        }

        let selection = try await imap.selectMailbox(folder)

        // Check UID validity — if changed, we need a full resync
        if let storedValidity = syncState.uidValidity,
           storedValidity != Int(selection.uidValidity.value) {
            // UID validity changed — full resync needed
            try await syncFolder(imap: imap, folder: folder, recentBodyCount: 100)
            return
        }

        // Fetch messages with UID > lastUid
        let startUid = UID(UInt32(lastUid + 1))
        let newHeaders: [MessageInfo]
        do {
            newHeaders = try await imap.fetchMessageInfos(uidRange: startUid...)
        } catch {
            // No new messages or range error
            return
        }

        guard !newHeaders.isEmpty else { return }

        for info in newHeaders {
            let record = Self.messageInfoToRecord(info, folder: folder)
            _ = try? await store.insertEmail(record)
            // Fetch body for new messages immediately
            await fetchAndStoreBody(imap: imap, info: info)
        }

        // Update sync state
        let newLastUid: Int = newHeaders.last?.uid.map { Int($0.value) } ?? lastUid
        let updatedState = SyncStateRecord(
            folder: folder,
            uidValidity: syncState.uidValidity,
            lastUid: newLastUid,
            lastSync: Int(Date().timeIntervalSince1970)
        )
        try await store.updateSyncState(updatedState)
    }

    // MARK: - Body Backfill

    /// Background task that progressively downloads bodies for older emails.
    /// Call this during idle time to build up the FTS5 search index.
    func performBodyBackfill(batchSize: Int = 50) async throws {
        let imap = try await transport.connectIMAP()

        // Find emails without bodies in the store
        let emailsWithoutBodies = try await store.fetchEmailsWithoutBodies(limit: batchSize)

        guard !emailsWithoutBodies.isEmpty else { return }

        // Group by folder for efficient IMAP access
        let byFolder = Dictionary(grouping: emailsWithoutBodies, by: \.folder)

        for (folder, records) in byFolder {
            _ = try await imap.selectMailbox(folder)

            for record in records {
                guard let uid = record.uid else { continue }
                let imapUid = UID(UInt32(uid))

                if let info = try await imap.fetchMessageInfo(for: imapUid) {
                    await fetchAndStoreBody(imap: imap, info: info, emailId: record.id)
                }
            }
        }
    }

    // MARK: - IDLE

    /// Starts IMAP IDLE on INBOX for real-time push notifications.
    /// Returns an AsyncStream of new message events.
    func startIdleWatch(onNewMessage: @escaping @Sendable () async -> Void) async throws {
        let imap = try await transport.connectIMAP()
        let session = try await imap.idle(on: "INBOX")

        Task {
            for await event in session.events {
                switch event {
                case .exists:
                    await onNewMessage()
                default:
                    break
                }
            }
        }
    }

    // MARK: - Helpers

    private func fetchAndStoreBody(imap: IMAPServer, info: MessageInfo, emailId: Int64? = nil) async {
        do {
            let message = try await imap.fetchMessage(from: info)
            let textBody = message.textBody
            let htmlBody = message.htmlBody

            if let emailId {
                try await store.insertBody(emailId: emailId, text: textBody, html: htmlBody)
            } else if let messageIdStr = info.messageId?.description {
                // Look up by message_id
                if let id = try await store.findEmailId(byMessageId: messageIdStr) {
                    try await store.insertBody(emailId: id, text: textBody, html: htmlBody)
                }
            }
        } catch {
            // Log but don't crash — body fetch failures are non-fatal
        }
    }

    /// Converts SwiftMail MessageInfo to our EmailRecord.
    /// Uses References/In-Reply-To for thread grouping (no Gmail X-GM-THRID).
    static func messageInfoToRecord(_ info: MessageInfo, folder: String) -> EmailRecord {
        let referencesStr = info.references?.map(\.description).joined(separator: " ")
        let inReplyToStr = info.inReplyTo?.description

        // Thread ID: use first reference (root message) or message-id itself
        let threadId = info.references?.first?.description ?? info.messageId?.description

        let flags = info.flags
        let isRead = flags.contains(.seen)
        let isStarred = flags.contains(.flagged)
        let isDeleted = flags.contains(.deleted)

        return EmailRecord(
            messageId: info.messageId?.description ?? UUID().uuidString,
            threadId: threadId,
            folder: folder,
            senderName: nil, // SwiftMail 'from' is a combined string
            senderEmail: info.from ?? "unknown@unknown.com",
            recipients: encodeRecipients(to: info.to, cc: info.cc),
            subject: info.subject,
            date: Int(info.date?.timeIntervalSince1970 ?? info.internalDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970),
            isRead: isRead,
            isStarred: isStarred,
            isDeleted: isDeleted,
            hasAttachments: !info.parts.filter { $0.disposition == "attachment" }.isEmpty,
            uid: info.uid.map { Int($0.value) },
            flags: flags.map(\.description).joined(separator: ","),
            referencesHeader: referencesStr,
            inReplyTo: inReplyToStr
        )
    }

    private static func encodeRecipients(to: [String], cc: [String]) -> String? {
        let all = to + cc
        guard !all.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(all) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
