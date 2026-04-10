import AppKit
import WebKit

/// Email detail view. Superhuman minimalism + Mimestream native feel.
/// Uses WKWebView for HTML emails (with images), NSTextView for plain text.
final class DetailView: NSObject, WKNavigationDelegate {

    let view: NSView

    // Header
    private let subjectLabel = NSTextField(labelWithString: "")
    private let avatarCircle: NSView
    private let avatarLabel = NSTextField(labelWithString: "")
    private let senderLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let recipientLabel = NSTextField(labelWithString: "")

    // Action bar
    private let replyButton: NSButton
    private let forwardButton: NSButton
    private let archiveButton: NSButton
    private let deleteButton: NSButton
    private let moveButton: NSButton
    private let viewSourceButton: NSButton
    private let actionBar: NSStackView

    // Separator
    private let headerSeparator = NSBox()

    // Body — dual renderer
    private let bodyTextView: NSTextView
    private let bodyScrollView: NSScrollView
    private(set) var webView: WKWebView?  // Created on demand for HTML emails
    private var sourceButton: NSButton?  // View Source

    // Empty state
    private let emptyContainer = NSView()
    private let emptyIcon = NSImageView()
    private let emptyTitle = NSTextField(labelWithString: "No message selected")
    private let emptySubtitle = NSTextField(labelWithString: "Select an email to read it here\n\u{2318}K to search \u{2022} j/k to navigate")

    // Bulk summary state
    private let summaryContainer = NSView()
    private let summaryIcon = NSImageView()
    private let summaryTitle = NSTextField(labelWithString: "")
    private let summaryList = NSTextField(labelWithString: "")

    // Callbacks
    var onReply: (() -> Void)?
    var onForward: (() -> Void)?
    var onArchive: (() -> Void)?
    var onDelete: (() -> Void)?
    var onMove: ((String) -> Void)?

    /// Available folders for the Move menu. Set by AppDelegate when displaying a message.
    var availableFolders: [MailFolder] = []

    // Attachment bar
    private let attachmentBar: NSStackView

    // Store raw source for "View Source"
    private var rawSource: String?

    /// Attachment info for the currently displayed email.
    private var currentAttachments: [AttachmentInfo] = []
    /// Callback to download attachment data by partId.
    var onDownloadAttachment: ((AttachmentInfo) -> Void)?

    // Colors for avatar (deterministic by sender)
    private static let avatarColors: [NSColor] = [
        NSColor(red: 0.35, green: 0.56, blue: 0.97, alpha: 1), // Blue
        NSColor(red: 0.94, green: 0.42, blue: 0.42, alpha: 1), // Red
        NSColor(red: 0.26, green: 0.76, blue: 0.53, alpha: 1), // Green
        NSColor(red: 0.96, green: 0.65, blue: 0.14, alpha: 1), // Orange
        NSColor(red: 0.67, green: 0.44, blue: 0.86, alpha: 1), // Purple
        NSColor(red: 0.87, green: 0.36, blue: 0.58, alpha: 1), // Pink
        NSColor(red: 0.27, green: 0.71, blue: 0.73, alpha: 1), // Teal
    ]

