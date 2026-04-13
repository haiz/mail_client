import Foundation

/// Drains `delete_jobs` and calls the provider's `deleteMessageBatch`. Serialized via actor.
///
/// Design: the worker is pure — it reads the queue, calls providers, updates the queue.
/// UI signaling (toasts, badges) happens via posts to `NotificationCenter` on permanent failure.
actor DeleteWorker {
    private let store: MailStore
    private let providerLookup: @Sendable (_ accountId: String) -> (any MailProvider)?
    private var tickTask: Task<Void, Never>?
    private let batchLimit: Int

    init(store: MailStore,
         providerLookup: @escaping @Sendable (String) -> (any MailProvider)?,
         batchLimit: Int = 200) {
        self.store = store
        self.providerLookup = providerLookup
        self.batchLimit = batchLimit
    }

    /// Starts a 10-second ticker. Idempotent.
    func start() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runOnce(now: Int(Date().timeIntervalSince1970))
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    /// Explicit kick after enqueue. Runs one drain pass immediately.
    func kick() async {
        await runOnce(now: Int(Date().timeIntervalSince1970))
    }

    /// Single drain pass. Public for tests.
    func runOnce(now: Int) async {
        let due: [DeleteJobRecord]
        do {
            due = try await store.fetchDueDeleteJobs(now: now, limit: batchLimit)
        } catch {
            return
        }
        guard !due.isEmpty else { return }

        // Group by (account, folder) so each IMAP batch selects one mailbox.
        let byGroup = Dictionary(grouping: due, by: { GroupKey(accountId: $0.accountId, folder: $0.folder) })
        for (key, jobs) in byGroup {
            await processGroup(accountId: key.accountId, folder: key.folder, jobs: jobs, now: now)
        }
    }

    private struct GroupKey: Hashable {
        let accountId: String
        let folder: String
    }

    private func processGroup(accountId: String, folder: String, jobs: [DeleteJobRecord], now: Int) async {
        guard let provider = providerLookup(accountId) else {
            // No provider — transient: maybe account not loaded yet.
            try? await store.failDeleteJobsTransient(
                jobIds: jobs.compactMap(\.id), now: now, error: "provider not available")
            return
        }
        let ids = jobs.compactMap(\.id)
        try? await store.markDeleteJobsRunning(jobIds: ids)

        let refs = jobs.map { "folder:\($0.folder):uid:\($0.uid)" }
        do {
            try await provider.deleteMessageBatch(messageRefs: refs)
            try? await store.succeedDeleteJobs(jobIds: ids)
        } catch {
            if DeleteWorker.isPermanent(error) || jobs.first.map({ $0.attempts + 1 >= 10 }) == true {
                try? await store.failDeleteJobsPermanent(jobIds: ids, error: "\(error)")
                NotificationCenter.default.post(name: .deleteJobsPermanentlyFailed,
                                                object: nil,
                                                userInfo: ["count": ids.count])
            } else {
                try? await store.failDeleteJobsTransient(jobIds: ids, now: now, error: "\(error)")
            }
        }
    }

    /// Classifies an error as permanent. Conservative: only well-known permanent cases.
    static func isPermanent(_ error: any Error) -> Bool {
        if let e = error as? IMAPProviderError {
            switch e {
            case .authFailed, .messageNotFound:
                return true
            default:
                return false
            }
        }
        return false
    }
}

extension Notification.Name {
    static let deleteJobsPermanentlyFailed = Notification.Name("LiteMail.deleteJobsPermanentlyFailed")
}
