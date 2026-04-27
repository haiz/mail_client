import AppKit
import WebKit

/// Handles `cid:` URL scheme requests from WKWebView for inline email images.
/// Lazily fetches attachment data on first request and caches the result.
private final class CidSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    /// Maps content-id string → (emailId, partId) for lazy fetching.
    var contentIdToPartId: [String: (emailId: Int64, partId: String)] = [:]
    var cachedData: [String: Data] = [:]
    var fetchData: ((Int64, String) async throws -> Data)?

    private var stoppedTaskIds: Set<ObjectIdentifier> = []

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let taskId = ObjectIdentifier(urlSchemeTask as AnyObject)
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let rawCid = url.absoluteString
        let cid = (rawCid.hasPrefix("cid:") ? String(rawCid.dropFirst(4)) : rawCid)
            .removingPercentEncoding ?? rawCid

        if let data = cachedData[cid] {
            guard !stoppedTaskIds.contains(taskId) else { return }
            serveData(data, url: url, task: urlSchemeTask)
            return
        }
        guard let info = contentIdToPartId[cid], let fetch = fetchData else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        Task { @MainActor [weak self] in
            guard let self, !self.stoppedTaskIds.contains(taskId) else { return }
            do {
                let data = try await fetch(info.emailId, info.partId)
                guard !self.stoppedTaskIds.contains(taskId) else { return }
                self.cachedData[cid] = data
                self.serveData(data, url: url, task: urlSchemeTask)
            } catch {
                guard !self.stoppedTaskIds.contains(taskId) else { return }
                urlSchemeTask.didFailWithError(error)
            }
            self.stoppedTaskIds.remove(taskId)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        stoppedTaskIds.insert(ObjectIdentifier(urlSchemeTask as AnyObject))
    }

    private func serveData(_ data: Data, url: URL, task: any WKURLSchemeTask) {
        let mime: String
        if data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) { mime = "image/png" }
        else if data.prefix(2) == Data([0xFF, 0xD8]) { mime = "image/jpeg" }
        else if data.prefix(6) == Data("GIF89a".utf8) || data.prefix(6) == Data("GIF87a".utf8) { mime = "image/gif" }
        else { mime = "image/jpeg" }

        let response = URLResponse(url: url, mimeType: mime,
                                   expectedContentLength: data.count,
                                   textEncodingName: nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}