    override init() {
        // Avatar circle (real layer-backed circle)
        avatarCircle = NSView()
        avatarCircle.wantsLayer = true
        avatarCircle.layer?.cornerRadius = 20

        // Action buttons with SF Symbols
        replyButton = CursorButton(image: NSImage(systemSymbolName: "arrowshape.turn.up.left.fill", accessibilityDescription: "Reply")!, target: nil, action: nil)
        forwardButton = CursorButton(image: NSImage(systemSymbolName: "arrowshape.turn.up.right.fill", accessibilityDescription: "Forward")!, target: nil, action: nil)
        archiveButton = CursorButton(image: NSImage(systemSymbolName: "archivebox.fill", accessibilityDescription: "Archive")!, target: nil, action: nil)
        deleteButton = CursorButton(image: NSImage(systemSymbolName: "trash.fill", accessibilityDescription: "Delete")!, target: nil, action: nil)
        moveButton = CursorButton(image: NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Move to Folder")!, target: nil, action: nil)

        for btn in [replyButton, forwardButton, archiveButton, deleteButton, moveButton] {
            btn.bezelStyle = .accessoryBarAction
            btn.isBordered = false
            btn.contentTintColor = .labelColor
            btn.widthAnchor.constraint(equalToConstant: 28).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }

        viewSourceButton = CursorButton(image: NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: "View Source")!, target: nil, action: nil)
        viewSourceButton.bezelStyle = .accessoryBarAction
        viewSourceButton.isBordered = false
        viewSourceButton.contentTintColor = .labelColor
        viewSourceButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        viewSourceButton.heightAnchor.constraint(equalToConstant: 28).isActive = true

        actionBar = NSStackView(views: [replyButton, forwardButton, archiveButton, deleteButton, moveButton, viewSourceButton])
        actionBar.spacing = 4

        // Attachment bar
        attachmentBar = NSStackView()
        attachmentBar.orientation = .horizontal
        attachmentBar.spacing = 8
        attachmentBar.isHidden = true

        // Body
        bodyTextView = LinkCursorTextView()
        bodyTextView.isEditable = false
        bodyTextView.isSelectable = true
        bodyTextView.isRichText = true
        bodyTextView.textContainerInset = NSSize(width: 0, height: 0)
        bodyTextView.textContainer?.widthTracksTextView = true
        bodyTextView.isAutomaticLinkDetectionEnabled = true
        bodyTextView.drawsBackground = false
        bodyTextView.linkTextAttributes = [
            .foregroundColor: NSColor.controlAccentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]

        bodyScrollView = NSScrollView()
        bodyScrollView.documentView = bodyTextView
        bodyScrollView.hasVerticalScroller = true
        bodyScrollView.autohidesScrollers = true
        bodyScrollView.drawsBackground = false

        view = NSView()
        view.wantsLayer = true

        super.init()

        replyButton.target = self; replyButton.action = #selector(replyClicked)
        forwardButton.target = self; forwardButton.action = #selector(forwardClicked)
        archiveButton.target = self; archiveButton.action = #selector(archiveClicked)
        deleteButton.target = self; deleteButton.action = #selector(deleteClicked)
        moveButton.target = self; moveButton.action = #selector(moveClicked)
        viewSourceButton.target = self; viewSourceButton.action = #selector(viewSourceClicked)

        setupLayout()
        showEmpty()
    }

    // MARK: - Layout

    private func setupLayout() {
        let allViews: [NSView] = [
            subjectLabel, avatarCircle, avatarLabel, senderLabel, dateLabel,
            recipientLabel, actionBar, headerSeparator, attachmentBar, bodyScrollView, emptyContainer,
            summaryContainer,
        ]
        for v in allViews {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }

        // Subject: 22pt bold
        subjectLabel.font = .systemFont(ofSize: 22, weight: .bold)
        subjectLabel.lineBreakMode = .byWordWrapping
        subjectLabel.maximumNumberOfLines = 2
        subjectLabel.textColor = .labelColor

        // Avatar
        avatarLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        avatarLabel.alignment = .center
        avatarLabel.textColor = .white
        avatarLabel.backgroundColor = .clear
        avatarLabel.isBordered = false
        avatarLabel.isEditable = false
        avatarLabel.drawsBackground = false

        // Sender: bold, inline with date
        senderLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        senderLabel.textColor = .labelColor
        senderLabel.lineBreakMode = .byTruncatingTail

        // Date: secondary, relative
        dateLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        dateLabel.textColor = .secondaryLabelColor

        // Recipients
        recipientLabel.font = .systemFont(ofSize: 12)
        recipientLabel.textColor = .secondaryLabelColor
        recipientLabel.lineBreakMode = .byTruncatingTail

        // Separator
        headerSeparator.boxType = .separator

        // Empty state
        emptyIcon.image = NSImage(systemSymbolName: "envelope.open", accessibilityDescription: nil)
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyIcon.symbolConfiguration = .init(pointSize: 40, weight: .ultraLight)
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false

        emptyTitle.font = .systemFont(ofSize: 18, weight: .medium)
        emptyTitle.textColor = .secondaryLabelColor
        emptyTitle.alignment = .center
        emptyTitle.translatesAutoresizingMaskIntoConstraints = false

        emptySubtitle.font = .systemFont(ofSize: 12)
        emptySubtitle.textColor = .tertiaryLabelColor
        emptySubtitle.alignment = .center
        emptySubtitle.maximumNumberOfLines = 3
        emptySubtitle.translatesAutoresizingMaskIntoConstraints = false

        emptyContainer.addSubview(emptyIcon)
        emptyContainer.addSubview(emptyTitle)
        emptyContainer.addSubview(emptySubtitle)

        NSLayoutConstraint.activate([
            emptyIcon.centerXAnchor.constraint(equalTo: emptyContainer.centerXAnchor),
            emptyIcon.centerYAnchor.constraint(equalTo: emptyContainer.centerYAnchor, constant: -40),
            emptyIcon.widthAnchor.constraint(equalToConstant: 48),
            emptyIcon.heightAnchor.constraint(equalToConstant: 48),
            emptyTitle.topAnchor.constraint(equalTo: emptyIcon.bottomAnchor, constant: 12),
            emptyTitle.centerXAnchor.constraint(equalTo: emptyContainer.centerXAnchor),
            emptySubtitle.topAnchor.constraint(equalTo: emptyTitle.bottomAnchor, constant: 6),
            emptySubtitle.centerXAnchor.constraint(equalTo: emptyContainer.centerXAnchor),
            emptySubtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 250),
        ])

