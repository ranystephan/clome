import AppKit
import QuartzCore

class ClomeWindow: NSWindow {
    let workspaceManager = WorkspaceManager()
    var ghosttyApp: GhosttyAppManager? {
        didSet { workspaceManager.ghosttyApp = ghosttyApp }
    }

    private(set) var sidebarView: SidebarView!
    private var contentArea: NSView!
    private var tabBarView: WorkspaceTabBar!
    private var splitDropZone: SplitDropZoneView!
    private var mainPanel: NSView!           // The rounded content panel
    private var sidebarContainer: NSView!     // Wraps sidebar for clipping
    private var dividerHandle: SidebarDivider!

    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var sidebarLeadingConstraint: NSLayoutConstraint!
    private var dragSplitTabIndex: Int?
    private var sidebarDragWsIndex: Int?
    private var sidebarDragTabIndex: Int?
    private var paneDragView: NSView?
    private let tabBarBgColor = NSColor(red: 0.13, green: 0.13, blue: 0.145, alpha: 0.6)
    private let outerEdgeMargin: CGFloat = 40

    // Sidebar state
    enum SidebarMode { case pinned, compact, hidden }
    private(set) var sidebarMode: SidebarMode = .pinned
    private var sidebarWidth: CGFloat = 230
    private let sidebarMinWidth: CGFloat = 180
    private let sidebarMaxWidth: CGFloat = 360
    private var hoverTrackingArea: NSTrackingArea?
    private let hoverEdgeWidth: CGFloat = 6 // px from left edge to trigger reveal

    // Colors
    private let windowBgColor = NSColor(red: 0.118, green: 0.118, blue: 0.133, alpha: 0.82)
    private var sidebarTintLayer: NSView?
    private let borderColor = NSColor(white: 1.0, alpha: 0.12)

