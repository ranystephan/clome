import AppKit

/// Native-feeling Claude session browser using system colors, vibrancy, and NSTableView.
class ClaudeSessionListView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    // MARK: - Callbacks

    var onSessionSelected: ((ClaudeSession) -> Void)?
    var onResumeSession: ((ClaudeSession) -> Void)?
    var onForkSession: ((ClaudeSession) -> Void)?
    var onResumeInNewTab: ((ClaudeSession) -> Void)?
    var onRenameSession: ((ClaudeSession, String) -> Void)?
    var onRefresh: (() -> Void)?

    // MARK: - State

    private var sessions: [ClaudeSession] = []
    private var filteredSessions: [ClaudeSession] = []
    private var searchQuery: String = ""

    // MARK: - Views

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No sessions found")

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setupUI() {
        wantsLayer = true

        // ── Search field (native NSSearchField) ──
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search"
        searchField.font = .systemFont(ofSize: 12)
        searchField.focusRingType = .none
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.delegate = self
        addSubview(searchField)

        // ── Separator ──
        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator
        addSubview(separator)

        // ── Table view ──
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.title = ""
        column.isEditable = false
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 52
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.selectionHighlightStyle = .regular
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(tableDoubleClicked(_:))
        tableView.target = self
        tableView.menu = makeTableMenu()

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        // ── Empty state ──
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        // ── Layout (8pt grid) ──
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            searchField.heightAnchor.constraint(equalToConstant: 28),

            separator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -12),
        ])
    }

    // MARK: - Public

    func reloadSessions(_ sessions: [ClaudeSession]) {
        self.sessions = sessions.sorted { $0.lastActiveAt > $1.lastActiveAt }
        applyFilter()
    }

    // MARK: - Filter

    private func applyFilter() {
        if searchQuery.isEmpty {
            filteredSessions = sessions
        } else {
            let q = searchQuery.lowercased()
            filteredSessions = sessions.filter { s in
                (s.name?.lowercased().contains(q) ?? false) ||
                (s.lastUserMessage?.lowercased().contains(q) ?? false) ||
                (s.gitBranch?.lowercased().contains(q) ?? false) ||
                s.id.lowercased().contains(q)
            }
        }
        emptyLabel.isHidden = !filteredSessions.isEmpty
        tableView.reloadData()
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        searchQuery = sender.stringValue
        applyFilter()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredSessions.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredSessions.count else { return nil }
        let session = filteredSessions[row]

        let cellId = NSUserInterfaceItemIdentifier("SessionCell")
        let cell: SessionCellView
        if let reused = tableView.makeView(withIdentifier: cellId, owner: nil) as? SessionCellView {
            cell = reused
        } else {
            cell = SessionCellView()
            cell.identifier = cellId
        }
        cell.configure(with: session)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        HoverRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredSessions.count else { return }
        let session = filteredSessions[row]
        onSessionSelected?(session)
        // Deselect after a brief moment so it acts like a button
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.tableView.deselectAll(nil)
        }
    }

    // MARK: - Double click

    @objc private func tableDoubleClicked(_ sender: Any) {
        let row = tableView.clickedRow
        guard row >= 0, row < filteredSessions.count else { return }
        startRename(filteredSessions[row])
    }

    // MARK: - Context Menu

    private func makeTableMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    private func startRename(_ session: ClaudeSession) {
        let alert = NSAlert()
        alert.messageText = "Rename Session"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = session.name ?? ""
        field.placeholderString = "Session name"
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { onRenameSession?(session, name) }
        }
    }

    // MARK: - Formatters

    static func relativeDate(_ date: Date) -> String {
        let s = -date.timeIntervalSinceNow
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        if s < 604800 { let d = Int(s / 86400); return d == 1 ? "1d" : "\(d)d" }
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f.string(from: date)
    }

    static func formatTokenCount(_ count: Int) -> String {
        if count < 1000 { return "\(count)" }
        if count < 1_000_000 {
            let k = Double(count) / 1000.0
            return k >= 100 ? "\(Int(k))k" : String(format: "%.1fk", k)
        }
        return String(format: "%.1fM", Double(count) / 1_000_000.0)
    }
}

// MARK: - NSMenuDelegate (right-click)

