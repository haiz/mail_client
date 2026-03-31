import AppKit

/// Sheet for adding a new email account.
/// Step 1: Enter email address → auto-discovery runs.
/// Step 2: Show discovered config (or manual form) → confirm.
final class AddAccountSheet: NSObject {

    private let sheet: NSWindow
    private let emailField: NSTextField
    private let statusLabel: NSTextField
    private let addButton: NSButton
    private let cancelButton: NSButton
    private let progressIndicator: NSProgressIndicator

    // Manual config fields (shown after discovery or on fallback)
    private let protocolPicker: NSPopUpButton
    private let usernameField: NSTextField
    private let hostField: NSTextField
    private let portField: NSTextField
    private let smtpHostField: NSTextField
    private let smtpPortField: NSTextField
    private let passwordField: NSSecureTextField
    private let manualStack: NSStackView

    private var discoveryResult: AutoDiscovery.Result?

    /// Called when user clicks Connect. Returns config + password.
    /// The caller must attempt connection and call the completion handler
    /// with nil on success or an error message on failure.
    var onAddAccount: ((AccountConfig, String?, @escaping (String?) -> Void) -> Void)?

    override init() {
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        sheet.title = "Add Account"

        emailField = NSTextField()
        emailField.placeholderString = "your@email.com"
        emailField.font = .systemFont(ofSize: 14)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = true

        progressIndicator = NSProgressIndicator()
        progressIndicator.style = .spinning
        progressIndicator.isHidden = true
        progressIndicator.controlSize = .small

        addButton = NSButton(title: "Add Account", target: nil, action: nil)
        addButton.bezelStyle = .rounded
        addButton.keyEquivalent = "\r"

        cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        // Manual config fields
        protocolPicker = NSPopUpButton()
        protocolPicker.addItems(withTitles: ["IMAP", "JMAP"])

        usernameField = NSTextField()
        usernameField.placeholderString = "Username (default: email address)"

        hostField = NSTextField()
        hostField.placeholderString = "imap.example.com"

        portField = NSTextField()
        portField.placeholderString = "993"

        smtpHostField = NSTextField()
        smtpHostField.placeholderString = "smtp.example.com"

        smtpPortField = NSTextField()
        smtpPortField.placeholderString = "465"

        passwordField = NSSecureTextField()
        passwordField.placeholderString = "Password or API token"

        manualStack = NSStackView()
        manualStack.orientation = .vertical
        manualStack.spacing = 8
        manualStack.isHidden = true

        super.init()

        addButton.target = self
        addButton.action = #selector(addClicked)
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)

