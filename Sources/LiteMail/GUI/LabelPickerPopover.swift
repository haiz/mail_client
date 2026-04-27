import AppKit

/// NSViewController shown in an NSPopover for applying / removing labels.
final class LabelPickerViewController: NSViewController {

    var onConfirm: ((_ toAdd: [String], _ toRemove: [String]) -> Void)?
    var onCreateNew: ((String) -> Void)?

    private var allLabels: [String] = []
    var applied: Set<String> = []
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private var filtered: [String] = []

    init(labels: [String], applied: Set<String>) {
        self.allLabels = labels
        self.applied = applied
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 280).isActive = true
        container.heightAnchor.constraint(equalToConstant: 320).isActive = true
        self.view = container

        searchField.placeholderString = "Search labels..."
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Label"))
        column.isEditable = false
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let createButton = CursorButton(title: "+ Create new label", target: self, action: #selector(createNewClicked))
        createButton.bezelStyle = .inline
        createButton.font = .systemFont(ofSize: 11)
        createButton.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(searchField)
        container.addSubview(scrollView)
        container.addSubview(createButton)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: createButton.topAnchor, constant: -4),

            createButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            createButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
        ])

        applyFilter("")
    }

    private func applyFilter(_ query: String) {
        if query.isEmpty {
            filtered = allLabels
        } else {
            filtered = allLabels.filter { $0.lowercased().contains(query.lowercased()) }
        }
        tableView.reloadData()
    }

    @objc private func searchChanged() {
        applyFilter(searchField.stringValue)
    }

    @objc private func createNewClicked() {
        let name = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        onCreateNew?(name)
        allLabels.append(name)
        applied.insert(name)
        applyFilter("")
    }
}

extension LabelPickerViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
}

extension LabelPickerViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filtered.count else { return nil }
        let label = filtered[row]
        let cellId = NSUserInterfaceItemIdentifier("LabelCell")
        let cell: NSTableCellView
        if let recycled = tableView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView {
            cell = recycled
        } else {
            cell = NSTableCellView()
            cell.identifier = cellId
            let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            checkbox.identifier = NSUserInterfaceItemIdentifier("checkbox")
            checkbox.translatesAutoresizingMaskIntoConstraints = false
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            cell.addSubview(checkbox)
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                checkbox.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                textField.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            ])
        }
        let checkbox = cell.subviews.first { $0.identifier?.rawValue == "checkbox" } as? NSButton
        cell.textField?.stringValue = label
        checkbox?.state = applied.contains(label) ? .on : .off
        checkbox?.target = self
        checkbox?.action = #selector(checkboxToggled(_:))
        checkbox?.tag = filtered.firstIndex(of: label) ?? 0
        return cell
    }

    @objc private func checkboxToggled(_ sender: NSButton) {
        let idx = sender.tag
        guard idx < filtered.count else { return }
        let label = filtered[idx]
        if applied.contains(label) {
            applied.remove(label)
        } else {
            applied.insert(label)
        }
        tableView.reloadData(forRowIndexes: IndexSet(integer: idx), columnIndexes: IndexSet(integer: 0))
    }
}

// MARK: - Public wrapper

/// Manages NSPopover lifecycle for label picking.
final class LabelPickerPopover: NSObject {

    private(set) var isVisible: Bool = false
    var onLabelsChanged: ((_ toAdd: [String], _ toRemove: [String]) -> Void)?
    var onCreateNew: ((String) -> Void)?

    func show(relativeTo view: NSView, labels: [String], applied: Set<String>) {
        let vc = LabelPickerViewController(labels: labels, applied: applied)
        let initialApplied = applied

        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .semitransient
        popover.delegate = self
        isVisible = true

        vc.onConfirm = { [weak self] toAdd, toRemove in
            self?.onLabelsChanged?(toAdd, toRemove)
            popover.close()
        }
        vc.onCreateNew = { [weak self] name in
            self?.onCreateNew?(name)
        }

        // Wire popover close to compute diff
        vc.loadViewIfNeeded()
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)

        // When popover closes, compute diff between initialApplied and final state
        NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover, queue: .main) { [weak self] _ in
            guard let self else { return }
            let toAdd = Array(vc.applied.subtracting(initialApplied))
            let toRemove = Array(initialApplied.subtracting(vc.applied))
            if !toAdd.isEmpty || !toRemove.isEmpty {
                self.onLabelsChanged?(toAdd, toRemove)
            }
            self.isVisible = false
        }
    }
}

extension LabelPickerPopover: NSPopoverDelegate {}
