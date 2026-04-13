import AppKit

/// Delegate for file explorer actions.
@MainActor
protocol FileExplorerDelegate: AnyObject {
    func fileExplorer(_ explorer: FileExplorerView, didSelectFile path: String)
    func fileExplorer(_ explorer: FileExplorerView, didRequestNewFileIn directory: String)
}

/// Custom row view that draws a subtle background for the active file.
class FileExplorerRowView: NSTableRowView {
    var isActiveFile: Bool = false {
        didSet { needsDisplay = true }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if isActiveFile {
            ClomeMacColor.border.withAlphaComponent(0.5).setFill()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 4, yRadius: 4)
            path.fill()

            // Left accent bar
            ClomeMacColor.accent.withAlphaComponent(0.7).setFill()
            let accent = NSRect(x: 2, y: bounds.minY + 4, width: 2, height: bounds.height - 8)
            NSBezierPath(roundedRect: accent, xRadius: 1, yRadius: 1).fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // Don't draw default selection — we handle it ourselves
    }
}

/// A file tree view for the sidebar, using NSOutlineView.
class FileExplorerView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var delegate: FileExplorerDelegate?
    private var rootNode: FileTreeNode?
    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let gitTracker = GitStatusTracker()
    private var headerBar: NSView!

    /// Tracks an in-progress inline creation (file or folder).
    private var pendingCreation: PendingCreation?
    /// Standalone text field overlaid on the outline view for inline rename.
    private var inlineTextField: NSTextField?

    // MARK: - Agent Changes Section
    private var agentChangesContainer: NSView!
    private var agentChangesStack: NSStackView!
    private var agentChangesHeaderLabel: NSTextField!
    private var agentChangesHeightConstraint: NSLayoutConstraint!
    private var scrollViewTopToAgent: NSLayoutConstraint!
    private var scrollViewTopToHeader: NSLayoutConstraint!

    private struct PendingCreation {
        let parentPath: String
        let isDirectory: Bool
        /// Temporary placeholder node inserted into the tree.
        let placeholderNode: FileTreeNode
    }

    /// Path of the currently active/open file, set by ProjectPanel
    var activeFilePath: String? {
        didSet {
            if oldValue != activeFilePath {
                outlineView.enumerateAvailableRowViews { rowView, row in
                    if let fileRow = rowView as? FileExplorerRowView,
                       let node = self.outlineView.item(atRow: row) as? FileTreeNode {
                        fileRow.isActiveFile = (!node.isDirectory && node.path == self.activeFilePath)
                    }
                }
            }
        }
    }

    var rootPath: String? {
        didSet {
            guard let path = rootPath else { rootNode = nil; return }
            rootNode = FileTreeNode(path: path)
            rootNode?.loadChildren()
            rootNode?.isExpanded = true
            refreshGitStatus()
            outlineView.reloadData()
            if let root = rootNode {
                outlineView.expandItem(root)
            }
        }
    }

    override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        setupUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(appearanceDidChange),
            name: .appearanceSettingsChanged, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Keep the table column width in sync with the outline view's visible width
        // so that cell text fields expand/contract properly on sidebar resize.
        if let col = outlineView.tableColumns.first {
            let visibleWidth = scrollView.contentSize.width
            if visibleWidth > 0 && abs(col.width - visibleWidth) > 1 {
                col.width = visibleWidth
            }
        }
    }

    @objc private func appearanceDidChange() {
        FileTypeIconProvider.shared.clearCache()
        outlineView.reloadData()
        if let root = rootNode { outlineView.expandItem(root) }
        expandPreviouslyExpanded(rootNode)
    }

    private func setupUI() {
        wantsLayer = true

        // Header bar with new file / new folder buttons
        headerBar = NSView()
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        headerBar.wantsLayer = true
        headerBar.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.0).cgColor
        addSubview(headerBar)

        let titleLabel = NSTextField(labelWithString: "")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.attributedStringValue = NSAttributedString(string: "EXPLORER", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: ClomeMacColor.textTertiary,
            .kern: 1.2,
        ])
        headerBar.addSubview(titleLabel)

        let iconCfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)

        let newFileBtn = NSButton()
        newFileBtn.translatesAutoresizingMaskIntoConstraints = false
        newFileBtn.bezelStyle = .texturedRounded
        newFileBtn.isBordered = false
        newFileBtn.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: "New File")?.withSymbolConfiguration(iconCfg)
        newFileBtn.contentTintColor = ClomeMacColor.textTertiary
        newFileBtn.target = self
        newFileBtn.action = #selector(newFileClicked(_:))
        newFileBtn.toolTip = "New File"
        headerBar.addSubview(newFileBtn)

        let newFolderBtn = NSButton()
        newFolderBtn.translatesAutoresizingMaskIntoConstraints = false
        newFolderBtn.bezelStyle = .texturedRounded
        newFolderBtn.isBordered = false
        newFolderBtn.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "New Folder")?.withSymbolConfiguration(iconCfg)
        newFolderBtn.contentTintColor = ClomeMacColor.textTertiary
        newFolderBtn.target = self
        newFolderBtn.action = #selector(newFolderClicked(_:))
        newFolderBtn.toolTip = "New Folder"
        headerBar.addSubview(newFolderBtn)

        let refreshBtn = NSButton()
        refreshBtn.translatesAutoresizingMaskIntoConstraints = false
        refreshBtn.bezelStyle = .texturedRounded
        refreshBtn.isBordered = false
        refreshBtn.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")?.withSymbolConfiguration(iconCfg)
        refreshBtn.contentTintColor = ClomeMacColor.textTertiary
        refreshBtn.target = self
        refreshBtn.action = #selector(refreshClicked(_:))
        refreshBtn.toolTip = "Refresh"
        headerBar.addSubview(refreshBtn)

        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            refreshBtn.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -8),
            refreshBtn.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            refreshBtn.widthAnchor.constraint(equalToConstant: 24),
            refreshBtn.heightAnchor.constraint(equalToConstant: 24),

            newFolderBtn.trailingAnchor.constraint(equalTo: refreshBtn.leadingAnchor, constant: -4),
            newFolderBtn.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            newFolderBtn.widthAnchor.constraint(equalToConstant: 24),
            newFolderBtn.heightAnchor.constraint(equalToConstant: 24),

            newFileBtn.trailingAnchor.constraint(equalTo: newFolderBtn.leadingAnchor, constant: -4),
            newFileBtn.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            newFileBtn.widthAnchor.constraint(equalToConstant: 24),
            newFileBtn.heightAnchor.constraint(equalToConstant: 24),
        ])

        // Outline view
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileTree"))
        col.title = ""
        col.resizingMask = .autoresizingMask
        outlineView.addTableColumn(col)
        outlineView.outlineTableColumn = col
        outlineView.headerView = nil
        outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.rowHeight = 26
        outlineView.indentationPerLevel = 16
        outlineView.backgroundColor = .clear
        outlineView.selectionHighlightStyle = .none
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClickedRow(_:))
        outlineView.intercellSpacing = NSSize(width: 0, height: 2)

        // Enable drag and drop
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.draggingDestinationFeedbackStyle = .regular

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScroller?.alphaValue = 0
        scrollView.borderType = .noBorder
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        if let scroller = scrollView.verticalScroller {
            scroller.controlSize = .small
        }
        addSubview(scrollView)

        // Agent changes section (hidden by default, shown when Claude Code modifies files)
        setupAgentChangesSection()

        scrollViewTopToHeader = scrollView.topAnchor.constraint(equalTo: headerBar.bottomAnchor)
        scrollViewTopToAgent = scrollView.topAnchor.constraint(equalTo: agentChangesContainer.bottomAnchor)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollViewTopToHeader,
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Observe agent file changes
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(agentFilesChanged), name: .agentFileChanged, object: nil)
        nc.addObserver(self, selector: #selector(agentFilesChanged), name: .agentFileReviewStateChanged, object: nil)
        nc.addObserver(self, selector: #selector(agentTrackingChanged), name: .agentTrackingStateChanged, object: nil)
    }

    // MARK: - Agent Changes Section

    private func setupAgentChangesSection() {
        agentChangesContainer = NSView()
        agentChangesContainer.translatesAutoresizingMaskIntoConstraints = false
        agentChangesContainer.wantsLayer = true
        agentChangesContainer.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.0).cgColor
        agentChangesContainer.isHidden = true
        addSubview(agentChangesContainer)

        // Header row
        let headerRow = NSView()
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        agentChangesContainer.addSubview(headerRow)

        let chevron = NSImageView()
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        chevron.contentTintColor = NSColor(white: 0.45, alpha: 1.0)
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        headerRow.addSubview(chevron)

        let sparkle = NSImageView()
        sparkle.translatesAutoresizingMaskIntoConstraints = false
        sparkle.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        sparkle.contentTintColor = NSColor(red: 0.45, green: 0.65, blue: 0.90, alpha: 1.0)
        sparkle.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        headerRow.addSubview(sparkle)

        agentChangesHeaderLabel = NSTextField(labelWithString: "CLAUDE CHANGES")
        agentChangesHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        agentChangesHeaderLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        agentChangesHeaderLabel.textColor = NSColor(red: 0.45, green: 0.65, blue: 0.90, alpha: 0.9)
        headerRow.addSubview(agentChangesHeaderLabel)

        let acceptAllBtn = NSButton()
        acceptAllBtn.translatesAutoresizingMaskIntoConstraints = false
        acceptAllBtn.bezelStyle = .texturedRounded
        acceptAllBtn.isBordered = false
        acceptAllBtn.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Accept All")?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        acceptAllBtn.contentTintColor = NSColor(red: 0.4, green: 0.8, blue: 0.5, alpha: 0.8)
        acceptAllBtn.target = self
        acceptAllBtn.action = #selector(acceptAllAgentChanges)
        acceptAllBtn.toolTip = "Accept All"
        headerRow.addSubview(acceptAllBtn)

        let rejectAllBtn = NSButton()
        rejectAllBtn.translatesAutoresizingMaskIntoConstraints = false
        rejectAllBtn.bezelStyle = .texturedRounded
        rejectAllBtn.isBordered = false
        rejectAllBtn.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Reject All")?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        rejectAllBtn.contentTintColor = NSColor(red: 0.8, green: 0.4, blue: 0.4, alpha: 0.8)
        rejectAllBtn.target = self
        rejectAllBtn.action = #selector(rejectAllAgentChanges)
        rejectAllBtn.toolTip = "Reject All"
        headerRow.addSubview(rejectAllBtn)

        // File list stack
        let scrollContainer = NSScrollView()
        scrollContainer.translatesAutoresizingMaskIntoConstraints = false
        scrollContainer.drawsBackground = false
        scrollContainer.hasVerticalScroller = false
        scrollContainer.borderType = .noBorder
        agentChangesContainer.addSubview(scrollContainer)

        agentChangesStack = NSStackView()
        agentChangesStack.translatesAutoresizingMaskIntoConstraints = false
        agentChangesStack.orientation = .vertical
        agentChangesStack.alignment = .leading
        agentChangesStack.spacing = 1
        scrollContainer.documentView = agentChangesStack

        agentChangesHeightConstraint = agentChangesContainer.heightAnchor.constraint(equalToConstant: 28)

        NSLayoutConstraint.activate([
            agentChangesContainer.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            agentChangesContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            agentChangesContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            agentChangesHeightConstraint,

            headerRow.topAnchor.constraint(equalTo: agentChangesContainer.topAnchor),
            headerRow.leadingAnchor.constraint(equalTo: agentChangesContainer.leadingAnchor),
            headerRow.trailingAnchor.constraint(equalTo: agentChangesContainer.trailingAnchor),
            headerRow.heightAnchor.constraint(equalToConstant: 28),

            chevron.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor, constant: 8),
            chevron.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 10),

            sparkle.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 4),
            sparkle.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),

            agentChangesHeaderLabel.leadingAnchor.constraint(equalTo: sparkle.trailingAnchor, constant: 4),
            agentChangesHeaderLabel.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),

            rejectAllBtn.trailingAnchor.constraint(equalTo: headerRow.trailingAnchor, constant: -8),
            rejectAllBtn.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            rejectAllBtn.widthAnchor.constraint(equalToConstant: 20),

            acceptAllBtn.trailingAnchor.constraint(equalTo: rejectAllBtn.leadingAnchor, constant: -2),
            acceptAllBtn.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            acceptAllBtn.widthAnchor.constraint(equalToConstant: 20),

            scrollContainer.topAnchor.constraint(equalTo: headerRow.bottomAnchor),
            scrollContainer.leadingAnchor.constraint(equalTo: agentChangesContainer.leadingAnchor),
            scrollContainer.trailingAnchor.constraint(equalTo: agentChangesContainer.trailingAnchor),
            scrollContainer.bottomAnchor.constraint(equalTo: agentChangesContainer.bottomAnchor),

            agentChangesStack.leadingAnchor.constraint(equalTo: scrollContainer.leadingAnchor),
            agentChangesStack.topAnchor.constraint(equalTo: scrollContainer.contentView.topAnchor),
            agentChangesStack.widthAnchor.constraint(equalTo: scrollContainer.widthAnchor),
        ])
    }

    private func updateAgentChangesSection() {
        let tracker = AgentFileTracker.shared
        let pending = tracker.pendingChanges

        if pending.isEmpty && !tracker.isTracking {
            hideAgentChangesSection()
            return
        }

        showAgentChangesSection()

        // Update header
        let count = pending.count
        agentChangesHeaderLabel.stringValue = count > 0
            ? "CLAUDE CHANGES (\(count))"
            : "CLAUDE CHANGES"

        // Rebuild file list
        agentChangesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for change in pending {
            let row = makeAgentChangeRow(change)
            agentChangesStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: agentChangesStack.widthAnchor).isActive = true
        }

        // Size the container: header (28) + rows (24 each), capped at 200px
        let contentHeight = 28 + CGFloat(min(pending.count, 7)) * 24
        agentChangesHeightConstraint.constant = min(contentHeight, 200)
    }

    private func makeAgentChangeRow(_ change: AgentFileTracker.FileChange) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true
        row.heightAnchor.constraint(equalToConstant: 24).isActive = true

        // Change type indicator
        let indicator = NSTextField(labelWithString: changeTypeSymbol(change.changeType))
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        indicator.textColor = changeTypeColor(change.changeType)
        row.addSubview(indicator)

        // File name
        let nameLabel = NSTextField(labelWithString: (change.path as NSString).lastPathComponent)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textColor = NSColor(white: 0.78, alpha: 1.0)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        row.addSubview(nameLabel)

        // Stats
        let stats = NSTextField(labelWithString: "+\(change.addedLines) -\(change.removedLines)")
        stats.translatesAutoresizingMaskIntoConstraints = false
        stats.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        stats.textColor = NSColor(white: 0.4, alpha: 1.0)
        row.addSubview(stats)

        // Click gesture to open diff
        let click = NSClickGestureRecognizer(target: self, action: #selector(agentChangeRowClicked(_:)))
        row.addGestureRecognizer(click)

        // Store path for click handler
        row.toolTip = change.path

        NSLayoutConstraint.activate([
            indicator.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            indicator.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 14),

            nameLabel.leadingAnchor.constraint(equalTo: indicator.trailingAnchor, constant: 4),
            nameLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: stats.leadingAnchor, constant: -4),

            stats.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            stats.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        return row
    }

    private func showAgentChangesSection() {
        guard agentChangesContainer.isHidden else { return }
        agentChangesContainer.isHidden = false
        scrollViewTopToHeader.isActive = false
        scrollViewTopToAgent.isActive = true
    }

    private func hideAgentChangesSection() {
        guard !agentChangesContainer.isHidden else { return }
        agentChangesContainer.isHidden = true
        scrollViewTopToAgent.isActive = false
        scrollViewTopToHeader.isActive = true
    }

    private func changeTypeSymbol(_ type: AgentFileTracker.ChangeType) -> String {
        switch type {
        case .created: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        }
    }

    private func changeTypeColor(_ type: AgentFileTracker.ChangeType) -> NSColor {
        switch type {
        case .created: return NSColor(red: 0.4, green: 0.8, blue: 0.5, alpha: 1.0)
        case .modified: return NSColor(red: 0.85, green: 0.75, blue: 0.3, alpha: 1.0)
        case .deleted: return NSColor(red: 0.85, green: 0.4, blue: 0.4, alpha: 1.0)
        }
    }

    @objc private func agentFilesChanged() {
        updateAgentChangesSection()
    }

    @objc private func agentTrackingChanged() {
        updateAgentChangesSection()
    }

    @objc private func agentChangeRowClicked(_ gesture: NSClickGestureRecognizer) {
        guard let row = gesture.view, let path = row.toolTip else { return }
        guard let change = AgentFileTracker.shared.change(for: path) else { return }

        // Post notification to open diff review
        NotificationCenter.default.post(
            name: .openDiffReview,
            object: self,
            userInfo: ["path": path, "oldContent": change.oldContent ?? "", "newContent": change.newContent ?? ""]
        )
    }

    @objc private func acceptAllAgentChanges() {
        AgentFileTracker.shared.acceptAll()
    }

    @objc private func rejectAllAgentChanges() {
        AgentFileTracker.shared.rejectAll()
    }

    func reload() {
        // Don't reload while user is typing a new file/folder name
        guard pendingCreation == nil else { return }
        rootNode?.reload()
        refreshGitStatus()
        outlineView.reloadData()
        if let root = rootNode {
            outlineView.expandItem(root)
        }
    }

    private func refreshGitStatus() {
        guard let path = rootPath else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.gitTracker.refresh(for: path)
            DispatchQueue.main.async {
                // Don't reload while user is typing a new file/folder name
                guard let self, self.pendingCreation == nil else { return }
                // Only redraw visible rows to update git status colors.
                // Avoids the expensive full reloadData + re-expand cycle
                // that destroys and recreates the entire view hierarchy.
                let visibleRows = self.outlineView.rows(in: self.outlineView.visibleRect)
                if visibleRows.length > 0 {
                    let columns = IndexSet(integersIn: 0..<max(1, self.outlineView.numberOfColumns))
                    self.outlineView.reloadData(
                        forRowIndexes: IndexSet(integersIn: visibleRows.location..<(visibleRows.location + visibleRows.length)),
                        columnIndexes: columns
                    )
                }
            }
        }
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return rootNode?.children?.count ?? 0
        }
        guard let node = item as? FileTreeNode else { return 0 }
        node.loadChildren()
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return rootNode!.children![index]
        }
        let node = item as! FileTreeNode
        return node.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FileTreeNode else { return false }
        return node.isDirectory
    }

    // MARK: - Drag and Drop (NSOutlineViewDataSource)

    /// Provide pasteboard data for dragging items OUT of the explorer.
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let node = item as? FileTreeNode, !node.isPlaceholder else { return nil }
        return URL(fileURLWithPath: node.path) as NSURL
    }

    /// Validate a proposed drop. Allows dropping on directories (or the root area).
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let rootPath else { return [] }

        // Determine the target directory
        let targetDir: String
        if let node = item as? FileTreeNode {
            if node.isDirectory {
                targetDir = node.path
            } else {
                // Retarget: drop alongside file → into its parent
                let parentPath = (node.path as NSString).deletingLastPathComponent
                if let parentNode = findNodeForPath(parentPath) {
                    outlineView.setDropItem(parentNode, dropChildIndex: NSOutlineViewDropOnItemIndex)
                } else {
                    outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
                }
                targetDir = parentPath
            }
        } else {
            targetDir = rootPath
        }

        // Read dragged file URLs
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty else {
            return []
        }

        // Don't allow dropping a folder onto itself or into its own subtree
        for url in urls {
            let srcPath = url.path
            if targetDir == srcPath || targetDir.hasPrefix(srcPath + "/") {
                return []
            }
            // Don't drop onto the same parent (would be a no-op)
            let srcParent = (srcPath as NSString).deletingLastPathComponent
            if srcParent == targetDir && info.draggingSource is NSOutlineView {
                return []
            }
        }

        // Option held → copy, otherwise move for local, copy for external
        if info.draggingSourceOperationMask.contains(.move) && isLocalDrag(info) {
            return .move
        }
        return .copy
    }

    /// Perform the drop — move or copy files into the target directory.
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let rootPath else { return false }

        let targetDir: String
        if let node = item as? FileTreeNode, node.isDirectory {
            targetDir = node.path
        } else if let node = item as? FileTreeNode {
            targetDir = (node.path as NSString).deletingLastPathComponent
        } else {
            targetDir = rootPath
        }

        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty else {
            return false
        }

        let fm = FileManager.default
        let shouldMove = info.draggingSourceOperationMask.contains(.move) && isLocalDrag(info)
        var didChange = false

        for url in urls {
            let srcPath = url.path
            let fileName = (srcPath as NSString).lastPathComponent
            var destPath = (targetDir as NSString).appendingPathComponent(fileName)

            // Resolve name conflicts
            destPath = uniqueDestinationPath(destPath)

            do {
                if shouldMove {
                    try fm.moveItem(atPath: srcPath, toPath: destPath)
                } else {
                    try fm.copyItem(atPath: srcPath, toPath: destPath)
                }
                didChange = true
            } catch {
                NSLog("FileExplorer drop failed: \(error)")
            }
        }

        if didChange {
            reload()
            // If a file was dropped, open it
            if urls.count == 1, let url = urls.first {
                let fileName = (url.path as NSString).lastPathComponent
                let destPath = (targetDir as NSString).appendingPathComponent(fileName)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: destPath, isDirectory: &isDir), !isDir.boolValue {
                    delegate?.fileExplorer(self, didSelectFile: destPath)
                }
            }
        }

        return didChange
    }

    /// Check if this drag originated from within Clome (local drag).
    private func isLocalDrag(_ info: NSDraggingInfo) -> Bool {
        return info.draggingSource is NSOutlineView
    }

    /// Generate a unique file path by appending " copy", " copy 2", etc.
    private func uniqueDestinationPath(_ path: String) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return path }

        let nsPath = path as NSString
        let dir = nsPath.deletingLastPathComponent
        let ext = nsPath.pathExtension
        let baseName: String
        if ext.isEmpty {
            baseName = nsPath.lastPathComponent
        } else {
            baseName = (nsPath.lastPathComponent as NSString).deletingPathExtension
        }

        for i in 1...100 {
            let suffix = i == 1 ? " copy" : " copy \(i)"
            let newName = ext.isEmpty ? "\(baseName)\(suffix)" : "\(baseName)\(suffix).\(ext)"
            let newPath = (dir as NSString).appendingPathComponent(newName)
            if !fm.fileExists(atPath: newPath) { return newPath }
        }
        return path // give up after 100
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = FileExplorerRowView()
        if let node = item as? FileTreeNode {
            rowView.isActiveFile = (!node.isDirectory && node.path == activeFilePath)
        }
        return rowView
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileTreeNode else { return nil }

        let cellId = NSUserInterfaceItemIdentifier("FileCell")
        let cell: NSTableCellView
        if let existing = outlineView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView {
            cell = existing
            // Remove old git status badges
            for sub in cell.subviews where sub.tag == 99 {
                sub.removeFromSuperview()
            }
        } else {
            cell = NSTableCellView()
            cell.identifier = cellId

            let img = NSImageView()
            img.translatesAutoresizingMaskIntoConstraints = false
            img.imageScaling = .scaleProportionallyDown
            cell.addSubview(img)
            cell.imageView = img

            let txt = NSTextField(labelWithString: "")
            txt.translatesAutoresizingMaskIntoConstraints = false
            txt.font = .systemFont(ofSize: 12)
            txt.lineBreakMode = .byTruncatingTail
            cell.addSubview(txt)
            cell.textField = txt

            NSLayoutConstraint.activate([
                img.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                img.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                img.widthAnchor.constraint(equalToConstant: 16),
                img.heightAnchor.constraint(equalToConstant: 16),

                txt.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 7),
                txt.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -24),
                txt.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        // Placeholder node — show editable text field
        if node.isPlaceholder {
            let iconCfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            if node.isDirectory {
                cell.imageView?.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)?.withSymbolConfiguration(iconCfg)
                cell.imageView?.contentTintColor = NSColor(red: 0.45, green: 0.65, blue: 0.85, alpha: 0.7)
            } else {
                cell.imageView?.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)?.withSymbolConfiguration(iconCfg)
                cell.imageView?.contentTintColor = ClomeMacColor.textTertiary
            }
            cell.textField?.stringValue = ""
            cell.textField?.placeholderString = node.isDirectory ? "folder name" : "filename.ext"
            cell.textField?.textColor = NSColor(white: 0.9, alpha: 1.0)
            return cell
        }

        // Text — consistent colors, no git tinting
        let isActive = (!node.isDirectory && node.path == activeFilePath)
        cell.textField?.stringValue = node.name
        cell.textField?.placeholderString = nil
        cell.textField?.isEditable = false
        cell.textField?.drawsBackground = false
        cell.textField?.textColor = node.isDirectory
            ? ClomeMacColor.textSecondary
            : (isActive ? ClomeMacColor.textPrimary : ClomeMacColor.textSecondary)

        // Icon
        let useColorful = ClomeSettings.shared.colorfulFileIcons
        let colorIcon: NSImage? = useColorful && !node.isDirectory
            ? (node.fileExtension.flatMap { FileTypeIconProvider.shared.icon(forExtension: $0) }
               ?? FileTypeIconProvider.shared.icon(forFilename: node.name))
            : nil
        if let colorIcon {
            cell.imageView?.image = colorIcon
            cell.imageView?.contentTintColor = nil
        } else {
            let iconCfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            cell.imageView?.image = NSImage(systemSymbolName: node.iconName, accessibilityDescription: nil)?.withSymbolConfiguration(iconCfg)
            cell.imageView?.contentTintColor = node.isDirectory
                ? NSColor(red: 0.45, green: 0.65, blue: 0.85, alpha: 1.0)
                : NSColor(white: 0.52, alpha: 1.0)
        }

        // Git badge — only the letter, only colored
        let gitStatus = gitTracker.status(for: node.path)
        if let status = gitStatus, !node.isDirectory {
            let label = statusLabel(status)
            if !label.isEmpty {
                let badge = NSTextField(labelWithString: label)
                badge.translatesAutoresizingMaskIntoConstraints = false
                badge.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
                badge.textColor = statusBadgeColor(status)
                badge.alignment = .right
                badge.tag = 99
                cell.addSubview(badge)

                NSLayoutConstraint.activate([
                    badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                    badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
        }

        return cell
    }

    private func statusLabel(_ status: GitFileStatus) -> String {
        switch status {
        case .modified: return "M"
        case .staged: return "A"
        case .stagedModified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "U"
        case .conflict: return "!"
        case .ignored: return ""
        }
    }

    private func statusBadgeColor(_ status: GitFileStatus) -> NSColor {
        switch status {
        case .staged, .renamed:
            return NSColor(red: 0.40, green: 0.72, blue: 0.40, alpha: 0.9)
        case .modified, .stagedModified:
            return NSColor(red: 0.88, green: 0.70, blue: 0.30, alpha: 0.9)
        case .untracked:
            return NSColor(red: 0.40, green: 0.72, blue: 0.40, alpha: 0.75)
        case .deleted:
            return NSColor(red: 0.82, green: 0.38, blue: 0.38, alpha: 0.9)
        case .conflict:
            return NSColor(red: 0.88, green: 0.42, blue: 0.42, alpha: 0.95)
        case .ignored:
            return NSColor(white: 0.35, alpha: 1.0)
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? FileTreeNode {
            node.isExpanded = true
            node.loadChildren()
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? FileTreeNode {
            node.isExpanded = false
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileTreeNode else { return }
        // Don't try to open placeholder nodes
        guard !node.isPlaceholder else { return }
        if !node.isDirectory {
            delegate?.fileExplorer(self, didSelectFile: node.path)
        }
    }

    // MARK: - New File / Folder (inline editing)

    @objc private func newFileClicked(_ sender: Any?) {
        beginInlineCreation(isDirectory: false)
    }

    @objc private func newFolderClicked(_ sender: Any?) {
        beginInlineCreation(isDirectory: true)
    }

    @objc private func refreshClicked(_ sender: Any?) {
        reload()
    }

    /// Determines the target directory for new item creation.
    /// If a directory is selected, creates inside it. If a file is selected, creates alongside it.
    /// Falls back to root.
    private func targetDirectoryForCreation() -> (path: String, parentNode: FileTreeNode?) {
        let row = outlineView.selectedRow
        if row >= 0, let node = outlineView.item(atRow: row) as? FileTreeNode {
            if node.isDirectory {
                return (node.path, node)
            } else {
                // Use the file's parent directory
                let parentPath = (node.path as NSString).deletingLastPathComponent
                // Find the parent node
                let parentNode = findParentNode(of: node)
                return (parentPath, parentNode)
            }
        }
        // Default to root
        return (rootPath ?? "", rootNode)
    }

    private func findParentNode(of child: FileTreeNode) -> FileTreeNode? {
        guard let root = rootNode else { return nil }
        return findParent(of: child, in: root)
    }

    private func findParent(of target: FileTreeNode, in node: FileTreeNode) -> FileTreeNode? {
        guard let children = node.children else { return nil }
        for child in children {
            if child === target { return node }
            if child.isDirectory, let found = findParent(of: target, in: child) {
                return found
            }
        }
        return nil
    }

    private func beginInlineCreation(isDirectory: Bool) {
        // Cancel any existing pending creation
        cancelPendingCreation()

        let (dirPath, parentNode) = targetDirectoryForCreation()
        guard !dirPath.isEmpty else { return }

        // Ensure the parent directory node is expanded
        if let parent = parentNode, parent.isDirectory {
            if !outlineView.isItemExpanded(parent) {
                outlineView.expandItem(parent)
            }
        }

        // Create a placeholder node
        let placeholderPath = (dirPath as NSString).appendingPathComponent("")
        let placeholder = FileTreeNode.placeholder(parentPath: dirPath, isDirectory: isDirectory)

        pendingCreation = PendingCreation(
            parentPath: dirPath,
            isDirectory: isDirectory,
            placeholderNode: placeholder
        )

        // Insert placeholder into the parent's children at the top
        if let parent = parentNode {
            parent.loadChildren()
            if parent.children == nil { parent.children = [] }
            // Insert at position 0 among files (after dirs) for files, or position 0 for dirs
            if isDirectory {
                parent.children?.insert(placeholder, at: 0)
            } else {
                let firstFileIdx = parent.children?.firstIndex(where: { !$0.isDirectory }) ?? (parent.children?.count ?? 0)
                parent.children?.insert(placeholder, at: firstFileIdx)
            }
        }

        outlineView.reloadData()
        // Re-expand everything that was expanded
        expandPreviouslyExpanded(rootNode)

        // Find the row of the placeholder and begin editing
        let row = outlineView.row(forItem: placeholder)
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
            // Start editing the text field in the cell
            DispatchQueue.main.async { [weak self] in
                self?.beginEditingRow(row)
            }
        }
    }

    private func expandPreviouslyExpanded(_ node: FileTreeNode?) {
        guard let node = node else { return }
        if node.isExpanded {
            outlineView.expandItem(node)
        }
        node.children?.forEach { expandPreviouslyExpanded($0) }
    }

    private func beginEditingRow(_ row: Int) {
        // Remove any previous overlay
        inlineTextField?.removeFromSuperview()
        inlineTextField = nil

        // Get the row rect in the outline view, then convert to scroll view coords
        let rowRect = outlineView.rect(ofRow: row)
        guard !rowRect.isEmpty else { return }

        // Determine the indent + icon offset so the field aligns with where text would be
        let level = outlineView.level(forRow: row)
        let indent = CGFloat(level + 1) * outlineView.indentationPerLevel + 24 // icon + spacing

        let field = NSTextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.stringValue = ""
        field.placeholderString = pendingCreation?.isDirectory == true ? "folder name" : "filename.ext"
        field.font = .systemFont(ofSize: 12)
        field.textColor = NSColor(white: 0.95, alpha: 1.0)
        field.backgroundColor = NSColor(white: 0.15, alpha: 1.0)
        field.drawsBackground = true
        field.isBezeled = false
        field.isBordered = true
        field.focusRingType = .none
        field.isEditable = true
        field.delegate = self
        field.cell?.sendsActionOnEndEditing = true

        // Add as a subview of the outline view so it scrolls with it
        outlineView.addSubview(field)
        field.frame = NSRect(
            x: rowRect.minX + indent,
            y: rowRect.minY + 1,
            width: rowRect.width - indent - 20,
            height: rowRect.height - 2
        )

        inlineTextField = field
        window?.makeFirstResponder(field)
    }

    private func commitCreation(name: String) {
        guard let pending = pendingCreation else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Clean up overlay
        inlineTextField?.removeFromSuperview()
        inlineTextField = nil

        guard !trimmed.isEmpty else {
            cancelPendingCreation()
            return
        }

        let newPath = (pending.parentPath as NSString).appendingPathComponent(trimmed)

        // Remove placeholder before reload
        if let parent = findNodeForPath(pending.parentPath) {
            parent.children?.removeAll(where: { $0 === pending.placeholderNode })
        }
        pendingCreation = nil

        if pending.isDirectory {
            try? FileManager.default.createDirectory(atPath: newPath, withIntermediateDirectories: true)
        } else {
            FileManager.default.createFile(atPath: newPath, contents: nil)
        }

        reload()

        // Open the newly created file
        if !pending.isDirectory {
            delegate?.fileExplorer(self, didSelectFile: newPath)
        }
    }

    private func cancelPendingCreation() {
        guard let pending = pendingCreation else { return }

        // Clean up overlay
        inlineTextField?.removeFromSuperview()
        inlineTextField = nil

        // Remove placeholder from parent's children
        if let parent = findNodeForPath(pending.parentPath) {
            parent.children?.removeAll(where: { $0 === pending.placeholderNode })
        }
        pendingCreation = nil
        outlineView.reloadData()
        expandPreviouslyExpanded(rootNode)
    }

    private func findNodeForPath(_ path: String) -> FileTreeNode? {
        guard let root = rootNode else { return nil }
        if root.path == path { return root }
        return findNode(path: path, in: root)
    }

    private func findNode(path: String, in node: FileTreeNode) -> FileTreeNode? {
        guard let children = node.children else { return nil }
        for child in children {
            if child.path == path { return child }
            if child.isDirectory, let found = findNode(path: path, in: child) {
                return found
            }
        }
        return nil
    }

    // MARK: - Context Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = outlineView.convert(event.locationInWindow, from: nil)
        let row = outlineView.row(at: point)

        let menu = NSMenu()

        if row >= 0, let node = outlineView.item(atRow: row) as? FileTreeNode {
            if node.isDirectory {
                let newFile = NSMenuItem(title: "New File…", action: #selector(contextNewFile(_:)), keyEquivalent: "")
                newFile.target = self
                newFile.representedObject = node.path
                menu.addItem(newFile)

                let newFolder = NSMenuItem(title: "New Folder…", action: #selector(contextNewFolder(_:)), keyEquivalent: "")
                newFolder.target = self
                newFolder.representedObject = node.path
                menu.addItem(newFolder)

                menu.addItem(NSMenuItem.separator())
            }

            let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(contextRevealInFinder(_:)), keyEquivalent: "")
            reveal.target = self
            reveal.representedObject = node.path
            menu.addItem(reveal)

            menu.addItem(NSMenuItem.separator())

            let delete = NSMenuItem(title: "Delete", action: #selector(contextDelete(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = node
            menu.addItem(delete)
        } else {
            if let root = rootPath {
                let newFile = NSMenuItem(title: "New File…", action: #selector(contextNewFile(_:)), keyEquivalent: "")
                newFile.target = self
                newFile.representedObject = root
                menu.addItem(newFile)

                let newFolder = NSMenuItem(title: "New Folder…", action: #selector(contextNewFolder(_:)), keyEquivalent: "")
                newFolder.target = self
                newFolder.representedObject = root
                menu.addItem(newFolder)
            }
        }

        return menu.items.isEmpty ? nil : menu
    }

    @objc private func contextNewFile(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? String else { return }
        promptForName(title: "New File", message: "Enter file name:") { [weak self] name in
            let path = (dir as NSString).appendingPathComponent(name)
            FileManager.default.createFile(atPath: path, contents: nil)
            self?.reload()
            self?.delegate?.fileExplorer(self!, didSelectFile: path)
        }
    }

    @objc private func contextNewFolder(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? String else { return }
        promptForName(title: "New Folder", message: "Enter folder name:") { [weak self] name in
            let path = (dir as NSString).appendingPathComponent(name)
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            self?.reload()
        }
    }

    @objc private func contextRevealInFinder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    @objc private func contextDelete(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileTreeNode else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(node.name)?"
        alert.informativeText = "This will move it to the Trash."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: node.path), resultingItemURL: nil)
            reload()
        }
    }

    @objc private func doubleClickedRow(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileTreeNode else { return }
        if node.isDirectory {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        } else {
            delegate?.fileExplorer(self, didSelectFile: node.path)
        }
    }

    private func promptForName(title: String, message: String, completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { completion(name) }
        }
    }
}

// MARK: - NSTextFieldDelegate (inline editing)

extension FileExplorerView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let textField = obj.object as? NSTextField,
              textField === inlineTextField,
              pendingCreation != nil else { return }

        // Check if this was triggered by Return key vs focus loss
        let movement = (obj.userInfo?["NSTextMovement"] as? Int) ?? 0
        if movement == NSReturnTextMovement {
            // Enter pressed — commit
            commitCreation(name: textField.stringValue)
        } else {
            // Focus was stolen — re-focus the field without selecting all text
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let field = self.inlineTextField, self.pendingCreation != nil else { return }
                self.window?.makeFirstResponder(field)
                // Move cursor to end instead of selecting all
                if let editor = field.currentEditor() as? NSTextView {
                    let end = editor.string.count
                    editor.setSelectedRange(NSRange(location: end, length: 0))
                }
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === inlineTextField else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Escape — cancel
            cancelPendingCreation()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Enter — commit
            commitCreation(name: inlineTextField?.stringValue ?? "")
            return true
        }
        return false
    }
}
