import AppKit

/// Compose window for new emails, replies, and forwards.
/// Draft auto-saves every 5 seconds to the outbox.
final class ComposerWindow: NSObject {

    private(set) var window: NSWindow
    private let fromPopup: NSPopUpButton
    private let toField: NSTextField
    private let ccField: NSTextField
    private let bccField: NSTextField
    private let subjectField: NSTextField
    private let bodyTextView: ComposerBodyTextView
    private let bodyScrollView: NSScrollView
    private let sendButton: NSButton
    private let sendLaterButton: NSButton
    private let validationLabel: NSTextField

    private let attachButton: NSButton
    private let attachmentChipsBar: NSStackView

    private let sendLaterPopover = SendLaterPopover()
    private var autoSaveTimer: Timer?
    private var draftId: Int64?

    /// Files attached by the user.
    private var pendingAttachments: [OutgoingAttachment] = []

    /// Account list for the From selector. Each entry is (id, email).
    private var accounts: [(id: String, email: String)] = []

    /// The account ID selected in the From popup.
    var selectedAccountId: String? {
        guard fromPopup.indexOfSelectedItem >= 0,
              fromPopup.indexOfSelectedItem < accounts.count else { return nil }
        return accounts[fromPopup.indexOfSelectedItem].id
    }

    /// Injected by AppDelegate for contact autocomplete.
    var contactsStore: ContactsStore?
    var accountId: String?

    /// Contacts preloaded from cache for autocomplete filtering.
    private var cachedContacts: [ContactRecord] = []

    /// State for suggestion menu.
    private var pendingSuggestions: [ContactRecord] = []
    private weak var suggestionField: NSTextField?

    /// Called when the user clicks Send. Receives the message and a completion handler.
    /// Call completion(nil) on success, completion("error message") on failure.
    var onSend: ((OutgoingMessage, @escaping (String?) -> Void) -> Void)?
    /// Called when the user schedules a message for later delivery.
    var onSchedule: ((OutgoingMessage, Date, @escaping (String?) -> Void) -> Void)?
    /// Called periodically for draft auto-save.
    var onSaveDraft: ((OutgoingMessage) -> Void)?

    /// HTML signature to append when composing a new message.
    var signatureHtml: String?

    enum Mode {
        case compose
        case reply(to: EmailHeader, body: EmailBody?)
        case replyAll(to: EmailHeader, body: EmailBody?, accountEmail: String)
        case forward(original: EmailHeader, body: EmailBody?)
        /// Reopen a previously queued (and subsequently canceled) outbox message.
        case draft(OutboxRecord)
    }

    private let mode: Mode

