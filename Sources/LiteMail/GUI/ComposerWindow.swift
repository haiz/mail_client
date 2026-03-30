import AppKit

/// Compose window for new emails, replies, and forwards.
/// Draft auto-saves every 5 seconds to the outbox.
final class ComposerWindow: NSObject {

    private let window: NSWindow
    private let toField: NSTextField
    private let ccField: NSTextField
    private let subjectField: NSTextField
    private let bodyTextView: NSTextView
    private let bodyScrollView: NSScrollView
    private let sendButton: NSButton

    private var autoSaveTimer: Timer?
    private var draftId: Int64?

    /// Called when the user clicks Send. Receives the composed message.
    var onSend: ((OutgoingMessage) -> Void)?
    /// Called periodically for draft auto-save.
    var onSaveDraft: ((OutgoingMessage) -> Void)?

    enum Mode {
        case compose
        case reply(to: EmailHeader, body: EmailBody?)
        case forward(original: EmailHeader, body: EmailBody?)
    }

    init(mode: Mode) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.windowTitle(for: mode)
        window.center()
        window.minSize = NSSize(width: 400, height: 300)

        // Fields
        toField = NSTextField()
        toField.placeholderString = "To"
        toField.font = .systemFont(ofSize: 13)

        ccField = NSTextField()
        ccField.placeholderString = "Cc"
        ccField.font = .systemFont(ofSize: 13)

        subjectField = NSTextField()
        subjectField.placeholderString = "Subject"
        subjectField.font = .systemFont(ofSize: 13)

        // Body
        bodyTextView = NSTextView()
        bodyTextView.isRichText = false
        bodyTextView.font = .systemFont(ofSize: 14)
        bodyTextView.isAutomaticSpellingCorrectionEnabled = true
        bodyTextView.isAutomaticQuoteSubstitutionEnabled = false
        bodyTextView.textContainerInset = NSSize(width: 8, height: 8)
        bodyTextView.textContainer?.widthTracksTextView = true

        bodyScrollView = NSScrollView()
        bodyScrollView.documentView = bodyTextView
        bodyScrollView.hasVerticalScroller = true
        bodyScrollView.autohidesScrollers = true

        // Send button
        sendButton = NSButton(title: "Send", target: nil, action: nil)
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        sendButton.keyEquivalentModifierMask = .command

        super.init()

        sendButton.target = self
        sendButton.action = #selector(sendClicked)

        setupLayout()
        prefill(mode: mode)
        startAutoSave()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        autoSaveTimer?.invalidate()
        window.close()
    }

    // MARK: - Layout

    private func setupLayout() {
        let container = NSView()

        let fields: [(NSTextField, String)] = [
            (toField, "To:"),
            (ccField, "Cc:"),
            (subjectField, "Subject:"),
        ]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (field, label) in fields {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8

            let lbl = NSTextField(labelWithString: label)
            lbl.font = .systemFont(ofSize: 12, weight: .medium)
            lbl.textColor = .secondaryLabelColor
            lbl.widthAnchor.constraint(equalToConstant: 60).isActive = true
            lbl.alignment = .right

            field.translatesAutoresizingMaskIntoConstraints = false

            row.addArrangedSubview(lbl)
            row.addArrangedSubview(field)
            stack.addArrangedSubview(row)
        }

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        bodyScrollView.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(sendButton)

        container.addSubview(stack)
        container.addSubview(separator)
        container.addSubview(bodyScrollView)
        container.addSubview(toolbar)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            separator.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            bodyScrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            bodyScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bodyScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bodyScrollView.bottomAnchor.constraint(equalTo: toolbar.topAnchor),

            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            toolbar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            toolbar.heightAnchor.constraint(equalToConstant: 36),

            sendButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            sendButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
        ])

        window.contentView = container
    }

    // MARK: - Prefill

    private func prefill(mode: Mode) {
        switch mode {
        case .compose:
            break

        case .reply(let header, let body):
            toField.stringValue = header.senderEmail
            subjectField.stringValue = header.subject.map { "Re: \($0)" } ?? "Re:"

            var quotedText = "\n\nOn \(Self.dateFormatter.string(from: header.date)), \(header.senderEmail) wrote:\n"
            if let text = body?.textBody {
                quotedText += text.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n")
            }
            bodyTextView.string = quotedText

        case .forward(let header, let body):
            subjectField.stringValue = header.subject.map { "Fwd: \($0)" } ?? "Fwd:"

            var fwdText = "\n\n---------- Forwarded message ----------\n"
            fwdText += "From: \(header.senderEmail)\n"
            fwdText += "Date: \(Self.dateFormatter.string(from: header.date))\n"
            fwdText += "Subject: \(header.subject ?? "")\n\n"
            if let text = body?.textBody {
                fwdText += text
            }
            bodyTextView.string = fwdText
        }
    }

    // MARK: - Actions

    @objc private func sendClicked() {
        let message = buildMessage()
        guard !message.to.isEmpty else {
            NSSound.beep()
            return
        }
        onSend?(message)
        close()
    }

    private func buildMessage() -> OutgoingMessage {
        let to = toField.stringValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let cc = ccField.stringValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return OutgoingMessage(
            to: to,
            cc: cc,
            bcc: [],
            subject: subjectField.stringValue,
            bodyText: bodyTextView.string,
            bodyHtml: nil,
            inReplyTo: nil
        )
    }

    // MARK: - Auto-save

    private func startAutoSave() {
        autoSaveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let draft = self.buildMessage()
            // Only save if there's content
            if !draft.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
               !draft.subject.isEmpty {
                self.onSaveDraft?(draft)
            }
        }
    }

    // MARK: - Helpers

    private static func windowTitle(for mode: Mode) -> String {
        switch mode {
        case .compose: return "New Message"
        case .reply: return "Reply"
        case .forward: return "Forward"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
