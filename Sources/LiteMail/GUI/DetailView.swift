import AppKit

/// Email detail view. Renders email body as NSAttributedString (no WebKit).
/// Shows sender, subject, date, and body content.
final class DetailView: NSObject {

    let view: NSView
    private let scrollView: NSScrollView
    private let contentView: NSView

    // Header elements
    private let subjectLabel = NSTextField(labelWithString: "")
    private let senderLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let avatarView = NSTextField(labelWithString: "")

    // Body
    private let bodyTextView: NSTextView
    private let bodyScrollView: NSScrollView

    // Empty state
    private let emptyLabel = NSTextField(labelWithString: "Select a message")

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    override init() {
        // Body text view
        bodyTextView = NSTextView()
        bodyTextView.isEditable = false
        bodyTextView.isSelectable = true
        bodyTextView.isRichText = true
        bodyTextView.textContainerInset = NSSize(width: 0, height: 0)
        bodyTextView.textContainer?.widthTracksTextView = true
        bodyTextView.isAutomaticLinkDetectionEnabled = true
        bodyTextView.drawsBackground = false

        bodyScrollView = NSScrollView()
        bodyScrollView.documentView = bodyTextView
        bodyScrollView.hasVerticalScroller = true
        bodyScrollView.autohidesScrollers = true
        bodyScrollView.drawsBackground = false
        bodyScrollView.translatesAutoresizingMaskIntoConstraints = false

        // Container
        contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        scrollView = NSScrollView()
        scrollView.documentView = contentView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        view = NSView()

        super.init()

        setupLayout()
        showEmpty()
    }

    private func setupLayout() {
        for v in [subjectLabel, senderLabel, dateLabel, avatarView, bodyScrollView, emptyLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }

        // Subject
        subjectLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        subjectLabel.lineBreakMode = .byWordWrapping
        subjectLabel.maximumNumberOfLines = 3
        subjectLabel.preferredMaxLayoutWidth = 500

        // Avatar circle
        avatarView.font = .systemFont(ofSize: 14, weight: .semibold)
        avatarView.alignment = .center
        avatarView.textColor = .controlAccentColor
        avatarView.backgroundColor = .controlAccentColor.withAlphaComponent(0.1)
        avatarView.isBordered = false
        avatarView.isEditable = false
        avatarView.wantsLayer = true
        avatarView.layer?.cornerRadius = 16

        // Sender
        senderLabel.font = .systemFont(ofSize: 13, weight: .medium)

        // Date
        dateLabel.font = .systemFont(ofSize: 11)
        dateLabel.textColor = .tertiaryLabelColor

        // Empty state
        emptyLabel.font = .systemFont(ofSize: 16)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center

        NSLayoutConstraint.activate([
            subjectLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            subjectLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            subjectLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            avatarView.topAnchor.constraint(equalTo: subjectLabel.bottomAnchor, constant: 12),
            avatarView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            avatarView.widthAnchor.constraint(equalToConstant: 32),
            avatarView.heightAnchor.constraint(equalToConstant: 32),

            senderLabel.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor, constant: -8),
            senderLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 10),

            dateLabel.topAnchor.constraint(equalTo: senderLabel.bottomAnchor, constant: 1),
            dateLabel.leadingAnchor.constraint(equalTo: senderLabel.leadingAnchor),

            bodyScrollView.topAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: 16),
            bodyScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            bodyScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            bodyScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    func display(header: EmailHeader, body: EmailBody?) {
        emptyLabel.isHidden = true
        subjectLabel.isHidden = false
        avatarView.isHidden = false
        senderLabel.isHidden = false
        dateLabel.isHidden = false
        bodyScrollView.isHidden = false

        subjectLabel.stringValue = header.subject ?? "(no subject)"
        senderLabel.stringValue = header.senderName ?? header.senderEmail
        dateLabel.stringValue = Self.dateFormatter.string(from: header.date)

        // Avatar initials
        let name = header.senderName ?? header.senderEmail
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        avatarView.stringValue = initials.isEmpty ? "?" : initials.uppercased()

        // Render body
        if let htmlBody = body?.htmlBody {
            bodyTextView.textStorage?.setAttributedString(Self.htmlToAttributedString(htmlBody))
        } else if let textBody = body?.textBody {
            bodyTextView.textStorage?.setAttributedString(Self.plainTextToAttributedString(textBody))
        } else {
            bodyTextView.string = "(loading...)"
        }

        bodyTextView.scrollToBeginningOfDocument(nil)
    }

    func clear() {
        showEmpty()
    }

    private func showEmpty() {
        emptyLabel.isHidden = false
        subjectLabel.isHidden = true
        avatarView.isHidden = true
        senderLabel.isHidden = true
        dateLabel.isHidden = true
        bodyScrollView.isHidden = true
    }

    // MARK: - Text Rendering (No WebKit)

    /// Converts HTML email body to NSAttributedString.
    /// This is the no-WebKit approach: graceful degradation for complex HTML,
    /// but keeps memory under 30MB always.
    private static func htmlToAttributedString(_ html: String) -> NSAttributedString {
        guard let data = html.data(using: .utf8) else {
            return plainTextToAttributedString(html)
        }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]

        if let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            // Apply our preferred font styling over the HTML defaults
            let mutable = NSMutableAttributedString(attributedString: attributed)
            let fullRange = NSRange(location: 0, length: mutable.length)
            mutable.enumerateAttribute(.font, in: fullRange) { value, range, _ in
                guard let font = value as? NSFont else { return }
                let newFont: NSFont
                if font.fontDescriptor.symbolicTraits.contains(.bold) {
                    newFont = .systemFont(ofSize: 14, weight: .semibold)
                } else if font.fontDescriptor.symbolicTraits.contains(.italic) {
                    newFont = .systemFont(ofSize: 14, weight: .regular) // TODO: italic variant
                } else {
                    newFont = .systemFont(ofSize: 14)
                }
                mutable.addAttribute(.font, value: newFont, range: range)
            }
            return mutable
        }

        return plainTextToAttributedString(html)
    }

    private static func plainTextToAttributedString(_ text: String) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        paragraphStyle.paragraphSpacing = 8

        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle,
        ])
    }
}
