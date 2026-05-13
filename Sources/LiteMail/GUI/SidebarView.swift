import AppKit

/// Sidebar with account switcher at top, folder list below.
/// One account active at a time.
final class SidebarView: NSObject {

    let view: NSView
    private let accountSwitcher: AccountSwitcherView
    private let composeButton: NSButton
    private let refreshButton: NSButton
    private let scrollView: NSScrollView
    private let outlineView: NSOutlineView

    /// Called when a folder is selected. (accountId, folderId)
    var onFolderSelected: ((String, String, Int) -> Void)?
    /// Called when an email is dragged and dropped onto a folder. (emailId, folderId)
    var onMoveToFolder: ((Int64, String) -> Void)?
    /// Called when user switches account via the dropdown.
    var onAccountSwitched: ((String) -> Void)?
    /// Called when Compose button is clicked.
    var onCompose: (() -> Void)?
    /// Called when Refresh button is clicked.
    var onRefresh: (() -> Void)?
    /// Called when the user taps "fix sign-in" for an account with an auth error. Receives accountId.
    var onAuthErrorFix: ((String) -> Void)?

    private var accounts: [(id: String, email: String)] = []
    private var currentAccountId: String?
    private var authErrorAccountIds: Set<String> = []
    /// Top-level items: system folder leaves + section headers with children
    private var mailboxes: [SidebarItem] = []
    private var savedSearchItems: [SidebarItem] = []
    /// Maps folderId → (id, query) for saved search items
    private var savedSearchMeta: [String: (id: Int64, query: String)] = [:]

    /// Called when a saved search is selected. Passes the raw query string.
    var onSavedSearchSelected: ((String) -> Void)?
    /// Called when user wants to delete a saved search. Passes the saved search id.
    var onDeleteSavedSearch: ((Int64) -> Void)?

    override init() {
        // Custom account switcher card
        accountSwitcher = AccountSwitcherView()
        accountSwitcher.translatesAutoresizingMaskIntoConstraints = false

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

        // Action buttons
        composeButton = CursorButton(
            image: NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Compose")!,
            target: nil, action: nil
        )
        composeButton.bezelStyle = .accessoryBarAction
        composeButton.isBordered = false
        composeButton.toolTip = "New Message (\u{2318}N)"
        composeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        composeButton.contentTintColor = .secondaryLabelColor

        refreshButton = CursorButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")!,
            target: nil, action: nil
        )
        refreshButton.bezelStyle = .accessoryBarAction
        refreshButton.isBordered = false
        refreshButton.toolTip = "Sync (\u{2318}\u{21E7}R)"
        refreshButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        refreshButton.contentTintColor = .secondaryLabelColor

        let actionBar = NSStackView(views: [composeButton, refreshButton])
        actionBar.spacing = 8
        actionBar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        actionBar.distribution = .fillEqually
        actionBar.translatesAutoresizingMaskIntoConstraints = false

        // Container: account switcher on top, separator, action toolbar, folder list below
        let container = NSView()
        container.addSubview(accountSwitcher)
        container.addSubview(scrollView)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(separator)

        container.addSubview(actionBar)

        NSLayoutConstraint.activate([
            accountSwitcher.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            accountSwitcher.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            accountSwitcher.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            accountSwitcher.heightAnchor.constraint(equalToConstant: 52),

            separator.topAnchor.constraint(equalTo: accountSwitcher.bottomAnchor, constant: 6),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            actionBar.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 2),
            actionBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            actionBar.heightAnchor.constraint(equalToConstant: 32),

            scrollView.topAnchor.constraint(equalTo: actionBar.bottomAnchor, constant: 2),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        view = container

        super.init()

        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.registerForDraggedTypes([.string])
        composeButton.target = self
        composeButton.action = #selector(composeClicked)
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)

        accountSwitcher.onTap = { [weak self] in
            self?.showAccountMenu()
        }

