# UID-Based Email Uniqueness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the global `UNIQUE(message_id)` constraint on the emails table with a partial unique index on `(account_id, folder, uid) WHERE uid IS NOT NULL`, so emails from one account can be received by another account without silent dedup failures.

**Architecture:** Modify the v5 migration (already in working tree, not yet applied) to use UID-based uniqueness instead of message_id-based. Update `insertEmail` to use insert-or-ignore semantics so re-syncing a known message is a safe no-op. The data wipe in v5 forces a clean full re-sync on first launch after upgrade.

**Tech Stack:** Swift, GRDB (SQLite), XCTest

---

## Files

- Modify: `Sources/LiteMail/Core/MailStore.swift`
  - v5 migration: change table DDL and remove inline `UNIQUE(message_id, folder, account_id)`, add partial index on `(account_id, folder, uid) WHERE uid IS NOT NULL`
  - `insertEmail`: change `record.insert(db)` to insert-or-ignore, return existing row ID on conflict
- Modify: `Tests/LiteMailTests/MailStoreTests.swift`
  - Update `testDuplicateMessageIdRejected` → `testDuplicateUidIsIgnoredAndReturnsExistingId`
  - Add `testCrossAccountSameMessageIdAllowed`
  - Add `testNilUidNeverConflicts`
  - Add `makeEmail` `uid` parameter to helper

---

## Task 1: Update tests to match new UID-based semantics

**Files:**
- Modify: `Tests/LiteMailTests/MailStoreTests.swift`

- [ ] **Step 1: Add `uid` parameter to `makeEmail` helper**

In `MailStoreTests.swift`, replace the `makeEmail` helper (around line 252):

```swift
private func makeEmail(
    messageId: String,
    subject: String? = "Test Subject",
    senderName: String? = nil,
    accountId: String? = nil,
    folder: String = "INBOX",
    uid: Int? = nil
) -> EmailRecord {
    EmailRecord(
        messageId: messageId,
        folder: folder,
        senderEmail: "sender@example.com",
        subject: subject,
        date: Int(Date().timeIntervalSince1970),
        isRead: false,
        isStarred: false,
        isDeleted: false,
        hasAttachments: false,
        uid: uid,
        accountId: accountId ?? testAccountId
    )
}
```

- [ ] **Step 2: Replace `testDuplicateMessageIdRejected` with `testDuplicateUidIsIgnoredAndReturnsExistingId`**

Remove the old `testDuplicateMessageIdRejected` (lines ~72–83) and replace with:

```swift
func testDuplicateUidIsIgnoredAndReturnsExistingId() async throws {
    // Same (account_id, folder, uid) inserted twice must be silently ignored.
    // The second call returns the existing row's ID.
    let record = makeEmail(messageId: "<dup@example.com>", uid: 42)
    let id1 = try await store.insertEmail(record)
    XCTAssertGreaterThan(id1, 0)

    let id2 = try await store.insertEmail(record)
    XCTAssertEqual(id1, id2, "Second insert for same UID must return the existing row ID")

    let count = try await store.emailCount(accountId: testAccountId)
    XCTAssertEqual(count, 1, "Only one row should exist")
}
```

- [ ] **Step 3: Add `testCrossAccountSameMessageIdAllowed`**

After the above test, add:

```swift
func testCrossAccountSameMessageIdAllowed() async throws {
    // The core bug: same message_id in two different accounts must both be stored.
    // e.g. hai@caodev.top's Sent and cthai83@gmail.com's INBOX share a message_id.
    let account2 = AccountRecord(
        id: "acct2",
        emailAddress: "other@example.com",
        protocolType: "imap",
        authType: "password",
        keychainRef: "k2",
        isDefault: false
    )
    try await store.insertAccount(account2)

    let sent = makeEmail(messageId: "<shared@example.com>", accountId: testAccountId, uid: 10)
    let inbox = makeEmail(messageId: "<shared@example.com>", accountId: "acct2", uid: 5)

    let id1 = try await store.insertEmail(sent)
    let id2 = try await store.insertEmail(inbox)

    XCTAssertGreaterThan(id1, 0)
    XCTAssertGreaterThan(id2, 0)
    XCTAssertNotEqual(id1, id2, "Each account stores its own copy of the email")

    let count1 = try await store.emailCount(accountId: testAccountId)
    let count2 = try await store.emailCount(accountId: "acct2")
    XCTAssertEqual(count1, 1)
    XCTAssertEqual(count2, 1)
}
```

