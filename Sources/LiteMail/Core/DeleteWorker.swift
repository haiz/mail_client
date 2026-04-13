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
            print("DeleteWorker: fetchDueDeleteJobs failed: \(error)")
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
            do {
                try await store.failDeleteJobsTransient(
                    jobIds: jobs.compactMap(\.id), now: now, error: "provider not available")
            } catch {
                print("DeleteWorker: failDeleteJobsTransient (no provider) failed: \(error)")
            }
            return
        }
        let ids = jobs.compactMap(\.id)
        do {
            try await store.markDeleteJobsRunning(jobIds: ids)
        } catch {
            print("DeleteWorker: markDeleteJobsRunning failed: \(error)")
        }

        let refs = jobs.map { "folder:\($0.folder):uid:\($0.uid)" }
        do {
            try await provider.deleteMessageBatch(messageRefs: refs)
            do {
                try await store.succeedDeleteJobs(jobIds: ids)
            } catch {
                print("DeleteWorker: succeedDeleteJobs failed after server-side delete: \(error)")
            }
        } catch {
            if DeleteWorker.isPermanent(error) {
                // Permanent provider error — all jobs in group fail permanently.
                do {
                    try await store.failDeleteJobsPermanent(jobIds: ids, error: "\(error)")
                } catch {
                    print("DeleteWorker: failDeleteJobsPermanent failed: \(error)")
                }
                NotificationCenter.default.post(name: .deleteJobsPermanentlyFailed,
                                                object: nil,
                                                userInfo: ["count": ids.count])
            } else {
                // Transient error — split by per-job attempt count.
                let giveupIds = jobs.filter { $0.attempts + 1 >= 10 }.compactMap(\.id)
                let retryIds  = jobs.filter { $0.attempts + 1 < 10 }.compactMap(\.id)
                if !giveupIds.isEmpty {
                    do {
                        try await store.failDeleteJobsPermanent(jobIds: giveupIds, error: "\(error)")
                    } catch {
                        print("DeleteWorker: failDeleteJobsPermanent (giveup) failed: \(error)")
                    }
                    NotificationCenter.default.post(name: .deleteJobsPermanentlyFailed,
                                                    object: nil,
                                                    userInfo: ["count": giveupIds.count])
                }
                if !retryIds.isEmpty {
                    do {
                        try await store.failDeleteJobsTransient(jobIds: retryIds, now: now, error: "\(error)")
                    } catch {
                        print("DeleteWorker: failDeleteJobsTransient failed: \(error)")
                    }
                }
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
