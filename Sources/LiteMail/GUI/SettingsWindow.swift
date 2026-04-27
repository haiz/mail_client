import AppKit

/// Settings/preferences window with multi-account management.
final class SettingsWindow: NSObject {

    private let window: NSWindow
    private let accountTableView: NSTableView
    private var googleClientIdField: NSTextField?
    private var emailListLimitPopup: NSPopUpButton?
    private var undoSendDelayPopup: NSPopUpButton?

    // Per-account signature UI
    private var signatureAccountPopup: NSPopUpButton?
    private var signatureTextView: NSTextView?

    var onAddAccount: (() -> Void)?
    var onRemoveAccount: ((String) -> Void)?
    var onSyncNow: (() -> Void)?

    /// Called when the user switches accounts in the signature popup.
    /// Returns the HTML signature for that account (nil = none).
    var onLoadSignature: ((String) async -> String?)?

    /// Called when the user clicks Save Signature.
    var onSaveSignature: ((String, String?) -> Void)?

    private var accounts: [AccountConfig] = []
    private var emailCount: Int = 0

    init(accounts: [AccountConfig], emailCount: Int) {
        self.accounts = accounts
        self.emailCount = emailCount

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()

        accountTableView = NSTableView()
        accountTableView.headerView = nil
        accountTableView.rowHeight = 36

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("AccountCol"))
        column.isEditable = false
        accountTableView.addTableColumn(column)

        super.init()

        accountTableView.dataSource = self
        accountTableView.delegate = self