        loadDefaultMailboxes()
    }

    // MARK: - Public API

    /// Sets available accounts. Selects the given accountId.
    func setAccounts(_ accountList: [(id: String, email: String)], activeId: String?) {
        accounts = accountList
        currentAccountId = activeId ?? accountList.first?.id

        let displayAccount = accountList.first(where: { $0.id == currentAccountId }) ?? accountList.first
        if let account = displayAccount {
            accountSwitcher.configure(email: account.email)
            accountSwitcher.setAuthError(authErrorAccountIds.contains(account.id))
        }
    }

    /// Updates the folder list for the current account, grouped into sections.
    func updateFolders(_ folders: [MailFolder]) {
        // Buckets
        var systemItems: [SidebarItem] = []
        var categoryItems: [SidebarItem] = []
        var labelItems: [SidebarItem] = []

        for folder in folders {
            let item = SidebarItem(
                title: folder.name,
                icon: Self.iconForFolder(folder.id, role: folder.role),
                folderId: folder.id,
                totalCount: folder.totalCount > 0 ? folder.totalCount : nil,
                unreadCount: folder.unreadCount > 0 ? folder.unreadCount : nil,
                hasUnread: folder.hasUnread,
                accountId: currentAccountId,
                role: folder.role
            )
            switch folder.role {
            case .inbox, .sent, .drafts, .trash, .spam, .starred, .archive, .all, .scheduled, .snoozed:
                systemItems.append(item)
            case .category:
                categoryItems.append(item)
            case nil:
                labelItems.append(item)
            }
        }

        // Sort system items by canonical order
        let systemOrder: [FolderRole] = [.inbox, .starred, .sent, .drafts, .scheduled, .snoozed, .spam, .trash, .archive, .all]
        systemItems.sort {
            let i = systemOrder.firstIndex(of: $0.role ?? .all) ?? 99
            let j = systemOrder.firstIndex(of: $1.role ?? .all) ?? 99
            return i < j
        }

        categoryItems.sort { $0.title < $1.title }
        labelItems.sort { $0.title < $1.title }

        var items = systemItems
        if !categoryItems.isEmpty {
            items.append(SidebarItem(title: "Categories", children: categoryItems))
        }
        if !labelItems.isEmpty {
            items.append(SidebarItem(title: "Labels", children: labelItems))
        }
        if !savedSearchItems.isEmpty {
            items.append(SidebarItem(title: "Saved", children: savedSearchItems))
        }

        // Preserve the user's current folder selection across reload.
        let previousFolderId: String? = {
            let row = outlineView.selectedRow
            guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem else { return nil }
            return item.folderId
        }()

        mailboxes = items
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)

        let targetFolder = previousFolderId ?? "INBOX"
        if let targetRow = findRow(folderId: targetFolder) {
            outlineView.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
        } else if let inboxRow = findRow(folderId: "INBOX") {
            outlineView.selectRowIndexes(IndexSet(integer: inboxRow), byExtendingSelection: false)
        }
    }

    /// Updates saved searches section. Pass an array of (id, name, query) tuples.
    func updateSavedSearches(_ searches: [(id: Int64, name: String, query: String)]) {
        savedSearchMeta = [:]
        savedSearchItems = searches.map { s in
            let fid = "__saved_search_\(s.id)__"
            savedSearchMeta[fid] = (id: s.id, query: s.query)
            return SidebarItem(title: s.name, icon: "magnifyingglass", folderId: fid)
        }
        // Remove any existing Saved section and re-add it
        mailboxes.removeAll { $0.isSection && $0.title == "Saved" }
        if !savedSearchItems.isEmpty {
            mailboxes.append(SidebarItem(title: "Saved", children: savedSearchItems))
        }
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
    }

    /// Marks or clears the auth-error badge for the given account.
    /// If that account is currently displayed, the badge updates immediately.
    func setAuthError(for accountId: String, hasError: Bool) {
        if hasError {
            authErrorAccountIds.insert(accountId)
        } else {
            authErrorAccountIds.remove(accountId)
        }
        if accountId == currentAccountId {
            accountSwitcher.setAuthError(hasError)
        }
    }

    // MARK: - Account Menu

    private func showAccountMenu() {
        guard !accounts.isEmpty else { return }
        let menu = NSMenu()

        // If the current account has an auth error, show a fix item at the top.
        if let currentId = currentAccountId, authErrorAccountIds.contains(currentId) {
            let fixItem = NSMenuItem(
                title: "⚠ Sign-in failed – tap to fix",
                action: #selector(authErrorMenuItemSelected(_:)),
                keyEquivalent: ""
            )
            fixItem.target = self
            fixItem.representedObject = currentId
            menu.addItem(fixItem)
            menu.addItem(.separator())
        }

        for account in accounts {
            let item = NSMenuItem(
                title: account.email,
                action: #selector(accountMenuItemSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = account.id
            if account.id == currentAccountId { item.state = .on }
            menu.addItem(item)
        }
        // Drop down below the switcher
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: accountSwitcher)
    }

    @objc private func accountMenuItemSelected(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let account = accounts.first(where: { $0.id == id }) else { return }
        currentAccountId = id
        accountSwitcher.configure(email: account.email)
        accountSwitcher.setAuthError(authErrorAccountIds.contains(id))
        onAccountSwitched?(id)
    }

    @objc private func authErrorMenuItemSelected(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onAuthErrorFix?(id)
    }

    @objc private func composeClicked() { onCompose?() }
    @objc private func refreshClicked() { onRefresh?() }

    // MARK: - Defaults

    private func loadDefaultMailboxes() {
        let defaults: [(String, String, String, FolderRole?)] = [
            ("Inbox", "tray.fill", "INBOX", .inbox),
            ("Starred", "star.fill", "[Gmail]/Starred", .starred),
            ("Sent", "paperplane.fill", "[Gmail]/Sent Mail", .sent),
            ("Drafts", "doc.text.fill", "[Gmail]/Drafts", .drafts),
            ("Scheduled", "clock.badge", "__scheduled__", .scheduled),
            ("Snoozed", "alarm.fill", "__snoozed__", .snoozed),
            ("Trash", "trash.fill", "[Gmail]/Trash", .trash),
        ]
        mailboxes = defaults.map { SidebarItem(title: $0.0, icon: $0.1, folderId: $0.2, role: $0.3) }
        outlineView.reloadData()
    }

    private func findRow(folderId: String) -> Int? {
        for row in 0..<outlineView.numberOfRows {
            if let item = outlineView.item(atRow: row) as? SidebarItem, item.folderId == folderId {
                return row
            }
        }
        return nil
    }

    private static func iconForFolder(_ folderId: String, role: FolderRole? = nil) -> String {
        switch role {
        case .inbox:   return "tray.fill"
        case .starred: return "star.fill"
        case .sent:    return "paperplane.fill"
        case .drafts:  return "doc.text.fill"
        case .trash:   return "trash.fill"
        case .spam:      return "xmark.bin.fill"
        case .scheduled: return "clock.badge"
        case .snoozed:   return "alarm.fill"
        case .archive, .all: return "archivebox.fill"
        case .category: return Self.iconForCategory(folderId)
        case nil:
            switch folderId {
            case "INBOX": return "tray.fill"
            default: return "tag.fill"
            }
        }
    }

    private static func iconForCategory(_ folderId: String) -> String {
        let name: String
        if let cat = GmailCategory(virtualFolderId: folderId) {
            name = cat.rawValue
        } else {
            // Legacy "[Gmail]/Category/Promotions" path
            name = folderId.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        }
        switch name {
        case "personal":   return "tray.fill"
        case "social":     return "person.2.fill"
        case "promotions": return "tag.fill"
        case "updates":    return "bell.fill"
        case "forums":     return "bubble.left.and.bubble.right.fill"
        case "purchases":  return "bag.fill"
        default:           return "tray.2.fill"
        }
    }
}