        // Bulk summary state
        summaryIcon.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        summaryIcon.contentTintColor = .tertiaryLabelColor
        summaryIcon.symbolConfiguration = .init(pointSize: 40, weight: .ultraLight)
        summaryIcon.translatesAutoresizingMaskIntoConstraints = false

        summaryTitle.font = .systemFont(ofSize: 18, weight: .medium)
        summaryTitle.textColor = .secondaryLabelColor
        summaryTitle.alignment = .center
        summaryTitle.translatesAutoresizingMaskIntoConstraints = false

        summaryList.font = .systemFont(ofSize: 12)
        summaryList.textColor = .tertiaryLabelColor
        summaryList.alignment = .center
        summaryList.maximumNumberOfLines = 6
        summaryList.lineBreakMode = .byWordWrapping
        summaryList.translatesAutoresizingMaskIntoConstraints = false

        summaryContainer.addSubview(summaryIcon)
        summaryContainer.addSubview(summaryTitle)
        summaryContainer.addSubview(summaryList)
        summaryContainer.isHidden = true

        NSLayoutConstraint.activate([
            summaryIcon.centerXAnchor.constraint(equalTo: summaryContainer.centerXAnchor),
            summaryIcon.centerYAnchor.constraint(equalTo: summaryContainer.centerYAnchor, constant: -50),
            summaryIcon.widthAnchor.constraint(equalToConstant: 48),
            summaryIcon.heightAnchor.constraint(equalToConstant: 48),
            summaryTitle.topAnchor.constraint(equalTo: summaryIcon.bottomAnchor, constant: 12),
            summaryTitle.centerXAnchor.constraint(equalTo: summaryContainer.centerXAnchor),
            summaryList.topAnchor.constraint(equalTo: summaryTitle.bottomAnchor, constant: 10),
            summaryList.centerXAnchor.constraint(equalTo: summaryContainer.centerXAnchor),
            summaryList.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
        ])

        // Main layout
        NSLayoutConstraint.activate([
            // Subject
            subjectLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            subjectLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            subjectLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),

            // Action bar (right-aligned, same line as subject top)
            actionBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            actionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),

            // Avatar
            avatarCircle.topAnchor.constraint(equalTo: subjectLabel.bottomAnchor, constant: 16),
            avatarCircle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            avatarCircle.widthAnchor.constraint(equalToConstant: 40),
            avatarCircle.heightAnchor.constraint(equalToConstant: 40),
            avatarLabel.centerXAnchor.constraint(equalTo: avatarCircle.centerXAnchor),
            avatarLabel.centerYAnchor.constraint(equalTo: avatarCircle.centerYAnchor),

