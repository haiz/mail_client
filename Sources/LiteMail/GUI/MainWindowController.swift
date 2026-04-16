import AppKit

/// Main 3-pane window: Sidebar | Message List | Detail View
/// Plus Cmd+K command palette overlay.
final class MainWindowController: NSObject {

    let window: NSWindow
    private let splitView: NSSplitView
    let sidebarView: SidebarView
    let messageListView: MessageListView
    let threadDetailView: ThreadDetailView
    let statusBar: StatusBar
    let undoToastView = UndoToastView()
    private var commandPalette: CommandPalette?
    private var keyboardMonitor: Any?

    /// Callback when a folder is selected in the sidebar. (accountId, folderId)
    var onFolderSelected: ((String, String) -> Void)?
    /// Callback when a message is selected in the list.
    var onMessageSelected: ((EmailHeader) -> Void)?
    /// Callback for actions from command palette or keyboard.
    var onAction: ((MailAction) -> Void)?

    override init() {
        // Window
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LiteMail"
        window.center()
        window.minSize = NSSize(width: 800, height: 500)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unified

        // Split view
        splitView = CursorSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        // Subviews
        sidebarView = SidebarView()
        messageListView = MessageListView()
        threadDetailView = ThreadDetailView()
        statusBar = StatusBar()

        super.init()

        // Message list column: message list (contains BulkActionBar internally) + UndoToastView floating
        let messageColumn = NSView()
        messageListView.view.translatesAutoresizingMaskIntoConstraints = false
        undoToastView.translatesAutoresizingMaskIntoConstraints = false
        messageColumn.addSubview(messageListView.view)
        messageColumn.addSubview(undoToastView)

        NSLayoutConstraint.activate([
            messageListView.view.topAnchor.constraint(equalTo: messageColumn.topAnchor),
            messageListView.view.leadingAnchor.constraint(equalTo: messageColumn.leadingAnchor),
            messageListView.view.trailingAnchor.constraint(equalTo: messageColumn.trailingAnchor),
            messageListView.view.bottomAnchor.constraint(equalTo: messageColumn.bottomAnchor),

            // Undo toast: centered, 8px above the bottom of the column, 240px wide
            undoToastView.centerXAnchor.constraint(equalTo: messageColumn.centerXAnchor),
            undoToastView.bottomAnchor.constraint(equalTo: messageColumn.bottomAnchor, constant: -8),
            undoToastView.widthAnchor.constraint(equalToConstant: 240),
        ])

        // Assemble split view
        splitView.addArrangedSubview(sidebarView.view)
        splitView.addArrangedSubview(messageColumn)
        splitView.addArrangedSubview(threadDetailView.view)

        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 2)

        // Set initial widths
        sidebarView.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        messageColumn.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true