/// NSView subclass that accepts first responder for keyboard navigation
/// and forwards Enter/Space to the card's toggle-expand handler.
private final class MessageCardContainerView: NSView {
    var onKeyActivate: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { // Enter or Space
            onKeyActivate?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Renders a single email as a card — either collapsed (one-line summary)
/// or expanded (full header + body + action buttons).
final class MessageCardView: NSObject {

    let view: NSView
    private let header: EmailHeader
    private(set) var isExpanded: Bool
    private let accountEmail: String?

    /// The email ID this card displays.
    var emailId: Int64 { header.id }

    /// The full header for this card (used by ThreadDetailView for keyboard-shortcut reply).
    var messageHeader: EmailHeader { header }

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
    private let headerContainer = NSView()
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

    // Loading spinner
    private let loadingSpinner = NSProgressIndicator()

    // vCard / iCal preview container (added lazily above attachment bar)
    private var attachmentPreviewContainer: NSView?

    // Remote-image blocking banner
    private let imageBlockedBanner = NSView()
    private let imageBlockedLabel = NSTextField(labelWithString: "Images blocked for privacy.")
    private let showOnceButton: NSButton
    private let alwaysAllowButton: NSButton
    private var lastBlockedCount = 0

    // Body cache
    private(set) var cachedBody: EmailBody?
    private var isLoadingBody = false

    // Per-card body rendering override (nil = use global preference)
    private var renderingOverride: BodyRendering?

    // Height constraint for expand/collapse animation
    private var collapsedHeightConstraint: NSLayoutConstraint!
    private var expandedTopConstraint: NSLayoutConstraint!

    // cid: inline-image handler (one per card, reused across webview recreations)
    private let cidHandler = CidSchemeHandler()

    // Callbacks
    var onToggleExpand: (() -> Void)?
    var onReply: ((EmailHeader, EmailBody?) -> Void)?
    var onReplyAll: ((EmailHeader, EmailBody?) -> Void)?
    var onForward: ((EmailHeader, EmailBody?) -> Void)?
    var onArchive: ((Int64) -> Void)?
    var onDelete: ((Int64) -> Void)?
    var onMarkSpam: ((Int64) -> Void)?
    var onMove: ((Int64, String) -> Void)?
    var onSnooze: ((Int64, Date) -> Void)?
    var onDownloadAttachment: ((AttachmentInfo) -> Void)?
    var onRequestBody: ((Int64) -> Void)?
    var onFetchAttachmentData: ((Int64, String) async throws -> Data)?
    var onAllowImages: ((String) -> Void)?
    var onShowLabelPicker: ((NSView, Int64) -> Void)?

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

    init(header: EmailHeader, isExpanded: Bool, accountEmail: String? = nil) {
        self.header = header
        self.isExpanded = isExpanded
        self.accountEmail = accountEmail

        view = MessageCardContainerView()
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

        showOnceButton = CursorButton(title: "Show Images", target: nil, action: nil)
        showOnceButton.bezelStyle = .inline
        showOnceButton.font = .systemFont(ofSize: 11)

        alwaysAllowButton = CursorButton(title: "Always show from sender", target: nil, action: nil)
        alwaysAllowButton.bezelStyle = .inline
        alwaysAllowButton.font = .systemFont(ofSize: 11)

        super.init()

        cidHandler.fetchData = { [weak self] emailId, partId in
            guard let fetch = self?.onFetchAttachmentData else { throw URLError(.fileDoesNotExist) }
            return try await fetch(emailId, partId)
        }

        replyButton.target = self
        replyButton.action = #selector(replyClicked)
        moreButton.target = self
        moreButton.action = #selector(moreClicked)

        setupCollapsedLayout()
        setupExpandedLayout()
        configureContent()
        updateVisibility()

        // Set initial accessibility state on the container view
        let initDisplayName = header.senderName ?? header.senderEmail
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(isExpanded
            ? "Collapse message from \(initDisplayName)"
            : "Expand message from \(initDisplayName)")

        (view as? MessageCardContainerView)?.onKeyActivate = { [weak self] in
            self?.onToggleExpand?()
        }
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

        let displayName = header.senderName ?? header.senderEmail
        collapsedContainer.setAccessibilityRole(.button)
        collapsedContainer.setAccessibilityLabel("Expand message from \(displayName)")

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
        // Header views go into headerContainer
        let headerViews: [NSView] = [expAvatarCircle, expAvatarLabel, expSenderLabel, expDateLabel, expRecipientLabel]
        for v in headerViews {
            v.translatesAutoresizingMaskIntoConstraints = false
            headerContainer.addSubview(v)
        }
        headerContainer.translatesAutoresizingMaskIntoConstraints = false

        // Image blocked banner
        imageBlockedBanner.translatesAutoresizingMaskIntoConstraints = false
        imageBlockedBanner.isHidden = true

        imageBlockedLabel.font = .systemFont(ofSize: 11)
        imageBlockedLabel.textColor = .secondaryLabelColor
        imageBlockedLabel.translatesAutoresizingMaskIntoConstraints = false

        showOnceButton.translatesAutoresizingMaskIntoConstraints = false
        showOnceButton.target = self
        showOnceButton.action = #selector(showImagesOnce)

        alwaysAllowButton.translatesAutoresizingMaskIntoConstraints = false
        alwaysAllowButton.target = self
        alwaysAllowButton.action = #selector(alwaysAllowImages)

        imageBlockedBanner.addSubview(imageBlockedLabel)
        imageBlockedBanner.addSubview(showOnceButton)
        imageBlockedBanner.addSubview(alwaysAllowButton)

        NSLayoutConstraint.activate([
            imageBlockedLabel.leadingAnchor.constraint(equalTo: imageBlockedBanner.leadingAnchor),
            imageBlockedLabel.centerYAnchor.constraint(equalTo: imageBlockedBanner.centerYAnchor),

            showOnceButton.leadingAnchor.constraint(equalTo: imageBlockedLabel.trailingAnchor, constant: 8),
            showOnceButton.centerYAnchor.constraint(equalTo: imageBlockedBanner.centerYAnchor),

            alwaysAllowButton.leadingAnchor.constraint(equalTo: showOnceButton.trailingAnchor, constant: 4),
            alwaysAllowButton.centerYAnchor.constraint(equalTo: imageBlockedBanner.centerYAnchor),

            imageBlockedBanner.heightAnchor.constraint(equalToConstant: 28),
        ])

        // headerContainer + remaining views go into expandedContainer
        let containerViews: [NSView] = [headerContainer, headerSeparator, attachmentBar, imageBlockedBanner, bodyScrollView, actionBar, loadingSpinner]
        for v in containerViews {
            v.translatesAutoresizingMaskIntoConstraints = false
            expandedContainer.addSubview(v)
        }
        expandedContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(expandedContainer)

        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .small
        loadingSpinner.isHidden = true

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

        // Single click gesture on the entire header container
        let headerClick = NSClickGestureRecognizer(target: self, action: #selector(cardClicked))
        headerContainer.addGestureRecognizer(headerClick)

        let expDisplayName = header.senderName ?? header.senderEmail
        expAvatarCircle.setAccessibilityRole(.button)
        expAvatarCircle.setAccessibilityLabel("Collapse message from \(expDisplayName)")

        expandedTopConstraint = expandedContainer.topAnchor.constraint(equalTo: view.topAnchor)

        NSLayoutConstraint.activate([
            expandedTopConstraint,
            expandedContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            expandedContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            expandedContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // headerContainer fills the top of expandedContainer
            headerContainer.topAnchor.constraint(equalTo: expandedContainer.topAnchor),
            headerContainer.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor),
            headerContainer.bottomAnchor.constraint(equalTo: expAvatarCircle.bottomAnchor, constant: 12),

            // Header views anchor within headerContainer
            expAvatarCircle.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: 12),
            expAvatarCircle.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 12),
            expAvatarCircle.widthAnchor.constraint(equalToConstant: 40),
            expAvatarCircle.heightAnchor.constraint(equalToConstant: 40),
            expAvatarLabel.centerXAnchor.constraint(equalTo: expAvatarCircle.centerXAnchor),
            expAvatarLabel.centerYAnchor.constraint(equalTo: expAvatarCircle.centerYAnchor),

            expSenderLabel.topAnchor.constraint(equalTo: expAvatarCircle.topAnchor, constant: 2),
            expSenderLabel.leadingAnchor.constraint(equalTo: expAvatarCircle.trailingAnchor, constant: 12),
            expSenderLabel.trailingAnchor.constraint(lessThanOrEqualTo: expDateLabel.leadingAnchor, constant: -12),

            expDateLabel.centerYAnchor.constraint(equalTo: expSenderLabel.centerYAnchor),
            expDateLabel.trailingAnchor.constraint(equalTo: actionBar.leadingAnchor, constant: -8),

            expRecipientLabel.topAnchor.constraint(equalTo: expSenderLabel.bottomAnchor, constant: 2),
            expRecipientLabel.leadingAnchor.constraint(equalTo: expSenderLabel.leadingAnchor),
            expRecipientLabel.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -12),

            // headerSeparator anchors to headerContainer bottom
            headerSeparator.topAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            headerSeparator.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor, constant: 12),
            headerSeparator.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor, constant: -12),