// MARK: - NSOutlineViewDataSource

extension SidebarView: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return mailboxes.count }
        return (item as? SidebarItem)?.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return mailboxes[index] }
        return (item as! SidebarItem).children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarItem)?.isSection ?? false
    }

    // MARK: - Drag & drop destination

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let sidebarItem = item as? SidebarItem, !sidebarItem.isSection, sidebarItem.folderId != nil else {
            return []
        }
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let sidebarItem = item as? SidebarItem, !sidebarItem.isSection,
              let folderId = sidebarItem.folderId,
              let idStr = info.draggingPasteboard.string(forType: .string),
              let emailId = Int64(idStr) else {
            return false
        }
        onMoveToFolder?(emailId, folderId)
        return true
    }
}

// MARK: - NSOutlineViewDelegate

extension SidebarView: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarItem)?.isSection ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !((item as? SidebarItem)?.isSection ?? false)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let sidebarItem = item as? SidebarItem else { return nil }

        // Section headers use the standard group cell
        if sidebarItem.isSection {
            let cellId = NSUserInterfaceItemIdentifier("SidebarGroupCell")
            let cell: NSTableCellView
            if let recycled = outlineView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView {
                cell = recycled
            } else {
                cell = NSTableCellView()
                cell.identifier = cellId
                let textField = NSTextField(labelWithString: "")
                textField.translatesAutoresizingMaskIntoConstraints = false
                textField.lineBreakMode = .byTruncatingTail
                cell.addSubview(textField)
                cell.textField = textField
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                ])
            }
            cell.textField?.stringValue = sidebarItem.title
            return cell
        }

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
        cell.textField?.font = sidebarItem.hasUnread
            ? .systemFont(ofSize: 13, weight: .semibold)
            : .systemFont(ofSize: 13)
        cell.textField?.textColor = .labelColor

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

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem,
              !item.isSection, let folderId = item.folderId else { return }
        if folderId.hasPrefix("__saved_search_") {
            if let meta = savedSearchMeta[folderId] {
                onSavedSearchSelected?(meta.query)
            }
            return
        }
        let accountId = item.accountId ?? currentAccountId ?? "default"
        onFolderSelected?(accountId, folderId, item.totalCount ?? 0)
    }
}

