import AppKit

/// Shared NSView base for compose surfaces (inline reply, future composer strips).
/// Provides: body editing area with scroll view, auto-save timer, and static helpers.
/// Subclasses must override `hasContent` and `buildMessage()`.
class ComposeView: NSView {

    let bodyTextView: NSTextView
    let bodyScrollView: NSScrollView

    var onSaveDraft: ((OutgoingMessage) -> Void)?
    var onDiscard: (() -> Void)?
    var onSend: ((OutgoingMessage, @escaping (String?) -> Void) -> Void)?

    private var autoSaveTimer: Timer?

    var hasContent: Bool { false }

    func buildMessage() -> OutgoingMessage {
        fatalError("ComposeView subclasses must override buildMessage()")
    }

    init(bodyTextView: NSTextView) {
        self.bodyTextView = bodyTextView

        bodyScrollView = NSScrollView()
        bodyScrollView.documentView = bodyTextView
        bodyScrollView.hasVerticalScroller = true
        bodyScrollView.autohidesScrollers = true

        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { autoSaveTimer?.invalidate() }

    func startAutoSave() {
        autoSaveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.forceSaveDraft()
        }
    }

    func stopAutoSave() {
        autoSaveTimer?.invalidate()
        autoSaveTimer = nil
    }

    func forceSaveDraft() {
        guard hasContent else { return }
        onSaveDraft?(buildMessage())
    }

    // MARK: - Shared static helpers

    static func buildQuotedText(header: EmailHeader, body: EmailBody?) -> String {
        var quoted = "\n\nOn \(dateFormatter.string(from: header.date)), \(header.senderEmail) wrote:\n"
        if let text = body?.textBody, !text.isEmpty {
            quoted += text.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n")
        }
        return quoted
    }

    static func reSubject(_ s: String) -> String {
        s.lowercased().hasPrefix("re:") ? s : "Re: \(s)"
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
