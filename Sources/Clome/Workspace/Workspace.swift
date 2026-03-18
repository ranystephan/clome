import AppKit

/// A single tab within a workspace.
@MainActor
class WorkspaceTab: Identifiable {
    let id = UUID()
    let type: TabType
    let view: NSView
    var title: String

    /// Split container for this tab's content. Supports recursive splits.
    let splitContainer = PaneContainerView()

    /// The currently focused pane within this tab's split tree.
    var focusedPane: NSView?

    /// Favicon image for browser tabs (fetched from the web page).
    var favicon: NSImage? {
        (view as? BrowserPanel)?.favicon
    }

    /// Whether this tab has been split into multiple panes.
    var isSplit: Bool { splitContainer.leafCount > 1 }

    /// Number of panes in this tab.
    var paneCount: Int { splitContainer.leafCount }

    /// Human-readable description of split contents (e.g. "Terminal + Browser", "Terminal × 3").
    var splitDescription: String {
        guard isSplit else { return title }
        let views = splitContainer.allLeafViews
        var counts: [String: Int] = [:]
        for v in views {
            let label: String
            if v is TerminalSurface { label = "Terminal" }
            else if v is BrowserPanel { label = "Browser" }
            else if v is EditorPanel { label = "Editor" }
            else if v is PDFPanel { label = "PDF" }
            else if v is NotebookPanel { label = "Notebook" }
            else { label = "Pane" }
            counts[label, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
            .map { $0.value > 1 ? "\($0.key) × \($0.value)" : $0.key }
            .joined(separator: " + ")
    }

    /// Label for a specific pane view.
    static func paneLabel(for view: NSView) -> (icon: String, title: String) {
        if let terminal = view as? TerminalSurface {
            return ("terminal", terminal.title.isEmpty ? "Terminal" : terminal.title)
        } else if let browser = view as? BrowserPanel {
            return ("globe", browser.title.isEmpty ? "Browser" : browser.title)
        } else if let editor = view as? EditorPanel {
            return ("doc.text", editor.title)
        } else if let pdf = view as? PDFPanel {
            return ("doc.richtext", pdf.title.isEmpty ? "PDF" : pdf.title)
        } else if let notebook = view as? NotebookPanel {
            return ("book", notebook.title.isEmpty ? "Notebook" : notebook.title)
        }
        return ("square", "Pane")
    }

    enum TabType: String {
        case terminal
        case browser
        case editor
        case pdf
        case diff
        case project
        case notebook

        var icon: String {
            switch self {
            case .terminal: return "terminal"
            case .browser: return "globe"
            case .editor: return "doc.text"
            case .pdf: return "doc.richtext"
            case .diff: return "arrow.left.arrow.right"
            case .project: return "folder"
            case .notebook: return "book"
            }
        }
    }

    init(type: TabType, view: NSView, title: String) {
        self.type = type
        self.view = view
        self.title = title
        splitContainer.setRoot(view)
        focusedPane = view
    }
}

/// Predefined folder color palette for workspaces.
enum WorkspaceColor: String, CaseIterable {
    case blue, purple, pink, red, orange, yellow, green, teal, gray

    var nsColor: NSColor {
        switch self {
        case .blue:   return NSColor(red: 0.40, green: 0.62, blue: 1.00, alpha: 1.0)
        case .purple: return NSColor(red: 0.69, green: 0.49, blue: 1.00, alpha: 1.0)
        case .pink:   return NSColor(red: 1.00, green: 0.45, blue: 0.65, alpha: 1.0)
        case .red:    return NSColor(red: 1.00, green: 0.42, blue: 0.42, alpha: 1.0)
        case .orange: return NSColor(red: 1.00, green: 0.62, blue: 0.30, alpha: 1.0)
        case .yellow: return NSColor(red: 1.00, green: 0.84, blue: 0.30, alpha: 1.0)
        case .green:  return NSColor(red: 0.40, green: 0.87, blue: 0.47, alpha: 1.0)
        case .teal:   return NSColor(red: 0.35, green: 0.82, blue: 0.80, alpha: 1.0)
        case .gray:   return NSColor(white: 0.60, alpha: 1.0)
        }
    }

    var displayName: String { rawValue.capitalized }

    /// Cycle to the next color in the palette.
    static func color(at index: Int) -> WorkspaceColor {
        let all = WorkspaceColor.allCases
        return all[index % all.count]
    }
}

/// Represents a single workspace in Clome.
/// A workspace contains a list of tabs, each holding a terminal, browser, editor, etc.
@MainActor
class Workspace: Identifiable {
    let id = UUID()
    var name: String
    var icon: String // SF Symbol name
    var color: WorkspaceColor
    /// When true, suppresses auto-terminal creation in ghosttyApp didSet (used during session restore)
    private var suppressAutoTerminal = false

    weak var ghosttyApp: GhosttyAppManager? {
        didSet {
            // If ghosttyApp was nil at init time (Workspace 1), create the initial terminal now
            if oldValue == nil && ghosttyApp != nil && tabs.isEmpty && !suppressAutoTerminal {
                addTerminalTab()
            }
        }
    }

    /// The content view that holds the active tab's view
    let contentContainer = NSView()

    /// All tabs in this workspace
    private(set) var tabs: [WorkspaceTab] = []

    /// Currently active tab index
    private(set) var activeTabIndex: Int = -1

    /// Working directory of the active surface (tracked via OSC 7).
    var workingDirectory: String?

    /// Git branch of the active surface (detected from working directory).
    var gitBranch: String?

    /// Called when tabs change (add/remove/select) so sidebar + tab bar can update
    var onTabsChanged: (() -> Void)?

    /// Lightweight callback — only the active tab selection changed (no add/remove/reorder)
    var onActiveTabChanged: (() -> Void)?

    var activeTab: WorkspaceTab? {
        guard activeTabIndex >= 0, activeTabIndex < tabs.count else { return nil }
        return tabs[activeTabIndex]
    }

    var activeSurface: TerminalSurface? {
        activeTab?.view as? TerminalSurface
    }

    init(name: String, icon: String = "terminal", color: WorkspaceColor = .blue, ghosttyApp: GhosttyAppManager?, skipInitialTab: Bool = false) {
        self.name = name
        self.icon = icon
        self.color = color
        self.suppressAutoTerminal = skipInitialTab
        self.ghosttyApp = ghosttyApp
        contentContainer.wantsLayer = true

        // Create initial terminal tab (unless restoring from session)
        if ghosttyApp != nil && !skipInitialTab {
            addTerminalTab()
        }
    }

    /// Call after session restore is complete to re-enable auto-terminal creation
    func finishRestore() {
        suppressAutoTerminal = false
    }

    // MARK: - Tab Management

    @discardableResult
    func addTerminalTab() -> WorkspaceTab? {
        guard let app = ghosttyApp else { return nil }
        let terminal = TerminalSurface(ghosttyApp: app)
        let tab = WorkspaceTab(type: .terminal, view: terminal, title: "Terminal")
        addTab(tab)
        return tab
    }

    @discardableResult
    func addBrowserTab(url: String? = nil) -> WorkspaceTab? {
        let browser = BrowserPanel()
        if let url { browser.loadURL(url) }
        let tab = WorkspaceTab(type: .browser, view: browser, title: "Browser")
        addTab(tab)
        return tab
    }

    @discardableResult
    func addEditorTab(path: String? = nil) throws -> WorkspaceTab? {
        let panel = EditorPanel()
        var title = "Untitled"
        if let path {
            try panel.openFile(path)
            title = (path as NSString).lastPathComponent
        }
        let tab = WorkspaceTab(type: .editor, view: panel, title: title)
        addTab(tab)
        return tab
    }

    @discardableResult
    func addProjectTab(directory: String) -> WorkspaceTab? {
        let panel = ProjectPanel(rootDirectory: directory)
        let title = (directory as NSString).lastPathComponent
        let tab = WorkspaceTab(type: .project, view: panel, title: title)
        addTab(tab)
        return tab
    }

    @discardableResult
    func addPDFTab(path: String) -> WorkspaceTab? {
        let panel = PDFPanel()
        panel.loadPDF(at: path)
        let title = (path as NSString).lastPathComponent
        let tab = WorkspaceTab(type: .pdf, view: panel, title: title)
        addTab(tab)
        return tab
    }

    @discardableResult
    func addNotebookTab(path: String) throws -> WorkspaceTab? {
        let panel = NotebookPanel()
        try panel.loadNotebook(at: path)
        let title = (path as NSString).lastPathComponent
        let tab = WorkspaceTab(type: .notebook, view: panel, title: title)
        addTab(tab)
        return tab
    }

    func openNotebook(_ path: String) throws {
        try addNotebookTab(path: path)
    }

    private func addTab(_ tab: WorkspaceTab) {
        tabs.append(tab)
        tab.splitContainer.onClosePane = { [weak self] pane in
            self?.closePane(pane)
        }
        observeTabView(tab.view)
        selectTab(tabs.count - 1)
        onTabsChanged?()
    }

    func selectTab(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }
        let previousIndex = activeTabIndex
        activeTabIndex = index

        // Hide previous tab's container instead of removing it
        if previousIndex >= 0 && previousIndex < tabs.count {
            tabs[previousIndex].splitContainer.isHidden = true
        }

        // Show the selected tab's container — add to hierarchy only on first show
        let container = tabs[index].splitContainer
        if container.superview !== contentContainer {
            container.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(container)
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                container.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                container.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                container.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ])
        }
        container.isHidden = false

