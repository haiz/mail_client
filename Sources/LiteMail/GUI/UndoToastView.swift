import AppKit

// MARK: - UndoableBatchAction

struct UndoableBatchAction {
    let description: String
    let reverseOperation: @Sendable () async throws -> Void
    let emailIds: [Int64]
    var isUndone: Bool = false
    var countdown: Int = 10
}

// MARK: - UndoToastView

/// Floating container that stacks multiple undo toasts.
///
/// Each call to `show(action:onExpire:)` adds a new 32px card to the bottom of the stack,
/// each with its own independent 10-second countdown. Older cards slide upward as new
/// ones appear. Cards remove themselves on expire or undo.
///
/// This matches Gmail's multi-action undo UX: rapidly deleting two batches of emails
/// leaves both batches independently undoable for their full 10-second window.
///
/// Usage:
/// ```swift
/// undoToastView.show(action: action, onExpire: { /* sync fired */ })
/// ```
@MainActor
final class UndoToastView: NSView {

    // MARK: - Subviews

    private let stackView = NSStackView()

    // MARK: - State

    private var cards: [UndoToastCard] = []

    // MARK: - Callbacks

    /// Called after a successful undo on any card (caller should reload the message list).
    var onUndo: (() -> Void)?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.distribution = .fill
        stackView.spacing = 6
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Start hidden while empty.
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public API

    /// Add a new toast to the stack, starting its independent 10-second countdown.
    /// Multiple toasts can be visible simultaneously — they stack vertically with the
    /// newest at the bottom (nearest the status bar).
    func show(action: UndoableBatchAction, onExpire: @escaping () -> Void) {
        let card = UndoToastCard(action: action)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.onExpire = { [weak self, weak card] in
            onExpire()
            guard let card else { return }
            self?.remove(card: card, firedUndo: false)
        }
        card.onUndoComplete = { [weak self, weak card] in
            guard let card else { return }
            self?.remove(card: card, firedUndo: true)
        }

        stackView.addArrangedSubview(card)
        cards.append(card)

        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalTo: widthAnchor),
        ])

        if isHidden {
            isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                animator().alphaValue = 1
            }
        }

        card.startCountdown()
        card.announceForAccessibility()
    }

    /// Undo the most recent (bottom-most) card that hasn't been undone yet.
    /// Wired to Cmd+Z.
    func performUndo() {
        guard let card = cards.reversed().first(where: { !$0.isUndone }) else { return }
        card.performUndo()
    }

    // MARK: - Private

    private func remove(card: UndoToastCard, firedUndo: Bool) {
        card.stop()
        stackView.removeArrangedSubview(card)
        card.removeFromSuperview()
        cards.removeAll(where: { $0 === card })

        if firedUndo {
            onUndo?()
        }

        if cards.isEmpty {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.cards.isEmpty else { return }
                    self.isHidden = true
                }
            })
        }
    }
}

// MARK: - UndoToastCard

/// A single 32px toast card. Owns its countdown timer, label, progress bar, and undo button.
/// Used internally by `UndoToastView` to support multiple simultaneous undo windows.
@MainActor
private final class UndoToastCard: NSView {

    // MARK: - Subviews

    private let messageLabel = NSTextField(labelWithString: "")
    private let undoButton: NSButton
    private let progressBar = NSView()

    // MARK: - State

    private var action: UndoableBatchAction
    private var countdownTimer: Timer?
    private var secondsRemaining: Int = 10
    private var progressWidthConstraint: NSLayoutConstraint?

    var isUndone: Bool { action.isUndone }

    // MARK: - Callbacks

    /// Called when the countdown expires without undo.
    var onExpire: (() -> Void)?
    /// Called after the reverse operation finishes following an undo tap.
    var onUndoComplete: (() -> Void)?

    // MARK: - Init

    init(action: UndoableBatchAction) {
        self.action = action

        undoButton = NSButton(title: "Undo", target: nil, action: nil)
        undoButton.bezelStyle = .inline
        undoButton.isBordered = false
        undoButton.font = .systemFont(ofSize: 11, weight: .semibold)
        undoButton.contentTintColor = .linkColor
        undoButton.translatesAutoresizingMaskIntoConstraints = false
        undoButton.setContentHuggingPriority(.required, for: .horizontal)

        super.init(frame: .zero)

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

        messageLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        messageLabel.textColor = .labelColor
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        progressBar.wantsLayer = true
        progressBar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        addSubview(progressBar)
        addSubview(messageLabel)
        addSubview(undoButton)

        heightAnchor.constraint(equalToConstant: 32).isActive = true

        NSLayoutConstraint.activate([
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: undoButton.leadingAnchor, constant: -8),

            undoButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            undoButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2),
        ])

        let pwc = progressBar.widthAnchor.constraint(equalTo: widthAnchor)
        pwc.isActive = true
        progressWidthConstraint = pwc

        undoButton.target = self
        undoButton.action = #selector(undoTapped)

        updateLabel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    func startCountdown() {
        stop()
        secondsRemaining = max(1, action.countdown)
        updateLabel()
        resetProgressBar()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    /// Stop the timer. Does NOT fire any callbacks.
    func stop() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    /// Invoke the reverse operation then notify the container.
    func performUndo() {
        guard !action.isUndone else { return }
        action.isUndone = true
        stop()

        let reverse = action.reverseOperation
        Task {
            try? await reverse()
            await MainActor.run { [weak self] in
                self?.onUndoComplete?()
            }
        }
    }

    func announceForAccessibility() {
        NSAccessibility.post(
            element: self,
            notification: .announcementRequested,
            userInfo: [.announcement: "\(action.description). Undo available for 10 seconds."]
        )
    }

    // MARK: - Private

    private func tick() {
        secondsRemaining -= 1
        updateLabel()
        animateProgress()

        if secondsRemaining <= 0 {
            expire()
        }
    }

    private func expire() {
        guard !action.isUndone else { return }
        stop()
        onExpire?()
    }

    private func updateLabel() {
        messageLabel.stringValue = "\(action.description) — Undo (\(secondsRemaining)s)"
    }

    private func resetProgressBar() {
        progressWidthConstraint?.isActive = false
        let full = progressBar.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 1.0)
        full.isActive = true
        progressWidthConstraint = full
        progressBar.layer?.removeAllAnimations()
        layoutSubtreeIfNeeded()
    }

    private func animateProgress() {
        let total = CGFloat(max(1, action.countdown))
        let fraction = CGFloat(secondsRemaining) / total
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

    // MARK: - Actions

    @objc private func undoTapped() {
        performUndo()
    }
}