- [ ] **Step 4: Add `testNilUidNeverConflicts`**

After the above, add:

```swift
func testNilUidNeverConflicts() async throws {
    // Emails with uid=nil are not covered by the partial index.
    // Two nil-uid emails with the same message_id can coexist (edge case: demo/offline data).
    let r1 = makeEmail(messageId: "<no-uid@example.com>", uid: nil)
    let r2 = makeEmail(messageId: "<no-uid@example.com>", uid: nil)

    let id1 = try await store.insertEmail(r1)
    let id2 = try await store.insertEmail(r2)

    XCTAssertGreaterThan(id1, 0)
    XCTAssertGreaterThan(id2, 0)
    // Both rows stored — no UID to deduplicate on
}
```

- [ ] **Step 5: Run the new tests to confirm they FAIL (schema not changed yet)**

```bash
swift test --filter MailStoreTests/testDuplicateUidIsIgnoredAndReturnsExistingId
swift test --filter MailStoreTests/testCrossAccountSameMessageIdAllowed
swift test --filter MailStoreTests/testNilUidNeverConflicts
```

Expected: all three FAIL (old schema still in place — `testCrossAccountSameMessageIdAllowed` will throw UNIQUE violation, others may fail too).

---

## Task 2: Modify v5 migration and `insertEmail`

**Files:**
- Modify: `Sources/LiteMail/Core/MailStore.swift`

- [ ] **Step 1: Update the v5 migration table DDL**

In `MailStore.swift`, find the `v5_multi_folder_emails` migration (around line 184). Replace the `CREATE TABLE emails_v5` SQL and the partial-index creation. The full migration block should look like this:

```swift
migrator.registerMigration("v5_multi_folder_emails") { db in
    // Wipe synced data (forces full re-sync on next launch)
    try db.execute(sql: "DELETE FROM email_fts")
    try db.execute(sql: "DELETE FROM email_bodies")
    try db.execute(sql: "DELETE FROM labels")
    try db.execute(sql: "DELETE FROM emails")
    try db.execute(sql: "DELETE FROM sync_state")

    // Recreate emails table. Remove the global UNIQUE(message_id) constraint.
    // Uniqueness is now enforced per (account_id, folder, uid) via a partial index below.
    // FK enforcement must be disabled while we drop and rename the table.
    try db.execute(sql: "PRAGMA foreign_keys = OFF")
    try db.execute(sql: """
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
    """)
    try db.execute(sql: "DROP INDEX IF EXISTS idx_emails_thread")
    try db.execute(sql: "DROP INDEX IF EXISTS idx_emails_folder")
    try db.execute(sql: "DROP INDEX IF EXISTS idx_emails_date")
    try db.execute(sql: "DROP INDEX IF EXISTS idx_emails_sender")
    try db.execute(sql: "DROP INDEX IF EXISTS idx_emails_account")
    try db.execute(sql: "DROP INDEX IF EXISTS idx_emails_account_folder")
    try db.execute(sql: "DROP TABLE emails")
    try db.execute(sql: "ALTER TABLE emails_v5 RENAME TO emails")
    try db.execute(sql: "PRAGMA foreign_keys = ON")

    try db.create(index: "idx_emails_thread", on: "emails", columns: ["thread_id"])
    try db.create(index: "idx_emails_folder", on: "emails", columns: ["folder"])
    try db.create(index: "idx_emails_date", on: "emails", columns: ["date"])
    try db.create(index: "idx_emails_sender", on: "emails", columns: ["sender_email"])
    try db.create(index: "idx_emails_account", on: "emails", columns: ["account_id"])
    try db.create(index: "idx_emails_account_folder", on: "emails", columns: ["account_id", "folder"])
    // Partial unique index: only deduplicate messages where UID is known.
    // NULL UIDs (edge case) are excluded — SQLite allows multiple NULLs in a unique index
    // anyway, but the explicit WHERE makes the intent clear.
    try db.execute(sql: """
        CREATE UNIQUE INDEX idx_emails_uid
        ON emails (account_id, folder, uid)
        WHERE uid IS NOT NULL
    """)
}
```

