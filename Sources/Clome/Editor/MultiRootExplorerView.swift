import AppKit

/// Delegate for multi-root file explorer actions.
@MainActor
protocol MultiRootExplorerDelegate: AnyObject {
    func multiRootExplorer(_ explorer: MultiRootExplorerView, didSelectFile path: String)
    func multiRootExplorer(_ explorer: MultiRootExplorerView, didDoubleClickFile path: String)
    func multiRootExplorer(_ explorer: MultiRootExplorerView, didRequestAddRoot sender: Any?)
    func multiRootExplorer(_ explorer: MultiRootExplorerView, didRequestRemoveRoot root: ProjectRoot)
}

/// Custom row view for the multi-root file explorer.
@MainActor
class MultiRootExplorerRowView: NSTableRowView {
    var isActiveFile: Bool = false {
        didSet { needsDisplay = true }
    }

    var isRootRow: Bool = false

    override func drawBackground(in dirtyRect: NSRect) {
        if isActiveFile {
            NSColor(white: 1.0, alpha: 0.10).setFill()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 4, yRadius: 4)
            path.fill()

            // Left accent bar
            NSColor(red: 0.45, green: 0.65, blue: 0.90, alpha: 0.7).setFill()
            let accent = NSRect(x: 2, y: bounds.minY + 4, width: 2, height: bounds.height - 8)
            NSBezierPath(roundedRect: accent, xRadius: 1, yRadius: 1).fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // Custom selection — handled via isActiveFile
    }
}

/// An outline item that wraps either a ProjectRoot (top-level) or a FileTreeNode (child).
/// Uses stable identity so NSOutlineView can track expand/collapse state.
class ExplorerItem: Equatable, Hashable {
    enum Kind {
        case root(ProjectRoot)
        case node(FileTreeNode, ProjectRoot)
    }
    let kind: Kind

    init(root: ProjectRoot) { self.kind = .root(root) }
    init(node: FileTreeNode, root: ProjectRoot) { self.kind = .node(node, root) }

    static func == (lhs: ExplorerItem, rhs: ExplorerItem) -> Bool {
        lhs.path == rhs.path
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }

    var isDirectory: Bool {
        switch kind {
        case .root: return true
        case .node(let node, _): return node.isDirectory
        }
    }

    var path: String {
        switch kind {
        case .root(let root): return root.path
        case .node(let node, _): return node.path
        }
    }

    var name: String {
        switch kind {
        case .root(let root): return root.name
        case .node(let node, _): return node.name
        }
    }

    var isRoot: Bool {
        if case .root = kind { return true }
        return false
    }

    var projectRoot: ProjectRoot {
        switch kind {
        case .root(let root): return root
        case .node(_, let root): return root
        }
    }

    var fileTreeNode: FileTreeNode? {
        if case .node(let node, _) = kind { return node }
        return nil
    }
}

