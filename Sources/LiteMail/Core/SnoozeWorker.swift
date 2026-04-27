import Foundation
import AppKit

/// Background worker that wakes snoozed emails when their snooze_until time passes.
/// Ticks every 60s and also fires on app-become-active to handle sleep/wake gaps.
actor SnoozeWorker {

    private let store: MailStore
    private let engine: AccountManager
    private var workerTask: Task<Void, Never>?

    init(store: MailStore, engine: AccountManager) {
        self.store = store
        self.engine = engine
    }

    func start() {
        workerTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.processDue()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.processDue() }
        }
    }

    func stop() {
        workerTask?.cancel()
        workerTask = nil
    }

    private func processDue() async {
        let due: [MailStore.SnoozeRecord]
        do { due = try await store.dueSnoozes(now: Date()) } catch { return }
        for rec in due {
            try? await engine.unsnooze(emailId: rec.emailId)
        }
        if !due.isEmpty {
            await MainActor.run {
                NotificationCenter.default.post(name: .snoozeDidWake, object: nil)
            }
        }
    }
}

extension Notification.Name {
    static let snoozeDidWake = Notification.Name("LiteMail.snoozeDidWake")
}