- [ ] **Step 2: Update `insertEmail` to insert-or-ignore**

Find `insertEmail` in `MailStore.swift` (around line 279). Replace the entire function:

```swift
func insertEmail(_ record: EmailRecord) throws -> Int64 {
    try dbPool.write { db in
        try record.insertOrIgnore(db)

        if db.changesCount > 0 {
            // New row was inserted — add FTS entry
            let emailId = db.lastInsertedRowID
            try db.execute(
                sql: """
                    INSERT INTO email_fts(rowid, subject, body_text, sender_name, sender_email)
                    VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [emailId, record.subject, nil, record.senderName, record.senderEmail]
            )
            return emailId
        } else {
            // Row already existed (UID conflict) — return the existing row's ID
            guard let uid = record.uid else { return 0 }
            let existing = try EmailRecord
                .filter(
                    Column("account_id") == record.accountId &&
                    Column("folder") == record.folder &&
                    Column("uid") == uid
                )
                .fetchOne(db)
            return existing?.id ?? 0
        }
    }
}
```

- [ ] **Step 3: Run the three new tests — they should now pass**

```bash
swift test --filter MailStoreTests/testDuplicateUidIsIgnoredAndReturnsExistingId
swift test --filter MailStoreTests/testCrossAccountSameMessageIdAllowed
swift test --filter MailStoreTests/testNilUidNeverConflicts
```

Expected: all three PASS.

- [ ] **Step 4: Run the full test suite to confirm no regressions**

```bash
swift test --filter MailStoreTests
```

Expected: all tests pass. If `testSameMessageIdInDifferentFoldersAllowed` fails (it uses `uid: nil` by default in `makeEmail`), that test is still valid behavior — nil-uid rows are not deduplicated, so both inserts succeed. Confirm the test still passes as-is.

- [ ] **Step 5: Delete the stale SQLite database so the migration runs on next launch**

The v5 migration wipes and recreates the emails table. Any existing DB on disk with the old schema needs to be removed so the migration runs. In development, delete the app database:

```bash
rm -f ~/Library/Application\ Support/LiteMail/mail.sqlite
rm -f ~/Library/Application\ Support/LiteMail/mail.sqlite-wal
rm -f ~/Library/Application\ Support/LiteMail/mail.sqlite-shm
```

- [ ] **Step 6: Build and run the app, verify the fix**

```bash
swift run LiteMail
```

1. Add / sign in to both hai@caodev.top and cthai83@gmail.com.
2. Send an email from hai@caodev.top to cthai83@gmail.com.
3. Switch to cthai83@gmail.com and click Refresh.
4. Confirm the email appears in the inbox.
5. Confirm the status bar shows "+1 emails" (or the correct count).

- [ ] **Step 7: Commit**

```bash
git add Sources/LiteMail/Core/MailStore.swift Tests/LiteMailTests/MailStoreTests.swift
git commit -m "fix: use (account_id, folder, uid) partial index for email uniqueness

Replaces the global UNIQUE(message_id) constraint that silently dropped
emails shared across accounts (e.g. Sent on one account, INBOX on another).
v5 migration wipes synced data and recreates the emails table. insertEmail
now uses insert-or-ignore so re-syncing known messages is a safe no-op."
```
