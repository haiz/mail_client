# Spec: Phased Delete with Server Reconciliation

**Date:** 2026-04-13
**Status:** Approved
**Related plan:** `docs/superpowers/plans/2026-04-13-phased-delete-reconciliation.md`

## Problem

The current bulk-delete flow lets the local DB diverge silently from the server.

Observed on `cthai83@gmail.com` on branch `feature/bulk-email-operations`:

| Folder | Server (Gmail web) | LiteMail `is_deleted=0` | LiteMail `is_deleted=1` |
|--------|-------------------:|------------------------:|------------------------:|
| Github | 3,983 | 18 | 5,007 |
| Other | 534 | 0 | 5,000 |

The emails exist in the local DB (sync pulled them). 5,007 Github and 5,000 Other rows are soft-deleted locally. The `flags` column contains `""` or `"seen"` (no `"deleted"`), proving the local `is_deleted=1` was set by a local bulk-delete action, not by IMAP flag sync.

### Root cause — three design flaws

1. **Fire-and-forget server call** in `AccountManager.deleteBatch` ([AccountManager.swift:257-264](../../Sources/LiteMail/Core/AccountManager.swift#L257-L264)):

   ```swift
   try await store.markDeletedBatch(emailIds: emailIds)         // local SET is_deleted=1
   for (provider, refs) in groups {
       Task { try? await provider.deleteMessageBatch(...) }    // fire-and-forget, swallows errors
   }
   ```

   If the server call fails, the local state is never corrected. There is no retry, no surfacing, no reconciliation.

2. **No state machine.** `is_deleted` is binary. There is no representation of "user requested delete but server has not confirmed," so the app cannot distinguish its own optimistic state from ground truth.

3. **Unscoped thread expansion** in `AppDelegate.expandThreadIds` ([AppDelegate.swift:289-305](../../Sources/LiteMail/App/AppDelegate.swift#L289-L305)) calls `fetchThread(threadId:)` which returns every member of the thread across every folder. Selecting a handful of GitHub PR rows (each thread has up to 263 messages) can expand into thousands of deletes the user never reviewed.

## Goal

Local delete state tracks through explicit phases and reconciles with the server. Deletes may be slow; they must not be wrong relative to the server.

## Non-goals

- Redesigning archive/move (covered only insofar as they share the same queue infrastructure — archive stays a move operation).
- Redesigning flag sync (`is_read`, `is_starred`).
- Optimistic UI for single-message delete (single `deleteEmail` already calls provider synchronously; only batch path is broken).
- Cross-account deduplication.

## Design

### 1. State machine

Each email row carries a `delete_state` (new column):

| State | Meaning | Visible in list? |
|---|---|---|
| `synced` (default) | Normal. Server is source of truth. | yes |
| `pending_delete` | User requested delete. Server not yet confirmed. | **no** |
| `delete_failed` | Server rejected or worker gave up. | yes, with badge |

Transitions:

```
synced ──(user batch delete)──▶ pending_delete
pending_delete ──(server expunged, confirmed)──▶ [row hard-deleted]
pending_delete ──(user undo)──▶ synced  (+ cancel job)
pending_delete ──(worker permanent fail)──▶ delete_failed
delete_failed ──(user retry)──▶ pending_delete
delete_failed ──(user give up)──▶ synced
```

`is_deleted` (legacy column) stays in the schema but new code stops writing to it. UI queries treat `is_deleted=1` OR `delete_state='pending_delete'` as hidden for backwards compatibility with existing rows.

### 2. Persistent job queue

New table `delete_jobs`:

```sql
CREATE TABLE delete_jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id TEXT NOT NULL,
    email_id INTEGER NOT NULL REFERENCES emails(id) ON DELETE CASCADE,
    folder TEXT NOT NULL,
    uid INTEGER NOT NULL,
    state TEXT NOT NULL DEFAULT 'queued',  -- queued | running | failed
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    next_attempt_at INTEGER NOT NULL,      -- unix seconds
    created_at INTEGER NOT NULL
);
CREATE INDEX idx_delete_jobs_due ON delete_jobs (state, next_attempt_at);
CREATE INDEX idx_delete_jobs_email ON delete_jobs (email_id);
```

Persistence: queue survives app restart. On launch, worker resumes any `queued` or `running` jobs (running → queued reset on startup since the previous run was interrupted).

### 3. `DeleteWorker` actor

Responsibilities:
- Wake on kick (after enqueue) and on a 10-second tick.
- Select due jobs (`state='queued' AND next_attempt_at <= now`) grouped by `(account_id, folder)`.
- For each group, call `provider.deleteMessageBatch(refs)`.
- On success: `DELETE FROM emails WHERE id IN (...)` + `DELETE FROM delete_jobs WHERE id IN (...)`.
- On transient error (network, timeout, connection lost): `attempts++`, `next_attempt_at = now + backoff(attempts)`, keep `state='queued'`. Backoff: `min(300, 2^attempts)` seconds, capped at 5 minutes.
- On permanent error (auth failure, 550, malformed ref) OR `attempts >= 10`: `state='failed'`, email `delete_state='delete_failed'`, surface via NotificationCenter.

Error classification is conservative: unknown errors are treated as transient unless explicitly permanent. `attempts >= 10` forces giveup regardless.

### 4. `deleteBatch` rewrite

```swift
func deleteBatch(emailIds: [Int64]) async throws {
    guard !emailIds.isEmpty else { return }
    // Fetch minimal metadata (folder, uid, account) before mutating.
    let records = try await store.fetchEmailRecords(ids: emailIds)
    // Atomic: mark pending_delete + enqueue jobs in one transaction.
    try await store.enqueueDeletes(records: records)
    // Kick worker; it runs asynchronously but is observable.
    await deleteWorker.kick()
}
```

No fire-and-forget. Errors from `enqueueDeletes` propagate. The worker owns all server interaction.

### 5. Sync reconciliation

In `IMAPProvider.incrementalSyncFolder`, after the regular UID-range fetch, run a reconciliation pass for `pending_delete` rows in this folder:

1. Read local emails where `account_id=? AND folder=? AND delete_state='pending_delete'`.
2. If empty, skip.
3. Batch `UID SEARCH UID <list>` against the server.
4. For UIDs NOT returned by SEARCH (server doesn't have them): hard-delete local row + delete job.
5. For UIDs still present on server: leave state alone — worker will retry. If the row is also in `delete_jobs` with `state='failed'`, upgrade email `delete_state='delete_failed'` and surface to UI.

This ensures that if the worker dies or a job is lost, the next incremental sync catches up.

### 6. Thread expansion fix

`expandThreadIds` in AppDelegate currently expands every thread member regardless of folder. Change it to:

```swift
private func expandThreadIds(_ ids: [Int64]) async throws -> [Int64] {
    guard let accountManager else { return ids }
    var expanded = Set<Int64>(ids)
    let groups = windowController?.messageListView.threadGroups ?? []
    let currentFolder = self.currentFolder  // folder the user is viewing
    for id in ids {
        if let group = groups.first(where: { $0.primaryHeader.id == id }),
           let threadId = group.threadId {
            let members = try await accountManager.fetchThread(threadId: threadId)
            for header in members where header.folder == currentFolder {
                expanded.insert(header.id)
            }
        }
    }
    return Array(expanded)
}
```

Deleting from "Github" only touches rows in "Github". Users who want to purge a whole thread across labels use a separate, explicit "Delete entire thread" action (out of scope here).

### 7. UI surfacing of `delete_failed`

- Row in list shows a small red `!` badge + tooltip with `last_error`.
- Bulk bar gains a "Retry failed deletes" button when any `delete_failed` rows are present in the current folder.
- Toast on worker permanent failure: `"Couldn't delete N messages. [Retry] [Dismiss]"`.

### 8. Migration & cleanup

v7 migration:
- Add `delete_state TEXT NOT NULL DEFAULT 'synced'` to `emails`.
- Create `delete_jobs` table and indexes.
- Do **not** retro-classify existing `is_deleted=1` rows. User can clear them manually via a "Restore hidden messages in this folder" action (out of scope — one-shot SQL from investigation is acceptable for this user right now).

## Open questions

1. **Gmail label semantics.** In a Gmail label folder, `STORE +FLAGS \Deleted` + `EXPUNGE` moves to Trash (current behavior). For `[Gmail]/Trash`, the same sequence is a permanent delete. This matches Gmail web. No change in this spec.
2. **Undo timeout.** Current toast gives a short undo window. With the queue, undo = mark `delete_state='synced'` + `DELETE FROM delete_jobs WHERE email_id=?`. If worker already started, cancel-flag on the job prevents server call (job worker checks state before running).

## Out of scope

- Replacing `is_deleted` column (future cleanup migration).
- Reconciliation for `pending_delete` rows in folders that never receive incremental sync (e.g., rarely-visited labels). The worker is the primary recovery path; sync reconciliation is a backstop.
- Surfacing long-running queues in a dedicated activity panel.
- Conflict: user deletes locally while another client moves the message to a different Gmail label. Worker sees `NO` from server on `STORE \Deleted`; job is retried until it gives up → `delete_failed`. User sees the badge and decides.