            attachmentBar.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor, constant: 8),
            attachmentBar.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor, constant: 12),
            attachmentBar.trailingAnchor.constraint(lessThanOrEqualTo: expandedContainer.trailingAnchor, constant: -12),

            imageBlockedBanner.topAnchor.constraint(equalTo: attachmentBar.bottomAnchor, constant: 4),
            imageBlockedBanner.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor, constant: 12),
            imageBlockedBanner.trailingAnchor.constraint(lessThanOrEqualTo: expandedContainer.trailingAnchor, constant: -12),

            bodyScrollView.topAnchor.constraint(equalTo: imageBlockedBanner.bottomAnchor, constant: 4),
            bodyScrollView.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor, constant: 12),
            bodyScrollView.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor, constant: -12),
            bodyScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            bodyScrollView.bottomAnchor.constraint(equalTo: expandedContainer.bottomAnchor, constant: -8),

            // actionBar overlays the header row at sender-label height
            actionBar.centerYAnchor.constraint(equalTo: expSenderLabel.centerYAnchor),
            actionBar.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor, constant: -12),

            loadingSpinner.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor, constant: 20),
            loadingSpinner.centerXAnchor.constraint(equalTo: expandedContainer.centerXAnchor),
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
        if let accountEmail, header.senderEmail.lowercased() == accountEmail.lowercased() {
            expRecipientLabel.stringValue = "to recipients"
        } else {
            expRecipientLabel.stringValue = "to me"
        }
    }

    // MARK: - Expand / Collapse

    private func updateVisibility() {
        collapsedContainer.isHidden = isExpanded
        expandedContainer.isHidden = !isExpanded
    }

    func setExpanded(_ expanded: Bool, animated: Bool = true) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded

        let displayName = header.senderName ?? header.senderEmail
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(expanded
            ? "Collapse message from \(displayName)"
            : "Expand message from \(displayName)")

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
        loadingSpinner.stopAnimation(nil)
        loadingSpinner.isHidden = true

        renderCurrentBody()
    }

    private func renderCurrentBody() {
        let body = cachedBody
        let effective = renderingOverride ?? DisplayPreferences.bodyRendering
        let hasHtml = !(body?.htmlBody ?? "").isEmpty
        let hasText = !(body?.textBody ?? "").isEmpty

        let showHtml: Bool
        switch effective {
        case .html: showHtml = hasHtml
        case .plain: showHtml = false
        case .auto: showHtml = hasHtml
        }

        if showHtml, let htmlBody = body?.htmlBody {
            bodyTextView.isHidden = true
            bodyScrollView.isHidden = true
            let shouldBlock = DisplayPreferences.remoteImagePolicy != .allowAll
            let (sanitized, blockedCount) = RemoteImageSanitizer.sanitize(htmlBody, blockImages: shouldBlock)
            lastBlockedCount = blockedCount
            imageBlockedBanner.isHidden = blockedCount == 0
            showWebView(html: sanitized)
        } else if hasText, let textBody = body?.textBody {
            hideWebView()
            imageBlockedBanner.isHidden = true
            bodyTextView.isHidden = false
            bodyScrollView.isHidden = false
            bodyTextView.textStorage?.setAttributedString(Self.renderPlainText(textBody))
        } else if hasHtml, let htmlBody = body?.htmlBody {
            // Plain preference but no text body — strip HTML tags to plain
            let stripped = NSAttributedString(html: htmlBody.data(using: .utf8) ?? Data(),
                                              options: [.documentType: NSAttributedString.DocumentType.html],
                                              documentAttributes: nil)?.string ?? "(no content)"
            hideWebView()
            imageBlockedBanner.isHidden = true
            bodyTextView.isHidden = false
            bodyScrollView.isHidden = false
            bodyTextView.textStorage?.setAttributedString(Self.renderPlainText(stripped))
        } else {
            hideWebView()
            imageBlockedBanner.isHidden = true
            bodyTextView.isHidden = false
            bodyScrollView.isHidden = false
            bodyTextView.textStorage?.setAttributedString(Self.renderPlainText("(no content)"))
        }
    }

    func showLoading() {
        isLoadingBody = true
        hideWebView()
        bodyTextView.isHidden = true
        bodyScrollView.isHidden = true
        loadingSpinner.isHidden = false
        loadingSpinner.startAnimation(nil)
    }

    // MARK: - Attachments

    func displayAttachments(_ attachments: [AttachmentInfo]) {
        currentAttachments = attachments

        // Remove any old preview
        attachmentPreviewContainer?.removeFromSuperview()
        attachmentPreviewContainer = nil

        // Register inline attachments with the cid: handler for WKWebView rendering.
        let emailId = header.id
        for att in attachments where att.isInline {
            if let cid = att.contentId {
                cidHandler.contentIdToPartId[cid] = (emailId: emailId, partId: att.partId)
            }
        }

        // Trigger vCard / iCal preview for supported attachments (async)
        for att in attachments where !att.isInline {
            let mime = att.mimeType?.lowercased() ?? ""
            let filename = att.filename?.lowercased() ?? ""
            let isVCard = mime == "text/vcard" || mime == "text/x-vcard" || filename.hasSuffix(".vcf")
            let isICS = mime == "text/calendar" || filename.hasSuffix(".ics")
            if isVCard || isICS, let fetch = onFetchAttachmentData {
                let partId = att.partId
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let data = try? await fetch(emailId, partId) else { return }
                    let preview: NSView?
                    if isVCard {
                        let cards = VCardParser.parse(data)
                        preview = cards.isEmpty ? nil : Self.buildVCardPreview(cards.first!)
                    } else {
                        let events = ICSParser.parse(data)
                        preview = events.isEmpty ? nil : Self.buildICSPreview(events.first!)
                    }
                    if let preview {
                        self.insertAttachmentPreview(preview)
                    }
                }
                break  // preview first qualifying attachment only
            }
        }

        // Only show chips for regular (non-inline) attachments.
        // Use original indices into currentAttachments so attachmentChipClicked works.
        attachmentBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let hasRegular = attachments.contains { !$0.isInline }
        guard hasRegular else {
            attachmentBar.isHidden = true
            return
        }
        attachmentBar.isHidden = false

        for (index, att) in attachments.enumerated() where !att.isInline {
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
        let replyAllItem = NSMenuItem(title: "Reply All", action: #selector(replyAllClicked), keyEquivalent: "")
        replyAllItem.target = self
        menu.addItem(replyAllItem)
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

        let spamItem = NSMenuItem(title: "Mark as Spam", action: #selector(markSpamClicked), keyEquivalent: "")
        spamItem.target = self
        menu.addItem(spamItem)

        menu.addItem(.separator())

        let labelsItem = NSMenuItem(title: "Labels...", action: #selector(labelsClicked), keyEquivalent: "")
        labelsItem.target = self
        menu.addItem(labelsItem)

        let snoozeItem = NSMenuItem(title: "Snooze", action: nil, keyEquivalent: "")
        let snoozeMenu = NSMenu()
        for (title, date) in Self.snoozeOptions() {
            let item = NSMenuItem(title: title, action: #selector(snoozeClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = date
            snoozeMenu.addItem(item)
        }
        snoozeItem.submenu = snoozeMenu
        menu.addItem(snoozeItem)

        menu.addItem(.separator())

        let currentlyHTML = (renderingOverride == nil || renderingOverride == .html || renderingOverride == .auto)
            && !(cachedBody?.htmlBody ?? "").isEmpty
        let toggleTitle = currentlyHTML ? "View as Plain Text" : "View as HTML"
        let toggleAction = currentlyHTML ? #selector(switchToPlainText) : #selector(switchToHTML)
        let toggleItem = NSMenuItem(title: toggleTitle, action: toggleAction, keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

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

    @objc private func replyAllClicked() { onReplyAll?(header, cachedBody) }
    @objc private func forwardClicked() { onForward?(header, cachedBody) }
    @objc private func archiveClicked() { onArchive?(header.id) }
    @objc private func deleteClicked() { onDelete?(header.id) }
    @objc private func markSpamClicked() { onMarkSpam?(header.id) }

    @objc private func showImagesOnce() {
        guard let html = cachedBody?.htmlBody else { return }
        imageBlockedBanner.isHidden = true
        showWebView(html: html)
    }

    @objc private func alwaysAllowImages() {
        onAllowImages?(header.senderEmail)
        showImagesOnce()
    }

    @objc private func switchToPlainText() {
        renderingOverride = .plain
        renderCurrentBody()
    }

    @objc private func switchToHTML() {
        renderingOverride = .html
        renderCurrentBody()
    }

    @objc private func labelsClicked() {
        onShowLabelPicker?(moreButton, header.id)
    }

    @objc private func snoozeClicked(_ sender: NSMenuItem) {
        guard let date = sender.representedObject as? Date else { return }
        onSnooze?(header.id, date)
    }

    private static func snoozeOptions() -> [(String, Date)] {
        var cal = Calendar.current
        cal.locale = Locale.current
        let now = Date()
        var options: [(String, Date)] = []

        // Later today (3h)
        options.append(("Later today (3h)", now.addingTimeInterval(3 * 3600)))

        // Tomorrow 8am
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
           let tomorrow8am = cal.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) {
            options.append(("Tomorrow 8am", tomorrow8am))
        }

        // This weekend (Saturday 9am)
        let weekday = cal.component(.weekday, from: now) // 1=Sun, 7=Sat
        let daysToSat = weekday == 7 ? 7 : (7 - weekday)
        if let sat = cal.date(byAdding: .day, value: daysToSat, to: now),
           let sat9am = cal.date(bySettingHour: 9, minute: 0, second: 0, of: sat) {
            options.append(("This weekend (Sat 9am)", sat9am))
        }

        // Next week (Monday 8am)
        let daysToMon = weekday == 2 ? 7 : ((9 - weekday) % 7)
        if let mon = cal.date(byAdding: .day, value: daysToMon, to: now),
           let mon8am = cal.date(bySettingHour: 8, minute: 0, second: 0, of: mon) {
            options.append(("Next week (Mon 8am)", mon8am))
        }

        return options
    }

    @objc private func moveFolderSelected(_ sender: NSMenuItem) {
        guard let folderId = sender.representedObject as? String else { return }
        onMove?(header.id, folderId)
    }

    // MARK: - Attachment preview (vCard / iCal)

    private func insertAttachmentPreview(_ preview: NSView) {
        attachmentPreviewContainer?.removeFromSuperview()
        attachmentPreviewContainer = preview
        preview.translatesAutoresizingMaskIntoConstraints = false
        expandedContainer.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor, constant: 8),
            preview.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor, constant: 12),
            preview.trailingAnchor.constraint(lessThanOrEqualTo: expandedContainer.trailingAnchor, constant: -12),
        ])
    }

    private static func buildVCardPreview(_ card: VCard) -> NSView {
        let container = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        func makeLabel(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
            let f = NSTextField(labelWithString: text)
            f.font = font
            f.textColor = color
            return f
        }

        if let name = card.fn { stack.addArrangedSubview(makeLabel(name, font: .systemFont(ofSize: 13, weight: .semibold))) }
        if let org = card.org { stack.addArrangedSubview(makeLabel(org, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)) }
        for email in card.emails { stack.addArrangedSubview(makeLabel(email, font: .systemFont(ofSize: 12), color: .controlAccentColor)) }
        for phone in card.phones { stack.addArrangedSubview(makeLabel(phone, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)) }

        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.layer?.cornerRadius = 8
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        return container
    }

    private static func buildICSPreview(_ event: ICSEvent) -> NSView {
        let container = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        func makeLabel(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
            let f = NSTextField(labelWithString: text)
            f.font = font
            f.textColor = color
            return f
        }

        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short

        if let summary = event.summary {
            stack.addArrangedSubview(makeLabel(summary, font: .systemFont(ofSize: 13, weight: .semibold)))
        }
        if let start = event.start {
            let dateStr: String
            if let end = event.end {
                dateStr = "\(fmt.string(from: start)) – \(fmt.string(from: end))"
            } else {
                dateStr = fmt.string(from: start)
            }
            stack.addArrangedSubview(makeLabel(dateStr, font: .systemFont(ofSize: 12), color: .secondaryLabelColor))
        }
        if let location = event.location {
            stack.addArrangedSubview(makeLabel(location, font: .systemFont(ofSize: 12), color: .secondaryLabelColor))
        }
        if let organizer = event.organizer {
            stack.addArrangedSubview(makeLabel("Organizer: \(organizer)", font: .systemFont(ofSize: 11), color: .tertiaryLabelColor))
        }

        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.layer?.cornerRadius = 8
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        return container
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
            config.setURLSchemeHandler(cidHandler, forURLScheme: "cid")
            let wv = WKWebView(frame: .zero, configuration: config)
            wv.translatesAutoresizingMaskIntoConstraints = false
            wv.setValue(true, forKey: "drawsBackground")
            expandedContainer.addSubview(wv)
            NSLayoutConstraint.activate([
                wv.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor, constant: 8),
                wv.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor, constant: 4),
                wv.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor, constant: -4),
                wv.bottomAnchor.constraint(equalTo: expandedContainer.bottomAnchor, constant: -8),
                wv.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
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
        @media (prefers-color-scheme: dark) {
            body { color: #e0e0e0; background: #1e1e1e; }
            a { color: #4da3ff; }
            blockquote { border-left-color: #555; color: #aaa; }
            pre, code { background: #2a2a2a; }
        }
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

    private static let fallbackDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static func relativeDate(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        if seconds < 172800 { return "Yesterday" }
        if seconds < 604800 { return "\(Int(seconds / 86400))d ago" }
        return Self.fallbackDateFormatter.string(from: date)
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
