import AppKit

// MARK: - UndoableBatchAction

struct UndoableBatchAction {
    let description: String
    let reverseOperation: @Sendable () async throws -> Void
    let emailIds: [Int64]
    var isUndone: Bool = false
}

// MARK: - UndoToastView

/// Floating toast that appears after a batch operation, offering a 10-second undo window.
///
/// Layout: 32px height, floats 8px above the StatusBar, centered in the message list column.
/// Shows countdown text + shrinking progress bar at the bottom.
///
/// Usage:
/// ```swift
/// undoToastView.show(action: action, onExpire: { /* sync fired */ })
/// ```
@MainActor
final class UndoToastView: NSView {

    // MARK: - Subviews

    private let messageLabel = NSTextField(labelWithString: "")
    private let undoButton: NSButton
    private let progressBar = NSView()

    // MARK: - State

    private var currentAction: UndoableBatchAction?
    private var countdownTimer: Timer?
    private var secondsRemaining: Int = 10
    private var progressWidthConstraint: NSLayoutConstraint?

    // MARK: - Callbacks

    /// Called when the countdown expires without undo (caller should commit the batch to server).
    var onExpire: (() -> Void)?
    /// Called after a successful undo (caller should reload the message list).
    var onUndo: (() -> Void)?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        undoButton = NSButton(title: "Undo", target: nil, action: nil)
        undoButton.bezelStyle = .inline
        undoButton.isBordered = false
        undoButton.font = .systemFont(ofSize: 11, weight: .semibold)
        undoButton.contentTintColor = .linkColor
        undoButton.translatesAutoresizingMaskIntoConstraints = false
        undoButton.setContentHuggingPriority(.required, for: .horizontal)

        super.init(frame: frameRect)

        // Card appearance
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        // Drop shadow
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.15)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 4
        self.shadow = shadow

        // Message label
        messageLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        messageLabel.textColor = .labelColor
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Progress bar (accent color, anchored to bottom, shrinks left-to-right)
        progressBar.wantsLayer = true
        progressBar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        addSubview(progressBar)
        addSubview(messageLabel)
        addSubview(undoButton)

        // Height fixed at 32px — caller constrains width/position
        heightAnchor.constraint(equalToConstant: 32).isActive = true

        // Layout: [message] [undo button]
        NSLayoutConstraint.activate([
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: undoButton.leadingAnchor, constant: -8),

            undoButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            undoButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Progress bar: 2px at bottom, starts full width
            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2),
        ])

        // Placeholder width constraint; updated each second
        let pwc = progressBar.widthAnchor.constraint(equalTo: widthAnchor)
        pwc.isActive = true
        progressWidthConstraint = pwc

        undoButton.target = self
        undoButton.action = #selector(undoTapped)

        // Start hidden
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public API

    /// Show the toast for `action`, starting the 10-second countdown.
    /// If a previous action is still counting down it is committed immediately.
    func show(action: UndoableBatchAction, onExpire: @escaping () -> Void) {
        // Commit any previous uncommitted action before starting new one
        commitCurrentAction()

        self.currentAction = action
        self.onExpire = onExpire
        self.secondsRemaining = 10

        updateLabel()
        resetProgressBar()
        appear()
        scheduleCountdown()
        announceForAccessibility(action.description)
    }

    /// Perform undo: cancel countdown, run reverse operation, dismiss, reload.
    func performUndo() {
        guard var action = currentAction, !action.isUndone else { return }
        action.isUndone = true
        currentAction = action
        stopCountdown()

        Task {
            try? await action.reverseOperation()
            await MainActor.run { [weak self] in
                self?.dismiss()
                self?.onUndo?()
            }
        }
    }

    /// Immediately commit the current action (fire onExpire) if one is pending.
    /// Called when a new batch action starts, to avoid multiple undoable states.
    func commitCurrentAction() {
        guard let action = currentAction, !action.isUndone else { return }
        stopCountdown()
        onExpire?()
        currentAction = nil
    }

    // MARK: - Private

    private func scheduleCountdown() {
        stopCountdown()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func tick() {
        secondsRemaining -= 1
        updateLabel()
        animateProgress()

        if secondsRemaining <= 0 {
            expire()
        }
    }

    private func expire() {
        guard let action = currentAction, !action.isUndone else { return }
        stopCountdown()
        onExpire?()
        currentAction = nil
        dismiss()
    }

    private func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    private func updateLabel() {
        guard let action = currentAction else { return }
        messageLabel.stringValue = "\(action.description) — Undo (\(secondsRemaining)s)"
    }

    private func resetProgressBar() {
        // Remove animation, snap to full width
        progressWidthConstraint?.isActive = false
        let full = progressBar.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 1.0)
        full.isActive = true
        progressWidthConstraint = full
        progressBar.layer?.removeAllAnimations()
        layoutSubtreeIfNeeded()
    }

    private func animateProgress() {
        let fraction = CGFloat(secondsRemaining) / 10.0
        progressWidthConstraint?.isActive = false
        let newConstraint = progressBar.widthAnchor.constraint(equalTo: widthAnchor, multiplier: max(fraction, 0))
        newConstraint.isActive = true
        progressWidthConstraint = newConstraint

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 1.0
            ctx.timingFunction = CAMediaTimingFunction(name: .linear)
            layoutSubtreeIfNeeded()
        }
    }

    private func appear() {
        isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            animator().alphaValue = 1
        }
    }

    private func dismiss() {
        stopCountdown()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.isHidden = true
        })
    }

    private func announceForAccessibility(_ description: String) {
        NSAccessibility.post(
            element: self,
            notification: .announcementRequested,
            userInfo: [.announcement: "\(description). Undo available for 10 seconds."]
        )
    }

    // MARK: - Actions

    @objc private func undoTapped() {
        performUndo()
    }
}
