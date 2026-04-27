import AppKit

final class KeyboardCheatSheetWindow: NSPanel {

    static let shared = KeyboardCheatSheetWindow()

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView, .hudWindow],
            backing: .buffered,
            defer: false
        )
        title = "Keyboard Shortcuts"
        isReleasedWhenClosed = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        contentView = buildContent()
    }

    func toggle() {
        if isVisible { close() } else { show() }
    }

    func show() {
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.midX - frame.width / 2
            let y = screen.visibleFrame.midY - frame.height / 2
            setFrameOrigin(NSPoint(x: x, y: y))
        }
        makeKeyAndOrderFront(nil)
    }

    private func buildContent() -> NSView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let grouped = Dictionary(grouping: KeyboardShortcuts.all, by: { $0.0.section })
        let sectionOrder = ["Navigation", "Actions", "Compose", "Go To"]
        for section in sectionOrder {
            guard let pairs = grouped[section] else { continue }
            let header = NSTextField(labelWithString: section.uppercased())
            header.font = .systemFont(ofSize: 10, weight: .semibold)
            header.textColor = .secondaryLabelColor
            stack.addArrangedSubview(header)
            for (shortcut, _) in pairs {
                stack.addArrangedSubview(makeRow(shortcut))
            }
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.heightAnchor.constraint(equalToConstant: 8).isActive = true
            stack.addArrangedSubview(spacer)
        }

        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        let container = NSView()
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func makeRow(_ shortcut: Shortcut) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: shortcut.label)
        label.font = .systemFont(ofSize: 13)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let keyLabel = NSTextField(labelWithString: shortcut.key == "\r" ? "↩" : shortcut.key)
        keyLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        keyLabel.textColor = .secondaryLabelColor
        keyLabel.alignment = .right
        keyLabel.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(label)
        row.addArrangedSubview(NSView()) // flexible spacer
        row.addArrangedSubview(keyLabel)
        row.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return row
    }
}