    init() {
        let frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        super.init(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.title = "Clome"
        self.minSize = NSSize(width: 600, height: 400)
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isMovableByWindowBackground = false
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.center()

        setupLayout()
        setupHoverTracking()
        workspaceManager.delegate = self
        workspaceManager.addWorkspace()

        NotificationCenter.default.addObserver(self, selector: #selector(appearanceDidChange), name: .appearanceSettingsChanged, object: nil)
    }

    @objc private func appearanceDidChange() {
        let settings = AppearanceSettings.shared
        sidebarTintLayer?.layer?.backgroundColor = settings.sidebarTintColor.cgColor
        mainPanel?.layer?.backgroundColor = settings.mainPanelBgColor.cgColor
    }

    // MARK: - Layout

    private let borderWidth: CGFloat = 0
    private let cornerRadius: CGFloat = 14

    private func setupLayout() {
        // Root — the liquid glass border (visual effect with rounded corners)
        let root = NSVisualEffectView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = cornerRadius
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true
        contentView = root

        // Inner container — holds all app content, inset by borderWidth
        let inner = NSView()
        inner.translatesAutoresizingMaskIntoConstraints = false
        inner.wantsLayer = true
        inner.layer?.cornerRadius = cornerRadius - borderWidth
        inner.layer?.cornerCurve = .continuous
        inner.layer?.masksToBounds = true
        inner.layer?.backgroundColor = NSColor.clear.cgColor
        root.addSubview(inner)

        // Sidebar container — NSVisualEffectView for backdrop blur
        let sidebarBlur = NSVisualEffectView()
        sidebarBlur.translatesAutoresizingMaskIntoConstraints = false
        sidebarBlur.material = .hudWindow
        sidebarBlur.blendingMode = .behindWindow
        sidebarBlur.state = .active
        sidebarBlur.wantsLayer = true
        sidebarBlur.layer?.cornerRadius = cornerRadius - borderWidth
        sidebarBlur.layer?.cornerCurve = .continuous
        sidebarBlur.layer?.masksToBounds = true
        sidebarContainer = sidebarBlur
        inner.addSubview(sidebarContainer)

        // Blue tint overlay on top of blur
        let sidebarTint = NSView()
        sidebarTint.translatesAutoresizingMaskIntoConstraints = false
        sidebarTint.wantsLayer = true
        sidebarTint.layer?.backgroundColor = AppearanceSettings.shared.sidebarTintColor.cgColor
        sidebarContainer.addSubview(sidebarTint)
        sidebarTintLayer = sidebarTint
        NSLayoutConstraint.activate([
            sidebarTint.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            sidebarTint.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            sidebarTint.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
            sidebarTint.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),
        ])

        // Sidebar content
        sidebarView = SidebarView(workspaceManager: workspaceManager)
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        sidebarView.onDragTabBegan = { [weak self] wsIndex, tabIndex in
            self?.sidebarDragWsIndex = wsIndex
            self?.sidebarDragTabIndex = tabIndex
        }
        sidebarView.onDragTabMoved = { [weak self] wsIndex, tabIndex, point in
            self?.handleSidebarDragMoved(wsIndex: wsIndex, tabIndex: tabIndex, windowPoint: point)
        }
        sidebarView.onDragTabEnded = { [weak self] wsIndex, tabIndex, point in
            self?.handleSidebarDragEnded(wsIndex: wsIndex, tabIndex: tabIndex, windowPoint: point)
        }
        sidebarContainer.addSubview(sidebarView)

        // Main panel — rounded left corners where it meets the sidebar
        // Uses NonDraggableView to prevent system titlebar drag interception
        mainPanel = NonDraggableView()
        mainPanel.translatesAutoresizingMaskIntoConstraints = false
        mainPanel.wantsLayer = true
        mainPanel.layer?.backgroundColor = AppearanceSettings.shared.mainPanelBgColor.cgColor
        mainPanel.layer?.cornerRadius = 10
        mainPanel.layer?.cornerCurve = .continuous
        mainPanel.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        mainPanel.layer?.masksToBounds = true
        inner.addSubview(mainPanel)

        // Sidebar resize drag handle — invisible, on top for mouse events
        dividerHandle = SidebarDivider()
        dividerHandle.translatesAutoresizingMaskIntoConstraints = false
        dividerHandle.onDrag = { [weak self] delta in self?.resizeSidebar(by: delta) }
        inner.addSubview(dividerHandle)

        // Tab bar
        tabBarView = WorkspaceTabBar()
        tabBarView.translatesAutoresizingMaskIntoConstraints = false
        tabBarView.delegate = self
        mainPanel.addSubview(tabBarView)

        // Content area
        contentArea = NSView()
        contentArea.translatesAutoresizingMaskIntoConstraints = false
        contentArea.wantsLayer = true
        mainPanel.addSubview(contentArea)

        // Split drop zone overlay (for drag-to-split) — frame-based, not constrained
        splitDropZone = SplitDropZoneView()
        splitDropZone.translatesAutoresizingMaskIntoConstraints = true
        mainPanel.addSubview(splitDropZone)

        // Constraints
        let panelGap: CGFloat = 2
        sidebarWidthConstraint = sidebarContainer.widthAnchor.constraint(equalToConstant: sidebarWidth)
        sidebarLeadingConstraint = sidebarContainer.leadingAnchor.constraint(equalTo: inner.leadingAnchor)

        NSLayoutConstraint.activate([
            // Inner container inset by borderWidth on all sides
            inner.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: borderWidth),
            inner.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -borderWidth),
            inner.topAnchor.constraint(equalTo: root.topAnchor, constant: borderWidth),
            inner.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -borderWidth),

            // Sidebar (flush top to bottom)
            sidebarLeadingConstraint,
            sidebarContainer.topAnchor.constraint(equalTo: inner.topAnchor),
            sidebarContainer.bottomAnchor.constraint(equalTo: inner.bottomAnchor),
            sidebarWidthConstraint,

            sidebarView.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            sidebarView.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            sidebarView.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),

