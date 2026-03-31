import AppKit

/// Sidebar with account switcher dropdown at top, folder list below.
/// One account active at a time.
final class SidebarView: NSObject {

    let view: NSView
    private let accountPicker: NSPopUpButton
    private let scrollView: NSScrollView
    private let outlineView: NSOutlineView

    /// Called when a folder is selected. (accountId, folderId)
    var onFolderSelected: ((String, String) -> Void)?
    /// Called when user switches account via the dropdown.
    var onAccountSwitched: ((String) -> Void)?

    private var accounts: [(id: String, email: String)] = []
    private var currentAccountId: String?
    private var mailboxes: [SidebarItem] = []

    override init() {
        // Account picker dropdown
        accountPicker = NSPopUpButton()
        accountPicker.font = .systemFont(ofSize: 12, weight: .medium)
        accountPicker.translatesAutoresizingMaskIntoConstraints = false

        // Outline view
        outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.indentationPerLevel = 14
        outlineView.rowHeight = 28
        outlineView.style = .sourceList

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarColumn"))
        column.isEditable = false
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        // Scroll view
        scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Container: picker on top, folder list below
        let container = NSView()
        container.addSubview(accountPicker)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            accountPicker.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            accountPicker.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            accountPicker.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: accountPicker.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        view = container

        super.init()

        outlineView.dataSource = self
        outlineView.delegate = self
        accountPicker.target = self
        accountPicker.action = #selector(accountPickerChanged)

        loadDefaultMailboxes()
    }

    // MARK: - Public API

    /// Sets available accounts in the dropdown. Selects the given accountId.
    func setAccounts(_ accountList: [(id: String, email: String)], activeId: String?) {
        accounts = accountList
        accountPicker.removeAllItems()

        for account in accountList {
            accountPicker.addItem(withTitle: account.email)
            accountPicker.lastItem?.representedObject = account.id
        }

        // Always show — even with 1 account, user needs to see which account is active
        accountPicker.isHidden = false

        if let activeId, let index = accountList.firstIndex(where: { $0.id == activeId }) {
            accountPicker.selectItem(at: index)
        }
        currentAccountId = activeId ?? accountList.first?.id
    }

    /// Updates the folder list for the current account.
    func updateFolders(_ folders: [MailFolder]) {
        let section = SidebarItem(title: "Mailboxes", icon: nil, folderId: nil, children: folders.map { folder in
            let icon = Self.iconForFolder(folder.id)
            return SidebarItem(title: folder.name, icon: icon, folderId: folder.id, unreadCount: folder.unreadCount, accountId: currentAccountId)
        })
        mailboxes = [section]
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)

        if let inboxRow = findRow(folderId: "INBOX") {
            outlineView.selectRowIndexes(IndexSet(integer: inboxRow), byExtendingSelection: false)
        }
    }

    // MARK: - Account Picker

    @objc private func accountPickerChanged() {
        guard let selectedId = accountPicker.selectedItem?.representedObject as? String else { return }
        currentAccountId = selectedId
        onAccountSwitched?(selectedId)
    }

    // MARK: - Defaults

    private func loadDefaultMailboxes() {
        let defaults: [(String, String, String)] = [
            ("Inbox", "tray.fill", "INBOX"),
            ("Starred", "star.fill", "[Gmail]/Starred"),
            ("Sent", "paperplane.fill", "[Gmail]/Sent Mail"),
            ("Drafts", "doc.text.fill", "[Gmail]/Drafts"),
            ("Trash", "trash.fill", "[Gmail]/Trash"),
        ]

        let children = defaults.map { (title, icon, folderId) in
            SidebarItem(title: title, icon: icon, folderId: folderId)
        }
        mailboxes = [SidebarItem(title: "Mailboxes", icon: nil, folderId: nil, children: children)]
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
    }

    private func findRow(folderId: String) -> Int? {
        for row in 0..<outlineView.numberOfRows {
            if let item = outlineView.item(atRow: row) as? SidebarItem, item.folderId == folderId {
                return row
            }
        }
        return nil
    }

    private static func iconForFolder(_ folderId: String) -> String {
        switch folderId {
        case "INBOX": return "tray.fill"
        case "[Gmail]/Starred": return "star.fill"
        case "[Gmail]/Sent Mail": return "paperplane.fill"
        case "[Gmail]/Drafts": return "doc.text.fill"
        case "[Gmail]/Trash": return "trash.fill"
        case "[Gmail]/All Mail": return "archivebox.fill"
        default: return "tag.fill"
        }
    }
}

// MARK: - NSOutlineViewDataSource

extension SidebarView: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return mailboxes.count }
        guard let section = item as? SidebarItem else { return 0 }
        return section.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return mailboxes[index] }
        guard let section = item as? SidebarItem else { return SidebarItem(title: "") }
        return section.children?[index] ?? SidebarItem(title: "")
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let sidebarItem = item as? SidebarItem else { return false }
        return sidebarItem.children != nil
    }
}

// MARK: - NSOutlineViewDelegate

extension SidebarView: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let sidebarItem = item as? SidebarItem else { return nil }

        let cellId = NSUserInterfaceItemIdentifier("SidebarCell")
        let cell: NSTableCellView

        if let recycled = outlineView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView {
            cell = recycled
        } else {
            cell = NSTableCellView()
            cell.identifier = cellId

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(imageView)
            cell.imageView = imageView

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            cell.addSubview(textField)
            cell.textField = textField

            let badge = NSTextField(labelWithString: "")
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.identifier = NSUserInterfaceItemIdentifier("badge")
            badge.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
            badge.textColor = .secondaryLabelColor
            badge.alignment = .right
            cell.addSubview(badge)

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),

                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                textField.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -4),

                badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
            ])
        }

        cell.textField?.stringValue = sidebarItem.title
        cell.textField?.font = sidebarItem.children != nil
            ? .systemFont(ofSize: 11, weight: .semibold)
            : .systemFont(ofSize: 13)
        cell.textField?.textColor = sidebarItem.children != nil
            ? .secondaryLabelColor
            : .labelColor

        if let iconName = sidebarItem.icon {
            cell.imageView?.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
            cell.imageView?.contentTintColor = .controlAccentColor
            cell.imageView?.isHidden = false
        } else {
            cell.imageView?.isHidden = true
        }

        let badgeField = cell.subviews.first { $0.identifier?.rawValue == "badge" } as? NSTextField
        if let count = sidebarItem.unreadCount, count > 0 {
            badgeField?.stringValue = "\(count)"
            badgeField?.isHidden = false
        } else {
            badgeField?.isHidden = true
        }

        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        guard let sidebarItem = item as? SidebarItem else { return false }
        return sidebarItem.children != nil
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem,
              let folderId = item.folderId else { return }
        let accountId = item.accountId ?? currentAccountId ?? "default"
        onFolderSelected?(accountId, folderId)
    }
}

// MARK: - Model

private class SidebarItem {
    let title: String
    let icon: String?
    let folderId: String?
    var unreadCount: Int?
    var children: [SidebarItem]?
    var accountId: String?

    init(title: String, icon: String? = nil, folderId: String? = nil, unreadCount: Int? = nil, children: [SidebarItem]? = nil, accountId: String? = nil) {
        self.title = title
        self.icon = icon
        self.folderId = folderId
        self.unreadCount = unreadCount
        self.children = children
        self.accountId = accountId
    }
}
