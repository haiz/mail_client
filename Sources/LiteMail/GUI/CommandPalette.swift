import AppKit

/// Cmd+K command palette. Floating NSPanel with fuzzy search across actions.
/// Non-activating so it doesn't steal focus from the main window.
final class CommandPalette: NSObject {

    private let panel: NSPanel
    private let searchField: NSTextField
    private let tableView: NSTableView
    private let scrollView: NSScrollView

    var onAction: ((MailAction) -> Void)?

    private var allCommands: [PaletteCommand] = []
    private var filteredCommands: [PaletteCommand] = []
    private var keyboardMonitor: Any?

    var isVisible: Bool { panel.isVisible }

    init(parentWindow: NSWindow) {
        // Panel
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = true

        // Search field
        searchField = NSTextField()
        searchField.placeholderString = "Type a command..."
        searchField.font = .systemFont(ofSize: 16)
        searchField.isBordered = false
        searchField.focusRingType = .none
        searchField.drawsBackground = false
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        // Table view for results
        tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = 36
        tableView.selectionHighlightStyle = .regular
        tableView.intercellSpacing = NSSize(width: 0, height: 0)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("CommandColumn"))
        column.isEditable = false
        tableView.addTableColumn(column)

        scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        super.init()

        // Layout
        let contentView = NSView()
        contentView.addSubview(searchField)
        contentView.addSubview(separator)
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            separator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        panel.contentView = contentView

        tableView.dataSource = self
        tableView.delegate = self
        searchField.delegate = self

        // Position relative to parent
        if let parentFrame = parentWindow.contentView?.window?.frame {
            let x = parentFrame.midX - 240
            let y = parentFrame.midY + 50
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        loadCommands()
        filteredCommands = allCommands

        // Monitor Escape key — must retain the returned monitor object
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard self?.isVisible == true else { return event }
            if event.keyCode == 53 { // Escape
                self?.dismiss()
                return nil
            }
            if event.keyCode == 36 { // Enter
                self?.executeSelected()
                return nil
            }
            if event.keyCode == 125 { // Down arrow
                self?.selectNext()
                return nil
            }
            if event.keyCode == 126 { // Up arrow
                self?.selectPrevious()
                return nil
            }
            return event
        }
    }

    deinit {
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func show() {
        searchField.stringValue = ""
        filteredCommands = allCommands
        tableView.reloadData()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        if !filteredCommands.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func dismiss() {
        panel.orderOut(nil)
    }

    // MARK: - Commands

    private func loadCommands() {
        allCommands = [
            PaletteCommand(title: "Archive conversation", shortcut: "\u{2318}\u{21E7}A", action: .archive(0)),
            PaletteCommand(title: "Delete conversation", shortcut: "\u{2318}\u{232B}", action: .delete(0)),
            PaletteCommand(title: "Mark as read", shortcut: "R", action: .markRead(0)),
            PaletteCommand(title: "Mark as unread", shortcut: "U", action: .markUnread(0)),
            PaletteCommand(title: "Toggle star", shortcut: "S", action: .toggleStar(0)),
            PaletteCommand(title: "Compose new email", shortcut: "\u{2318}N", action: .compose),
            PaletteCommand(title: "Reply", shortcut: "\u{2318}R", action: .reply(0)),
            PaletteCommand(title: "Forward", shortcut: "\u{2318}F", action: .forward(0)),
            PaletteCommand(title: "Refresh inbox", shortcut: "\u{2318}\u{21E7}R", action: .refresh),
        ]
    }

    private func filterCommands(query: String) {
        if query.isEmpty {
            filteredCommands = allCommands
        } else {
            let lowered = query.lowercased()
            filteredCommands = allCommands.filter { $0.title.lowercased().contains(lowered) }
        }
        tableView.reloadData()
        if !filteredCommands.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private func executeSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredCommands.count else { return }
        let command = filteredCommands[row]
        dismiss()
        onAction?(command.action)
    }

    private func selectNext() {
        let next = min(tableView.selectedRow + 1, filteredCommands.count - 1)
        guard next >= 0 else { return }
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
    }

    private func selectPrevious() {
        let prev = max(tableView.selectedRow - 1, 0)
        tableView.selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
    }
}

// MARK: - NSTableViewDataSource

extension CommandPalette: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredCommands.count
    }
}

// MARK: - NSTableViewDelegate

extension CommandPalette: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredCommands.count else { return nil }
        let cmd = filteredCommands[row]

        let cellId = NSUserInterfaceItemIdentifier("CommandCell")
        let cell: NSTableCellView

        if let recycled = tableView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView {
            cell = recycled
        } else {
            cell = NSTableCellView()
            cell.identifier = cellId

            let titleLabel = NSTextField(labelWithString: "")
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.font = .systemFont(ofSize: 13)
            cell.addSubview(titleLabel)
            cell.textField = titleLabel

            let shortcutLabel = NSTextField(labelWithString: "")
            shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
            shortcutLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            shortcutLabel.textColor = .tertiaryLabelColor
            shortcutLabel.identifier = NSUserInterfaceItemIdentifier("shortcut")
            cell.addSubview(shortcutLabel)

            NSLayoutConstraint.activate([
                titleLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
                titleLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

                shortcutLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -16),
                shortcutLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        cell.textField?.stringValue = cmd.title
        let shortcutField = cell.subviews.first { $0.identifier?.rawValue == "shortcut" } as? NSTextField
        shortcutField?.stringValue = cmd.shortcut

        return cell
    }
}

// MARK: - NSTextFieldDelegate

extension CommandPalette: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        filterCommands(query: searchField.stringValue)
    }
}

// MARK: - Model

private struct PaletteCommand {
    let title: String
    let shortcut: String
    let action: MailAction
}