            // Drag handle — at sidebar trailing edge
            dividerHandle.leadingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor, constant: -2),
            dividerHandle.topAnchor.constraint(equalTo: inner.topAnchor),
            dividerHandle.bottomAnchor.constraint(equalTo: inner.bottomAnchor),
            dividerHandle.widthAnchor.constraint(equalToConstant: 6),

            // Main panel — flush on right/top/bottom, gap only on left (sidebar side)
            mainPanel.leadingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor, constant: panelGap),
            mainPanel.trailingAnchor.constraint(equalTo: inner.trailingAnchor),
            mainPanel.topAnchor.constraint(equalTo: inner.topAnchor),
            mainPanel.bottomAnchor.constraint(equalTo: inner.bottomAnchor),

            // Tab bar
            tabBarView.topAnchor.constraint(equalTo: mainPanel.topAnchor),
            tabBarView.leadingAnchor.constraint(equalTo: mainPanel.leadingAnchor),
            tabBarView.trailingAnchor.constraint(equalTo: mainPanel.trailingAnchor),

            // Content
            contentArea.topAnchor.constraint(equalTo: tabBarView.bottomAnchor),
            contentArea.leadingAnchor.constraint(equalTo: mainPanel.leadingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: mainPanel.trailingAnchor),
            contentArea.bottomAnchor.constraint(equalTo: mainPanel.bottomAnchor),
        ])
    }

    // MARK: - Sidebar Modes

    func toggleSidebar() {
        switch sidebarMode {
        case .pinned:
            setSidebarMode(.hidden)
        case .compact, .hidden:
            setSidebarMode(.pinned)
        }
    }

    func setSidebarMode(_ mode: SidebarMode, animated: Bool = true) {
        sidebarMode = mode
        let duration = animated ? 0.25 : 0.0

        // Adjust tab bar leading inset to avoid traffic light buttons
        tabBarView.setSidebarVisible(mode == .pinned, animated: animated)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true

            switch mode {
            case .pinned:
                sidebarWidthConstraint.animator().constant = sidebarWidth
                sidebarContainer.animator().alphaValue = 1.0
                dividerHandle.animator().alphaValue = 1.0

            case .compact:
                // Shown temporarily (hover), same width
                sidebarWidthConstraint.animator().constant = sidebarWidth
                sidebarContainer.animator().alphaValue = 1.0
                dividerHandle.animator().alphaValue = 0.0

            case .hidden:
                sidebarWidthConstraint.animator().constant = 0
                sidebarContainer.animator().alphaValue = 0.0
                dividerHandle.animator().alphaValue = 0.0
            }
        }
    }

    // MARK: - Sidebar Hover Reveal (Compact Mode)

    private func setupHoverTracking() {
        // We track the full content view; check mouse X position
        guard let cv = contentView else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        cv.addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard sidebarMode == .hidden else { return }
        guard let cv = contentView else { return }

        let point = cv.convert(event.locationInWindow, from: nil)
        if point.x < hoverEdgeWidth {
            // Reveal sidebar temporarily
            setSidebarMode(.compact)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // When mouse leaves the window, hide compact sidebar
        if sidebarMode == .compact {
            setSidebarMode(.hidden)
        }
    }

    // Check if mouse moved away from sidebar area
    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        if event.type == .mouseMoved && sidebarMode == .compact {
            guard let cv = contentView else { return }
            let point = cv.convert(event.locationInWindow, from: nil)
            if point.x > sidebarWidth + 20 {
                setSidebarMode(.hidden)
            }
        }
    }

    // MARK: - Sidebar Resize

    private func resizeSidebar(by delta: CGFloat) {
        guard sidebarMode == .pinned else { return }
        sidebarWidth = max(sidebarMinWidth, min(sidebarMaxWidth, sidebarWidth + delta))
        sidebarWidthConstraint.constant = sidebarWidth
    }

    // MARK: - Content

    func showWorkspaceContent(_ workspace: Workspace) {
        contentArea.subviews.forEach { $0.removeFromSuperview() }

        let container = workspace.contentContainer
        container.translatesAutoresizingMaskIntoConstraints = false
        contentArea.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            container.topAnchor.constraint(equalTo: contentArea.topAnchor),
            container.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
        ])

        workspace.onTabsChanged = { [weak self] in
            self?.updateTabBar()
            self?.sidebarView?.reloadWorkspaces()
            self?.wirePaneDragCallbacks()
        }

        wirePaneDragCallbacks()
        updateTabBar()
    }

    /// Wire pane header drag callbacks on the active tab's split container.
    private func wirePaneDragCallbacks() {
        guard let tab = workspaceManager.activeWorkspace?.activeTab else { return }
        let container = tab.splitContainer

        container.onPaneDragBegan = { [weak self] pane in
            self?.paneDragView = pane
        }
        container.onPaneDragMoved = { [weak self] pane, windowPoint in
            guard let self else { return }
            let tabBarLocal = self.tabBarView.convert(windowPoint, from: nil)
            let inTabBar = tabBarLocal.y >= 0 && tabBarLocal.y <= self.tabBarView.bounds.height

            if inTabBar {
                // Show tab bar highlight for unsplit
                if !self.splitDropZone.isHidden { self.splitDropZone.hide() }
                self.tabBarView.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor
            } else {
                self.tabBarView.layer?.backgroundColor = self.tabBarBgColor.cgColor
                self.showPerPaneDropZones(at: windowPoint)
            }
        }
        container.onPaneDragEnded = { [weak self] pane, windowPoint in
            guard let self, let workspace = self.workspaceManager.activeWorkspace else { return }

            self.tabBarView.layer?.backgroundColor = self.tabBarBgColor.cgColor

            let tabBarLocal = self.tabBarView.convert(windowPoint, from: nil)
            let inTabBar = tabBarLocal.y >= 0 && tabBarLocal.y <= self.tabBarView.bounds.height

            if inTabBar {
                workspace.detachPaneToTab(pane)
            } else if !self.splitDropZone.isHidden, let result = self.splitDropZone.dropResult {
                if let direction = result.zone.splitDirection {
                    workspace.reSplitPane(pane, direction: direction, targetPane: result.targetPane)
                }
            }

            self.splitDropZone.hide()
            self.updateTabBar()
            self.sidebarView?.reloadWorkspaces()
            self.paneDragView = nil
        }

    }

    func updateTabBar() {
        guard let workspace = workspaceManager.activeWorkspace else { return }
        tabBarView.updateTabs(workspace: workspace)
    }
}