    init(mode: Mode) {
        self.mode = mode
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        // NSWindow defaults isReleasedWhenClosed = true, which causes AppKit to call
        // [window release] on close(). Since ComposerWindow holds a strong reference,
        // that release would free the underlying object while our stored property still
        // points to it, causing a double-free when ComposerWindow later deallocates.
        window.isReleasedWhenClosed = false
        window.title = Self.windowTitle(for: mode)
        window.center()
        window.minSize = NSSize(width: 400, height: 300)

        // From selector
        fromPopup = NSPopUpButton()
        fromPopup.font = .systemFont(ofSize: 13)
        fromPopup.controlSize = .regular

        // Fields
        toField = NSTextField()
        toField.placeholderString = "To"
        toField.font = .systemFont(ofSize: 13)

        ccField = NSTextField()
        ccField.placeholderString = "Cc"
        ccField.font = .systemFont(ofSize: 13)

        bccField = NSTextField()
        bccField.placeholderString = "Bcc"
        bccField.font = .systemFont(ofSize: 13)

        subjectField = NSTextField()
        subjectField.placeholderString = "Subject"
        subjectField.font = .systemFont(ofSize: 13)

        // Body — rich text enabled, supports inline image drag-drop
        bodyTextView = ComposerBodyTextView()
        bodyTextView.isRichText = true
        bodyTextView.allowsUndo = true
        bodyTextView.font = .systemFont(ofSize: 14)
        bodyTextView.isAutomaticSpellingCorrectionEnabled = true
        bodyTextView.isAutomaticQuoteSubstitutionEnabled = false
        bodyTextView.textContainerInset = NSSize(width: 8, height: 8)
        bodyTextView.textContainer?.widthTracksTextView = true

        bodyScrollView = NSScrollView()
        bodyScrollView.documentView = bodyTextView
        bodyScrollView.hasVerticalScroller = true
        bodyScrollView.autohidesScrollers = true

        // Attach button
        attachButton = CursorButton(image: NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Attach File")!, target: nil, action: nil)
        attachButton.bezelStyle = .accessoryBarAction

        // Attachment chips bar (shows attached file names)
        attachmentChipsBar = NSStackView()
        attachmentChipsBar.orientation = .horizontal
        attachmentChipsBar.spacing = 6
        attachmentChipsBar.isHidden = true

        // Send button
        sendButton = CursorButton(title: "Send", target: nil, action: nil)
        sendButton.bezelStyle = .rounded
        sendButton.controlSize = .large
        sendButton.keyEquivalent = "\r"
        sendButton.keyEquivalentModifierMask = .command
        sendButton.contentTintColor = .white
        sendButton.bezelColor = .controlAccentColor

        // Send Later button
        sendLaterButton = CursorButton(title: "Send Later", target: nil, action: nil)
        sendLaterButton.bezelStyle = .rounded
        sendLaterButton.controlSize = .large

        validationLabel = NSTextField(labelWithString: "")
        validationLabel.font = .systemFont(ofSize: 11)
        validationLabel.textColor = .systemRed
        validationLabel.isHidden = true
        validationLabel.translatesAutoresizingMaskIntoConstraints = false

        super.init()

        toField.delegate = self
        ccField.delegate = self
        bccField.delegate = self

        attachButton.target = self
        attachButton.action = #selector(attachClicked)
        sendButton.target = self
        sendButton.action = #selector(sendClicked)
        sendLaterButton.target = self
        sendLaterButton.action = #selector(sendLaterClicked)

        // Inline image drag-drop
        bodyTextView.onImageDropped = { [weak self] url, data, mimeType, cid in
            guard let self else { return }
            self.pendingAttachments.append(
                OutgoingAttachment(filename: url.lastPathComponent, mimeType: mimeType,
                                   data: data, contentId: cid, isInline: true)
            )
            // Inline images don't show as chips; no refreshAttachmentChips() call needed.
        }
        bodyTextView.onFilesDropped = { [weak self] urls in
            guard let self else { return }
            for url in urls {
                guard let data = try? Data(contentsOf: url) else { continue }
                self.pendingAttachments.append(
                    OutgoingAttachment(filename: url.lastPathComponent,
                                       mimeType: Self.mimeType(for: url.pathExtension),
                                       data: data)
                )
            }
            self.refreshAttachmentChips()
        }

        setupLayout()
        prefill(mode: mode)
        startAutoSave()
    }

    /// Populate the From popup with available accounts. Select the given accountId.
    func setAccounts(_ list: [(id: String, email: String)], selected: String?) {
        accounts = list
        fromPopup.removeAllItems()
        for account in list {
            fromPopup.addItem(withTitle: account.email)
        }
        if let selected, let idx = list.firstIndex(where: { $0.id == selected }) {
            fromPopup.selectItem(at: idx)
        }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        preloadContacts()
    }

    func close() {
        autoSaveTimer?.invalidate()
        // Clear AppKit assign-typed delegate pointers before the window is released.
        // NSTextField.delegate is an unsafe `assign` property — if the delegate object is
        // deallocated while still set, AppKit's internal NSConcretePointerArray retains a
        // dangling pointer and crashes during the next CA commit.
        toField.delegate = nil
        ccField.delegate = nil
        bccField.delegate = nil
        window.close()
    }

    // MARK: - Contact preload

    private func preloadContacts() {
        guard let contactsStore, let accountId else { return }
        Task { @MainActor in
            self.cachedContacts = (try? await contactsStore.allCachedContacts(accountId: accountId)) ?? []
        }
    }

    // MARK: - Autocomplete

    /// Extracts the last comma-separated token from a recipient field string.
    private func currentToken(in text: String) -> String {
        let parts = text.components(separatedBy: ",")
        return parts.last?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// Inserts a selected contact into the recipient field, replacing the last token.
    private func insertContact(_ contact: ContactRecord, into field: NSTextField) {
        let entry: String
        if let name = contact.name, !name.isEmpty {
            entry = "\(name) <\(contact.email)>"
        } else {
            entry = contact.email
        }

        let existing = field.stringValue
        let parts = existing.components(separatedBy: ",")
        if parts.count > 1 {
            field.stringValue = parts.dropLast().joined(separator: ",") + ", " + entry + ", "
        } else {
            field.stringValue = entry + ", "
        }
    }

    private func showSuggestions(_ contacts: [ContactRecord], for field: NSTextField) {
        pendingSuggestions = contacts
        suggestionField = field

        let menu = NSMenu()
        for (index, contact) in contacts.enumerated() {
            let title: String
            if let name = contact.name, !name.isEmpty {
                title = "\(name) <\(contact.email)>"
            } else {
                title = contact.email
            }
            let item = NSMenuItem(title: title, action: #selector(suggestionSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }

        menu.popUp(positioning: menu.items.first, at: NSPoint(x: 0, y: -2), in: field)
    }

    @objc private func suggestionSelected(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index >= 0, index < pendingSuggestions.count,
              let field = suggestionField else { return }
        insertContact(pendingSuggestions[index], into: field)
    }

    // MARK: - Layout

    private func setupLayout() {
        let container = NSView()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        // From row (popup button, not text field)
        let fromRow = NSStackView()
        fromRow.orientation = .horizontal
        fromRow.spacing = 8
        let fromLabel = NSTextField(labelWithString: "From:")
        fromLabel.font = .systemFont(ofSize: 12, weight: .medium)
        fromLabel.textColor = .secondaryLabelColor
        fromLabel.widthAnchor.constraint(equalToConstant: 60).isActive = true
        fromLabel.alignment = .right
        fromPopup.translatesAutoresizingMaskIntoConstraints = false
        fromRow.addArrangedSubview(fromLabel)
        fromRow.addArrangedSubview(fromPopup)
        stack.addArrangedSubview(fromRow)

        // Recipient + subject fields
        let fields: [(NSTextField, String)] = [
            (toField, "To:"),
            (ccField, "Cc:"),
            (bccField, "Bcc:"),
            (subjectField, "Subject:"),
        ]

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
            // Insert validation label right after the To row
            if field === toField {
                stack.addArrangedSubview(validationLabel)
            }
        }

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        bodyScrollView.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendLaterButton.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(sendButton)
        toolbar.addSubview(sendLaterButton)

        // Formatting toolbar
        let boldBtn = CursorButton(title: "B", target: self, action: #selector(toggleBold))
        boldBtn.font = .boldSystemFont(ofSize: 13)
        boldBtn.bezelStyle = .accessoryBarAction
        let italicBtn = CursorButton(title: "I", target: self, action: #selector(toggleItalic))
        italicBtn.font = NSFontManager.shared.convert(.systemFont(ofSize: 13), toHaveTrait: .italicFontMask)
        italicBtn.bezelStyle = .accessoryBarAction
        let underlineBtn = CursorButton(title: "U", target: self, action: #selector(toggleUnderline))
        underlineBtn.bezelStyle = .accessoryBarAction
        let linkBtn = CursorButton(image: NSImage(systemSymbolName: "link", accessibilityDescription: "Insert Link")!, target: self, action: #selector(insertLink))
        linkBtn.bezelStyle = .accessoryBarAction

        let formatBar = NSStackView(views: [boldBtn, italicBtn, underlineBtn, linkBtn, attachButton])
        formatBar.spacing = 2
        formatBar.translatesAutoresizingMaskIntoConstraints = false

        attachmentChipsBar.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        container.addSubview(separator)
        container.addSubview(formatBar)
        container.addSubview(attachmentChipsBar)
        container.addSubview(bodyScrollView)
        container.addSubview(toolbar)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            separator.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            formatBar.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            formatBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),

            attachmentChipsBar.topAnchor.constraint(equalTo: formatBar.bottomAnchor, constant: 4),
            attachmentChipsBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            attachmentChipsBar.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),

            bodyScrollView.topAnchor.constraint(equalTo: attachmentChipsBar.bottomAnchor, constant: 4),
            bodyScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bodyScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bodyScrollView.bottomAnchor.constraint(equalTo: toolbar.topAnchor),

            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            toolbar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            toolbar.heightAnchor.constraint(equalToConstant: 36),

            sendButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            sendButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            sendLaterButton.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),
            sendLaterButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
        ])

        window.contentView = container
    }

    // MARK: - Prefill

    func applySignature(html: String?) {
        self.signatureHtml = html
        // Re-run prefill for compose mode so the new signature replaces the placeholder.
        if case .compose = mode { prefill(mode: mode) }
    }

    private func prefill(mode: Mode) {
        let signature = signatureHtml ?? ""
        let signatureBlock = signature.isEmpty ? "" : "\n\n--\n\(signature)"
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor,
        ]

        switch mode {
        case .compose:
            let text = NSAttributedString(string: signatureBlock, attributes: bodyAttrs)
            bodyTextView.textStorage?.setAttributedString(text)

        case .reply(let header, let body):
            toField.stringValue = header.senderEmail
            subjectField.stringValue = header.subject.map { ComposeView.reSubject($0) } ?? "Re:"
            bodyTextView.textStorage?.setAttributedString(
                NSAttributedString(string: ComposeView.buildQuotedText(header: header, body: body),
                                   attributes: bodyAttrs)
            )

        case .replyAll(let header, let body, let accountEmail):
            toField.stringValue = header.senderEmail
            let allRecipients = Self.parseAddresses(header.recipients)
            let ccAddresses = allRecipients
                .filter { $0.lowercased() != accountEmail.lowercased() &&
                          $0.lowercased() != header.senderEmail.lowercased() }
            ccField.stringValue = ccAddresses.joined(separator: ", ")
            subjectField.stringValue = header.subject.map { ComposeView.reSubject($0) } ?? "Re:"
            bodyTextView.textStorage?.setAttributedString(
                NSAttributedString(string: ComposeView.buildQuotedText(header: header, body: body),
                                   attributes: bodyAttrs)
            )

        case .forward(let header, let body):
            subjectField.stringValue = header.subject.map { "Fwd: \($0)" } ?? "Fwd:"

            var fwdText = "\n\n---------- Forwarded message ----------\n"
            fwdText += "From: \(header.senderEmail)\n"
            fwdText += "Date: \(ComposeView.dateFormatter.string(from: header.date))\n"
            fwdText += "Subject: \(header.subject ?? "")\n\n"
            if let text = body?.textBody {
                fwdText += text
            }
            bodyTextView.textStorage?.setAttributedString(
                NSAttributedString(string: fwdText, attributes: bodyAttrs)
            )

        case .draft(let rec):
            // Restore a previously queued message that was undone.
            // The recipients were stored as JSON arrays; toOutgoingMessage() decodes them.
            let msg = rec.toOutgoingMessage()
            toField.stringValue = msg.to.joined(separator: ", ")
            ccField.stringValue = msg.cc.joined(separator: ", ")
            bccField.stringValue = msg.bcc.joined(separator: ", ")
            subjectField.stringValue = msg.subject
            bodyTextView.textStorage?.setAttributedString(
                NSAttributedString(string: msg.bodyText, attributes: bodyAttrs)
            )
        }
    }

    // MARK: - Actions

    @objc private func toggleBold() {
        NSFontManager.shared.addFontTrait(nil)
        // Trigger bold via NSFontManager
        let range = bodyTextView.selectedRange()
        guard range.length > 0, let storage = bodyTextView.textStorage else { return }
        storage.enumerateAttribute(.font, in: range) { value, subRange, _ in
            guard let font = value as? NSFont else { return }
            let newFont: NSFont
            if font.fontDescriptor.symbolicTraits.contains(.bold) {
                newFont = NSFontManager.shared.convert(font, toNotHaveTrait: .boldFontMask)
            } else {
                newFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            storage.addAttribute(.font, value: newFont, range: subRange)
        }
    }

    @objc private func toggleItalic() {
        let range = bodyTextView.selectedRange()
        guard range.length > 0, let storage = bodyTextView.textStorage else { return }
        storage.enumerateAttribute(.font, in: range) { value, subRange, _ in
            guard let font = value as? NSFont else { return }
            let newFont: NSFont
            if font.fontDescriptor.symbolicTraits.contains(.italic) {
                newFont = NSFontManager.shared.convert(font, toNotHaveTrait: .italicFontMask)
            } else {
                newFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            storage.addAttribute(.font, value: newFont, range: subRange)
        }
    }

    @objc private func toggleUnderline() {
        let range = bodyTextView.selectedRange()
        guard range.length > 0, let storage = bodyTextView.textStorage else { return }
        let hasUnderline = storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int
        if hasUnderline != nil && hasUnderline != 0 {
            storage.removeAttribute(.underlineStyle, range: range)
        } else {
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
    }

    @objc private func insertLink() {
        let alert = NSAlert()
        alert.messageText = "Insert Link"
        alert.addButton(withTitle: "Insert")
        alert.addButton(withTitle: "Cancel")

        let urlField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        urlField.placeholderString = "https://example.com"
        alert.accessoryView = urlField

        if alert.runModal() == .alertFirstButtonReturn {
            let url = urlField.stringValue
            guard !url.isEmpty else { return }
            let range = bodyTextView.selectedRange()
            let linkText = range.length > 0 ? (bodyTextView.string as NSString).substring(with: range) : url
            let attributed = NSMutableAttributedString(string: linkText, attributes: [
                .link: url,
                .foregroundColor: NSColor.controlAccentColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .font: NSFont.systemFont(ofSize: 14),
            ])
            bodyTextView.textStorage?.replaceCharacters(in: range, with: attributed)
        }
    }

    @objc private func attachClicked() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let mimeType = Self.mimeType(for: url.pathExtension)
            let attachment = OutgoingAttachment(filename: url.lastPathComponent, mimeType: mimeType, data: data)
            pendingAttachments.append(attachment)
        }
        refreshAttachmentChips()
    }

    private func refreshAttachmentChips() {
        attachmentChipsBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let hasRegular = pendingAttachments.contains { !$0.isInline }
        guard hasRegular else {
            attachmentChipsBar.isHidden = true
            return
        }
        attachmentChipsBar.isHidden = false
        // Use original indices so removeAttachment(_:) can find the right entry.
        for (index, att) in pendingAttachments.enumerated() where !att.isInline {
            let chip = CursorButton(title: "\(att.filename) ✕", target: self, action: #selector(removeAttachment(_:)))
            chip.font = .systemFont(ofSize: 11)
            chip.bezelStyle = .accessoryBarAction
            chip.tag = index
            attachmentChipsBar.addArrangedSubview(chip)
        }
    }

    @objc private func removeAttachment(_ sender: NSButton) {
        let index = sender.tag
        guard index >= 0, index < pendingAttachments.count else { return }
        pendingAttachments.remove(at: index)
        refreshAttachmentChips()
    }

    @objc private func sendClicked() {
        let message = buildMessage()
        guard !message.to.isEmpty else {
            showToValidationError()
            return
        }

        sendButton.isEnabled = false
        sendButton.title = "Sending…"

        onSend?(message) { [weak self] errorMessage in
            guard let self else { return }
            DispatchQueue.main.async {
                if let errorMessage {
                    self.sendButton.isEnabled = true
                    self.sendButton.title = "Send"
                    let alert = NSAlert()
                    alert.messageText = "Failed to Send"
                    alert.informativeText = errorMessage
                    alert.alertStyle = .warning
                    alert.runModal()
                } else {
                    self.sendButton.title = "Sent ✓"
                    // Keep strong reference so close() fires after the 0.8s delay.
                    // [weak self] would allow ComposerWindow to be deallocated
                    // (AppDelegate nils composerWindow right after completion(nil)),
                    // leaving self nil when the timer fires and close() never called.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        self.close()
                    }
                }
            }
        }
    }

    @objc private func sendLaterClicked() {
        let message = buildMessage()
        guard !message.to.isEmpty else { showToValidationError(); return }
        sendLaterPopover.onSchedule = { [weak self] date in
            guard let self else { return }
            self.sendButton.isEnabled = false
            self.sendLaterButton.isEnabled = false
            self.sendLaterButton.title = "Scheduling…"
            self.onSchedule?(message, date) { [weak self] errorMessage in
                guard let self else { return }
                DispatchQueue.main.async {
                    if let errorMessage {
                        self.sendButton.isEnabled = true
                        self.sendLaterButton.isEnabled = true
                        self.sendLaterButton.title = "Send Later"
                        let alert = NSAlert()
                        alert.messageText = "Failed to Schedule"
                        alert.informativeText = errorMessage
                        alert.alertStyle = .warning
                        alert.runModal()
                    } else {
                        self.sendLaterButton.title = "Scheduled ✓"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.close() }
                    }
                }
            }
        }
        sendLaterPopover.show(relativeTo: sendLaterButton)
    }

    private func showToValidationError() {
        validationLabel.stringValue = "Add at least one recipient"
        validationLabel.isHidden = false

        toField.wantsLayer = true
        toField.layer?.borderColor = NSColor.systemRed.cgColor
        toField.layer?.borderWidth = 1
        toField.layer?.cornerRadius = 4

        window.makeFirstResponder(toField)

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.clearToValidationError()
        }
    }

