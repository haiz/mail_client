import AppKit
import WebKit

/// Renders a single email as a card — either collapsed (one-line summary)
/// or expanded (full header + body + action buttons).
final class MessageCardView: NSObject {

    let view: NSView
    private let header: EmailHeader
    private(set) var isExpanded: Bool

    /// The email ID this card displays.
    var emailId: Int64 { header.id }

    // Collapsed state views
    private let avatarCircle = NSView()
    private let avatarLabel = NSTextField(labelWithString: "")
    private let senderLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let snippetLabel = NSTextField(labelWithString: "")
    private let attachmentIcon = NSImageView()
    private let collapsedContainer = NSView()

    // Expanded state views
    private let expandedContainer = NSView()
    private let expAvatarCircle = NSView()
    private let expAvatarLabel = NSTextField(labelWithString: "")
    private let expSenderLabel = NSTextField(labelWithString: "")
    private let expDateLabel = NSTextField(labelWithString: "")
    private let expRecipientLabel = NSTextField(labelWithString: "")
    private let headerSeparator = NSBox()
    private let attachmentBar = NSStackView()
    private let bodyTextView: NSTextView
    private let bodyScrollView: NSScrollView
    private(set) var webView: WKWebView?
    private let actionBar = NSStackView()
    private let replyButton: NSButton
    private let moreButton: NSButton

    // Body cache
    private(set) var cachedBody: EmailBody?
    private var isLoadingBody = false

    // Height constraint for expand/collapse animation
    private var collapsedHeightConstraint: NSLayoutConstraint!
    private var expandedTopConstraint: NSLayoutConstraint!

    // Callbacks
    var onToggleExpand: (() -> Void)?
    var onReply: ((EmailHeader, EmailBody?) -> Void)?
    var onForward: ((EmailHeader, EmailBody?) -> Void)?
    var onArchive: ((Int64) -> Void)?
    var onDelete: ((Int64) -> Void)?
    var onMove: ((Int64, String) -> Void)?
    var onDownloadAttachment: ((AttachmentInfo) -> Void)?
    var onRequestBody: ((Int64) -> Void)?

    /// Available folders for the Move menu.
    var availableFolders: [MailFolder] = []

    // Avatar colors (same as old DetailView)
    private static let avatarColors: [NSColor] = [
        NSColor(red: 0.35, green: 0.56, blue: 0.97, alpha: 1),
        NSColor(red: 0.94, green: 0.42, blue: 0.42, alpha: 1),
        NSColor(red: 0.26, green: 0.76, blue: 0.53, alpha: 1),
        NSColor(red: 0.96, green: 0.65, blue: 0.14, alpha: 1),
        NSColor(red: 0.67, green: 0.44, blue: 0.86, alpha: 1),
        NSColor(red: 0.87, green: 0.36, blue: 0.58, alpha: 1),
        NSColor(red: 0.27, green: 0.71, blue: 0.73, alpha: 1),
    ]

    init(header: EmailHeader, isExpanded: Bool) {
        self.header = header
        self.isExpanded = isExpanded

        view = NSView()
        view.wantsLayer = true

        // Collapsed avatar
        avatarCircle.wantsLayer = true
        avatarCircle.layer?.cornerRadius = 16

        // Expanded avatar
        expAvatarCircle.wantsLayer = true
        expAvatarCircle.layer?.cornerRadius = 20

        // Body text view
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
        bodyScrollView.hasVerticalScroller = false
        bodyScrollView.drawsBackground = false

        // Action buttons
        replyButton = CursorButton(
            image: NSImage(systemSymbolName: "arrowshape.turn.up.left.fill",
                           accessibilityDescription: "Reply")!,
            target: nil, action: nil
        )
        moreButton = CursorButton(
            image: NSImage(systemSymbolName: "ellipsis",
                           accessibilityDescription: "More Actions")!,
            target: nil, action: nil
        )

        for btn in [replyButton, moreButton] {
            btn.bezelStyle = .accessoryBarAction
            btn.isBordered = false
            btn.contentTintColor = .labelColor
            btn.widthAnchor.constraint(equalToConstant: 28).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }

        super.init()

        replyButton.target = self
        replyButton.action = #selector(replyClicked)
        moreButton.target = self
        moreButton.action = #selector(moreClicked)

        setupCollapsedLayout()
        setupExpandedLayout()
        configureContent()
        updateVisibility()
    }

    // MARK: - Collapsed Layout