            // Sender + date on one line
            senderLabel.topAnchor.constraint(equalTo: avatarCircle.topAnchor, constant: 2),
            senderLabel.leadingAnchor.constraint(equalTo: avatarCircle.trailingAnchor, constant: 12),
            dateLabel.centerYAnchor.constraint(equalTo: senderLabel.centerYAnchor),
            dateLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            senderLabel.trailingAnchor.constraint(lessThanOrEqualTo: dateLabel.leadingAnchor, constant: -12),

            // Recipients below sender
            recipientLabel.topAnchor.constraint(equalTo: senderLabel.bottomAnchor, constant: 2),
            recipientLabel.leadingAnchor.constraint(equalTo: senderLabel.leadingAnchor),
            recipientLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),

            // Separator
            headerSeparator.topAnchor.constraint(equalTo: avatarCircle.bottomAnchor, constant: 16),
            headerSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            headerSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),

            // Attachment bar (below header separator, hidden when no attachments)
            attachmentBar.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor, constant: 8),
            attachmentBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            attachmentBar.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28),

            // Body
            bodyScrollView.topAnchor.constraint(equalTo: attachmentBar.bottomAnchor, constant: 8),
            bodyScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            bodyScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            bodyScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),

            // Empty state
            emptyContainer.topAnchor.constraint(equalTo: view.topAnchor),
            emptyContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Bulk summary state
            summaryContainer.topAnchor.constraint(equalTo: view.topAnchor),
            summaryContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summaryContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            summaryContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Display

    func display(header: EmailHeader, body: EmailBody?, isLoading: Bool = false) {
        emptyContainer.isHidden = true
        summaryContainer.isHidden = true
        for v in [subjectLabel, avatarCircle, avatarLabel, senderLabel, dateLabel, recipientLabel, actionBar, headerSeparator, bodyScrollView] as [NSView] {
            v.isHidden = false
        }

        // Subject
        subjectLabel.stringValue = header.subject ?? "(no subject)"

        // Sender
        let displayName = header.senderName ?? header.senderEmail
        senderLabel.stringValue = displayName

        // Date (relative)
        dateLabel.stringValue = Self.relativeDate(header.date)

        // Recipients
        recipientLabel.stringValue = "to me"

        // Avatar (gradient circle with initials)
        let initials = displayName.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        avatarLabel.stringValue = initials.isEmpty ? "?" : initials
        let color = Self.avatarColor(for: header.senderEmail)
        avatarCircle.layer?.backgroundColor = color.cgColor

        // Store raw source
        rawSource = body?.htmlBody ?? body?.textBody

        // Body rendering
        if let htmlBody = body?.htmlBody, !htmlBody.isEmpty {
            // Use WKWebView for HTML emails (renders images, CSS, etc.)
            bodyTextView.isHidden = true
            bodyScrollView.isHidden = true
            showWebView(html: htmlBody)
        } else if let textBody = body?.textBody, !textBody.isEmpty {
            hideWebView()
            bodyTextView.isHidden = false
            bodyScrollView.isHidden = false
            bodyTextView.textStorage?.setAttributedString(Self.renderPlainText(textBody))
            bodyTextView.scrollToBeginningOfDocument(nil)
        } else if isLoading {
            hideWebView()
            bodyTextView.isHidden = false
            bodyScrollView.isHidden = false
            let loadingAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            bodyTextView.textStorage?.setAttributedString(NSAttributedString(string: "Loading…", attributes: loadingAttrs))
        } else {
            hideWebView()
            bodyTextView.isHidden = false
            bodyScrollView.isHidden = false
            bodyTextView.textStorage?.setAttributedString(Self.renderPlainText("(no content)"))
        }
    }

    /// Show attachment chips below the header.
    func displayAttachments(_ attachments: [AttachmentInfo]) {
        currentAttachments = attachments
        // Clear old chips
        attachmentBar.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard !attachments.isEmpty else {
            attachmentBar.isHidden = true
            return
        }
        attachmentBar.isHidden = false

        for (index, att) in attachments.enumerated() {
            let icon = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil) ?? NSImage()
            let name = att.filename ?? "Attachment"
            let sizeStr = att.sizeBytes.map { Self.formatFileSize($0) } ?? ""
            let title = sizeStr.isEmpty ? name : "\(name) (\(sizeStr))"

            let chip = CursorButton(title: title, target: self, action: #selector(attachmentChipClicked(_:)))
            chip.image = icon
            chip.imagePosition = .imageLeading
            chip.bezelStyle = .accessoryBarAction
            chip.font = .systemFont(ofSize: 11)
            chip.tag = index
            attachmentBar.addArrangedSubview(chip)
        }
    }

    @objc private func attachmentChipClicked(_ sender: NSButton) {
        let index = sender.tag
        guard index >= 0, index < currentAttachments.count else { return }
        onDownloadAttachment?(currentAttachments[index])
    }

    func clear() { showEmpty() }

    private func showEmpty() {
        emptyContainer.isHidden = false
        summaryContainer.isHidden = true
        for v in [subjectLabel, avatarCircle, avatarLabel, senderLabel, dateLabel, recipientLabel, actionBar, headerSeparator, bodyScrollView] as [NSView] {
            v.isHidden = true
        }
    }

    /// Show bulk selection summary for the given email headers.
    func showBulkSummary(headers: [EmailHeader]) {
        let count = headers.count
        summaryTitle.stringValue = "\(count) conversation\(count == 1 ? "" : "s") selected"

        let preview = headers.prefix(5).map { h -> String in
            let sender = h.senderName ?? h.senderEmail
            let subject = h.subject ?? "(no subject)"
            return "\(sender) — \(subject)"
        }.joined(separator: "\n")
        summaryList.stringValue = preview

        summaryContainer.isHidden = false
        emptyContainer.isHidden = true
        for v in [subjectLabel, avatarCircle, avatarLabel, senderLabel, dateLabel, recipientLabel, actionBar, headerSeparator, bodyScrollView] as [NSView] {
            v.isHidden = true
        }
        hideWebView()
    }

    /// Hide the bulk selection summary (email content shown by normal display flow).
    func hideBulkSummary() {
        summaryContainer.isHidden = true
    }

    // MARK: - WebView

    private func showWebView(html: String) {
        if webView == nil {
            let config = WKWebViewConfiguration()
            config.preferences.isElementFullscreenEnabled = false
            let wv = WKWebView(frame: .zero, configuration: config)
            wv.translatesAutoresizingMaskIntoConstraints = false
            wv.navigationDelegate = self
            // White background — emails are designed for light backgrounds (like Apple Mail)
            wv.setValue(true, forKey: "drawsBackground")
            view.addSubview(wv)
            NSLayoutConstraint.activate([
                wv.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor, constant: 8),
                wv.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
                wv.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
                wv.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
            ])
            webView = wv
        }

        // Minimal CSS wrapper — preserve original email design (like Apple Mail).
        // Don't force dark mode on emails: most HTML emails are designed for light backgrounds.
        // Only add light safety defaults; let the email's own CSS take priority.
        let styledHTML = """
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <style>
        body { font-family: -apple-system, SF Pro, system-ui, sans-serif; font-size: 15px;
               line-height: 1.65; margin: 16px; word-wrap: break-word;
               color: #222; background: #fff; }
        a { color: #0066cc; }
        img { max-width: 100%; height: auto; }
        blockquote { margin: 8px 0; padding-left: 12px;
                     border-left: 3px solid #ddd; color: #666; }
        pre, code { padding: 2px 6px; border-radius: 4px; font-size: 13px;
                    background: #f5f5f5; }
        </style></head><body>\(html)</body></html>
        """

        webView?.stopLoading()
        webView?.loadHTMLString(styledHTML, baseURL: nil)
        webView?.isHidden = false
    }

    private func hideWebView() {
        webView?.stopLoading()
        webView?.isHidden = true
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Allow initial load; open all link clicks in the default browser
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    // MARK: - View Source

    func viewSource() {
        guard let source = rawSource else { return }
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        panel.title = "Email Source"
        panel.center()

        let textView = NSTextView()
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = source
        textView.textColor = .labelColor

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        panel.contentView = scroll
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - Actions

    @objc private func replyClicked() { onReply?() }
    @objc private func forwardClicked() { onForward?() }
    @objc private func archiveClicked() { onArchive?() }
    @objc private func deleteClicked() { onDelete?() }
    @objc private func viewSourceClicked() { viewSource() }

    func printEmail() {
        if let wv = webView, !wv.isHidden {
            let printInfo = NSPrintInfo.shared
            let printOp = wv.printOperation(with: printInfo)
            printOp.showsPrintPanel = true
            printOp.showsProgressPanel = true
            printOp.run()
        } else {
            let printInfo = NSPrintInfo.shared
            let printOp = NSPrintOperation(view: bodyScrollView, printInfo: printInfo)
            printOp.showsPrintPanel = true
            printOp.run()
        }
    }

    @objc private func moveClicked() {
        guard !availableFolders.isEmpty else { return }
        let menu = NSMenu()
        for folder in availableFolders {
            let item = NSMenuItem(title: folder.name, action: #selector(moveFolderSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = folder.id
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moveButton.bounds.height), in: moveButton)
    }

    @objc private func moveFolderSelected(_ sender: NSMenuItem) {
        guard let folderId = sender.representedObject as? String else { return }
        onMove?(folderId)
    }

    // MARK: - Text Rendering

    private static func htmlToAttributedString(_ html: String) -> NSAttributedString {
        guard let data = html.data(using: .utf8) else {
            return renderPlainText(html)
        }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]

        guard let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return renderPlainText(html)
        }

        let mutable = NSMutableAttributedString(attributedString: attributed)
        let fullRange = NSRange(location: 0, length: mutable.length)

        // Restyle fonts to SF Pro with proper sizing
        mutable.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let traits = font.fontDescriptor.symbolicTraits
            let size: CGFloat = 15
            let newFont: NSFont
            if traits.contains(.bold) && traits.contains(.italic) {
                newFont = NSFont.systemFont(ofSize: size, weight: .semibold) // No italic variant easily
            } else if traits.contains(.bold) {
                newFont = .systemFont(ofSize: size, weight: .semibold)
            } else if traits.contains(.italic) {
                newFont = NSFontManager.shared.convert(.systemFont(ofSize: size), toHaveTrait: .italicFontMask)
            } else {
                newFont = .systemFont(ofSize: size)
            }
            mutable.addAttribute(.font, value: newFont, range: range)
        }

        // Proper line height
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 5
        paragraphStyle.paragraphSpacing = 10
        mutable.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)

        // Link styling
        mutable.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            if value != nil {
                mutable.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: range)
            }
        }

        return mutable
    }

    /// Renders plain text with quote detection.
    /// Lines starting with > get a left border + dimmed color (reply style).
    private static func renderPlainText(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")

        let normalStyle = NSMutableParagraphStyle()
        normalStyle.lineSpacing = 5
        normalStyle.paragraphSpacing = 6

        let quoteStyle = NSMutableParagraphStyle()
        quoteStyle.lineSpacing = 4
        quoteStyle.paragraphSpacing = 2
        quoteStyle.headIndent = 16
        quoteStyle.firstLineHeadIndent = 16

        let normalAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: normalStyle,
        ]

        let quoteAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: quoteStyle,
        ]

        for (i, line) in lines.enumerated() {
            let isQuote = line.hasPrefix(">")
            let cleanLine = isQuote ? String(line.dropFirst().trimmingCharacters(in: .whitespaces)) : line
            let attrs = isQuote ? quoteAttrs : normalAttrs
            result.append(NSAttributedString(string: cleanLine, attributes: attrs))
            if i < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: attrs))
            }
        }

        return result
    }

    // MARK: - Helpers

    private static func relativeDate(_ date: Date) -> String {
        let now = Date()
        let seconds = now.timeIntervalSince(date)

        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        if seconds < 172800 { return "Yesterday" }
        if seconds < 604800 { return "\(Int(seconds / 86400))d ago" }

        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    private static func formatFileSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    private static func avatarColor(for email: String) -> NSColor {
        let hash = abs(email.hashValue)
        return avatarColors[hash % avatarColors.count]
    }
}