        // Focus the focused pane (or the original view)
        let focusTarget = tabs[index].focusedPane ?? tabs[index].view
        if let terminal = focusTarget as? TerminalSurface {
            focusTarget.window?.makeFirstResponder(terminal)
        }

        onActiveTabChanged?()
    }

    func closeTab(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }
        let tab = tabs.remove(at: index)
        // Destroy all terminals and shut down notebook kernels in the split tree
        for pane in tab.splitContainer.allLeafViews {
            if let terminal = pane as? TerminalSurface {
                terminal.destroySurface()
            }
            if let notebook = pane as? NotebookPanel {
                notebook.willClose()
            }
        }
        tab.splitContainer.removeFromSuperview()

        if tabs.isEmpty {
            activeTabIndex = -1
            contentContainer.subviews.forEach { $0.removeFromSuperview() }
        } else if index == activeTabIndex {
            // Closed the active tab — select the nearest remaining tab
            selectTab(min(activeTabIndex, tabs.count - 1))
        } else if index < activeTabIndex {
            // Closed a tab before the active one — adjust index to follow the same tab
            activeTabIndex -= 1
        }
        // If closed tab was after active, activeTabIndex is still valid — no change needed
        onTabsChanged?()
    }

    func closeActiveTab() {
        guard activeTabIndex >= 0 else { return }
        closeTab(activeTabIndex)
    }

    func moveTab(from: Int, to: Int) {
        guard from >= 0, from < tabs.count, to >= 0, to < tabs.count, from != to else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        // Update active index to follow the moved tab
        if activeTabIndex == from {
            activeTabIndex = to
        } else if from < activeTabIndex && to >= activeTabIndex {
            activeTabIndex -= 1
        } else if from > activeTabIndex && to <= activeTabIndex {
            activeTabIndex += 1
        }
        onTabsChanged?()
    }

    func renameTab(_ index: Int, to name: String) {
        guard index >= 0, index < tabs.count else { return }
        tabs[index].title = name
        onTabsChanged?()
    }

    // MARK: - Convenience (old API compatibility)

    func addSurface() {
        addTerminalTab()
    }

    func addBrowserSurface(url: String? = nil) {
        addBrowserTab(url: url)
    }

    func openFile(_ path: String) throws {
        try addEditorTab(path: path)
    }

    func openPDF(_ path: String) {
        addPDFTab(path: path)
    }

    func closeActiveSurface() {
        closeActiveTab()
    }

    // MARK: - Split Panes

    /// Split the focused pane of the active tab in the given direction.
    func splitActivePane(direction: SplitDirection) {
        guard let tab = activeTab, let app = ghosttyApp else { return }
        guard let focused = tab.focusedPane else { return }

        let newTerminal = TerminalSurface(ghosttyApp: app)
        observeTabView(newTerminal)
        tab.splitContainer.split(view: focused, with: newTerminal, direction: direction)
        tab.focusedPane = newTerminal
        tab.splitContainer.focusedPane = newTerminal
        newTerminal.window?.makeFirstResponder(newTerminal)
        onTabsChanged?()
    }

    /// Split the active tab into a 2x2 grid (4 panes).
    func splitActivePaneQuad() {
        guard let tab = activeTab, let app = ghosttyApp else { return }
        guard let focused = tab.focusedPane else { return }

        // Split horizontal first
        let right = TerminalSurface(ghosttyApp: app)
        observeTabView(right)
        tab.splitContainer.split(view: focused, with: right, direction: .right)

        // Split each half vertically
        let bottomLeft = TerminalSurface(ghosttyApp: app)
        observeTabView(bottomLeft)
        tab.splitContainer.split(view: focused, with: bottomLeft, direction: .down)

        let bottomRight = TerminalSurface(ghosttyApp: app)
        observeTabView(bottomRight)
        tab.splitContainer.split(view: right, with: bottomRight, direction: .down)

        tab.focusedPane = focused
        tab.splitContainer.focusedPane = focused
        onTabsChanged?()
    }

    /// Close the focused split pane of the active tab.
    func closeSplitPane() {
        guard let tab = activeTab else { return }
        guard tab.splitContainer.leafCount > 1 else {
            // Only one pane left — close the entire tab
            closeActiveTab()
            return
        }
        guard let focused = tab.focusedPane else { return }

        if let terminal = focused as? TerminalSurface {
            terminal.destroySurface()
        }
        tab.splitContainer.removePaneAndCollapse(focused)

        // Focus the next available pane
        let nextFocus = tab.splitContainer.allLeafViews.first
        tab.focusedPane = nextFocus
        tab.splitContainer.focusedPane = nextFocus
        if let terminal = nextFocus as? TerminalSurface {
            terminal.window?.makeFirstResponder(terminal)
        }
        onTabsChanged?()
    }

    /// Close a specific pane view (called from per-pane close button).
    func closePane(_ paneView: NSView) {
        guard let tab = activeTab else { return }
        guard tab.splitContainer.leafCount > 1 else {
            closeActiveTab()
            return
        }

        if let terminal = paneView as? TerminalSurface {
            terminal.destroySurface()
        }
        tab.splitContainer.removePaneAndCollapse(paneView)

        // Focus the next available pane
        let nextFocus = tab.splitContainer.allLeafViews.first
        tab.focusedPane = nextFocus
        tab.splitContainer.focusedPane = nextFocus
        if let terminal = nextFocus as? TerminalSurface {
            terminal.window?.makeFirstResponder(terminal)
        }
        onTabsChanged?()
    }

    /// Split the active tab by moving an existing tab's view into a split pane.
    /// Used for drag-and-drop tab splitting. Splits against the focused pane by default.
    /// If targetPane is nil, splits at the root level (wrapping the entire split tree).
    func splitWithTab(_ tabIndex: Int, direction: SplitDirection, targetPane: NSView? = nil) {
        guard let activeTab = activeTab, tabIndex >= 0, tabIndex < tabs.count else { return }
        guard tabIndex != activeTabIndex else { return }

        let sourceTab = tabs[tabIndex]
        let sourceView = sourceTab.view

        // Remove the source tab (without destroying its view)
        tabs.remove(at: tabIndex)
        if activeTabIndex > tabIndex { activeTabIndex -= 1 }

        if let target = targetPane {
            // Per-pane split: split against the specific target pane
            activeTab.splitContainer.split(view: target, with: sourceView, direction: direction)
        } else {
            // Root-level split: wrap the entire split tree
            activeTab.splitContainer.splitRoot(with: sourceView, direction: direction)
        }

        activeTab.focusedPane = sourceView
        activeTab.splitContainer.focusedPane = sourceView

        if let terminal = sourceView as? TerminalSurface {
            terminal.window?.makeFirstResponder(terminal)
        }
        onTabsChanged?()
    }

    /// Detach a pane from a split and make it its own tab.
    func detachPaneToTab(_ paneView: NSView) {
        guard let tab = activeTab else { return }
        guard tab.splitContainer.leafCount > 1 else { return }

        // Remove the pane from the split tree
        tab.splitContainer.removePaneAndCollapse(paneView)

        // Focus the next pane in the original tab
        let nextFocus = tab.splitContainer.allLeafViews.first
        tab.focusedPane = nextFocus
        tab.splitContainer.focusedPane = nextFocus

        // Determine tab type for the detached pane
        let tabType: WorkspaceTab.TabType
        let title: String
        if let terminal = paneView as? TerminalSurface {
            tabType = .terminal
            title = terminal.title.isEmpty ? "Terminal" : terminal.title
        } else if let browser = paneView as? BrowserPanel {
            tabType = .browser
            title = browser.title.isEmpty ? "Browser" : browser.title
        } else if let editor = paneView as? EditorPanel {
            tabType = .editor
            title = editor.title
        } else if let pdf = paneView as? PDFPanel {
            tabType = .pdf
            title = pdf.title.isEmpty ? "PDF" : pdf.title
        } else if let notebook = paneView as? NotebookPanel {
            tabType = .notebook
            title = notebook.title.isEmpty ? "Notebook" : notebook.title
        } else {
            tabType = .terminal
            title = "Pane"
        }

        // Create a new tab with this pane
        let newTab = WorkspaceTab(type: tabType, view: paneView, title: title)
        addTab(newTab)
    }

    /// Move a pane from its current split to a new split direction.
    /// If targetPane is provided, splits against that specific pane.
    /// If targetPane is nil, splits at the root level (wrapping the entire split tree).
    func reSplitPane(_ paneView: NSView, direction: SplitDirection, targetPane: NSView? = nil) {
        guard let tab = activeTab else { return }
        guard tab.splitContainer.leafCount > 1 else { return }

        // Remove the pane from the split tree
        tab.splitContainer.removePaneAndCollapse(paneView)

        if let target = targetPane {
            // Per-pane split: split against the specific target pane
            tab.splitContainer.split(view: target, with: paneView, direction: direction)
        } else {
            // Root-level split: wrap the entire remaining split tree
            tab.splitContainer.splitRoot(with: paneView, direction: direction)
        }

        tab.focusedPane = paneView
        tab.splitContainer.focusedPane = paneView

        if let terminal = paneView as? TerminalSurface {
            terminal.window?.makeFirstResponder(terminal)
        }
        onTabsChanged?()
    }

    // MARK: - Split Navigation

    func navigateSplit(_ direction: SplitDirection) {
        guard let tab = activeTab else { return }

        // If the tab has splits, navigate between panes
        if tab.splitContainer.leafCount > 1 {
            if let newFocus = tab.splitContainer.navigateFocus(direction) {
                tab.focusedPane = newFocus
                if let terminal = newFocus as? TerminalSurface {
                    terminal.window?.makeFirstResponder(terminal)
                }
            }
        } else {
            // No splits — navigate between tabs
            switch direction {
            case .left, .up:
                if activeTabIndex > 0 { selectTab(activeTabIndex - 1) }
            case .right, .down:
                if activeTabIndex < tabs.count - 1 { selectTab(activeTabIndex + 1) }
            }
        }
    }

    // MARK: - Observation

    private func observeTabView(_ view: NSView) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(tabTitleChanged(_:)),
            name: .terminalSurfaceTitleChanged,
            object: view
        )
    }

    @objc private func tabTitleChanged(_ notification: Notification) {
        guard let view = notification.object as? NSView else { return }

        // Update the tab's title from whichever view type posted the notification
        if let tab = tabs.first(where: { $0.view === view }) {
            if let terminal = view as? TerminalSurface {
                tab.title = terminal.title
            } else if let browser = view as? BrowserPanel {
                tab.title = browser.title
            } else if let editor = view as? EditorPanel {
                tab.title = editor.title
            } else if let notebook = view as? NotebookPanel {
                tab.title = notebook.title
            }
            onTabsChanged?()
        }

        // Track working directory from terminals
        if let surface = view as? TerminalSurface, let pwd = surface.workingDirectory {
            workingDirectory = pwd
            detectGitBranch(at: pwd)
        }
    }

    private func detectGitBranch(at path: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let headPath = "\(path)/.git/HEAD"
            guard let contents = try? String(contentsOfFile: headPath, encoding: .utf8) else {
                DispatchQueue.main.async { self?.gitBranch = nil }
                return
            }
            let branch: String?
            if contents.hasPrefix("ref: refs/heads/") {
                branch = String(contents.dropFirst("ref: refs/heads/".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                branch = String(contents.prefix(7))
            }
            DispatchQueue.main.async { self?.gitBranch = branch }
        }
    }
}

enum SplitDirection {
    case right, down, left, up

    var isHorizontal: Bool {
        self == .right || self == .left
    }
}
