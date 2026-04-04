import Foundation
import GRDB

/// Actor that owns all SQLite/GRDB access. Serial access prevents write conflicts.
/// Uses WAL mode for concurrent reads during sync (file-based DBs only).
actor MailStore {
    private let dbPool: any DatabaseWriter & DatabaseReader

    init(path: String) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA cache_size = -2000")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            if path != ":memory:" {
                try db.execute(sql: "PRAGMA journal_mode = WAL")
            }
        }
        if path == ":memory:" {
            dbPool = try DatabaseQueue(path: path, configuration: config)
        } else {
            dbPool = try DatabasePool(path: path, configuration: config)
        }
        try migrate()
    }

    // MARK: - Migrations

    private nonisolated func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "emails") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("message_id", .text).notNull().unique()
                t.column("thread_id", .text)
                t.column("folder", .text).notNull().defaults(to: "INBOX")
                t.column("sender_name", .text)
                t.column("sender_email", .text).notNull()
                t.column("recipients", .text)
                t.column("subject", .text)
                t.column("date", .integer).notNull()
                t.column("is_read", .integer).notNull().defaults(to: 0)
                t.column("is_starred", .integer).notNull().defaults(to: 0)
                t.column("is_deleted", .integer).notNull().defaults(to: 0)
                t.column("has_attachments", .integer).notNull().defaults(to: 0)
                t.column("uid", .integer)
                t.column("flags", .text)
                t.column("references_header", .text)
                t.column("in_reply_to", .text)
                t.column("created_at", .integer)
            }
            try db.create(index: "idx_emails_thread", on: "emails", columns: ["thread_id"])
            try db.create(index: "idx_emails_folder", on: "emails", columns: ["folder"])
            try db.create(index: "idx_emails_date", on: "emails", columns: ["date"])
            try db.create(index: "idx_emails_sender", on: "emails", columns: ["sender_email"])

            try db.create(table: "email_bodies") { t in
                t.primaryKey("email_id", .integer).references("emails", onDelete: .cascade)
                t.column("body_text", .text)
                t.column("body_html", .text)
            }

            try db.execute(sql: """
                CREATE VIRTUAL TABLE email_fts USING fts5(
                    subject, body_text, sender_name, sender_email,
                    tokenize='unicode61'
                )
            """)

            try db.create(table: "labels") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("email_id", .integer).notNull().references("emails", onDelete: .cascade)
                t.column("label", .text).notNull()
            }
            try db.create(index: "idx_labels_email", on: "labels", columns: ["email_id"])
            try db.create(index: "idx_labels_label", on: "labels", columns: ["label"])

            try db.create(table: "attachments") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("email_id", .integer).notNull().references("emails", onDelete: .cascade)
                t.column("filename", .text)
                t.column("mime_type", .text)
                t.column("size_bytes", .integer)
                t.column("content_id", .text)
                t.column("cache_path", .text)
            }

            try db.create(table: "outbox") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("to_recipients", .text).notNull()
                t.column("cc_recipients", .text)
                t.column("bcc_recipients", .text)
                t.column("subject", .text)
                t.column("body_text", .text)
                t.column("body_html", .text)
                t.column("in_reply_to", .text)
                t.column("created_at", .integer)
                t.column("status", .text).notNull().defaults(to: "queued")
            }

            try db.create(table: "sync_state") { t in
                t.primaryKey("folder", .text)
                t.column("uid_validity", .integer)
                t.column("last_uid", .integer)
                t.column("last_sync", .integer)
            }
        }

        // v2: Multi-account support
        migrator.registerMigration("v2_multi_account") { db in
            // Accounts table
            try db.create(table: "accounts") { t in
                t.column("id", .text).primaryKey()
                t.column("email_address", .text).notNull().unique()
                t.column("display_name", .text)
                t.column("protocol_type", .text).notNull().defaults(to: "imap")
                t.column("imap_host", .text)
                t.column("imap_port", .integer).defaults(to: 993)
                t.column("smtp_host", .text)
                t.column("smtp_port", .integer).defaults(to: 465)
                t.column("jmap_url", .text)
                t.column("auth_type", .text).notNull().defaults(to: "oauth2")
                t.column("keychain_ref", .text).notNull()
                t.column("is_default", .integer).defaults(to: 0)
                t.column("created_at", .integer)
            }

            // Add account_id to emails
            try db.alter(table: "emails") { t in
                t.add(column: "account_id", .text).defaults(to: "default")
            }
            try db.create(index: "idx_emails_account", on: "emails", columns: ["account_id"])
            try db.create(index: "idx_emails_account_folder", on: "emails", columns: ["account_id", "folder"])

            // Add account_id to sync_state — need to recreate since it's the primary key
            try db.rename(table: "sync_state", to: "sync_state_old")
            try db.create(table: "sync_state") { t in
                t.column("account_id", .text).notNull().defaults(to: "default")
                t.column("folder", .text).notNull()
                t.column("uid_validity", .integer)
                t.column("last_uid", .integer)
                t.column("last_sync", .integer)
                t.primaryKey(["account_id", "folder"])
            }
            try db.execute(sql: """
                INSERT INTO sync_state (account_id, folder, uid_validity, last_uid, last_sync)
                SELECT 'default', folder, uid_validity, last_uid, last_sync FROM sync_state_old
            """)
            try db.drop(table: "sync_state_old")

            // Add account_id to outbox
            try db.alter(table: "outbox") { t in
                t.add(column: "account_id", .text).defaults(to: "default")
            }
        }

        // v3: IMAP username field (when different from email)
        migrator.registerMigration("v3_imap_username") { db in
            try db.alter(table: "accounts") { t in
                t.add(column: "imap_username", .text)
            }
        }

        // v4: Google Contacts cache
        migrator.registerMigration("v4_contacts") { db in
            try db.create(table: "contacts") { t in
                t.column("id", .text).notNull()
                t.column("account_id", .text).notNull().references("accounts", onDelete: .cascade)
                t.column("name", .text)
                t.column("email", .text).notNull()
                t.column("photo_url", .text)
                t.column("synced_at", .integer).notNull()
                t.primaryKey(["account_id", "email"])
            }
            try db.create(index: "idx_contacts_account_email", on: "contacts", columns: ["account_id", "email"])
        }

        try migrator.migrate(dbPool)
    }

    // MARK: - Account CRUD

    func insertAccount(_ record: AccountRecord) throws {
        try dbPool.write { db in
            try record.insert(db)
        }
    }

    func listAccounts() throws -> [AccountRecord] {
        try dbPool.read { db in
            try AccountRecord.order(Column("is_default").desc, Column("email_address").asc).fetchAll(db)
        }
    }

    func getAccount(id: String) throws -> AccountRecord? {
        try dbPool.read { db in
            try AccountRecord.fetchOne(db, key: id)
        }
    }

    func deleteAccount(id: String) throws {
        try dbPool.write { db in
            // Delete emails (cascade handles bodies, labels, attachments)
            try db.execute(sql: "DELETE FROM emails WHERE account_id = ?", arguments: [id])
            // Delete sync state
            try db.execute(sql: "DELETE FROM sync_state WHERE account_id = ?", arguments: [id])
            // Delete outbox
            try db.execute(sql: "DELETE FROM outbox WHERE account_id = ?", arguments: [id])
            // Delete contacts
            try db.execute(sql: "DELETE FROM contacts WHERE account_id = ?", arguments: [id])
            // Delete account
            try db.execute(sql: "DELETE FROM accounts WHERE id = ?", arguments: [id])
            // Rebuild FTS (some entries may reference deleted emails)
            try db.execute(sql: "INSERT INTO email_fts(email_fts) VALUES('rebuild')")
        }
    }

    // MARK: - Email CRUD

    func insertEmail(_ record: EmailRecord) throws -> Int64 {
        try dbPool.write { db in
            try record.insert(db)
            let emailId = db.lastInsertedRowID

            try db.execute(
                sql: """
                    INSERT INTO email_fts(rowid, subject, body_text, sender_name, sender_email)
                    VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [emailId, record.subject, nil, record.senderName, record.senderEmail]
            )

            return emailId
        }
    }

    func insertBody(emailId: Int64, text: String?, html: String?) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO email_bodies (email_id, body_text, body_html) VALUES (?, ?, ?)",
                arguments: [emailId, text, html]
            )

            try db.execute(sql: "DELETE FROM email_fts WHERE rowid = ?", arguments: [emailId])

            let row = try Row.fetchOne(db, sql: "SELECT subject, sender_name, sender_email FROM emails WHERE id = ?", arguments: [emailId])
            if let row {
                try db.execute(
                    sql: """
                        INSERT INTO email_fts(rowid, subject, body_text, sender_name, sender_email)
                        VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [emailId, row["subject"], text, row["sender_name"], row["sender_email"]]
                )
            }
        }
    }

    func fetchHeaders(accountId: String, folder: String, offset: Int, limit: Int) throws -> [EmailRecord] {
        try dbPool.read { db in
            try EmailRecord
                .filter(Column("account_id") == accountId && Column("folder") == folder && Column("is_deleted") == false)
                .order(Column("date").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    func fetchBody(emailId: Int64) throws -> (text: String?, html: String?)? {
        try dbPool.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT body_text, body_html FROM email_bodies WHERE email_id = ?", arguments: [emailId])
            guard let row else { return nil }
            return (text: row["body_text"], html: row["body_html"])
        }
    }

    func fetchThread(threadId: String) throws -> [EmailRecord] {
        try dbPool.read { db in
            try EmailRecord
                .filter(Column("thread_id") == threadId)
                .order(Column("date").asc)
                .fetchAll(db)
        }
    }

    // MARK: - Search

    func search(query: String, accountId: String? = nil) throws -> [EmailRecord] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        return try dbPool.read { db in
            let escapedQuery = query.replacingOccurrences(of: "\"", with: "\"\"")

            let rowids = try Int64.fetchAll(db, sql: """
                SELECT rowid FROM email_fts WHERE email_fts MATCH ? LIMIT 100
            """, arguments: ["\"\(escapedQuery)\""])

            guard !rowids.isEmpty else { return [] }

            var query = EmailRecord.filter(rowids.contains(Column("id")))
            if let accountId {
                query = query.filter(Column("account_id") == accountId)
            }
            return try query.order(Column("date").desc).fetchAll(db)
        }
    }

    func warmSearchCache() throws {
        _ = try dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT count(*) FROM email_fts WHERE email_fts MATCH '\"warmup\"'")
        }
    }

    // MARK: - Actions

    func markRead(emailId: Int64, read: Bool) throws {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE emails SET is_read = ? WHERE id = ?", arguments: [read ? 1 : 0, emailId])
        }
    }

    func markStarred(emailId: Int64, starred: Bool) throws {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE emails SET is_starred = ? WHERE id = ?", arguments: [starred ? 1 : 0, emailId])
        }
    }

    func markDeleted(emailId: Int64) throws {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE emails SET is_deleted = 1 WHERE id = ?", arguments: [emailId])
        }
    }

    func moveEmail(emailId: Int64, toFolder: String) throws {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE emails SET folder = ? WHERE id = ?", arguments: [toFolder, emailId])
        }
    }

    // MARK: - Folders

    func listFolders(accountId: String) throws -> [(folder: String, unreadCount: Int)] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT folder, COUNT(*) FILTER (WHERE is_read = 0) as unread_count
                FROM emails
                WHERE is_deleted = 0 AND account_id = ?
                GROUP BY folder
                ORDER BY folder
            """, arguments: [accountId])
            return rows.map { (folder: $0["folder"], unreadCount: $0["unread_count"]) }
        }
    }

    // MARK: - Sync State

    func getSyncState(accountId: String, folder: String) throws -> SyncStateRecord? {
        try dbPool.read { db in
            try SyncStateRecord.fetchOne(db, key: ["account_id": accountId, "folder": folder])
        }
    }

    func updateSyncState(_ record: SyncStateRecord) throws {
        try dbPool.write { db in
            try record.save(db)
        }
    }

    // MARK: - Outbox

    func queueOutgoing(_ message: OutboxRecord) throws -> Int64 {
        try dbPool.write { db in
            try message.insert(db)
            return db.lastInsertedRowID
        }
    }

    func fetchPendingOutbox() throws -> [OutboxRecord] {
        try dbPool.read { db in
            try OutboxRecord.filter(Column("status") == "queued").fetchAll(db)
        }
    }

    func updateOutboxStatus(id: Int64, status: String) throws {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE outbox SET status = ? WHERE id = ?", arguments: [status, id])
        }
    }

    // MARK: - Lookup

    func findEmailId(byMessageId messageId: String) throws -> Int64? {
        try dbPool.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT id FROM emails WHERE message_id = ?", arguments: [messageId])
            return row?["id"] as Int64?
        }
    }

    func fetchEmailsWithoutBodies(accountId: String, limit: Int) throws -> [EmailRecord] {
        try dbPool.read { db in
            try EmailRecord.fetchAll(db, sql: """
                SELECT e.* FROM emails e
                LEFT JOIN email_bodies b ON e.id = b.email_id
                WHERE b.email_id IS NULL AND e.is_deleted = 0 AND e.account_id = ?
                ORDER BY e.date DESC
                LIMIT ?
            """, arguments: [accountId, limit])
        }
    }

    // MARK: - Contacts

    func upsertContacts(_ contacts: [ContactRecord]) throws {
        try dbPool.write { db in
            for contact in contacts {
                try contact.save(db)
            }
        }
    }

    func lookupContacts(prefix: String, accountId: String, limit: Int = 20) throws -> [ContactRecord] {
        let lowPrefix = prefix.lowercased()
        let pattern = "\(lowPrefix)%"
        return try dbPool.read { db in
            if lowPrefix.isEmpty {
                return try ContactRecord
                    .filter(Column("account_id") == accountId)
                    .order(Column("name").asc)
                    .limit(limit)
                    .fetchAll(db)
            }
            return try ContactRecord.fetchAll(db, sql: """
                SELECT * FROM contacts
                WHERE account_id = ?
                  AND (lower(email) LIKE ? OR lower(name) LIKE ?)
                ORDER BY name ASC
                LIMIT \(limit)
            """, arguments: [accountId, pattern, pattern])
        }
    }

    // MARK: - Stats

    func emailCount(accountId: String? = nil) throws -> Int {
        try dbPool.read { db in
            if let accountId {
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM emails WHERE is_deleted = 0 AND account_id = ?", arguments: [accountId]) ?? 0
            }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM emails WHERE is_deleted = 0") ?? 0
        }
    }
}

// MARK: - GRDB Records

struct AccountRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "accounts"

    var id: String
    var emailAddress: String
    var displayName: String?
    var protocolType: String
    var imapUsername: String?
    var imapHost: String?
    var imapPort: Int?
    var smtpHost: String?
    var smtpPort: Int?
    var jmapUrl: String?
    var authType: String
    var keychainRef: String
    var isDefault: Bool
    var createdAt: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case emailAddress = "email_address"
        case displayName = "display_name"
        case protocolType = "protocol_type"
        case imapUsername = "imap_username"
        case imapHost = "imap_host"
        case imapPort = "imap_port"
        case smtpHost = "smtp_host"
        case smtpPort = "smtp_port"
        case jmapUrl = "jmap_url"
        case authType = "auth_type"
        case keychainRef = "keychain_ref"
        case isDefault = "is_default"
        case createdAt = "created_at"
    }
}

struct EmailRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "emails"

    var id: Int64?
    var messageId: String
    var threadId: String?
    var folder: String
    var senderName: String?
    var senderEmail: String
    var recipients: String?
    var subject: String?
    var date: Int
    var isRead: Bool
    var isStarred: Bool
    var isDeleted: Bool
    var hasAttachments: Bool
    var uid: Int?
    var flags: String?
    var referencesHeader: String?
    var inReplyTo: String?
    var createdAt: Int?
    var accountId: String?

    enum CodingKeys: String, CodingKey {
        case id, folder, subject, date, uid, flags, recipients
        case messageId = "message_id"
        case threadId = "thread_id"
        case senderName = "sender_name"
        case senderEmail = "sender_email"
        case isRead = "is_read"
        case isStarred = "is_starred"
        case isDeleted = "is_deleted"
        case hasAttachments = "has_attachments"
        case referencesHeader = "references_header"
        case inReplyTo = "in_reply_to"
        case createdAt = "created_at"
        case accountId = "account_id"
    }
}

struct SyncStateRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "sync_state"

    var accountId: String
    var folder: String
    var uidValidity: Int?
    var lastUid: Int?
    var lastSync: Int?

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case folder
        case uidValidity = "uid_validity"
        case lastUid = "last_uid"
        case lastSync = "last_sync"
    }
}

struct ContactRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "contacts"
    let id: String
    let accountId: String
    let name: String?
    let email: String
    let photoURL: String?
    let syncedAt: Int

    enum CodingKeys: String, CodingKey {
        case id, name, email
        case accountId = "account_id"
        case photoURL = "photo_url"
        case syncedAt = "synced_at"
    }
}

struct OutboxRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "outbox"

    var id: Int64?
    var toRecipients: String
    var ccRecipients: String?
    var bccRecipients: String?
    var subject: String?
    var bodyText: String?
    var bodyHtml: String?
    var inReplyTo: String?
    var createdAt: Int?
    var status: String
    var accountId: String?

    enum CodingKeys: String, CodingKey {
        case id, subject, status
        case toRecipients = "to_recipients"
        case ccRecipients = "cc_recipients"
        case bccRecipients = "bcc_recipients"
        case bodyText = "body_text"
        case bodyHtml = "body_html"
        case inReplyTo = "in_reply_to"
        case createdAt = "created_at"
        case accountId = "account_id"
    }
}