        setupLayout()
    }

    func show(relativeTo parentWindow: NSWindow) {
        parentWindow.beginSheet(sheet)
    }

    // MARK: - Layout

    private func setupLayout() {
        let container = NSView()

        let titleLabel = NSTextField(labelWithString: "Add Email Account")
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)

        let subtitleLabel = NSTextField(labelWithString: "Enter your email address. LiteMail will auto-detect your server settings.")
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.preferredMaxLayoutWidth = 380

        let emailLabel = NSTextField(labelWithString: "Email:")
        emailLabel.font = .systemFont(ofSize: 12, weight: .medium)

        // Manual config rows
        func row(_ label: String, _ field: NSView) -> NSStackView {
            let lbl = NSTextField(labelWithString: label)
            lbl.font = .systemFont(ofSize: 11, weight: .medium)
            lbl.textColor = .secondaryLabelColor
            lbl.widthAnchor.constraint(equalToConstant: 80).isActive = true
            lbl.alignment = .right
            let r = NSStackView(views: [lbl, field])
            r.spacing = 8
            return r
        }

        manualStack.addArrangedSubview(row("Protocol:", protocolPicker))
        manualStack.addArrangedSubview(row("Username:", usernameField))
        manualStack.addArrangedSubview(row("Server:", hostField))
        manualStack.addArrangedSubview(row("Port:", portField))
        manualStack.addArrangedSubview(row("SMTP:", smtpHostField))
        manualStack.addArrangedSubview(row("SMTP Port:", smtpPortField))
        manualStack.addArrangedSubview(row("Password:", passwordField))

        let buttonStack = NSStackView(views: [cancelButton, addButton])
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        let mainStack = NSStackView(views: [
            titleLabel, subtitleLabel,
            emailLabel, emailField,
            statusLabel, progressIndicator,
            manualStack,
        ])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 10
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(mainStack)
        container.addSubview(buttonStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),

            // Buttons pinned to bottom-right, always visible
            buttonStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            buttonStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),

            emailField.widthAnchor.constraint(equalToConstant: 380),
            usernameField.widthAnchor.constraint(equalToConstant: 280),
            hostField.widthAnchor.constraint(equalToConstant: 280),
            smtpHostField.widthAnchor.constraint(equalToConstant: 280),
            passwordField.widthAnchor.constraint(equalToConstant: 280),
        ])

        sheet.contentView = container
    }

    // MARK: - Actions

    @objc private func addClicked() {
        let email = emailField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty, email.contains("@") else {
            statusLabel.stringValue = "Please enter a valid email address."
            statusLabel.textColor = .systemRed
            statusLabel.isHidden = false
            return
        }

        if discoveryResult != nil || !manualStack.isHidden {
            // We have config — create the account
            confirmAccount(email: email)
        } else {
            // Run auto-discovery
            runDiscovery(email: email)
        }
    }

    @objc private func cancelClicked() {
        sheet.sheetParent?.endSheet(sheet)
    }

    private func runDiscovery(email: String) {
        statusLabel.stringValue = "Discovering server settings..."
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = false
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
        addButton.isEnabled = false

        Task { @MainActor in
            let result = await AutoDiscovery.discover(email: email)
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
            addButton.isEnabled = true

            if let result {
                self.discoveryResult = result
                let providerName = result.providerName ?? result.protocolType.rawValue.uppercased()
                statusLabel.stringValue = "Found: \(providerName) (\(result.protocolType.rawValue.uppercased()))"
                statusLabel.textColor = .systemGreen

                // Pre-fill manual fields
                protocolPicker.selectItem(withTitle: result.protocolType == .jmap ? "JMAP" : "IMAP")
                hostField.stringValue = result.imapHost ?? result.jmapUrl ?? ""
                portField.stringValue = result.imapPort.map(String.init) ?? ""
                smtpHostField.stringValue = result.smtpHost ?? ""
                smtpPortField.stringValue = result.smtpPort.map(String.init) ?? ""

                // Show manual fields for password entry
                manualStack.isHidden = false
                addButton.title = "Connect"
            } else {
                statusLabel.stringValue = "Could not auto-detect. Enter settings manually."
                statusLabel.textColor = .systemOrange
                manualStack.isHidden = false
                addButton.title = "Connect"
            }
        }
    }

    private func confirmAccount(email: String) {
        let isJMAP = protocolPicker.titleOfSelectedItem == "JMAP"
        let password = passwordField.stringValue

        let username = usernameField.stringValue.trimmingCharacters(in: .whitespaces)

        let config = AccountConfig(
            id: UUID().uuidString,
            emailAddress: email,
            displayName: nil,
            protocolType: isJMAP ? .jmap : .imap,
            imapUsername: username.isEmpty ? nil : username,
            imapHost: isJMAP ? nil : hostField.stringValue.isEmpty ? nil : hostField.stringValue,
            imapPort: Int(portField.stringValue),
            smtpHost: smtpHostField.stringValue.isEmpty ? nil : smtpHostField.stringValue,
            smtpPort: Int(smtpPortField.stringValue),
            jmapUrl: isJMAP ? hostField.stringValue : nil,
            authType: discoveryResult?.authType ?? .password,
            keychainRef: "account-\(UUID().uuidString)",
            isDefault: false
        )

        // Show connecting state
        statusLabel.stringValue = "Connecting..."
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = false
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
        addButton.isEnabled = false
        cancelButton.isEnabled = false

        onAddAccount?(config, password.isEmpty ? nil : password) { [weak self] errorMessage in
            guard let self else { return }
            DispatchQueue.main.async {
                self.progressIndicator.stopAnimation(nil)
                self.progressIndicator.isHidden = true
                self.addButton.isEnabled = true
                self.cancelButton.isEnabled = true

                if let errorMessage {
                    // Connection failed — show error, stay on sheet
                    self.statusLabel.stringValue = errorMessage
                    self.statusLabel.textColor = .systemRed
                } else {
                    // Success — close sheet
                    self.statusLabel.stringValue = "Connected!"
                    self.statusLabel.textColor = .systemGreen
                    self.sheet.sheetParent?.endSheet(self.sheet)
                }
            }
        }
    }
}