        // Main container with split view + status bar
        let mainContainer = NSView()
        splitView.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        mainContainer.addSubview(splitView)
        mainContainer.addSubview(statusBar)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: mainContainer.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: mainContainer.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: mainContainer.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: mainContainer.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: mainContainer.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: mainContainer.bottomAnchor),
        ])

        window.contentView = mainContainer
        splitView.delegate = self

        // Wire callbacks
        sidebarView.onFolderSelected = { [weak self] accountId, folder in
            self?.onFolderSelected?(accountId, folder)
        }
        messageListView.onMessageSelected = { [weak self] header in
            self?.onMessageSelected?(header)
        }
        messageListView.bulkActionBar.onArchive = { [weak self] in
            guard let self else { return }
            let ids = Array(messageListView.checkedIds)
            guard !ids.isEmpty else { return }
            onAction?(.batchArchive(ids))
        }
        messageListView.bulkActionBar.onDelete = { [weak self] in
            guard let self else { return }
            let ids = Array(messageListView.checkedIds)
            guard !ids.isEmpty else { return }
            onAction?(.batchDelete(ids))
        }
        messageListView.bulkActionBar.onMarkRead = { [weak self] in
            guard let self else { return }
            let ids = Array(messageListView.checkedIds)
            guard !ids.isEmpty else { return }
            onAction?(.batchMarkRead(ids))
        }
        messageListView.bulkActionBar.onStar = { [weak self] in
            guard let self else { return }
            let ids = Array(messageListView.checkedIds)
            guard !ids.isEmpty else { return }
            onAction?(.batchToggleStar(ids))
        }
        messageListView.bulkActionBar.onMove = { [weak self] in
            // Move requires folder selection — for now dispatch a placeholder;
            // the caller can intercept via onAction if needed.
            guard let self else { return }
            let ids = Array(messageListView.checkedIds)
            guard !ids.isEmpty else { return }
            onAction?(.batchMove(ids, ""))
        }
        messageListView.bulkActionBar.onSelectAll = { [weak self] in
            self?.messageListView.selectAllChecked()
        }
        messageListView.bulkActionBar.onDeselectAll = { [weak self] in
            self?.messageListView.clearCheckedIds()
        }

        // Keyboard monitor — must retain the returned monitor object
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
        }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        // Set initial divider positions after layout
        DispatchQueue.main.async { [self] in
            splitView.setPosition(200, ofDividerAt: 0)
            splitView.setPosition(540, ofDividerAt: 1)
        }
    }

    deinit {
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Keyboard Handling

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // Never intercept keys when a text field or text view has focus
        // (e.g. search field, compose window, add account sheet)
        if let responder = event.window?.firstResponder,
           responder is NSTextView || responder is NSTextField {
            // Exception: Cmd+K works everywhere
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "k" {
                toggleCommandPalette()
                return nil
            }
            return event
        }

        // Cmd+K → command palette
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "k" {
            toggleCommandPalette()
            return nil
        }

        // Cmd+Z → undo last batch action
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "z" {
            Task { @MainActor [weak self] in self?.undoToastView.performUndo() }
            return nil
        }

        // If command palette is visible, let it handle input
        if commandPalette?.isVisible == true {
            return event
        }

        // Only handle vim keys when our main window's table view is focused
        guard event.window === window,
              window.firstResponder === messageListView.tableView else {
            return event
        }

        switch event.charactersIgnoringModifiers {
        case "j":
            messageListView.selectNextRow()
            return nil
        case "k":
            messageListView.selectPreviousRow()
            return nil
        case "e":
            let checkedE = Array(messageListView.checkedIds)
            if !checkedE.isEmpty {
                onAction?(.batchArchive(checkedE))
            } else if let selected = messageListView.selectedHeader {
                onAction?(.archive(selected.id))
            }
            return nil
        case "s":
            let checkedS = Array(messageListView.checkedIds)
            if !checkedS.isEmpty {
                onAction?(.batchToggleStar(checkedS))
            } else if let selected = messageListView.selectedHeader {
                onAction?(.toggleStar(selected.id))
            }
            return nil
        case "r":
            let checkedR = Array(messageListView.checkedIds)
            if !checkedR.isEmpty {
                onAction?(.batchMarkRead(checkedR))
            } else if let selected = messageListView.selectedHeader {
                onAction?(.markRead(selected.id))
            }
            return nil
        case "\r": // Enter
            if let selected = messageListView.selectedHeader {
                onMessageSelected?(selected)
            }
            return nil
        default:
            break
        }

        // Delete/Backspace → delete checked or selected
        if event.keyCode == 51 {
            let checkedDel = Array(messageListView.checkedIds)
            if !checkedDel.isEmpty {
                onAction?(.batchDelete(checkedDel))
            } else if let selected = messageListView.selectedHeader {
                onAction?(.delete(selected.id))
            }
            return nil
        }

        // Escape → clear detail view
        if event.keyCode == 53 { // Escape
            threadDetailView.clear()
            return nil
        }

        return event
    }

    // MARK: - Command Palette

    private func toggleCommandPalette() {
        if let palette = commandPalette, palette.isVisible {
            palette.dismiss()
        } else {
            let palette = CommandPalette(parentWindow: window)
            palette.onAction = { [weak self] action in
                self?.onAction?(action)
            }
            palette.show()
            self.commandPalette = palette
        }
    }
}

// MARK: - NSSplitViewDelegate

extension MainWindowController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        switch dividerIndex {
        case 0: return 150  // Sidebar min width
        case 1: return 300  // Message list min width (from left edge)
        default: return proposedMinimumPosition
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        switch dividerIndex {
        case 0: return 250  // Sidebar max width
        default: return proposedMaximumPosition
        }
    }
}

// MARK: - Actions

enum MailAction {
    case archive(Int64)
    case delete(Int64)
    case toggleStar(Int64)
    case markRead(Int64)
    case markUnread(Int64)
    case moveToFolder(Int64, String)
    case compose
    case reply(Int64)
    case forward(Int64)
    case search(String)
    case refresh
    case batchDelete([Int64])
    case batchArchive([Int64])
    case batchMarkRead([Int64])
    case batchMarkUnread([Int64])
    case batchToggleStar([Int64])
    case batchMove([Int64], String)
}