    private func setupCollapsedLayout() {
        let views: [NSView] = [avatarCircle, avatarLabel, senderLabel, dateLabel, snippetLabel, attachmentIcon]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            collapsedContainer.addSubview(v)
        }
        collapsedContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collapsedContainer)

        avatarLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        avatarLabel.alignment = .center
        avatarLabel.textColor = .white

        senderLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        senderLabel.lineBreakMode = .byTruncatingTail

        dateLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        dateLabel.textColor = .secondaryLabelColor
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        snippetLabel.font = .systemFont(ofSize: 12)
        snippetLabel.textColor = .tertiaryLabelColor
        snippetLabel.lineBreakMode = .byTruncatingTail

        attachmentIcon.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Has attachments")
        attachmentIcon.contentTintColor = .tertiaryLabelColor
        attachmentIcon.symbolConfiguration = .init(pointSize: 10, weight: .regular)

        collapsedHeightConstraint = collapsedContainer.heightAnchor.constraint(equalToConstant: 44)

        // Click gesture on collapsed container
        let click = NSClickGestureRecognizer(target: self, action: #selector(cardClicked))
        collapsedContainer.addGestureRecognizer(click)

        NSLayoutConstraint.activate([
            collapsedContainer.topAnchor.constraint(equalTo: view.topAnchor),
            collapsedContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collapsedContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collapsedHeightConstraint,

            avatarCircle.leadingAnchor.constraint(equalTo: collapsedContainer.leadingAnchor, constant: 12),
            avatarCircle.centerYAnchor.constraint(equalTo: collapsedContainer.centerYAnchor),
            avatarCircle.widthAnchor.constraint(equalToConstant: 32),
            avatarCircle.heightAnchor.constraint(equalToConstant: 32),
            avatarLabel.centerXAnchor.constraint(equalTo: avatarCircle.centerXAnchor),
            avatarLabel.centerYAnchor.constraint(equalTo: avatarCircle.centerYAnchor),

            senderLabel.topAnchor.constraint(equalTo: collapsedContainer.topAnchor, constant: 6),
            senderLabel.leadingAnchor.constraint(equalTo: avatarCircle.trailingAnchor, constant: 10),
            senderLabel.trailingAnchor.constraint(lessThanOrEqualTo: dateLabel.leadingAnchor, constant: -8),

            dateLabel.centerYAnchor.constraint(equalTo: senderLabel.centerYAnchor),
            dateLabel.trailingAnchor.constraint(equalTo: attachmentIcon.leadingAnchor, constant: -4),

            attachmentIcon.centerYAnchor.constraint(equalTo: senderLabel.centerYAnchor),
            attachmentIcon.trailingAnchor.constraint(equalTo: collapsedContainer.trailingAnchor, constant: -12),
            attachmentIcon.widthAnchor.constraint(equalToConstant: 14),
            attachmentIcon.heightAnchor.constraint(equalToConstant: 14),

            snippetLabel.topAnchor.constraint(equalTo: senderLabel.bottomAnchor, constant: 1),
            snippetLabel.leadingAnchor.constraint(equalTo: senderLabel.leadingAnchor),
            snippetLabel.trailingAnchor.constraint(equalTo: collapsedContainer.trailingAnchor, constant: -12),
        ])
    }

    // MARK: - Expanded Layout

    private func setupExpandedLayout() {
        let views: [NSView] = [expAvatarCircle, expAvatarLabel, expSenderLabel, expDateLabel,
                               expRecipientLabel, headerSeparator, attachmentBar, bodyScrollView, actionBar]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            expandedContainer.addSubview(v)
        }
        expandedContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(expandedContainer)

        expAvatarLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        expAvatarLabel.alignment = .center
        expAvatarLabel.textColor = .white

        expSenderLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        expSenderLabel.lineBreakMode = .byTruncatingTail

        expDateLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        expDateLabel.textColor = .secondaryLabelColor

        expRecipientLabel.font = .systemFont(ofSize: 12)
        expRecipientLabel.textColor = .secondaryLabelColor
        expRecipientLabel.lineBreakMode = .byTruncatingTail

        headerSeparator.boxType = .separator

        attachmentBar.orientation = .horizontal
        attachmentBar.spacing = 8
        attachmentBar.isHidden = true

        actionBar.addArrangedSubview(replyButton)
        actionBar.addArrangedSubview(moreButton)
        actionBar.spacing = 4

        // Click gesture on expanded header area (avatar + sender + date)
        let headerClick = NSClickGestureRecognizer(target: self, action: #selector(cardClicked))
        expAvatarCircle.addGestureRecognizer(headerClick)
        let senderClick = NSClickGestureRecognizer(target: self, action: #selector(cardClicked))
        expSenderLabel.addGestureRecognizer(senderClick)

        expandedTopConstraint = expandedContainer.topAnchor.constraint(equalTo: view.topAnchor)

        NSLayoutConstraint.activate([
            expandedTopConstraint,
            expandedContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            expandedContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            expandedContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            expAvatarCircle.topAnchor.constraint(equalTo: expandedContainer.topAnchor, constant: 12),
            expAvatarCircle.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor, constant: 12),
            expAvatarCircle.widthAnchor.constraint(equalToConstant: 40),
            expAvatarCircle.heightAnchor.constraint(equalToConstant: 40),
            expAvatarLabel.centerXAnchor.constraint(equalTo: expAvatarCircle.centerXAnchor),
            expAvatarLabel.centerYAnchor.constraint(equalTo: expAvatarCircle.centerYAnchor),

            expSenderLabel.topAnchor.constraint(equalTo: expAvatarCircle.topAnchor, constant: 2),
            expSenderLabel.leadingAnchor.constraint(equalTo: expAvatarCircle.trailingAnchor, constant: 12),
            expSenderLabel.trailingAnchor.constraint(lessThanOrEqualTo: expDateLabel.leadingAnchor, constant: -12),

            expDateLabel.centerYAnchor.constraint(equalTo: expSenderLabel.centerYAnchor),
            expDateLabel.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor, constant: -12),

            expRecipientLabel.topAnchor.constraint(equalTo: expSenderLabel.bottomAnchor, constant: 2),
            expRecipientLabel.leadingAnchor.constraint(equalTo: expSenderLabel.leadingAnchor),
            expRecipientLabel.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor, constant: -12),

            headerSeparator.topAnchor.constraint(equalTo: expAvatarCircle.bottomAnchor, constant: 12),
            headerSeparator.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor, constant: 12),
            headerSeparator.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor, constant: -12),

            attachmentBar.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor, constant: 8),
            attachmentBar.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor, constant: 12),
            attachmentBar.trailingAnchor.constraint(lessThanOrEqualTo: expandedContainer.trailingAnchor, constant: -12),

            bodyScrollView.topAnchor.constraint(equalTo: attachmentBar.bottomAnchor, constant: 8),
            bodyScrollView.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor, constant: 12),
            bodyScrollView.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor, constant: -12),

            actionBar.topAnchor.constraint(equalTo: bodyScrollView.bottomAnchor, constant: 8),
            actionBar.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor, constant: -12),
            actionBar.bottomAnchor.constraint(equalTo: expandedContainer.bottomAnchor, constant: -8),
        ])
    }

    // MARK: - Content

    private func configureContent() {
        let displayName = header.senderName ?? header.senderEmail
        let initials = displayName.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        let color = Self.avatarColor(for: header.senderEmail)

        // Collapsed
        avatarLabel.stringValue = initials.isEmpty ? "?" : initials
        avatarCircle.layer?.backgroundColor = color.cgColor
        senderLabel.stringValue = displayName
        senderLabel.font = header.isRead ? .systemFont(ofSize: 13) : .systemFont(ofSize: 13, weight: .semibold)
        senderLabel.textColor = header.isRead ? .secondaryLabelColor : .labelColor
        dateLabel.stringValue = Self.relativeDate(header.date)
        snippetLabel.stringValue = header.snippet ?? ""
        attachmentIcon.isHidden = !header.hasAttachments

        // Expanded
        expAvatarLabel.stringValue = initials.isEmpty ? "?" : initials
        expAvatarCircle.layer?.backgroundColor = color.cgColor
        expSenderLabel.stringValue = displayName
        expDateLabel.stringValue = Self.relativeDate(header.date)
        expRecipientLabel.stringValue = "to me"
    }

    // MARK: - Expand / Collapse

    private func updateVisibility() {
        collapsedContainer.isHidden = isExpanded
        expandedContainer.isHidden = !isExpanded
    }

    func setExpanded(_ expanded: Bool, animated: Bool = true) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded

        if !expanded {
            // Release WebView on collapse to free memory
            webView?.stopLoading()
            webView?.removeFromSuperview()
            webView = nil
        }

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.allowsImplicitAnimation = true
                updateVisibility()
                view.superview?.layoutSubtreeIfNeeded()
            }
        } else {
            updateVisibility()
        }
    }

    @objc private func cardClicked() {
        onToggleExpand?()
    }

    // MARK: - Body Display

    func displayBody(_ body: EmailBody?) {
        cachedBody = body
        isLoadingBody = false

        if let htmlBody = body?.htmlBody, !htmlBody.isEmpty {
            bodyTextView.isHidden = true
            bodyScrollView.isHidden = true
            showWebView(html: htmlBody)
        } else if let textBody = body?.textBody, !textBody.isEmpty {
            hideWebView()
            bodyTextView.isHidden = false
            bodyScrollView.isHidden = false
            bodyTextView.textStorage?.setAttributedString(Self.renderPlainText(textBody))
        } else {
            hideWebView()
            bodyTextView.isHidden = false
            bodyScrollView.isHidden = false
            bodyTextView.textStorage?.setAttributedString(Self.renderPlainText("(no content)"))
        }
    }

    func showLoading() {
        isLoadingBody = true
        hideWebView()
        bodyTextView.isHidden = false
        bodyScrollView.isHidden = false
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        bodyTextView.textStorage?.setAttributedString(NSAttributedString(string: "Loading\u{2026}", attributes: attrs))
    }

    // MARK: - Attachments

    func displayAttachments(_ attachments: [AttachmentInfo]) {
        currentAttachments = attachments
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

    // MARK: - Actions

    @objc private func replyClicked() {
        onReply?(header, cachedBody)
    }

    @objc private func moreClicked() {
        let menu = NSMenu()
        let forwardItem = NSMenuItem(title: "Forward", action: #selector(forwardClicked), keyEquivalent: "")
        forwardItem.target = self
        menu.addItem(forwardItem)

        menu.addItem(.separator())

        let archiveItem = NSMenuItem(title: "Archive", action: #selector(archiveClicked), keyEquivalent: "")
        archiveItem.target = self
        menu.addItem(archiveItem)

        let deleteItem = NSMenuItem(title: "Delete", action: #selector(deleteClicked), keyEquivalent: "")
        deleteItem.target = self
        menu.addItem(deleteItem)

        if !availableFolders.isEmpty {
            let moveItem = NSMenuItem(title: "Move to...", action: nil, keyEquivalent: "")
            let moveSubmenu = NSMenu()
            for folder in availableFolders {
                let folderItem = NSMenuItem(title: folder.name, action: #selector(moveFolderSelected(_:)), keyEquivalent: "")
                folderItem.target = self
                folderItem.representedObject = folder.id
                moveSubmenu.addItem(folderItem)
            }
            moveItem.submenu = moveSubmenu
            menu.addItem(moveItem)
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.height), in: moreButton)
    }

    @objc private func forwardClicked() { onForward?(header, cachedBody) }
    @objc private func archiveClicked() { onArchive?(header.id) }
    @objc private func deleteClicked() { onDelete?(header.id) }

    @objc private func moveFolderSelected(_ sender: NSMenuItem) {
        guard let folderId = sender.representedObject as? String else { return }
        onMove?(header.id, folderId)
    }

    private var currentAttachments: [AttachmentInfo] = []

    @objc private func attachmentChipClicked(_ sender: NSButton) {
        let index = sender.tag
        guard index >= 0, index < currentAttachments.count else { return }
        onDownloadAttachment?(currentAttachments[index])
    }

    // MARK: - WebView

    private func showWebView(html: String) {
        if webView == nil {
            let config = WKWebViewConfiguration()
            config.preferences.isElementFullscreenEnabled = false
            let wv = WKWebView(frame: .zero, configuration: config)
            wv.translatesAutoresizingMaskIntoConstraints = false
            wv.setValue(true, forKey: "drawsBackground")
            expandedContainer.addSubview(wv)
            NSLayoutConstraint.activate([
                wv.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor, constant: 8),
                wv.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor, constant: 4),
                wv.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor, constant: -4),
                wv.bottomAnchor.constraint(equalTo: actionBar.topAnchor, constant: -8),
            ])
            webView = wv
        }

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
        bodyScrollView.isHidden = true
        bodyTextView.isHidden = true
    }

    private func hideWebView() {
        webView?.stopLoading()
        webView?.isHidden = true
    }

    // MARK: - Text Rendering

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
        let seconds = Date().timeIntervalSince(date)
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