    private func clearToValidationError() {
        validationLabel.isHidden = true
        toField.layer?.borderWidth = 0
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

        let bcc = bccField.stringValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let inReplyTo: String?
        switch mode {
        case .reply(let header, _): inReplyTo = header.messageId
        case .replyAll(let header, _, _): inReplyTo = header.messageId
        case .forward(let header, _): inReplyTo = header.messageId
        case .compose: inReplyTo = nil
        case .draft(let rec): inReplyTo = rec.inReplyTo
        }

        return OutgoingMessage(
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subjectField.stringValue,
            bodyText: bodyTextView.string,
            bodyHtml: buildHtmlBody(),
            inReplyTo: inReplyTo,
            attachments: pendingAttachments
        )
    }

    /// Generates an HTML body only when inline images are present.
    /// Walks the attributed string: text ranges are HTML-escaped; NSTextAttachment
    /// ranges with `.inlineCid` become `<img src="cid:…">`.
    /// Returns nil when there are no inline attachments (plain text path is used).
    private func buildHtmlBody() -> String? {
        guard pendingAttachments.contains(where: { $0.isInline }) else { return nil }

        var html = ""
        let attrStr = bodyTextView.attributedString()

        attrStr.enumerateAttributes(in: NSRange(location: 0, length: attrStr.length),
                                    options: []) { attrs, range, _ in
            if attrs[.attachment] != nil {
                if let cid = attrs[.inlineCid] as? String {
                    html += "<img src=\"cid:\(cid)\" style=\"max-width:100%;\">"
                }
            } else {
                let text = (attrStr.string as NSString).substring(with: range)
                html += Self.htmlEscapeBody(text)
            }
        }

        return html.isEmpty ? nil : html
    }