// MARK: - Non-Draggable View

/// NSView subclass that prevents system titlebar window-drag interception.
/// Used for the main panel so tab bar dragging works.
class NonDraggableView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - Sidebar Resize Divider

class SidebarDivider: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var lastX: CGFloat = 0

    override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        lastX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        let delta = event.locationInWindow.x - lastX
        lastX = event.locationInWindow.x
        onDrag?(delta)
    }
}


// MARK: - WorkspaceManagerDelegate

extension ClomeWindow: @preconcurrency WorkspaceManagerDelegate {
    func workspaceManager(_ manager: WorkspaceManager, didSwitchTo workspace: Workspace) {
        showWorkspaceContent(workspace)
        sidebarView?.reloadWorkspaces()
    }
}

// MARK: - WorkspaceTabBarDelegate

extension ClomeWindow: @preconcurrency WorkspaceTabBarDelegate {
    func tabBar(_ tabBar: WorkspaceTabBar, didSelectTabAt index: Int) {
        workspaceManager.activeWorkspace?.selectTab(index)
        updateTabBar()
        sidebarView?.reloadWorkspaces()
    }

    func tabBar(_ tabBar: WorkspaceTabBar, didCloseTabAt index: Int) {
        workspaceManager.activeWorkspace?.closeTab(index)
        updateTabBar()
        sidebarView?.reloadWorkspaces()
    }

    func tabBar(_ tabBar: WorkspaceTabBar, didMoveTabFrom from: Int, to: Int) {
        workspaceManager.activeWorkspace?.moveTab(from: from, to: to)
        updateTabBar()
        sidebarView?.reloadWorkspaces()
    }

    func tabBar(_ tabBar: WorkspaceTabBar, didRenameTabAt index: Int, to name: String) {
        workspaceManager.activeWorkspace?.renameTab(index, to: name)
        updateTabBar()
        sidebarView?.reloadWorkspaces()
    }

    func tabBarDidRequestNewTab(_ tabBar: WorkspaceTabBar) {
        workspaceManager.activeWorkspace?.addTerminalTab()
        updateTabBar()
        sidebarView?.reloadWorkspaces()
    }

    func tabBarDidRequestNewTerminal(_ tabBar: WorkspaceTabBar) {
        workspaceManager.activeWorkspace?.addTerminalTab()
        updateTabBar()
        sidebarView?.reloadWorkspaces()
    }

    func tabBarDidRequestNewBrowser(_ tabBar: WorkspaceTabBar) {
        workspaceManager.activeWorkspace?.addBrowserTab()
        updateTabBar()
        sidebarView?.reloadWorkspaces()
    }