/// Multi-root file explorer with NSOutlineView.
/// Shows multiple project root directories in a unified tree.
@MainActor
class MultiRootExplorerView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var delegate: MultiRootExplorerDelegate?

    private var projectRoots: [ProjectRoot] = []
    private var rootItems: [ExplorerItem] = []
    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private var headerBar: NSView!

    /// Cache of ExplorerItem instances keyed by path for stable NSOutlineView identity.
    private var itemCache: [String: ExplorerItem] = [:]

    /// Tracks inline creation state
    private var pendingCreation: PendingCreation?
    private var inlineTextField: NSTextField?

    private struct PendingCreation {
        let parentPath: String
        let root: ProjectRoot
        let isDirectory: Bool
        let placeholderNode: FileTreeNode
    }

    /// Path of the currently active/open file
    var activeFilePath: String? {
        didSet {
            if oldValue != activeFilePath {
                outlineView.enumerateAvailableRowViews { rowView, row in
                    if let fileRow = rowView as? MultiRootExplorerRowView,
                       let item = self.outlineView.item(atRow: row) as? ExplorerItem {
                        fileRow.isActiveFile = (!item.isDirectory && item.path == self.activeFilePath)
                    }
                }
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
        expandPreviouslyExpanded()
    }

    // MARK: - Setup

    private func setupUI() {
        wantsLayer = true

        // Header bar
        headerBar = NSView()
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        headerBar.wantsLayer = true
        headerBar.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(headerBar)

        let titleLabel = NSTextField(labelWithString: "")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.attributedStringValue = NSAttributedString(string: "EXPLORER", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor(white: 1.0, alpha: 0.45),
            .kern: 1.2,
        ])
        headerBar.addSubview(titleLabel)

        let iconCfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)

        let addRootBtn = NSButton()
        addRootBtn.translatesAutoresizingMaskIntoConstraints = false
        addRootBtn.bezelStyle = .texturedRounded
        addRootBtn.isBordered = false
        addRootBtn.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Folder")?.withSymbolConfiguration(iconCfg)
        addRootBtn.contentTintColor = NSColor(white: 0.55, alpha: 1.0)
        addRootBtn.target = self
        addRootBtn.action = #selector(addRootClicked(_:))
        addRootBtn.toolTip = "Add Project Folder"
        headerBar.addSubview(addRootBtn)

        let refreshBtn = NSButton()
        refreshBtn.translatesAutoresizingMaskIntoConstraints = false
        refreshBtn.bezelStyle = .texturedRounded
        refreshBtn.isBordered = false
        refreshBtn.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")?.withSymbolConfiguration(iconCfg)
        refreshBtn.contentTintColor = NSColor(white: 0.55, alpha: 1.0)
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

            addRootBtn.trailingAnchor.constraint(equalTo: refreshBtn.leadingAnchor, constant: -4),
            addRootBtn.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            addRootBtn.widthAnchor.constraint(equalToConstant: 24),
            addRootBtn.heightAnchor.constraint(equalToConstant: 24),
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
        outlineView.rowHeight = 28
        outlineView.indentationPerLevel = 14
        outlineView.backgroundColor = .clear
        outlineView.selectionHighlightStyle = .none
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClickedRow(_:))
        outlineView.intercellSpacing = NSSize(width: 0, height: 2)

        // Drag and drop
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
        scrollView.borderType = .noBorder
        scrollView.scrollerKnobStyle = .light
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        if let scroller = scrollView.verticalScroller {
            scroller.controlSize = .small
        }
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Data

    func setProjectRoots(_ roots: [ProjectRoot]) {
        // Only rebuild if roots actually changed
        let rootPaths = roots.map(\.path)
        let currentPaths = projectRoots.map(\.path)
        guard rootPaths != currentPaths else { return }

        projectRoots = roots
        itemCache.removeAll()
        rootItems = roots.map { cachedItem(root: $0) }
        outlineView.reloadData()
        expandPreviouslyExpanded()
    }

    /// Get or create a cached ExplorerItem for stable identity.
    private func cachedItem(root: ProjectRoot) -> ExplorerItem {
        let key = "root:\(root.path)"
        if let cached = itemCache[key] { return cached }
        let item = ExplorerItem(root: root)
        itemCache[key] = item
        return item
    }

    private func cachedItem(node: FileTreeNode, root: ProjectRoot) -> ExplorerItem {
        let key = "node:\(node.path)"
        if let cached = itemCache[key] { return cached }
        let item = ExplorerItem(node: node, root: root)
        itemCache[key] = item
        return item
    }

    func reload() {
        guard pendingCreation == nil else { return }
        outlineView.reloadData()
        expandPreviouslyExpanded()
    }

    /// Lightweight refresh — only updates git status display without reloading file tree.
    func refreshGitStatus() {
        for root in projectRoots {
            root.refreshGitStatus()
        }
        // Reload outline view to show updated git badges
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.outlineView.reloadData()
            self?.expandPreviouslyExpanded()
        }
    }

    private func expandPreviouslyExpanded() {
        for (i, root) in projectRoots.enumerated() {
            guard i < rootItems.count else { continue }
            if !root.isCollapsed {
                outlineView.expandItem(rootItems[i])
            }
            expandChildNodes(root.fileTree, root: root)
        }
    }

    private func expandChildNodes(_ node: FileTreeNode, root: ProjectRoot) {
        guard let children = node.children else { return }
        for child in children where child.isDirectory && child.isExpanded {
            let item = ExplorerItem(node: child, root: root)
            outlineView.expandItem(item)
            expandChildNodes(child, root: root)
        }
    }

    // MARK: - Actions

    @objc private func addRootClicked(_ sender: Any?) {
        delegate?.multiRootExplorer(self, didRequestAddRoot: sender)
    }

    @objc private func refreshClicked(_ sender: Any?) {
        reload()
    }

    @objc private func doubleClickedRow(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? ExplorerItem else { return }
        if item.isDirectory {
            if outlineView.isItemExpanded(item) {
                outlineView.collapseItem(item)
            } else {
                outlineView.expandItem(item)
            }
        } else {
            delegate?.multiRootExplorer(self, didDoubleClickFile: item.path)
        }
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return rootItems.count
        }
        guard let explorerItem = item as? ExplorerItem else { return 0 }
        switch explorerItem.kind {
        case .root(let root):
            root.fileTree.loadChildren()
            return root.fileTree.children?.count ?? 0
        case .node(let node, _):
            node.loadChildren()
            return node.children?.count ?? 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return rootItems[index]
        }
        guard let explorerItem = item as? ExplorerItem else { fatalError() }
        let children: [FileTreeNode]
        let root: ProjectRoot
        switch explorerItem.kind {
        case .root(let r):
            children = r.fileTree.children ?? []
            root = r
        case .node(let node, let r):
            children = node.children ?? []
            root = r
        }
        return cachedItem(node: children[index], root: root)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let explorerItem = item as? ExplorerItem else { return false }
        return explorerItem.isDirectory
    }

    // MARK: - Drag and Drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let explorerItem = item as? ExplorerItem, !explorerItem.isRoot else { return nil }
        if let node = explorerItem.fileTreeNode, node.isPlaceholder { return nil }
        return URL(fileURLWithPath: explorerItem.path) as NSURL
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        // Determine target directory
        let targetDir: String
        if let explorerItem = item as? ExplorerItem {
            if explorerItem.isDirectory {
                targetDir = explorerItem.path
            } else {
                targetDir = (explorerItem.path as NSString).deletingLastPathComponent
            }
        } else if let firstRoot = projectRoots.first {
            targetDir = firstRoot.path
        } else {
            return []
        }

        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL], !urls.isEmpty else {
            return []
        }

        for url in urls {
            let srcPath = url.path
            if targetDir == srcPath || targetDir.hasPrefix(srcPath + "/") { return [] }
            let srcParent = (srcPath as NSString).deletingLastPathComponent
            if srcParent == targetDir && info.draggingSource is NSOutlineView { return [] }
        }

        if info.draggingSourceOperationMask.contains(.move) && info.draggingSource is NSOutlineView {
            return .move
        }
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let targetDir: String
        if let explorerItem = item as? ExplorerItem {
            targetDir = explorerItem.isDirectory ? explorerItem.path : (explorerItem.path as NSString).deletingLastPathComponent
        } else if let firstRoot = projectRoots.first {
            targetDir = firstRoot.path
        } else {
            return false
        }

        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL], !urls.isEmpty else {
            return false
        }

        let fm = FileManager.default
        let shouldMove = info.draggingSourceOperationMask.contains(.move) && info.draggingSource is NSOutlineView
        var didChange = false

        for url in urls {
            let srcPath = url.path
            let fileName = (srcPath as NSString).lastPathComponent
            var destPath = (targetDir as NSString).appendingPathComponent(fileName)
            destPath = uniqueDestinationPath(destPath)

            do {
                if shouldMove {
                    try fm.moveItem(atPath: srcPath, toPath: destPath)
                } else {
                    try fm.copyItem(atPath: srcPath, toPath: destPath)
                }
                didChange = true
            } catch {
                NSLog("MultiRootExplorer drop failed: \(error)")
            }
        }

        if didChange {
            reload()
            if urls.count == 1, let url = urls.first {
                let fileName = (url.path as NSString).lastPathComponent
                let destPath = (targetDir as NSString).appendingPathComponent(fileName)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: destPath, isDirectory: &isDir), !isDir.boolValue {
                    delegate?.multiRootExplorer(self, didSelectFile: destPath)
                }
            }
        }

        return didChange
    }

    private func uniqueDestinationPath(_ path: String) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return path }
        let nsPath = path as NSString
        let dir = nsPath.deletingLastPathComponent
        let ext = nsPath.pathExtension
        let baseName = ext.isEmpty ? nsPath.lastPathComponent : (nsPath.lastPathComponent as NSString).deletingPathExtension
        for i in 1...100 {
            let suffix = i == 1 ? " copy" : " copy \(i)"
            let newName = ext.isEmpty ? "\(baseName)\(suffix)" : "\(baseName)\(suffix).\(ext)"
            let newPath = (dir as NSString).appendingPathComponent(newName)
            if !fm.fileExists(atPath: newPath) { return newPath }
        }
        return path
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = MultiRootExplorerRowView()
        if let explorerItem = item as? ExplorerItem {
            rowView.isActiveFile = (!explorerItem.isDirectory && explorerItem.path == activeFilePath)
            rowView.isRootRow = explorerItem.isRoot
        }
        return rowView
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let explorerItem = item as? ExplorerItem else { return nil }

        if explorerItem.isRoot {
            return makeRootCellView(for: explorerItem)
        }

        guard let node = explorerItem.fileTreeNode else { return nil }
        return makeFileCellView(for: node, explorerItem: explorerItem)
    }

    private func makeRootCellView(for item: ExplorerItem) -> NSView {
        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier("RootCell")

        let img = NSImageView()
        img.translatesAutoresizingMaskIntoConstraints = false
        img.imageScaling = .scaleProportionallyDown
        let iconCfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        img.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?.withSymbolConfiguration(iconCfg)
        img.contentTintColor = NSColor(red: 0.45, green: 0.65, blue: 0.85, alpha: 1.0)
        cell.addSubview(img)
        cell.imageView = img

        let txt = NSTextField(labelWithString: item.name)
        txt.translatesAutoresizingMaskIntoConstraints = false
        txt.font = .systemFont(ofSize: 12, weight: .semibold)
        txt.textColor = NSColor(white: 0.90, alpha: 1.0)
        txt.lineBreakMode = .byTruncatingTail
        cell.addSubview(txt)
        cell.textField = txt

        // Remove root button (appears on hover via row view)
        let removeBtn = NSButton()
        removeBtn.translatesAutoresizingMaskIntoConstraints = false
        removeBtn.bezelStyle = .texturedRounded
        removeBtn.isBordered = false
        let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        removeBtn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove Root")?.withSymbolConfiguration(cfg)
        removeBtn.contentTintColor = NSColor(white: 0.40, alpha: 1.0)
        removeBtn.target = self
        removeBtn.action = #selector(removeRootClicked(_:))
        removeBtn.tag = projectRoots.firstIndex(where: { $0 === item.projectRoot }) ?? 0
        removeBtn.toolTip = "Remove from Workspace"
        cell.addSubview(removeBtn)

        NSLayoutConstraint.activate([
            img.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            img.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: 16),
            img.heightAnchor.constraint(equalToConstant: 16),

            txt.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 6),
            txt.trailingAnchor.constraint(lessThanOrEqualTo: removeBtn.leadingAnchor, constant: -4),
            txt.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

            removeBtn.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            removeBtn.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            removeBtn.widthAnchor.constraint(equalToConstant: 16),
            removeBtn.heightAnchor.constraint(equalToConstant: 16),
        ])

        return cell
    }

    private func makeFileCellView(for node: FileTreeNode, explorerItem: ExplorerItem) -> NSView {
        let cellId = NSUserInterfaceItemIdentifier("FileCell")
        let cell: NSTableCellView
        if let existing = outlineView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView {
            cell = existing
            for sub in cell.subviews where sub.tag == 99 { sub.removeFromSuperview() }
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

                txt.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 4),
                txt.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -24),
                txt.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        // Text
        let isActive = (!node.isDirectory && node.path == activeFilePath)
        cell.textField?.stringValue = node.name
        cell.textField?.textColor = node.isDirectory
            ? NSColor(white: 0.67, alpha: 1.0)
            : (isActive ? NSColor(white: 0.95, alpha: 1.0) : NSColor(white: 0.85, alpha: 1.0))
        cell.textField?.font = isActive ? .systemFont(ofSize: 12, weight: .medium) : .systemFont(ofSize: 12)

        // Icon
        let useColorful = AppearanceSettings.shared.colorfulFileIcons
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

        // Git status badge
        let root = explorerItem.projectRoot
        let gitStatus = root.gitTracker.status(for: node.path)
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

    // MARK: - Expand/Collapse tracking

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? ExplorerItem else { return }
        switch item.kind {
        case .root(let root):
            root.isCollapsed = false
        case .node(let node, _):
            node.isExpanded = true
            node.loadChildren()
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? ExplorerItem else { return }
        switch item.kind {
        case .root(let root):
            root.isCollapsed = true
        case .node(let node, _):
            node.isExpanded = false
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? ExplorerItem else { return }
        if !item.isDirectory && !item.isRoot {
            delegate?.multiRootExplorer(self, didSelectFile: item.path)
        }
    }

    // MARK: - Context Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = outlineView.convert(event.locationInWindow, from: nil)
        let row = outlineView.row(at: point)

        let menu = NSMenu()

        if row >= 0, let item = outlineView.item(atRow: row) as? ExplorerItem {
            if item.isRoot {
                // Root context menu
                let removeItem = NSMenuItem(title: "Remove from Workspace", action: #selector(contextRemoveRoot(_:)), keyEquivalent: "")
                removeItem.target = self
                removeItem.representedObject = item.projectRoot
                menu.addItem(removeItem)

                menu.addItem(NSMenuItem.separator())

                let newFileItem = NSMenuItem(title: "New File...", action: #selector(contextNewFile(_:)), keyEquivalent: "")
                newFileItem.target = self
                newFileItem.representedObject = item.path
                menu.addItem(newFileItem)

                let newFolderItem = NSMenuItem(title: "New Folder...", action: #selector(contextNewFolder(_:)), keyEquivalent: "")
                newFolderItem.target = self
                newFolderItem.representedObject = item.path
                menu.addItem(newFolderItem)

                menu.addItem(NSMenuItem.separator())

                let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(contextRevealInFinder(_:)), keyEquivalent: "")
                revealItem.target = self
                revealItem.representedObject = item.path
                menu.addItem(revealItem)

                let copyPathItem = NSMenuItem(title: "Copy Path", action: #selector(contextCopyPath(_:)), keyEquivalent: "")
                copyPathItem.target = self
                copyPathItem.representedObject = item.path
                menu.addItem(copyPathItem)
            } else if let node = item.fileTreeNode {
                if node.isDirectory {
                    let newFile = NSMenuItem(title: "New File...", action: #selector(contextNewFile(_:)), keyEquivalent: "")
                    newFile.target = self
                    newFile.representedObject = node.path
                    menu.addItem(newFile)

                    let newFolder = NSMenuItem(title: "New Folder...", action: #selector(contextNewFolder(_:)), keyEquivalent: "")
                    newFolder.target = self
                    newFolder.representedObject = node.path
                    menu.addItem(newFolder)

                    menu.addItem(NSMenuItem.separator())
                }

                let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(contextRevealInFinder(_:)), keyEquivalent: "")
                reveal.target = self
                reveal.representedObject = node.path
                menu.addItem(reveal)

                let copyPath = NSMenuItem(title: "Copy Path", action: #selector(contextCopyPath(_:)), keyEquivalent: "")
                copyPath.target = self
                copyPath.representedObject = node.path
                menu.addItem(copyPath)

                menu.addItem(NSMenuItem.separator())

                let delete = NSMenuItem(title: "Delete", action: #selector(contextDelete(_:)), keyEquivalent: "")
                delete.target = self
                delete.representedObject = node
                menu.addItem(delete)
            }
        } else {
            // Empty area context menu
            let addRoot = NSMenuItem(title: "Add Folder to Workspace...", action: #selector(addRootClicked(_:)), keyEquivalent: "")
            addRoot.target = self
            menu.addItem(addRoot)
        }

        return menu.items.isEmpty ? nil : menu
    }

    @objc private func removeRootClicked(_ sender: NSButton) {
        let index = sender.tag
        guard index >= 0, index < projectRoots.count else { return }
        delegate?.multiRootExplorer(self, didRequestRemoveRoot: projectRoots[index])
    }

    @objc private func contextRemoveRoot(_ sender: NSMenuItem) {
        guard let root = sender.representedObject as? ProjectRoot else { return }
        delegate?.multiRootExplorer(self, didRequestRemoveRoot: root)
    }

    @objc private func contextNewFile(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? String else { return }
        promptForName(title: "New File", message: "Enter file name:") { [weak self] name in
            let path = (dir as NSString).appendingPathComponent(name)
            FileManager.default.createFile(atPath: path, contents: nil)
            self?.reload()
            guard let self else { return }
            self.delegate?.multiRootExplorer(self, didSelectFile: path)
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

    @objc private func contextCopyPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
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
