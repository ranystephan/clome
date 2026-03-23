import AppKit

/// Delegate for result selection events.
@MainActor
protocol LauncherResultsDelegate: AnyObject {
    func resultsView(_ view: LauncherResultsView, didSelectItem item: LauncherItem)
    func resultsView(_ view: LauncherResultsView, didActivateItem item: LauncherItem)
}

/// Scrollable list of launcher results with section headers.
@MainActor
class LauncherResultsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    weak var resultsDelegate: LauncherResultsDelegate?

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
    private let emptyStateLabel = NSTextField(labelWithString: "")

    /// Flat list of displayable rows (headers + items).
    private var rows: [Row] = []

    /// All items, used for index lookup.
    private var allItems: [LauncherItem] = []

    /// Currently selected item index in the `rows` array.
    var selectedRow: Int {
        get { tableView.selectedRow }
        set {
            if newValue >= 0 && newValue < rows.count {
                tableView.selectRowIndexes(IndexSet(integer: newValue), byExtendingSelection: false)
                tableView.scrollRowToVisible(newValue)
            }
        }
    }

    /// The currently selected LauncherItem, if any.
    var selectedItem: LauncherItem? {
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count else { return nil }
        if case .item(let item) = rows[row] { return item }
        return nil
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setupViews() {
        // Table view
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 48
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(doubleClicked)
        tableView.target = self

        // Scroll view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        addSubview(scrollView)

        // Empty state label
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.font = .systemFont(ofSize: 13, weight: .regular)
        emptyStateLabel.textColor = NSColor(white: 0.35, alpha: 1.0)
        emptyStateLabel.alignment = .center
        emptyStateLabel.isHidden = true
        addSubview(emptyStateLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyStateLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// Update the displayed results, grouped by section.
    /// - Parameters:
    ///   - sections: The result sections to display.
    ///   - query: The current search query (used to determine empty state message).
    func updateResults(_ sections: [(title: String, items: [LauncherItem])], query: String = "") {
        rows.removeAll()
        allItems.removeAll()

        for section in sections {
            guard !section.items.isEmpty else { continue }
            rows.append(.header(section.title))
            for item in section.items {
                rows.append(.item(item))
                allItems.append(item)
            }
        }

        tableView.reloadData()

        // Show/hide empty state
        if allItems.isEmpty {
            let trimmedQuery = query.trimmingCharacters(in: .whitespaces)
            emptyStateLabel.stringValue = trimmedQuery.isEmpty
                ? "Type to search..."
                : "No results for \"\(trimmedQuery)\""
            emptyStateLabel.isHidden = false
            scrollView.isHidden = true
        } else {
            emptyStateLabel.isHidden = true
            scrollView.isHidden = false
        }

        // Auto-select first item row
        if let firstItemIndex = rows.firstIndex(where: { if case .item = $0 { return true } else { return false } }) {
            selectedRow = firstItemIndex
        }
    }

    // MARK: - Keyboard Navigation

    func moveSelectionDown() {
        let current = tableView.selectedRow
        var next = current + 1
        while next < rows.count {
            if case .item = rows[next] {
                selectedRow = next
                notifySelection()
                return
            }
            next += 1
        }
    }

    func moveSelectionUp() {
        let current = tableView.selectedRow
        var prev = current - 1
        while prev >= 0 {
            if case .item = rows[prev] {
                selectedRow = prev
                notifySelection()
                return
            }
            prev -= 1
        }
    }

    func activateSelection() {
        if let item = selectedItem {
            resultsDelegate?.resultsView(self, didActivateItem: item)
        }
    }

    private func notifySelection() {
        if let item = selectedItem {
            resultsDelegate?.resultsView(self, didSelectItem: item)
        }
    }

    @objc private func doubleClicked() {
        activateSelection()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            return makeSectionHeader(title)
        case .item(let item):
            let rowView = LauncherResultRowView()
            rowView.configure(with: item)
            return rowView
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header: return 28
        case .item(let item):
            return (item.subtitle != nil && !item.subtitle!.isEmpty) ? 48 : 36
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = rows[row] { return false }
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateVisibleRowSelection()
        notifySelection()
    }

    private func updateVisibleRowSelection() {
        let selectedIndex = tableView.selectedRow
        let visibleRange = tableView.rows(in: tableView.visibleRect)
        for row in visibleRange.location..<(visibleRange.location + visibleRange.length) {
            guard row >= 0, row < rows.count else { continue }
            if let cellView = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? LauncherResultRowView {
                cellView.isItemSelected = (row == selectedIndex)
            }
        }
    }

    // MARK: - Section Header

    private func makeSectionHeader(_ title: String) -> NSView {
        let container = NSView()
        let label = NSTextField(labelWithString: title.uppercased())
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = NSColor(white: 0.38, alpha: 1.0)
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        return container
    }

    // MARK: - Row Type

    private enum Row {
        case header(String)
        case item(LauncherItem)
    }
}
