import AppKit

/// Message list with NSTableView, lazy row loading from GRDB, thread grouping.
/// View-based table with cell recycling for minimal memory usage.
final class MessageListView: NSObject {

    let view: NSView
    private let scrollView: NSScrollView
    let tableView: NSTableView
    private let searchField: NSSearchField

    var onMessageSelected: ((EmailHeader) -> Void)?
    var onSearchChanged: ((String) -> Void)?

    private(set) var messages: [EmailHeader] = []
    private(set) var selectedHeader: EmailHeader? {
        didSet {
            if let header = selectedHeader {
                onMessageSelected?(header)
            }
        }
    }

    override init() {
        // Search field at top
        searchField = NSSearchField()
        searchField.placeholderString = "Search emails... \u{2318}K"
        searchField.translatesAutoresizingMaskIntoConstraints = false

        // Table view
        tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = 64
        tableView.selectionHighlightStyle = .regular
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.gridStyleMask = []

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MessageColumn"))
        column.isEditable = false
        tableView.addTableColumn(column)

        // Scroll view
        scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Container
        let container = NSView()
        container.addSubview(searchField)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            searchField.heightAnchor.constraint(equalToConstant: 28),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        view = container

        super.init()

        tableView.dataSource = self
        tableView.delegate = self
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldChanged)
    }

    func update(messages: [EmailHeader]) {
        self.messages = messages
        tableView.reloadData()
        if !messages.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func selectNextRow() {
        let next = min(tableView.selectedRow + 1, messages.count - 1)
        guard next >= 0 else { return }
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    func selectPreviousRow() {
        let prev = max(tableView.selectedRow - 1, 0)
        tableView.selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
        tableView.scrollRowToVisible(prev)
    }

    @objc private func searchFieldChanged() {
        onSearchChanged?(searchField.stringValue)
    }
}

// MARK: - NSTableViewDataSource

extension MessageListView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        messages.count
    }
}

// MARK: - NSTableViewDelegate

extension MessageListView: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < messages.count else { return nil }
        let msg = messages[row]

        let cellId = NSUserInterfaceItemIdentifier("MessageCell")
        let cell: MessageCellView

        if let recycled = tableView.makeView(withIdentifier: cellId, owner: self) as? MessageCellView {
            cell = recycled
        } else {
            cell = MessageCellView()
            cell.identifier = cellId
        }

        cell.configure(with: msg)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < messages.count else {
            selectedHeader = nil
            return
        }
        selectedHeader = messages[row]
    }
}

// MARK: - NSSearchFieldDelegate

extension MessageListView: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        onSearchChanged?(searchField.stringValue)
    }
}

// MARK: - MessageCellView

private final class MessageCellView: NSTableCellView {

    private let senderLabel = NSTextField(labelWithString: "")
    private let subjectLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let starIcon = NSImageView()
    private let unreadDot = NSView()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        for v in [senderLabel, subjectLabel, dateLabel, starIcon, unreadDot] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        senderLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        senderLabel.lineBreakMode = .byTruncatingTail

        subjectLabel.font = .systemFont(ofSize: 12)
        subjectLabel.textColor = .secondaryLabelColor
        subjectLabel.lineBreakMode = .byTruncatingTail

        dateLabel.font = .systemFont(ofSize: 10)
        dateLabel.textColor = .tertiaryLabelColor
        dateLabel.alignment = .right
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        starIcon.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Starred")
        starIcon.contentTintColor = .systemYellow

        unreadDot.wantsLayer = true
        unreadDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        unreadDot.layer?.cornerRadius = 4

        NSLayoutConstraint.activate([
            unreadDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            unreadDot.centerYAnchor.constraint(equalTo: senderLabel.centerYAnchor),
            unreadDot.widthAnchor.constraint(equalToConstant: 8),
            unreadDot.heightAnchor.constraint(equalToConstant: 8),

            senderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            senderLabel.leadingAnchor.constraint(equalTo: unreadDot.trailingAnchor, constant: 6),
            senderLabel.trailingAnchor.constraint(lessThanOrEqualTo: dateLabel.leadingAnchor, constant: -8),

            dateLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            subjectLabel.topAnchor.constraint(equalTo: senderLabel.bottomAnchor, constant: 2),
            subjectLabel.leadingAnchor.constraint(equalTo: senderLabel.leadingAnchor),
            subjectLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            starIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            starIcon.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            starIcon.widthAnchor.constraint(equalToConstant: 12),
            starIcon.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    func configure(with header: EmailHeader) {
        senderLabel.stringValue = header.senderName ?? header.senderEmail
        senderLabel.font = header.isRead
            ? .systemFont(ofSize: 13)
            : .systemFont(ofSize: 13, weight: .semibold)
        senderLabel.textColor = header.isRead ? .secondaryLabelColor : .labelColor

        subjectLabel.stringValue = header.subject ?? "(no subject)"
        subjectLabel.textColor = header.isRead ? .tertiaryLabelColor : .secondaryLabelColor

        dateLabel.stringValue = Self.dateFormatter.string(from: header.date)

        starIcon.isHidden = !header.isStarred
        unreadDot.isHidden = header.isRead
    }
}