extension ClaudeSessionListView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0, row < filteredSessions.count else { return }
        let session = filteredSessions[row]

        let resume = NSMenuItem(title: "Resume", action: #selector(ctxResume(_:)), keyEquivalent: "\r")
        resume.representedObject = session; resume.target = self
        menu.addItem(resume)

        let newTab = NSMenuItem(title: "Resume in New Tab", action: #selector(ctxNewTab(_:)), keyEquivalent: "")
        newTab.representedObject = session; newTab.target = self
        menu.addItem(newTab)

        let fork = NSMenuItem(title: "Fork", action: #selector(ctxFork(_:)), keyEquivalent: "")
        fork.representedObject = session; fork.target = self
        menu.addItem(fork)

        menu.addItem(NSMenuItem.separator())

        let rename = NSMenuItem(title: "Rename...", action: #selector(ctxRename(_:)), keyEquivalent: "")
        rename.representedObject = session; rename.target = self
        menu.addItem(rename)
    }

    @objc private func ctxResume(_ s: NSMenuItem) {
        guard let session = s.representedObject as? ClaudeSession else { return }
        onResumeSession?(session)
    }
    @objc private func ctxNewTab(_ s: NSMenuItem) {
        guard let session = s.representedObject as? ClaudeSession else { return }
        onResumeInNewTab?(session)
    }
    @objc private func ctxFork(_ s: NSMenuItem) {
        guard let session = s.representedObject as? ClaudeSession else { return }
        onForkSession?(session)
    }
    @objc private func ctxRename(_ s: NSMenuItem) {
        guard let session = s.representedObject as? ClaudeSession else { return }
        startRename(session)
    }
}

// MARK: - NSTextFieldDelegate

extension ClaudeSessionListView: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField, field === searchField else { return }
        searchQuery = field.stringValue
        applyFilter()
    }
}

// MARK: - Session Cell View (reusable table cell)

private class SessionCellView: NSTableCellView {

    private let nameLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let activeDot = NSView()
    private let workspaceLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        addSubview(nameLabel)

        // Green dot for active sessions
        activeDot.translatesAutoresizingMaskIntoConstraints = false
        activeDot.wantsLayer = true
        activeDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        activeDot.layer?.cornerRadius = 3
        activeDot.isHidden = true
        addSubview(activeDot)

        // Workspace name badge
        workspaceLabel.translatesAutoresizingMaskIntoConstraints = false
        workspaceLabel.font = .systemFont(ofSize: 10, weight: .medium)
        workspaceLabel.textColor = .systemGreen
        workspaceLabel.isHidden = true
        workspaceLabel.setContentHuggingPriority(.required, for: .horizontal)
        workspaceLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(workspaceLabel)

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .tertiaryLabelColor
        timeLabel.alignment = .right
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(timeLabel)

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = .systemFont(ofSize: 11)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.maximumNumberOfLines = 1
        addSubview(metaLabel)

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: activeDot.leadingAnchor, constant: -6),

            activeDot.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            activeDot.widthAnchor.constraint(equalToConstant: 6),
            activeDot.heightAnchor.constraint(equalToConstant: 6),

            workspaceLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            workspaceLabel.leadingAnchor.constraint(equalTo: activeDot.trailingAnchor, constant: 4),

            timeLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            timeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: workspaceLabel.trailingAnchor, constant: 6),

            metaLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            metaLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            metaLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with session: ClaudeSession) {
        nameLabel.stringValue = session.displayName
        timeLabel.stringValue = ClaudeSessionListView.relativeDate(session.lastActiveAt)

        // Active indicator
        if let wsName = session.activeInWorkspace {
            activeDot.isHidden = false
            workspaceLabel.isHidden = false
            if wsName == "Active" {
                // Running but not in a Clome workspace (external terminal)
                workspaceLabel.stringValue = "Active"
                workspaceLabel.textColor = .systemOrange
                activeDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            } else {
                // Running in a specific Clome workspace
                workspaceLabel.stringValue = wsName
                workspaceLabel.textColor = .systemGreen
                activeDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            }
        } else {
            activeDot.isHidden = true
            workspaceLabel.isHidden = true
            workspaceLabel.stringValue = ""
        }

        // Meta line
        var parts: [String] = []
        if let branch = session.gitBranch { parts.append(branch) }
        if session.messageCount > 0 { parts.append("\(session.messageCount) msgs") }
        let tokens = session.totalInputTokens + session.totalOutputTokens
        if tokens > 0 { parts.append(ClaudeSessionListView.formatTokenCount(tokens) + " tokens") }
        if session.estimatedCost >= 0.01 { parts.append(String(format: "$%.2f", session.estimatedCost)) }
        metaLabel.stringValue = parts.joined(separator: " \u{00B7} ")
    }
}

// MARK: - Hover Row View (subtle hover highlight)

private class HoverRowView: NSTableRowView {
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isHovered && !isSelected {
            NSColor.labelColor.withAlphaComponent(0.04).setFill()
            let r = bounds.insetBy(dx: 4, dy: 0)
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
            let r = bounds.insetBy(dx: 4, dy: 0)
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        }
    }
}
