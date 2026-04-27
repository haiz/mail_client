import AppKit

/// Inline reply composer docked below the last message in a thread.
/// Handles both reply (to sender only) and reply-all (to all recipients).
final class InlineReplyView: ComposeView {

    enum Mode { case reply, replyAll }

    /// Backward-compat alias so ThreadDetailView callers read `.view` as before.
    var view: NSView { self }

    private let header: EmailHeader
    private let mode: Mode
    private let contextLabel = NSTextField(labelWithString: "")
    private let sendButton: NSButton
    private let discardButton: NSButton
    private let errorLabel = NSTextField(labelWithString: "")
    private var prefillText: String = ""
    private let accountEmail: String?

    override var hasContent: Bool {
        bodyTextView.string != prefillText &&
        !bodyTextView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(header: EmailHeader, body: EmailBody?, mode: Mode, accountEmail: String? = nil) {
        self.header = header
        self.mode = mode
        self.accountEmail = accountEmail

        let tv = NSTextView()
        tv.isRichText = false
        tv.drawsBackground = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: 14)
        tv.isAutomaticSpellingCorrectionEnabled = true
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.textContainer?.widthTracksTextView = true

        sendButton = CursorButton(title: "Send", target: nil, action: nil)
        sendButton.bezelStyle = .rounded
        sendButton.controlSize = .regular
        sendButton.keyEquivalent = "\r"
        sendButton.keyEquivalentModifierMask = [.command]

        discardButton = CursorButton(title: "Discard", target: nil, action: nil)
        discardButton.bezelStyle = .rounded
        discardButton.controlSize = .regular

        super.init(bodyTextView: tv)

        sendButton.target = self
        sendButton.action = #selector(sendClicked)
        discardButton.target = self
        discardButton.action = #selector(discardClicked)

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.isHidden = true

        setupLayout(mode: mode)
        prefill(body: body)
        startAutoSave()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func setupLayout(mode: Mode) {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let contextText: String
        switch mode {
        case .reply:
            contextText = "Reply to \(header.senderName ?? header.senderEmail)"
        case .replyAll:
            var parts: [String] = [header.senderName ?? header.senderEmail]
            if let r = header.recipients {
                parts += r.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            let shown = parts.prefix(3).joined(separator: ", ")
            let extra = parts.count > 3 ? " +\(parts.count - 3) more" : ""
            contextText = "Reply all to \(shown)\(extra)"
        }
        contextLabel.stringValue = contextText
        contextLabel.font = .systemFont(ofSize: 12, weight: .medium)
        contextLabel.textColor = .secondaryLabelColor
        contextLabel.translatesAutoresizingMaskIntoConstraints = false

        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyScrollView.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = NSStackView(views: [errorLabel, discardButton, sendButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        addSubview(separator)
        addSubview(contextLabel)
        addSubview(bodyScrollView)
        addSubview(toolbar)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            contextLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            contextLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            contextLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            bodyScrollView.topAnchor.constraint(equalTo: contextLabel.bottomAnchor, constant: 8),
            bodyScrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            bodyScrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            bodyScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),

            toolbar.topAnchor.constraint(equalTo: bodyScrollView.bottomAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            toolbar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    private func prefill(body: EmailBody?) {
        let quoted = Self.buildQuotedText(header: header, body: body)
        bodyTextView.string = quoted
        prefillText = quoted
        bodyTextView.setSelectedRange(NSRange(location: 0, length: 0))
        bodyTextView.scrollToBeginningOfDocument(nil)
    }

    // MARK: - Public

    func focusBody(in window: NSWindow) {
        window.makeFirstResponder(bodyTextView)
    }

    // MARK: - Override

    override func buildMessage() -> OutgoingMessage {
        let to: [String]
        switch mode {
        case .reply:
            to = [header.senderEmail]
        case .replyAll:
            var addrs = [header.senderEmail]
            if let r = header.recipients {
                addrs += r.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            var seen = Set<String>()
            if let own = accountEmail { seen.insert(own.lowercased()) }
            to = addrs.filter { seen.insert($0.lowercased()).inserted }
        }

        let subject = header.subject.map { Self.reSubject($0) } ?? "Re:"

        return OutgoingMessage(
            to: to, cc: [], bcc: [],
            subject: subject,
            bodyText: bodyTextView.string,
            inReplyTo: header.messageId
        )
    }

    // MARK: - Actions

    @objc private func sendClicked() {
        guard let onSend else {
            errorLabel.stringValue = "Cannot send — not connected"
            errorLabel.isHidden = false
            return
        }
        let message = buildMessage()
        sendButton.isEnabled = false
        sendButton.title = "Sending\u{2026}"
        errorLabel.isHidden = true

        onSend(message) { [weak self] error in
            guard let self else { return }
            if let error {
                self.sendButton.isEnabled = true
                self.sendButton.title = "Send"
                self.errorLabel.stringValue = error
                self.errorLabel.isHidden = false
            } else {
                self.onDiscard?()
            }
        }
    }

    @objc private func discardClicked() {
        onDiscard?()
    }
}