    func tabBarDidRequestNewProject(_ tabBar: WorkspaceTabBar) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        panel.beginSheetModal(for: self) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.workspaceManager.activeWorkspace?.addProjectTab(directory: url.path)
            self?.updateTabBar()
            self?.sidebarView?.reloadWorkspaces()
        }
    }

    func tabBarDidRequestNewFile(_ tabBar: WorkspaceTabBar) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open File"
        panel.beginSheetModal(for: self) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            try? self?.workspaceManager.activeWorkspace?.addEditorTab(path: url.path)
            self?.updateTabBar()
            self?.sidebarView?.reloadWorkspaces()
        }
    }

    func tabBarDidRequestSplit(_ tabBar: WorkspaceTabBar, direction: SplitDirection) {
        workspaceManager.activeWorkspace?.splitActivePane(direction: direction)
        updateTabBar()
    }

    func tabBarDidRequestQuadSplit(_ tabBar: WorkspaceTabBar) {
        workspaceManager.activeWorkspace?.splitActivePaneQuad()
        updateTabBar()
    }

    // MARK: - Drag-to-Split

    func tabBar(_ tabBar: WorkspaceTabBar, didBeginDragTabAt index: Int) {
        dragSplitTabIndex = index
    }

    func tabBar(_ tabBar: WorkspaceTabBar, didDragTabAt index: Int, to windowPoint: NSPoint) {
        let tabBarLocal = tabBarView.convert(windowPoint, from: nil)
        let outsideTabBar = tabBarLocal.y < 0 || tabBarLocal.y > tabBarView.bounds.height
        if outsideTabBar {
            showPerPaneDropZones(at: windowPoint)
        } else {
            if !splitDropZone.isHidden { splitDropZone.hide() }
        }
    }

    func tabBar(_ tabBar: WorkspaceTabBar, didEndDragTabAt index: Int, at windowPoint: NSPoint) {
        guard !splitDropZone.isHidden, let result = splitDropZone.dropResult else {
            splitDropZone.hide()
            dragSplitTabIndex = nil
            return
        }

        if let direction = result.zone.splitDirection, let workspace = workspaceManager.activeWorkspace {
            workspace.splitWithTab(index, direction: direction, targetPane: result.targetPane)
            updateTabBar()
            sidebarView?.reloadWorkspaces()
        } else if result.zone == .center {
            workspaceManager.activeWorkspace?.selectTab(index)
            updateTabBar()
        }

        splitDropZone.hide()
        dragSplitTabIndex = nil
    }


    // MARK: - Sidebar Drag-to-Split

    private func handleSidebarDragMoved(wsIndex: Int, tabIndex: Int, windowPoint: NSPoint) {
        let contentLocal = contentArea.convert(windowPoint, from: nil)
        if contentArea.bounds.contains(contentLocal) {
            showPerPaneDropZones(at: windowPoint)
        } else {
            if !splitDropZone.isHidden { splitDropZone.hide() }
        }
    }

    private func handleSidebarDragEnded(wsIndex: Int, tabIndex: Int, windowPoint: NSPoint) {
        guard !splitDropZone.isHidden, let result = splitDropZone.dropResult else {
            splitDropZone.hide()
            sidebarDragWsIndex = nil
            sidebarDragTabIndex = nil
            return
        }

        workspaceManager.switchTo(index: wsIndex)

        if let direction = result.zone.splitDirection, let workspace = workspaceManager.activeWorkspace {
            workspace.splitWithTab(tabIndex, direction: direction, targetPane: result.targetPane)
            updateTabBar()
            sidebarView?.reloadWorkspaces()
        } else if result.zone == .center {
            workspaceManager.activeWorkspace?.selectTab(tabIndex)
            updateTabBar()
        }

        splitDropZone.hide()
        sidebarDragWsIndex = nil
        sidebarDragTabIndex = nil
    }

    // MARK: - Per-Pane Drop Zones

    /// Show drop zones on the specific pane under the cursor.
    /// When the cursor is near the outer edges of the content area and there are multiple panes,
    /// shows root-level drop zones (full content area). Otherwise, shows per-pane drop zones.
    private func showPerPaneDropZones(at windowPoint: NSPoint) {
        guard let tab = workspaceManager.activeWorkspace?.activeTab else { return }
        let container = tab.splitContainer
        let contentFrame = contentArea.convert(contentArea.bounds, to: splitDropZone.superview)

        // If only 1 pane, always show drop zone over entire content area
        if container.leafCount <= 1 {
            if splitDropZone.isHidden { splitDropZone.show() }
            splitDropZone.positionOverPane(container.allLeafViews.first ?? tab.view, paneFrame: contentFrame)
            splitDropZone.updateHover(at: windowPoint)
            return
        }

        // Multiple panes — check if cursor is in the outer edge margin for root-level splitting
        let localPoint = contentArea.convert(windowPoint, from: nil)
        let bounds = contentArea.bounds
        let inOuterMargin = localPoint.x < outerEdgeMargin
            || localPoint.x > bounds.width - outerEdgeMargin
            || localPoint.y < outerEdgeMargin
            || localPoint.y > bounds.height - outerEdgeMargin

        if inOuterMargin {
            // Root-level: position over entire content area, no target pane
            if splitDropZone.isHidden { splitDropZone.show() }
            splitDropZone.positionOverArea(frame: contentFrame)
            splitDropZone.updateHover(at: windowPoint)
            return
        }

        // Per-pane: find which pane the cursor is over
        if let (pane, paneFrame) = container.paneAt(windowPoint: windowPoint) {
            let frameInWindow = container.convert(paneFrame, to: splitDropZone.superview)
            if splitDropZone.isHidden { splitDropZone.show() }
            splitDropZone.positionOverPane(pane, paneFrame: frameInWindow)
            splitDropZone.updateHover(at: windowPoint)
        }
    }
}