        setupLayout()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        loadSignatureForSelectedAccount()
    }

    private func setupLayout() {
        let container = NSView()

        // MARK: Accounts
        let accountHeader = Self.sectionHeader("Accounts")

        let scrollView = NSScrollView()
        scrollView.documentView = accountTableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(equalToConstant: 140).isActive = true

        let addButton = CursorButton(title: "Add Account...", target: self, action: #selector(addClicked))
        addButton.bezelStyle = .rounded

        let removeButton = CursorButton(title: "Remove", target: self, action: #selector(removeClicked))
        removeButton.bezelStyle = .rounded

        let syncButton = CursorButton(title: "Sync All", target: self, action: #selector(syncClicked))
        syncButton.bezelStyle = .rounded

        let accountButtons = NSStackView(views: [addButton, removeButton, syncButton])
        accountButtons.spacing = 8

        // MARK: Appearance
        let appearanceHeader = Self.sectionHeader("Appearance")

        let limitLabel = NSTextField(labelWithString: "Emails per page:")
        limitLabel.font = .systemFont(ofSize: 13)

        let limitPopup = NSPopUpButton()
        limitPopup.target = self
        limitPopup.action = #selector(emailListLimitChanged(_:))
        for preset in DisplayPreferences.emailListLimitPresets {
            limitPopup.addItem(withTitle: "\(preset)")
            limitPopup.lastItem?.tag = preset
        }
        limitPopup.selectItem(withTag: DisplayPreferences.emailListLimit)
        self.emailListLimitPopup = limitPopup

        let limitRow = NSStackView(views: [limitLabel, limitPopup])
        limitRow.spacing = 8
        limitRow.alignment = .firstBaseline

        // MARK: Privacy — remote image blocking
        let privacyHeader = Self.sectionHeader("Privacy")

        let imageBlockLabel = NSTextField(labelWithString: "Remote images:")
        imageBlockLabel.font = .systemFont(ofSize: 13)

        let blockAllRadio = NSButton(radioButtonWithTitle: "Always block", target: self, action: #selector(imageBlockingChanged(_:)))
        blockAllRadio.tag = 0
        let blockUnknownRadio = NSButton(radioButtonWithTitle: "Block from unknown senders", target: self, action: #selector(imageBlockingChanged(_:)))
        blockUnknownRadio.tag = 1
        let allowAllRadio = NSButton(radioButtonWithTitle: "Always allow", target: self, action: #selector(imageBlockingChanged(_:)))
        allowAllRadio.tag = 2

        switch DisplayPreferences.remoteImagePolicy {
        case .blockAll: blockAllRadio.state = .on
        case .blockUnknown: blockUnknownRadio.state = .on
        case .allowAll: allowAllRadio.state = .on
        }

        let imageBlockRadioStack = NSStackView(views: [blockAllRadio, blockUnknownRadio, allowAllRadio])
        imageBlockRadioStack.orientation = .vertical
        imageBlockRadioStack.alignment = .leading
        imageBlockRadioStack.spacing = 4

        let imageBlockRow = NSStackView(views: [imageBlockLabel, imageBlockRadioStack])
        imageBlockRow.spacing = 8
        imageBlockRow.alignment = .top

        // MARK: Composing — per-account signature + undo send
        let composingHeader = Self.sectionHeader("Composing")

        let undoSendLabel = NSTextField(labelWithString: "Undo Send delay:")
        undoSendLabel.font = .systemFont(ofSize: 13)

        let undoDelayPopup = NSPopUpButton()
        for (seconds, title) in [(0, "Off"), (5, "5 seconds"), (10, "10 seconds"), (30, "30 seconds")] {
            undoDelayPopup.addItem(withTitle: title)
            undoDelayPopup.lastItem?.tag = seconds
        }
        undoDelayPopup.selectItem(withTag: UserDefaults.standard.integer(forKey: "undo_send_delay"))
        undoDelayPopup.target = self
        undoDelayPopup.action = #selector(undoSendDelayChanged(_:))
        self.undoSendDelayPopup = undoDelayPopup

        let undoSendRow = NSStackView(views: [undoSendLabel, undoDelayPopup])
        undoSendRow.spacing = 8
        undoSendRow.alignment = .firstBaseline

        let sigAccountLabel = NSTextField(labelWithString: "Signature for:")
        sigAccountLabel.font = .systemFont(ofSize: 13)

        let sigAccountPopup = NSPopUpButton()
        for account in accounts {
            sigAccountPopup.addItem(withTitle: account.emailAddress)
        }
        sigAccountPopup.target = self
        sigAccountPopup.action = #selector(signatureAccountChanged(_:))
        self.signatureAccountPopup = sigAccountPopup

        let sigAccountRow = NSStackView(views: [sigAccountLabel, sigAccountPopup])
        sigAccountRow.spacing = 8
        sigAccountRow.alignment = .firstBaseline

        let sigTextView = NSTextView()
        sigTextView.isRichText = true
        sigTextView.allowsUndo = true
        sigTextView.font = .systemFont(ofSize: 13)
        sigTextView.isAutomaticSpellingCorrectionEnabled = false
        sigTextView.isAutomaticQuoteSubstitutionEnabled = false
        sigTextView.textContainerInset = NSSize(width: 6, height: 6)
        sigTextView.textContainer?.widthTracksTextView = true
        self.signatureTextView = sigTextView

        let sigScrollView = NSScrollView()
        sigScrollView.documentView = sigTextView
        sigScrollView.hasVerticalScroller = true
        sigScrollView.autohidesScrollers = true
        sigScrollView.borderType = .bezelBorder
        sigScrollView.translatesAutoresizingMaskIntoConstraints = false
        sigScrollView.widthAnchor.constraint(equalToConstant: 400).isActive = true
        sigScrollView.heightAnchor.constraint(equalToConstant: 100).isActive = true

        let saveSigButton = CursorButton(title: "Save Signature", target: self, action: #selector(saveSignature))
        saveSigButton.bezelStyle = .rounded

        // MARK: Integrations
        let integrationsHeader = Self.sectionHeader("Integrations")
        let googleClientIdField = NSTextField()
        googleClientIdField.placeholderString = "YOUR_CLIENT_ID.apps.googleusercontent.com"
        googleClientIdField.stringValue = UserDefaults.standard.string(forKey: GoogleConfig.clientIdDefaultsKey) ?? ""
        googleClientIdField.font = .systemFont(ofSize: 12)
        googleClientIdField.translatesAutoresizingMaskIntoConstraints = false
        googleClientIdField.widthAnchor.constraint(equalToConstant: 400).isActive = true
        self.googleClientIdField = googleClientIdField

        let googleHint = NSTextField(labelWithString: "Google OAuth 2.0 Client ID (Desktop app type). Required for Gmail sign-in.")
        googleHint.font = .systemFont(ofSize: 11)
        googleHint.textColor = .secondaryLabelColor
        googleHint.lineBreakMode = .byWordWrapping
        googleHint.preferredMaxLayoutWidth = 400

        let saveGoogleButton = CursorButton(title: "Save Client ID", target: self, action: #selector(saveGoogleClientId))
        saveGoogleButton.bezelStyle = .rounded

        // MARK: About
        let aboutHeader = Self.sectionHeader("About")
        let versionLabel = NSTextField(labelWithString: "LiteMail v0.2.0 — Multi-account IMAP/JMAP")
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .tertiaryLabelColor

        let countLabel = NSTextField(labelWithString: "Total emails stored: \(emailCount)")
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [
            accountHeader, scrollView, accountButtons,
            Self.spacer(),
            appearanceHeader, limitRow,
            Self.spacer(),
            privacyHeader, imageBlockRow,
            Self.spacer(),
            composingHeader, undoSendRow, sigAccountRow, sigScrollView, saveSigButton,
            Self.spacer(),
            integrationsHeader, googleClientIdField, googleHint, saveGoogleButton,
            Self.spacer(),
            aboutHeader, versionLabel, countLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            scrollView.widthAnchor.constraint(equalToConstant: 400),
        ])

        window.contentView = container
    }

    // MARK: - Signature helpers

    private func selectedAccountId() -> String? {
        guard let popup = signatureAccountPopup else { return nil }
        let idx = popup.indexOfSelectedItem
        guard idx >= 0, idx < accounts.count else { return nil }
        return accounts[idx].id
    }

    private func loadSignatureForSelectedAccount() {
        guard let accountId = selectedAccountId(), let onLoad = onLoadSignature else { return }
        Task { @MainActor in
            let html = await onLoad(accountId)
            self.displaySignature(html: html)
        }
    }

    private func displaySignature(html: String?) {
        guard let textView = signatureTextView else { return }
        if let html, !html.isEmpty,
           let data = html.data(using: .utf8),
           let attrStr = NSAttributedString(
               html: data,
               options: [.documentType: NSAttributedString.DocumentType.html,
                         .characterEncoding: String.Encoding.utf8.rawValue as Any],
               documentAttributes: nil) {
            textView.textStorage?.setAttributedString(attrStr)
        } else {
            textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        }
    }

    @objc private func signatureAccountChanged(_ sender: NSPopUpButton) {
        loadSignatureForSelectedAccount()
    }

    @objc private func saveSignature() {
        guard let accountId = selectedAccountId(), let textView = signatureTextView else { return }
        let html: String?
        if textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            html = nil
        } else if let data = try? textView.textStorage?.data(
            from: NSRange(location: 0, length: textView.textStorage?.length ?? 0),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
        ), let str = String(data: data, encoding: .utf8) {
            html = str
        } else {
            html = textView.string.isEmpty ? nil : textView.string
        }
        onSaveSignature?(accountId, html)
        let alert = NSAlert()
        alert.messageText = "Signature saved"
        alert.alertStyle = .informational
        alert.runModal()
    }

    // MARK: - Other actions

    @objc private func addClicked() {
        onAddAccount?()
    }

    @objc private func removeClicked() {
        let row = accountTableView.selectedRow
        guard row >= 0, row < accounts.count else { return }
        let account = accounts[row]

        let alert = NSAlert()
        alert.messageText = "Remove Account"
        alert.informativeText = "Remove \(account.emailAddress)? All local emails for this account will be deleted."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            onRemoveAccount?(account.id)
            accounts.remove(at: row)
            accountTableView.reloadData()
        }
    }

    @objc private func syncClicked() {
        onSyncNow?()
    }

    @objc private func emailListLimitChanged(_ sender: NSPopUpButton) {
        let selected = sender.selectedTag()
        guard DisplayPreferences.emailListLimitPresets.contains(selected) else { return }
        DisplayPreferences.emailListLimit = selected
    }

    @objc private func undoSendDelayChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.selectedTag(), forKey: "undo_send_delay")
    }

    @objc private func imageBlockingChanged(_ sender: NSButton) {
        switch sender.tag {
        case 0: DisplayPreferences.remoteImagePolicy = .blockAll
        case 2: DisplayPreferences.remoteImagePolicy = .allowAll
        default: DisplayPreferences.remoteImagePolicy = .blockUnknown
        }
    }

    @objc private func saveGoogleClientId() {
        let clientId = googleClientIdField?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
        if clientId.isEmpty {
            UserDefaults.standard.removeObject(forKey: GoogleConfig.clientIdDefaultsKey)
        } else {
            UserDefaults.standard.set(clientId, forKey: GoogleConfig.clientIdDefaultsKey)
        }
        let alert = NSAlert()
        alert.messageText = "Client ID saved"
        alert.informativeText = "The Google Client ID will be used for the next Gmail sign-in."
        alert.alertStyle = .informational
        alert.runModal()
    }

    private static func sectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private static func spacer() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 8).isActive = true
        return v
    }
}

// MARK: - NSTableViewDataSource

extension SettingsWindow: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { accounts.count }
}

// MARK: - NSTableViewDelegate

extension SettingsWindow: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < accounts.count else { return nil }
        let account = accounts[row]

        let cellId = NSUserInterfaceItemIdentifier("AccountCell")
        let cell: NSTableCellView

        if let recycled = tableView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView {
            cell = recycled
        } else {
            cell = NSTableCellView()
            cell.identifier = cellId

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField

            let badge = NSTextField(labelWithString: "")
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.identifier = NSUserInterfaceItemIdentifier("protocol")
            badge.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
            badge.textColor = .secondaryLabelColor
            cell.addSubview(badge)

            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        cell.textField?.stringValue = account.emailAddress
        cell.textField?.font = account.isDefault ? .systemFont(ofSize: 13, weight: .medium) : .systemFont(ofSize: 13)

        let badge = cell.subviews.first { $0.identifier?.rawValue == "protocol" } as? NSTextField
        badge?.stringValue = account.protocolType.rawValue.uppercased()

        return cell
    }
}
