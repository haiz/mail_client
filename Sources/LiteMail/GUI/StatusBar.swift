import AppKit

/// Status bar at the bottom of the window showing connection state,
/// memory usage, email count, and sync status.
final class StatusBar: NSView {

    private let connectionLabel = NSTextField(labelWithString: "")
    private let memoryLabel = NSTextField(labelWithString: "")
    private let emailCountLabel = NSTextField(labelWithString: "")
    private let syncLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "\u{2318}K Command Palette")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor

        let topBorder = NSBox()
        topBorder.boxType = .separator
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBorder)

        let labels = [connectionLabel, memoryLabel, emailCountLabel, syncLabel, shortcutLabel]
        let stack = NSStackView(views: labels)
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for label in labels {
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            label.textColor = .tertiaryLabelColor
        }

        shortcutLabel.alignment = .right

        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(equalToConstant: 24),
        ])

        updateConnection(status: .disconnected)
        updateMemory()
        updateEmailCount(0)

        // Refresh memory display every 5 seconds
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateMemory()
        }
    }

    // MARK: - Updates

    enum ConnectionStatus {
        case connected, syncing, reconnecting, disconnected, offline
    }

    func updateConnection(status: ConnectionStatus) {
        switch status {
        case .connected:
            connectionLabel.stringValue = "Connected"
            connectionLabel.textColor = .systemGreen
        case .syncing:
            connectionLabel.stringValue = "Syncing..."
            connectionLabel.textColor = .controlAccentColor
        case .reconnecting:
            connectionLabel.stringValue = "Reconnecting..."
            connectionLabel.textColor = .systemOrange
        case .disconnected:
            connectionLabel.stringValue = "Disconnected"
            connectionLabel.textColor = .tertiaryLabelColor
        case .offline:
            connectionLabel.stringValue = "Offline"
            connectionLabel.textColor = .secondaryLabelColor
        }
    }

    func updateEmailCount(_ count: Int) {
        emailCountLabel.stringValue = "Emails: \(Self.formatNumber(count))"
    }

    func updateSyncStatus(_ text: String) {
        syncLabel.stringValue = text
    }

    func updateMemory() {
        let mb = Self.residentMemoryMB()
        memoryLabel.stringValue = "RAM: \(String(format: "%.1f", mb)) MB"
        memoryLabel.textColor = mb < 30 ? .systemGreen : (mb < 50 ? .systemOrange : .systemRed)
    }

    // MARK: - Helpers

    private static func residentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            return Double(info.resident_size) / 1_048_576.0
        }
        return 0
    }

    private static func formatNumber(_ n: Int) -> String {
        if n >= 1000 {
            return String(format: "%.1fk", Double(n) / 1000.0)
        }
        return "\(n)"
    }
}