// MARK: - Account Switcher Card

/// Identity Card account switcher: 36px colored avatar, initials, display name + email two-line,
/// chevron.up.chevron.down picker affordance.
///
/// Rendering strategy: the card background uses wantsUpdateLayer so layer colors are captured
/// by cacheDisplay(). Text subviews live in a plain (non-wantsUpdateLayer) layer container so
/// NSTextField text renders normally in both live display and screenshot capture.
private final class AccountSwitcherView: NSView {

    var onTap: (() -> Void)?

    // Layer-backed containers (captured via layer compositing in cacheDisplay)
    private let avatarCircle = NSView()
    // Avatar text inside its own non-wantsUpdateLayer container — text renders correctly
    private let avatarLabel = NSTextField(labelWithString: "")
    // Text stack in a plain layer container so NSTextField renders correctly
    private let textContainer = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let emailLabel = NSTextField(labelWithString: "")
    private let chevron: NSImageView
    private let warningBadge: NSImageView

    private var avatarColor: NSColor = .controlAccentColor
    private var isHovered = false
    private var isPressed = false
    private var hasAuthError = false
    var authError: Bool { hasAuthError }

    private static let avatarColors: [NSColor] = [
        NSColor(red: 0.35, green: 0.56, blue: 0.97, alpha: 1), // Blue
        NSColor(red: 0.94, green: 0.42, blue: 0.42, alpha: 1), // Red
        NSColor(red: 0.26, green: 0.76, blue: 0.53, alpha: 1), // Green
        NSColor(red: 0.96, green: 0.65, blue: 0.14, alpha: 1), // Orange
        NSColor(red: 0.67, green: 0.44, blue: 0.86, alpha: 1), // Purple
        NSColor(red: 0.87, green: 0.36, blue: 0.58, alpha: 1), // Pink
        NSColor(red: 0.27, green: 0.71, blue: 0.73, alpha: 1), // Teal
    ]

    override init(frame frameRect: NSRect) {
        chevron = NSImageView(
            image: NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil) ?? NSImage()
        )
        warningBadge = NSImageView(
            image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Auth error") ?? NSImage()
        )
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8

        // 36px avatar circle
        avatarCircle.wantsLayer = true
        avatarCircle.layer?.cornerRadius = 18
        avatarCircle.translatesAutoresizingMaskIntoConstraints = false

        // Avatar initials: inside avatarCircle (not wantsUpdateLayer → text renders)
        avatarLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        avatarLabel.textColor = .white
        avatarLabel.alignment = .center
        avatarLabel.drawsBackground = false
        avatarLabel.isBordered = false
        avatarLabel.isEditable = false
        avatarLabel.translatesAutoresizingMaskIntoConstraints = false
        avatarCircle.addSubview(avatarLabel)
        NSLayoutConstraint.activate([
            avatarLabel.centerXAnchor.constraint(equalTo: avatarCircle.centerXAnchor),
            avatarLabel.centerYAnchor.constraint(equalTo: avatarCircle.centerYAnchor),
        ])

        // Text container: plain NSView (no wantsLayer) inside the wantsUpdateLayer parent.
        // NSTextField text rendering works via the normal draw path in this configuration.
        textContainer.translatesAutoresizingMaskIntoConstraints = false

        // Display name: 13pt semibold, primary label
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.drawsBackground = false
        nameLabel.isBordered = false
        nameLabel.isEditable = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        // Email address: 11pt regular, secondary
        emailLabel.font = .systemFont(ofSize: 11, weight: .regular)
        emailLabel.textColor = .secondaryLabelColor
        emailLabel.lineBreakMode = .byTruncatingTail
        emailLabel.drawsBackground = false
        emailLabel.isBordered = false
        emailLabel.isEditable = false
        emailLabel.translatesAutoresizingMaskIntoConstraints = false

        textContainer.addSubview(nameLabel)
        textContainer.addSubview(emailLabel)
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            nameLabel.bottomAnchor.constraint(equalTo: textContainer.centerYAnchor, constant: -1),

            emailLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            emailLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            emailLabel.topAnchor.constraint(equalTo: textContainer.centerYAnchor, constant: 1),
        ])

        // Picker chevron
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        // Warning badge: orange triangle, overlaid on bottom-right corner of avatar
        warningBadge.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        warningBadge.contentTintColor = .systemOrange
        warningBadge.translatesAutoresizingMaskIntoConstraints = false
        warningBadge.isHidden = true
        warningBadge.toolTip = "Sign-in failed — click to fix"

        addSubview(avatarCircle)
        addSubview(warningBadge)
        addSubview(textContainer)
        addSubview(chevron)

        NSLayoutConstraint.activate([
            // Avatar: 36×36, 10px from left, vertically centered
            avatarCircle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            avatarCircle.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatarCircle.widthAnchor.constraint(equalToConstant: 36),
            avatarCircle.heightAnchor.constraint(equalToConstant: 36),

            // Warning badge: 14×14, bottom-right of avatar circle
            warningBadge.widthAnchor.constraint(equalToConstant: 14),
            warningBadge.heightAnchor.constraint(equalToConstant: 14),
            warningBadge.trailingAnchor.constraint(equalTo: avatarCircle.trailingAnchor, constant: 3),
            warningBadge.bottomAnchor.constraint(equalTo: avatarCircle.bottomAnchor, constant: 3),

            // Chevron: 8px from right, vertically centered
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 11),
            chevron.heightAnchor.constraint(equalToConstant: 16),

            // Text container: fills space between avatar and chevron, full height
            textContainer.leadingAnchor.constraint(equalTo: avatarCircle.trailingAnchor, constant: 10),
            textContainer.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -4),
            textContainer.topAnchor.constraint(equalTo: topAnchor),
            textContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel("Account")
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let bg: NSColor
            if isPressed {
                bg = .labelColor.withAlphaComponent(0.13)
            } else if isHovered {
                bg = .labelColor.withAlphaComponent(0.07)
            } else {
                bg = .controlColor
            }
            layer?.backgroundColor = bg.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Updates the displayed account.
    func configure(email: String) {
        emailLabel.stringValue = email

        // Derive a readable display name from the local part
        let localPart = email.components(separatedBy: "@").first ?? email
        let words = localPart.replacingOccurrences(of: ".", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        nameLabel.stringValue = words.isEmpty ? email : words.joined(separator: " ")

        // Initials from name words (e.g. "John Doe" → "JD", "Hai" → "H")
        if words.count >= 2 {
            avatarLabel.stringValue = words.prefix(2).map { String($0.prefix(1)) }.joined()
        } else {
            avatarLabel.stringValue = String((words.first ?? email).prefix(1)).uppercased()
        }

        avatarColor = Self.avatarColors[abs(email.hashValue) % Self.avatarColors.count]
        avatarCircle.layer?.backgroundColor = avatarColor.cgColor
        setAccessibilityValue(email)
        needsDisplay = true
    }

    /// Shows or hides the auth-error warning badge.
    func setAuthError(_ error: Bool) {
        hasAuthError = error
        warningBadge.isHidden = !error
    }

    // MARK: - Hover & Click

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
        NSCursor.pointingHand.push()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        needsDisplay = true
        NSCursor.pop()
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isHovered = inside
        needsDisplay = true
        if inside {
            onTap?()
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }
}

// MARK: - Sidebar Model

private class SidebarItem {
    let title: String
    let icon: String?
    let folderId: String?
    var totalCount: Int?
    var unreadCount: Int?
    var hasUnread: Bool
    var accountId: String?
    var role: FolderRole?
    /// Non-nil for section headers (Categories, Labels). Leaf items have nil.
    var children: [SidebarItem]?

    var isSection: Bool { children != nil }

    /// Leaf folder item.
    init(title: String, icon: String? = nil, folderId: String? = nil, totalCount: Int? = nil,
         unreadCount: Int? = nil, hasUnread: Bool = false, accountId: String? = nil, role: FolderRole? = nil) {
        self.title = title
        self.icon = icon
        self.folderId = folderId
        self.totalCount = totalCount
        self.unreadCount = unreadCount
        self.hasUnread = hasUnread
        self.accountId = accountId
        self.role = role
    }

    /// Section header item.
    init(title: String, children: [SidebarItem]) {
        self.title = title
        self.icon = nil
        self.folderId = nil
        self.totalCount = nil
        self.unreadCount = nil
        self.hasUnread = false
        self.accountId = nil
        self.role = nil
        self.children = children
    }
}