    private static func htmlEscapeBody(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: "<br>\n")
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
        case .replyAll: return "Reply All"
        case .forward: return "Forward"
        case .draft: return "New Message"
        }
    }

    /// Parses a comma-separated recipient string into individual email addresses.
    /// Handles both "Name <email>" and bare "email" formats.
    private static func parseAddresses(_ recipients: String?) -> [String] {
        guard let recipients, !recipients.isEmpty else { return [] }
        return recipients
            .components(separatedBy: ",")
            .compactMap { token -> String? in
                let t = token.trimmingCharacters(in: .whitespaces)
                if let start = t.lastIndex(of: "<"), let end = t.lastIndex(of: ">"), start < end {
                    let addr = String(t[t.index(after: start)..<end]).trimmingCharacters(in: .whitespaces)
                    return addr.isEmpty ? nil : addr
                }
                return t.isEmpty ? nil : t
            }
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": return "application/pdf"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "txt": return "text/plain"
        case "html", "htm": return "text/html"
        case "zip": return "application/zip"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "csv": return "text/csv"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - NSTextFieldDelegate (contacts autocomplete)

extension ComposerWindow: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        // Clear validation error when user types in the To field
        if let field = obj.object as? NSTextField, field === toField {
            clearToValidationError()
        }

        guard let field = obj.object as? NSTextField,
              (field === toField || field === ccField || field === bccField) else { return }

        let token = currentToken(in: field.stringValue)
        guard token.count >= 2 else { return }

        let lowToken = token.lowercased()
        let matches = cachedContacts.filter { contact in
            contact.email.lowercased().hasPrefix(lowToken) ||
            (contact.name?.lowercased().hasPrefix(lowToken) ?? false)
        }.prefix(8)

        guard !matches.isEmpty else { return }
        showSuggestions(Array(matches), for: field)
    }
}
