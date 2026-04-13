# Spec: UID-Based Email Uniqueness

**Date:** 2026-04-06  
**Status:** Approved

## Problem

Emails sent from one LiteMail account to another are never shown in the recipient account's inbox.

**Root cause:** The `emails` table has a global `UNIQUE(message_id)` constraint (schema v1). When LiteMail syncs hai@caodev.top's Sent folder, it stores the sent email by its `message_id`. When it later tries to insert the same email into cthai83@gmail.com's INBOX (same `message_id`, different account), SQLite throws a UNIQUE constraint violation. `insertEmail` is called with `try?`, so the error is silently swallowed and the email is never stored for the receiving account.

The v2 migration added `account_id` to the emails table but never updated the unique constraint to scope it per account. A partial fix (v5 migration, already in the working tree) changes the constraint to `UNIQUE(message_id, folder, account_id)`, but we are replacing this with a more IMAP-correct approach.

## Solution: UID-based uniqueness

Replace the `message_id`-based unique constraint with a **partial unique index on `(account_id, folder, uid) WHERE uid IS NOT NULL`**.

In IMAP, UIDs are guaranteed to be unique per folder per account within a UIDVALIDITY period — this is the canonical identity of a message. `message_id` is an application-level header that can collide across accounts (same email in Sent and INBOX) and is sometimes absent or generated with a random UUID fallback.

## Changes

### 1. MailStore — v5 migration (modify in-place)

The v5 migration already exists in the working tree but has not been applied (app not yet rebuilt). Modify it to:

- Wipe all synced email data and sync_state (forces a clean full re-sync — same as current v5 approach).
- Recreate the `emails` table with **no inline UNIQUE constraint on `message_id`**.
- Create a partial unique index: `CREATE UNIQUE INDEX idx_emails_uid ON emails (account_id, folder, uid) WHERE uid IS NOT NULL`.

Messages with `uid IS NULL` (edge case for non-IMAP or demo accounts) are not deduplicated by this index. This is acceptable — real IMAP mailboxes always provide UIDs.

Table DDL (replacing the current v5 `emails_v5` definition):

```sql
CREATE TABLE emails_v5 (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    message_id TEXT NOT NULL,
    thread_id TEXT,
    folder TEXT NOT NULL DEFAULT 'INBOX',
    sender_name TEXT,
    sender_email TEXT NOT NULL,
    recipients TEXT,
    subject TEXT,
    date INTEGER NOT NULL DEFAULT 0,
    is_read INTEGER NOT NULL DEFAULT 0,
    is_starred INTEGER NOT NULL DEFAULT 0,
    is_deleted INTEGER NOT NULL DEFAULT 0,
    has_attachments INTEGER NOT NULL DEFAULT 0,
    uid INTEGER,
    flags TEXT,
    references_header TEXT,
    in_reply_to TEXT,
    created_at INTEGER,
    account_id TEXT NOT NULL DEFAULT 'default'
)
```

After rename: `CREATE UNIQUE INDEX idx_emails_uid ON emails (account_id, folder, uid) WHERE uid IS NOT NULL`

### 2. MailStore — `insertEmail`

Current: `try record.insert(db)` — throws on conflict; callers silence with `try?`.

Change to: on conflict for `(account_id, folder, uid)`, skip the insert and return the existing row's ID. Implementation:

```swift
func insertEmail(_ record: EmailRecord) throws -> Int64 {
    try dbPool.write { db in
        // Insert, ignoring UID conflicts (re-sync of already-known messages)
        try record.insertOrIgnore(db)
        if db.lastInsertedRowID != 0 {
            // New row inserted — also insert FTS entry
            let emailId = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO email_fts(rowid, subject, body_text, sender_name, sender_email)
                VALUES (?, ?, ?, ?, ?)
            """, arguments: [emailId, record.subject, nil, record.senderName, record.senderEmail])
            return emailId
        } else {
            // Row already existed — return its ID
            let existing = try EmailRecord
                .filter(Column("account_id") == record.accountId &&
                        Column("folder") == record.folder &&
                        Column("uid") == record.uid)
                .fetchOne(db)
            return existing?.id ?? 0
        }
    }
}
```

### 3. No changes to sync logic

`syncFolder` and `incrementalSyncFolder` require no changes. SwiftMail includes UIDs in envelope fetches (both sequence-range and UID-range), so `uid` is populated for all real IMAP messages. The silent `catch { return }` in `incrementalSyncFolder` for `fetchMessageInfos(uidRange:)` errors is a separate issue and out of scope here.

## Migration behavior

On first launch after upgrade:
1. v5 migration runs — wipes emails, email_bodies, labels, email_fts, sync_state.
2. App performs a full re-sync for all accounts.
3. Emails from multiple accounts with the same `message_id` now coexist — stored as separate rows keyed by `(account_id, folder, uid)`.

## Out of scope

- Fixing the silent `catch { return }` in `incrementalSyncFolder` (separate bug, no user-visible fix here).
- Flag sync (marking read/starred via IMAP — currently store-only stubs).
- Deduplication of the same email across multiple Gmail labels within one account (rare, no user report).
