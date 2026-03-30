import AppKit

/// Settings/preferences window for account management and sync configuration.
final class SettingsWindow: NSObject {

    private let window: NSWindow

    var onSignOut: (() -> Void)?
    var onSyncNow: (() -> Void)?

    init(userEmail: String, emailCount: Int, lastSync: Date?) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()

        super.init()

        let container = NSView()

        // Account section
        let accountHeader = Self.sectionHeader("Account")
        let emailLabel = NSTextField(labelWithString: userEmail)
        emailLabel.font = .systemFont(ofSize: 13)

        let signOutButton = NSButton(title: "Sign Out", target: self, action: #selector(signOutClicked))
        signOutButton.bezelStyle = .rounded

        // Sync section
        let syncHeader = Self.sectionHeader("Sync")

        let countLabel = NSTextField(labelWithString: "Emails stored: \(emailCount)")
        countLabel.font = .systemFont(ofSize: 13)

        let lastSyncLabel = NSTextField(labelWithString: "Last sync: \(Self.formatDate(lastSync))")
        lastSyncLabel.font = .systemFont(ofSize: 13)
        lastSyncLabel.textColor = .secondaryLabelColor

        let syncButton = NSButton(title: "Sync Now", target: self, action: #selector(syncNowClicked))
        syncButton.bezelStyle = .rounded

        // About section
        let aboutHeader = Self.sectionHeader("About")
        let versionLabel = NSTextField(labelWithString: "LiteMail v0.1.0")
        versionLabel.font = .systemFont(ofSize: 13)
        versionLabel.textColor = .secondaryLabelColor

        let descLabel = NSTextField(labelWithString: "Lightweight native macOS mail client")
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = .tertiaryLabelColor

        // Layout
        let stack = NSStackView(views: [
            accountHeader, emailLabel, signOutButton,
            Self.spacer(),
            syncHeader, countLabel, lastSyncLabel, syncButton,
            Self.spacer(),
            aboutHeader, versionLabel, descLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])

        window.contentView = container
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func signOutClicked() {
        let alert = NSAlert()
        alert.messageText = "Sign Out"
        alert.informativeText = "This will remove your account credentials. You'll need to sign in again."
        alert.addButton(withTitle: "Sign Out")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            onSignOut?()
            window.close()
        }
    }

    @objc private func syncNowClicked() {
        onSyncNow?()
    }

    // MARK: - Helpers

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

    private static func formatDate(_ date: Date?) -> String {
        guard let date else { return "Never" }
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }
}
