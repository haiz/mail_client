import AppKit

/// Settings/preferences window with multi-account management.
final class SettingsWindow: NSObject {

    private let window: NSWindow
    private let accountTableView: NSTableView
    private var signatureField: NSTextField?
    private var googleClientIdField: NSTextField?

    var onAddAccount: (() -> Void)?
    var onRemoveAccount: ((String) -> Void)?
    var onSyncNow: (() -> Void)?

    private var accounts: [AccountConfig] = []
    private var emailCount: Int = 0

    init(accounts: [AccountConfig], emailCount: Int) {
        self.accounts = accounts
        self.emailCount = emailCount

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
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
    }

    private func setupLayout() {
        let container = NSView()

        // Accounts section
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

        let accountButtons = NSStackView(views: [addButton, removeButton])
        accountButtons.spacing = 8

        // Stats section
        let statsHeader = Self.sectionHeader("Stats")
        let countLabel = NSTextField(labelWithString: "Total emails: \(emailCount)")
        countLabel.font = .systemFont(ofSize: 13)

        let syncButton = CursorButton(title: "Sync All", target: self, action: #selector(syncClicked))
        syncButton.bezelStyle = .rounded

        // Signature section
        let sigHeader = Self.sectionHeader("Signature")
        let sigField = NSTextField()
        sigField.placeholderString = "Your email signature..."
        sigField.stringValue = UserDefaults.standard.string(forKey: "email_signature") ?? ""
        sigField.font = .systemFont(ofSize: 12)
        sigField.lineBreakMode = .byWordWrapping
        sigField.translatesAutoresizingMaskIntoConstraints = false
        sigField.widthAnchor.constraint(equalToConstant: 400).isActive = true

        let saveSigButton = CursorButton(title: "Save Signature", target: self, action: #selector(saveSignature))
        saveSigButton.bezelStyle = .rounded
        self.signatureField = sigField

        // Google section
        let googleHeader = Self.sectionHeader("Google")
        let googleClientIdField = NSTextField()
        googleClientIdField.placeholderString = "YOUR_CLIENT_ID.apps.googleusercontent.com"
        googleClientIdField.stringValue = UserDefaults.standard.string(forKey: GoogleConfig.clientIdDefaultsKey) ?? ""
        googleClientIdField.font = .systemFont(ofSize: 12)
        googleClientIdField.translatesAutoresizingMaskIntoConstraints = false
        googleClientIdField.widthAnchor.constraint(equalToConstant: 400).isActive = true
        self.googleClientIdField = googleClientIdField

        let googleHint = NSTextField(labelWithString: "OAuth 2.0 Client ID from Google Cloud Console (Desktop app type). Required for Gmail sign-in.")
        googleHint.font = .systemFont(ofSize: 11)
        googleHint.textColor = .secondaryLabelColor
        googleHint.lineBreakMode = .byWordWrapping
        googleHint.preferredMaxLayoutWidth = 400

        let saveGoogleButton = CursorButton(title: "Save Client ID", target: self, action: #selector(saveGoogleClientId))
        saveGoogleButton.bezelStyle = .rounded

        // About
        let aboutHeader = Self.sectionHeader("About")
        let versionLabel = NSTextField(labelWithString: "LiteMail v0.2.0 — Multi-account IMAP/JMAP")
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [
            accountHeader, scrollView, accountButtons,
            Self.spacer(),
            statsHeader, countLabel, syncButton,
            Self.spacer(),
            sigHeader, sigField, saveSigButton,
            Self.spacer(),
            googleHeader, googleClientIdField, googleHint, saveGoogleButton,
            Self.spacer(),
            aboutHeader, versionLabel,
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

    @objc private func saveSignature() {
        let sig = signatureField?.stringValue ?? ""
        UserDefaults.standard.set(sig, forKey: "email_signature")
        let alert = NSAlert()
        alert.messageText = "Signature saved"
        alert.alertStyle = .informational
        alert.runModal()
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
