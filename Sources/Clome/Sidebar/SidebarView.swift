import AppKit
import SwiftUI

/// Zen Browser-inspired sidebar with workspaces and tab list.
class SidebarView: NSView {
    private let workspaceManager: WorkspaceManager
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()

    private var bgColor: NSColor { ClomeMacTheme.surfaceColor(.sidebar) }

    /// File shelf
    private var bottomBar: NSView!
    private var scrollViewBottomConstraint: NSLayoutConstraint!
    private var fileShelfView: FileShelfView?
    private var isShelfVisible = false
    private var shelfBtn: NSButton!

    /// Claude sessions popover
    private var sessionsBtn: NSButton!
    private var sessionsPopover: NSPopover?
    private var sessionsRefreshTimer: Timer?

    /// Remote connection indicator
    private var remoteBtn: NSButton!
    private var isRemoteConnected = false
    private var connectedDeviceName: String?
    private var remotePopover: NSPopover?

    /// Which workspaces are expanded
    private var expandedWorkspaces: Set<UUID> = []

    /// Which workspaces have the new-tab cards revealed
    private var revealedNewTab: Set<UUID> = []

    /// Which split tabs are collapsed in the sidebar
    private var collapsedSplitTabs: Set<UUID> = []

    /// User-resizable explorer height
    private var explorerHeight: CGFloat = 220

    /// Stored height constraint for the file explorer (to avoid accumulation)
    private var explorerHeightConstraint: NSLayoutConstraint?

    /// Whether the explorer resize handle is being dragged
    private var isExplorerResizing: Bool = false

    /// Whether a tab drag-to-split is in progress (suppresses reloads)
    private var isDraggingTab: Bool = false

    /// Debounce timer for activity updates
    private var activityDebounceTimer: Timer?

    /// Whether auto-expand has run on first load
    private var hasAutoExpanded = false

    /// Coalescing flag for setNeedsReload()
    private var reloadScheduled = false

    // MARK: - New Sectioned Layout Components

    /// Compact workspace selector at top
    private var workspaceSwitcher: WorkspaceSwitcherView?

    /// Multi-root file explorer
    private var multiRootExplorer: MultiRootExplorerView?

    /// Source control section
    private var sourceControlSection: SourceControlSection?

    /// Explorer resize handle
    private var explorerResizeHandle: ExplorerResizeHandle?

    /// Thin separator between the explorer and the source-control section.
    /// Stored so we can hide it together with those sections when there is no
    /// project root open.
    private var chromeSeparator: NSView?

    /// Tabs section header
    private var tabsSectionHeader: SidebarSectionHeader?

    /// Whether the tabs section is expanded
    private var isTabsSectionExpanded: Bool = true

    /// Callbacks
    var onToggleSidebar: (() -> Void)?
    var onDragTabBegan: ((Int, Int) -> Void)?                // (wsIndex, tabIndex)
    var onDragTabMoved: ((Int, Int, NSPoint) -> Void)?       // (wsIndex, tabIndex, windowPoint)
    var onDragTabEnded: ((Int, Int, NSPoint) -> Void)?       // (wsIndex, tabIndex, windowPoint)

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
        super.init(frame: .zero)
        setupUI()
        reloadWorkspaces()
        observeNotifications()
        refreshRemoteState()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = bgColor.cgColor
        fileShelfView?.refreshAppearance()
        sourceControlSection?.refreshAppearance()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = bgColor.cgColor

        // ──── Workspace Switcher (top, replaces old nav bar) ────
        let switcher = WorkspaceSwitcherView(workspaceManager: workspaceManager)
        switcher.translatesAutoresizingMaskIntoConstraints = false
        switcher.onToggleSidebar = { [weak self] in self?.onToggleSidebar?() }
        addSubview(switcher)
        workspaceSwitcher = switcher

        // ──── Multi-Root File Explorer ────
        let explorer = MultiRootExplorerView()
        explorer.translatesAutoresizingMaskIntoConstraints = false
        explorer.delegate = self
        addSubview(explorer)
        multiRootExplorer = explorer

        // ──── Explorer Resize Handle ────
        let resizeHandle = ExplorerResizeHandle()
        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        resizeHandle.onDrag = { [weak self] delta in
            guard let self else { return }
            let newHeight = max(100, min(600, self.explorerHeight - delta))
            self.explorerHeight = newHeight
            self.explorerHeightConstraint?.constant = newHeight
        }
        resizeHandle.onDragBegan = { [weak self] in self?.isExplorerResizing = true }
        resizeHandle.onDragEnded = { [weak self] in
            guard let self else { return }
            self.isExplorerResizing = false
            if self.needsReloadAfterResize {
                self.needsReloadAfterResize = false
                self.reloadWorkspaces()
            }
        }
        addSubview(resizeHandle)
        explorerResizeHandle = resizeHandle

        // ──── Source Control Section ────
        let scSection = SourceControlSection()
        scSection.translatesAutoresizingMaskIntoConstraints = false
        scSection.onFileSelected = { [weak self] path in
            guard let workspace = self?.workspaceManager.activeWorkspace else { return }
            workspace.openFileAsTab(path)
        }
        addSubview(scSection)
        sourceControlSection = scSection

        // ──── Separator ────
        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = ClomeMacColor.border.cgColor
        addSubview(separator)
        chromeSeparator = separator

        // ──── Scrollable tab list (terminals/browsers only) ────
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        stackView.orientation = .vertical
        stackView.spacing = 6
        stackView.alignment = .centerX
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let clipView = FlippedClipView()
        clipView.drawsBackground = false
        clipView.documentView = stackView
        scrollView.contentView = clipView

        // ──── Bottom toolbar ────
        bottomBar = NSView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.wantsLayer = true
        bottomBar.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(bottomBar)

        // 1pt hairline divider above the footer — same treatment AppKit uses
        // for the source-list status bar in Mail / Notes.
        let footerDivider = NSView()
        footerDivider.translatesAutoresizingMaskIntoConstraints = false
        footerDivider.wantsLayer = true
        footerDivider.layer?.backgroundColor = ClomeMacColor.border.withAlphaComponent(0.6).cgColor
        addSubview(footerDivider)
        NSLayoutConstraint.activate([
            footerDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerDivider.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            footerDivider.heightAnchor.constraint(equalToConstant: 1),
        ])

        // Three borderless icon buttons — laid out like a native macOS sidebar
        // status bar (Finder, Notes, Mail). No card chrome, no labels: identical
        // hit targets, identical symbol weight, hover provides the only fill.
        shelfBtn = makeFooterIconButton(
            symbol: "tray.and.arrow.down",
            tooltip: "File Shelf",
            action: #selector(shelfToggleTapped)
        )
        bottomBar.addSubview(shelfBtn)

        sessionsBtn = makeFooterIconButton(
            symbol: "sparkles",
            tooltip: "Claude Sessions",
            action: #selector(sessionsToggleTapped)
        )
        if let claudeImage = NSImage(named: "claude-logo") {
            claudeImage.size = NSSize(width: 14, height: 14)
            claudeImage.isTemplate = false
            sessionsBtn.image = claudeImage
            // Don't tint — preserve Claude brand color
            sessionsBtn.contentTintColor = nil
        }
        bottomBar.addSubview(sessionsBtn)

        remoteBtn = makeFooterIconButton(
            symbol: "iphone",
            tooltip: "No device connected",
            action: #selector(remoteBtnTapped)
        )
        bottomBar.addSubview(remoteBtn)

        // ──── Layout ────
        explorerHeightConstraint = explorer.heightAnchor.constraint(equalToConstant: explorerHeight)
        scrollViewBottomConstraint = scSection.bottomAnchor.constraint(lessThanOrEqualTo: bottomBar.topAnchor)

        NSLayoutConstraint.activate([
            // Workspace switcher (top)
            switcher.topAnchor.constraint(equalTo: topAnchor),
            switcher.leadingAnchor.constraint(equalTo: leadingAnchor),
            switcher.trailingAnchor.constraint(equalTo: trailingAnchor),

            // Scrollable tab list (workspaces)
            scrollView.topAnchor.constraint(equalTo: switcher.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

            // Resize handle (between workspaces and explorer)
            resizeHandle.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            resizeHandle.leadingAnchor.constraint(equalTo: leadingAnchor),
            resizeHandle.trailingAnchor.constraint(equalTo: trailingAnchor),
            resizeHandle.heightAnchor.constraint(equalToConstant: 12),

            // File explorer
            explorer.topAnchor.constraint(equalTo: resizeHandle.bottomAnchor),
            explorer.leadingAnchor.constraint(equalTo: leadingAnchor),
            explorer.trailingAnchor.constraint(equalTo: trailingAnchor),
            explorerHeightConstraint!,

            // Separator
            separator.topAnchor.constraint(equalTo: explorer.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            separator.heightAnchor.constraint(equalToConstant: 1),

            // Source control
            scSection.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            scSection.leadingAnchor.constraint(equalTo: leadingAnchor),
            scSection.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollViewBottomConstraint,

            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),

            // Bottom bar — slim native footer, no top border (the parent sidebar
            // already provides a divider via the source-control section above).
            bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 36),

            // All three footer buttons share the exact same hit target so they
            // line up vertically and read as a single control group.
            shelfBtn.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 8),
            shelfBtn.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            shelfBtn.widthAnchor.constraint(equalToConstant: 26),
            shelfBtn.heightAnchor.constraint(equalToConstant: 22),

            sessionsBtn.leadingAnchor.constraint(equalTo: shelfBtn.trailingAnchor, constant: 2),
            sessionsBtn.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            sessionsBtn.widthAnchor.constraint(equalToConstant: 26),
            sessionsBtn.heightAnchor.constraint(equalToConstant: 22),

            remoteBtn.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -8),
            remoteBtn.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            remoteBtn.widthAnchor.constraint(equalToConstant: 26),
            remoteBtn.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    /// Native-style sidebar footer button: borderless SF Symbol, subtle hover
    /// fill, accent tint when "on". Mirrors the look of Finder / Notes / Mail
    /// status-bar buttons so all three footer controls read as a single group.
    private func makeFooterIconButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let btn = FooterIconButton()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.bezelStyle = .texturedRounded
        btn.isBordered = false
        btn.title = ""
        btn.imagePosition = .imageOnly
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(cfg)
        btn.contentTintColor = ClomeMacColor.textSecondary
        btn.toolTip = tooltip
        btn.target = self
        btn.action = action
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 5
        btn.layer?.cornerCurve = .continuous
        return btn
    }

    private func makeNavButton(symbol: String, action: Selector?) -> NSButton {
        let btn = NSButton()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.bezelStyle = .texturedRounded
        btn.isBordered = false
        btn.title = ""
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        btn.contentTintColor = ClomeMacColor.textSecondary
        btn.wantsLayer = true
        btn.layer?.cornerRadius = ClomeMacMetric.compactRadius
        btn.layer?.cornerCurve = .continuous
        btn.layer?.backgroundColor = ClomeMacTheme.surfaceColor(.chromeAlt).cgColor
        btn.layer?.borderWidth = 1
        btn.layer?.borderColor = ClomeMacColor.border.cgColor
        if let action {
            btn.target = self
            btn.action = action
        }
        return btn
    }

    private func observeNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(onNotificationChange(_:)), name: .clomeNotificationCountChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onNotificationChange(_:)), name: .appearanceSettingsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onNotificationChange(_:)), name: .terminalActivityChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onTerminalFocused(_:)), name: .terminalSurfaceFocused, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onRemoteClientConnected(_:)), name: .remoteClientConnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onRemoteClientDisconnected(_:)), name: .remoteClientDisconnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onRemotePairingStateChanged(_:)), name: .remotePairingStarted, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onRemotePairingStateChanged(_:)), name: .remotePairingStopped, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onRemotePairingStateChanged(_:)), name: .remoteCloudStateChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onGitStatusChanged(_:)), name: .projectRootGitStatusChanged, object: nil)
    }

    @objc private func onNotificationChange(_ n: Notification) {
        if n.name == .terminalActivityChanged {
            // Terminal activity changes (output preview, program detection) happen every ~1s.
            // Do NOT rebuild the entire sidebar — it destroys hover states and eats clicks.
            // Only rebuild if we detect structural changes (tab count, titles).
            return
        }
        if n.name == .appearanceSettingsChanged {
            layer?.backgroundColor = bgColor.cgColor
            fileShelfView?.refreshAppearance()
            sourceControlSection?.refreshAppearance()
        }
        reloadWorkspaces()
    }

    @objc private func onTerminalFocused(_ n: Notification) {
        guard let terminal = n.object as? TerminalSurface else { return }
        guard let workspace = workspaceManager.activeWorkspace,
              let tab = workspace.activeTab else { return }
        let leaves = tab.splitContainer.allLeafViews
        if leaves.contains(where: { $0 === terminal }) {
            tab.focusedPane = terminal
            tab.splitContainer.focusedPane = terminal
            // Don't rebuild — just update the focused pane tracking.
            // The sidebar will rebuild on the next structural change.
        }
    }
    @objc private func sidebarToggleTapped() { onToggleSidebar?() }
    @objc private func shelfToggleTapped() {
        if isShelfVisible {
            hideFileShelf()
        } else {
            showFileShelf()
        }
    }

    @objc private func sessionsToggleTapped() {
        toggleSessionsPopover()
    }

    // MARK: - Remote Connection

    @objc private func onRemoteClientConnected(_ n: Notification) {
        refreshRemoteState()
    }

    @objc private func onRemoteClientDisconnected(_ n: Notification) {
        refreshRemoteState()
    }

    @objc private func onRemotePairingStateChanged(_ n: Notification) {
        refreshRemoteState()
    }

    @objc private func onGitStatusChanged(_ n: Notification) {
        guard let rootPath = n.object as? String,
              let workspace = workspaceManager.activeWorkspace,
              workspace.projectRoots.contains(where: { $0.path == rootPath }) else { return }
        updateSourceControl()
    }

    private func refreshRemoteState() {
        let server = RemoteServer.shared
        isRemoteConnected = server.connectedDeviceCount > 0
        connectedDeviceName = server.connectedDeviceNames.first
        updateRemoteButtonAppearance()
    }

    private func updateRemoteButtonAppearance() {
        // Native footer buttons communicate state through tint only — no card
        // background or border, matching the way Mail's status-bar buttons
        // light up when something is active.
        if isRemoteConnected {
            remoteBtn.contentTintColor = ClomeMacColor.success
            remoteBtn.toolTip = connectedDeviceName ?? "Device connected"
        } else if RemoteServer.shared.isPairingMode {
            remoteBtn.contentTintColor = ClomeMacColor.accent
            if let code = RemoteServer.shared.currentPairingCode {
                remoteBtn.toolTip = "Pairing active: \(code)"
            } else {
                remoteBtn.toolTip = "Pairing active"
            }
        } else {
            remoteBtn.contentTintColor = ClomeMacColor.textSecondary
            remoteBtn.toolTip = "No device connected"
        }
    }

    @objc private func remoteBtnTapped() {
        if let popover = remotePopover, popover.isShown {
            popover.performClose(nil)
            remotePopover = nil
            return
        }

        let server = RemoteServer.shared
        let content = RemotePopoverContent(
            connectedDeviceNames: server.connectedDeviceNames,
            pairedDeviceCount: server.pairedDeviceCount,
            currentPairingCode: server.currentPairingCode,
            isPairingMode: server.isPairingMode,
            cloudStatusSummary: server.cloudStatusSummary,
            isCloudHostingEnabled: server.isCloudHostingEnabled,
            onStartPairing: { [weak self] in
                _ = RemoteServer.shared.startPairing()
                self?.refreshRemoteState()
                self?.remotePopover?.performClose(nil)
                self?.remotePopover = nil
            },
            onStopPairing: { [weak self] in
                RemoteServer.shared.stopPairing()
                self?.refreshRemoteState()
                self?.remotePopover?.performClose(nil)
                self?.remotePopover = nil
            },
            onDisconnectAll: { [weak self] in
                RemoteServer.shared.disconnectAllClients()
                self?.refreshRemoteState()
                self?.remotePopover?.performClose(nil)
                self?.remotePopover = nil
            },
            onResetTrust: { [weak self] in
                RemoteServer.shared.resetTrustedDevices()
                self?.refreshRemoteState()
                self?.remotePopover?.performClose(nil)
                self?.remotePopover = nil
            },
            onToggleCloudHosting: { [weak self] enabled in
                RemoteServer.shared.setCloudHostingEnabled(enabled)
                self?.refreshRemoteState()
                self?.remotePopover?.performClose(nil)
                self?.remotePopover = nil
            }
        )
        let hosting = NSHostingController(rootView: content)

        let popover = NSPopover()
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: 336, height: server.isPairingMode ? 430 : 392)
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .aqua)
        popover.show(relativeTo: remoteBtn.bounds, of: remoteBtn, preferredEdge: .maxY)
        remotePopover = popover
    }

    /// Toggle the Claude sessions popover anchored to the sessions button.
    func toggleSessionsPopover() {
        if let popover = sessionsPopover, popover.isShown {
            popover.performClose(nil)
            sessionsRefreshTimer?.invalidate()
            sessionsRefreshTimer = nil
            sessionsPopover = nil
            sessionsBtn.contentTintColor = ClomeMacColor.textSecondary
            return
        }

        // Tint accent while the popover is open — same affordance Mail uses
        // for its "show unread" status button.
        sessionsBtn.contentTintColor = ClomeMacColor.accent

        let listView = ClaudeSessionListView()
        listView.translatesAutoresizingMaskIntoConstraints = false

        // Wire up callbacks
        listView.onResumeSession = { [weak self] session in
            self?.launchClaudeSession(sessionId: session.id, projectPath: session.projectPath, fork: false)
            self?.sessionsPopover?.performClose(nil)
        }
        listView.onForkSession = { [weak self] session in
            self?.launchClaudeSession(sessionId: session.id, projectPath: session.projectPath, fork: true)
            self?.sessionsPopover?.performClose(nil)
        }
        listView.onResumeInNewTab = { [weak self] session in
            self?.launchClaudeSession(sessionId: session.id, projectPath: session.projectPath, fork: false)
            self?.sessionsPopover?.performClose(nil)
        }
        listView.onSessionSelected = { [weak self] session in
            self?.launchClaudeSession(sessionId: session.id, projectPath: session.projectPath, fork: false)
            self?.sessionsPopover?.performClose(nil)
        }
        listView.onRenameSession = { session, name in
            ClaudeSessionManager.shared.saveSessionName(session.id, name: name)
            // Refresh the list to show updated name
            let projectPath = self.workspaceManager.activeWorkspace?.workingDirectory ?? session.projectPath
            let sessions = ClaudeSessionManager.shared.refreshSessions(forProject: projectPath)
            listView.reloadSessions(sessions)
        }
        listView.onRefresh = { [weak self] in
            guard let self else { return }
            ClaudeSessionManager.shared.invalidateCache()
            listView.reloadSessions(self.loadClaudeSessions())
        }

        // Load initial sessions
        ClaudeSessionManager.shared.invalidateCache()
        listView.reloadSessions(loadClaudeSessions())

        let vc = NSViewController()
        let effectView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        vc.view = effectView

        listView.translatesAutoresizingMaskIntoConstraints = true
        listView.frame = effectView.bounds
        listView.autoresizingMask = [.width, .height]
        effectView.addSubview(listView)

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 400)
        popover.behavior = .transient
        popover.contentViewController = vc
        popover.delegate = self
        popover.show(relativeTo: sessionsBtn.bounds, of: sessionsBtn, preferredEdge: .maxY)
        sessionsPopover = popover

        // Auto-refresh every 5s while popover is open
        sessionsRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self, weak listView] _ in
            Task { @MainActor in
                guard let self, let listView else { return }
                ClaudeSessionManager.shared.invalidateCache()
                let sessions = self.loadClaudeSessions()
                listView.reloadSessions(sessions)
            }
        }
    }

    private func loadClaudeSessions() -> [ClaudeSession] {
        let projectPath = workspaceManager.activeWorkspace?.workingDirectory ?? ""
        if !projectPath.isEmpty {
            return ClaudeSessionManager.shared.discoverSessions(forProject: projectPath)
        } else {
            return ClaudeSessionManager.shared.discoverAllSessions()
        }
    }

    private func launchClaudeSession(sessionId: String, projectPath: String, fork: Bool) {
        guard let workspace = workspaceManager.activeWorkspace else { return }
        workspace.addClaudeSessionTab(sessionId: sessionId, workingDirectory: projectPath, fork: fork)
        reloadWorkspaces()
    }

    private func showFileShelf() {
        guard fileShelfView == nil else { return }
        isShelfVisible = true
        shelfBtn.contentTintColor = ClomeMacColor.accent

        let shelf = FileShelfView()
        shelf.translatesAutoresizingMaskIntoConstraints = false
        shelf.alphaValue = 0
        // Add the shelf as a pure overlay above the existing sidebar content.
        // We deliberately do NOT reroute the source-control section's bottom
        // anchor through the shelf — doing so fights the workspace-list /
        // explorer / source-control constraint chain and on hide leaves the
        // sidebar in a half-collapsed state.
        addSubview(shelf, positioned: .above, relativeTo: nil)
        fileShelfView = shelf

        NSLayoutConstraint.activate([
            shelf.leadingAnchor.constraint(equalTo: leadingAnchor),
            shelf.trailingAnchor.constraint(equalTo: trailingAnchor),
            shelf.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            shelf.heightAnchor.constraint(equalToConstant: 280),
        ])

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            shelf.animator().alphaValue = 1
        }
    }

    private func hideFileShelf() {
        guard let shelf = fileShelfView else { return }
        isShelfVisible = false
        fileShelfView = nil
        shelfBtn.contentTintColor = ClomeMacColor.textPrimary

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            shelf.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                shelf.cleanup()
                shelf.removeFromSuperview()
            }
        })
    }

    @objc private func plusTapped() {
        let ws = workspaceManager.addWorkspace()
        expandedWorkspaces.insert(ws.id)
        reloadWorkspaces()
    }

    // MARK: - Coalesced Reload

    /// Schedule a reload on the next run loop iteration, deduplicating multiple calls within the same event.
    func setNeedsReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.reloadScheduled else { return }
            self.reloadScheduled = false
            self.reloadWorkspaces()
        }
    }

    // MARK: - Reload

    private var needsReloadAfterResize = false

    /// Show or hide the file-explorer + source-control chrome as a single unit.
    /// We collapse the explorer's height to 0 (instead of leaving a stale fixed
    /// height behind a hidden view) so the workspace list expands to fill the
    /// reclaimed space cleanly.
    private func setProjectChromeVisible(_ visible: Bool) {
        multiRootExplorer?.isHidden = !visible
        explorerResizeHandle?.isHidden = !visible
        chromeSeparator?.isHidden = !visible
        sourceControlSection?.isHidden = !visible
        explorerHeightConstraint?.constant = visible ? explorerHeight : 0
    }

    func reloadWorkspaces() {
        // Cancel any pending coalesced reload to avoid double-reload
        reloadScheduled = false

        // Don't rebuild views while user is dragging the explorer resize handle
        if isExplorerResizing {
            needsReloadAfterResize = true
            return
        }

        // Don't rebuild views while a tab drag-to-split is in progress
        if isDraggingTab {
            return
        }

        // ── Update new sectioned components (lightweight — no file tree reload) ──
        workspaceSwitcher?.update()

        // Update file explorer with project roots from active workspace
        let activeRoots: [ProjectRoot]
        if let workspace = workspaceManager.activeWorkspace {
            activeRoots = workspace.projectRoots
            multiRootExplorer?.setProjectRoots(activeRoots)
            // Update active file highlight from the current editor tab
            if let activeTab = workspace.activeTab, let editor = activeTab.view as? EditorPanel {
                multiRootExplorer?.activeFilePath = editor.filePath
            } else {
                multiRootExplorer?.activeFilePath = nil
            }
        } else {
            activeRoots = []
            multiRootExplorer?.setProjectRoots([])
        }
        // Hide the explorer / source-control chrome entirely until at least one
        // folder has been opened. An empty file tree and an empty "Source
        // Control" section just add visual noise to the welcome state.
        setProjectChromeVisible(!activeRoots.isEmpty)
        // Refresh git status so the Source Control section is in sync with the
        // active workspace on every reload (workspace switch, root added, etc).
        for root in activeRoots { root.refreshGitStatus() }
        updateSourceControl()

        // Auto-expand all workspaces on first load only
        if !hasAutoExpanded {
            hasAutoExpanded = true
            for ws in workspaceManager.workspaces {
                expandedWorkspaces.insert(ws.id)
            }
        }

        // Preserve scroll position across rebuild
        let savedScrollY = scrollView.contentView.bounds.origin.y

        stackView.arrangedSubviews.forEach { stackView.removeArrangedSubview($0); $0.removeFromSuperview() }

        for (wsIndex, workspace) in workspaceManager.workspaces.enumerated() {
            let isActive = wsIndex == workspaceManager.activeWorkspaceIndex
            let isExpanded = expandedWorkspaces.contains(workspace.id)
            let capturedWsIndex = wsIndex

            // ── Workspace group container (no background, separated by spacing) ──
            let wsGroup = NSView()
            wsGroup.translatesAutoresizingMaskIntoConstraints = false
            wsGroup.wantsLayer = true

            let wsStack = NSStackView()
            wsStack.orientation = .vertical
            wsStack.spacing = 2
            wsStack.alignment = .leading
            wsStack.translatesAutoresizingMaskIntoConstraints = false
            wsGroup.addSubview(wsStack)

            NSLayoutConstraint.activate([
                wsStack.leadingAnchor.constraint(equalTo: wsGroup.leadingAnchor),
                wsStack.trailingAnchor.constraint(equalTo: wsGroup.trailingAnchor),
                wsStack.topAnchor.constraint(equalTo: wsGroup.topAnchor),
                wsStack.bottomAnchor.constraint(equalTo: wsGroup.bottomAnchor),
            ])

            // ── Workspace header ──
            let header = SidebarRow(height: 30)
            let folderIcon = NSImageView()
            let chevronIcon = NSImageView()
            let plusIcon = NSImageView()
            header.configure { view in
                let tc = isActive ? NSColor(white: 0.92, alpha: 1.0) : NSColor(white: 0.55, alpha: 1.0)

                // Folder icon — visible by default, hides on hover
                let folderCfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
                let folderName = isExpanded ? "folder.fill" : "folder"
                folderIcon.translatesAutoresizingMaskIntoConstraints = false
                folderIcon.image = NSImage(systemSymbolName: folderName, accessibilityDescription: nil)?.withSymbolConfiguration(folderCfg)
                folderIcon.contentTintColor = isActive ? workspace.color.nsColor : workspace.color.nsColor.withAlphaComponent(0.6)
                folderIcon.imageScaling = .scaleProportionallyDown
                view.addSub(folderIcon, leading: 10, centerY: true, width: 16, height: 14)

                // Chevron — same position as folder, hidden by default, replaces folder on hover
                let chevCfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
                let chevName = isExpanded ? "chevron.down" : "chevron.right"
                chevronIcon.translatesAutoresizingMaskIntoConstraints = false
                chevronIcon.image = NSImage(systemSymbolName: chevName, accessibilityDescription: nil)?.withSymbolConfiguration(chevCfg)
                chevronIcon.contentTintColor = NSColor(white: 0.55, alpha: 1.0)
                chevronIcon.imageScaling = .scaleProportionallyDown
                chevronIcon.alphaValue = 0
                view.addSub(chevronIcon, leading: 10, centerY: true, width: 16, height: 14)

                let title = NSTextField(labelWithString: workspace.name)
                title.font = .systemFont(ofSize: 12, weight: .medium)
                title.textColor = tc
                title.lineBreakMode = .byTruncatingTail
                view.addSub(title, leading: 32, centerY: true, trailingOffset: 28)

                // Small "+" icon on the right, hidden until hover
                let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
                plusIcon.translatesAutoresizingMaskIntoConstraints = false
                plusIcon.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")?.withSymbolConfiguration(cfg)
                plusIcon.contentTintColor = NSColor(white: 0.50, alpha: 1.0)
                plusIcon.imageScaling = .scaleProportionallyDown
                plusIcon.alphaValue = 0
                view.addSub(plusIcon, trailing: 6, centerY: true, width: 20, height: 20)
            }

            header.bgHover = ClomeMacColor.hoverFill
            header.cornerRadius = 6
            header.onHoverChange = { hovering in
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    // Crossfade: folder ↔ chevron
                    folderIcon.animator().alphaValue = hovering ? 0.0 : 1.0
                    chevronIcon.animator().alphaValue = hovering ? 1.0 : 0.0
                    plusIcon.animator().alphaValue = hovering ? 1.0 : 0.0
                }
            }
            header.onClick = { [weak self] clickPoint in
                guard let self else { return }
                // Check if click landed on the "+" icon area (right 28px)
                let plusHit = clickPoint.x > header.bounds.width - 28
                if plusHit && isExpanded {
                    self.toggleNewTabReveal(workspace.id)
                } else {
                    let wasExpanded = self.expandedWorkspaces.contains(workspace.id)
                    // Only switch active workspace when expanding or clicking already-expanded
                    if !wasExpanded || isActive {
                        self.workspaceManager.switchTo(index: capturedWsIndex)
                        NotificationSystem.shared.markRead(workspaceId: workspace.id)
                    }
                    self.toggleExpand(workspace.id)
                }
            }
            header.onDoubleClick = { [weak self] in
                self?.startRenameWorkspace(at: capturedWsIndex)
            }
            header.onRightClick = { [weak self] event in
                self?.showWorkspaceContextMenu(at: capturedWsIndex, event: event)
            }
            header.onDragReorder = { [weak self] delta in
                self?.handleWorkspaceDrag(from: capturedWsIndex, delta: delta)
            }

            wsStack.addArrangedSubview(header)
            let hLead = header.leadingAnchor.constraint(equalTo: wsStack.leadingAnchor, constant: 4)
            hLead.priority = .defaultHigh
            hLead.isActive = true
            let hTrail = header.trailingAnchor.constraint(equalTo: wsStack.trailingAnchor, constant: -4)
            hTrail.priority = .defaultHigh
            hTrail.isActive = true

            // ── Tab rows (indented with vertical guide line) ──
            if isExpanded {
                // Container with subtle left indent line
                let tabsContainer = NSView()
                tabsContainer.translatesAutoresizingMaskIntoConstraints = false
                tabsContainer.wantsLayer = true

                let tabsStack = NSStackView()
                tabsStack.orientation = .vertical
                tabsStack.spacing = 1
                tabsStack.alignment = .leading
                tabsStack.translatesAutoresizingMaskIntoConstraints = false
                tabsContainer.addSubview(tabsStack)

                NSLayoutConstraint.activate([
                    tabsStack.leadingAnchor.constraint(equalTo: tabsContainer.leadingAnchor, constant: 10),
                    tabsStack.trailingAnchor.constraint(equalTo: tabsContainer.trailingAnchor),
                    tabsStack.topAnchor.constraint(equalTo: tabsContainer.topAnchor),
                    tabsStack.bottomAnchor.constraint(equalTo: tabsContainer.bottomAnchor),
                ])

                for (tabIndex, tab) in workspace.tabs.enumerated() {
                    let isTabActive = isActive && tabIndex == workspace.activeTabIndex
                    let capturedTabIndex = tabIndex

                    // Check if this is a non-split terminal tab with activity info
                    let terminal = tab.view as? TerminalSurface
                    let hasActivity = !tab.isSplit && terminal != nil && (terminal?.detectedProgram != nil || terminal?.outputPreview != nil)

                    if tab.isSplit {
                        // ── Split tab: plain text header with collapse/expand + close ──
                        let isSplitCollapsed = collapsedSplitTabs.contains(tab.id)
                        let splitHeader = SidebarRow(height: 26)
                        let splitCloseBtn = NSButton()
                        splitHeader.configure { view in
                            let tc = isTabActive ? NSColor(white: 0.55, alpha: 1.0) : NSColor(white: 0.40, alpha: 1.0)

                            let chevron = NSImageView()
                            let chevCfg = NSImage.SymbolConfiguration(pointSize: 8, weight: .medium)
                            let chevName = isSplitCollapsed ? "chevron.right" : "chevron.down"
                            chevron.image = NSImage(systemSymbolName: chevName, accessibilityDescription: nil)?.withSymbolConfiguration(chevCfg)
                            chevron.contentTintColor = tc
                            view.addSub(chevron, leading: 10, centerY: true, width: 10, height: 10)

                            let title = NSTextField(labelWithString: tab.splitDescription)
                            title.font = .systemFont(ofSize: 11, weight: .regular)
                            title.textColor = tc
                            title.lineBreakMode = .byTruncatingTail
                            view.addSub(title, leading: 24, centerY: true, trailingOffset: 26)

                            splitCloseBtn.translatesAutoresizingMaskIntoConstraints = false
                            splitCloseBtn.bezelStyle = .texturedRounded
                            splitCloseBtn.isBordered = false
                            splitCloseBtn.title = ""
                            let closeCfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
                            splitCloseBtn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?.withSymbolConfiguration(closeCfg)
                            splitCloseBtn.contentTintColor = NSColor(white: 0.4, alpha: 1.0)
                            splitCloseBtn.alphaValue = 0
                            splitCloseBtn.target = self
                            splitCloseBtn.action = #selector(closeTabButtonTapped(_:))
                            splitCloseBtn.identifier = NSUserInterfaceItemIdentifier("closeTab-\(capturedWsIndex)-\(capturedTabIndex)")
                            view.addSub(splitCloseBtn, trailing: 6, centerY: true, width: 20, height: 20)
                        }

                        splitHeader.cornerRadius = 4
                        splitHeader.onHoverChange = { hovering in
                            NSAnimationContext.runAnimationGroup { ctx in
                                ctx.duration = 0.15
                                splitCloseBtn.animator().alphaValue = hovering ? 1.0 : 0.0
                            }
                        }
                        splitHeader.onClick = { [weak self] clickPoint in
                            guard let self else { return }
                            let closeHit = clickPoint.x > splitHeader.bounds.width - 28
                            if !closeHit {
                                self.workspaceManager.switchTo(index: capturedWsIndex)
                                workspace.selectTab(capturedTabIndex)
                                if self.collapsedSplitTabs.contains(tab.id) {
                                    self.collapsedSplitTabs.remove(tab.id)
                                } else {
                                    self.collapsedSplitTabs.insert(tab.id)
                                }
                                self.reloadWorkspaces()
                            }
                        }
                        splitHeader.onRightClick = { [weak self] event in
                            self?.showTabContextMenu(workspace: workspace, wsIndex: capturedWsIndex, tabIndex: capturedTabIndex, event: event)
                        }
                        splitHeader.onDragBegan = { [weak self] point in
                            self?.isDraggingTab = true
                            self?.onDragTabBegan?(capturedWsIndex, capturedTabIndex)
                        }
                        splitHeader.onDragMoved = { [weak self] point in
                            self?.onDragTabMoved?(capturedWsIndex, capturedTabIndex, point)
                        }
                        splitHeader.onDragEnded = { [weak self] point in
                            self?.onDragTabEnded?(capturedWsIndex, capturedTabIndex, point)
                            self?.isDraggingTab = false
                            self?.setNeedsReload()
                        }
                        splitHeader.onDragReorder = { [weak self] delta in
                            self?.handleTabDrag(workspace: workspace, from: capturedTabIndex, delta: delta)
                        }

                        tabsStack.addArrangedSubview(splitHeader)
                        splitHeader.leadingAnchor.constraint(equalTo: tabsStack.leadingAnchor, constant: 2).isActive = true
                        splitHeader.trailingAnchor.constraint(equalTo: tabsStack.trailingAnchor, constant: -2).isActive = true

                        // ── Pane group (collapsible) ──
                        if !isSplitCollapsed {
                            let splitGroup = NSView()
                            splitGroup.translatesAutoresizingMaskIntoConstraints = false
                            splitGroup.wantsLayer = true
                            splitGroup.layer?.backgroundColor = ClomeMacTheme.surfaceColor(.chromeAlt).cgColor
                            splitGroup.layer?.cornerRadius = 8
                            splitGroup.layer?.cornerCurve = .continuous

                            let splitStack = NSStackView()
                            splitStack.orientation = .vertical
                            splitStack.spacing = 0
                            splitStack.alignment = .leading
                            splitStack.translatesAutoresizingMaskIntoConstraints = false
                            splitGroup.addSubview(splitStack)

                            NSLayoutConstraint.activate([
                                splitStack.leadingAnchor.constraint(equalTo: splitGroup.leadingAnchor),
                                splitStack.trailingAnchor.constraint(equalTo: splitGroup.trailingAnchor),
                                splitStack.topAnchor.constraint(equalTo: splitGroup.topAnchor, constant: 4),
                                splitStack.bottomAnchor.constraint(equalTo: splitGroup.bottomAnchor, constant: -4),
                            ])

                            for paneView in tab.splitContainer.allLeafViews {
                                let isFocused = paneView === tab.focusedPane
                                let capturedPane = paneView

                                let focusAction: () -> Void = { [weak self] in
                                    self?.workspaceManager.switchTo(index: capturedWsIndex)
                                    tab.focusedPane = capturedPane
                                    tab.splitContainer.focusedPane = capturedPane
                                    workspace.selectTab(capturedTabIndex)
                                    self?.reloadWorkspaces()
                                }

                                if let terminal = paneView as? TerminalSurface,
                                   terminal.detectedProgram != nil || terminal.outputPreview != nil {
                                    let card = makePaneActivityCard(
                                        terminal: terminal,
                                        isFocused: isFocused,
                                        onClick: focusAction
                                    )
                                    splitStack.addArrangedSubview(card)
                                    card.leadingAnchor.constraint(equalTo: splitStack.leadingAnchor).isActive = true
                                    card.trailingAnchor.constraint(equalTo: splitStack.trailingAnchor).isActive = true
                                } else {
                                    let (paneIcon, paneTitle) = WorkspaceTab.paneLabel(for: paneView)
                                    let paneRow = SidebarRow(height: 28)
                                    paneRow.configure { view in
                                        let tc = isFocused ? NSColor(white: 0.85, alpha: 1.0) : NSColor(white: 0.45, alpha: 1.0)

                                        let icon = NSImageView()
                                        let iconCfg = NSImage.SymbolConfiguration(pointSize: 10, weight: isFocused ? .semibold : .regular)
                                        icon.image = NSImage(systemSymbolName: paneIcon, accessibilityDescription: nil)?.withSymbolConfiguration(iconCfg)
                                        icon.contentTintColor = isFocused ? NSColor.controlAccentColor : tc
                                        icon.imageScaling = .scaleProportionallyDown
                                        view.addSub(icon, leading: 14, centerY: true, width: 14, height: 14)

                                        let title = NSTextField(labelWithString: paneTitle)
                                        title.font = .systemFont(ofSize: 11, weight: isFocused ? .medium : .regular)
                                        title.textColor = tc
                                        title.lineBreakMode = .byTruncatingTail
                                        view.addSub(title, leading: 32, centerY: true, trailingOffset: 10)
                                    }

                                    paneRow.bgHover = ClomeMacColor.hoverFill
                                    paneRow.cornerRadius = 6
                                    paneRow.onClick = { _ in focusAction() }

                                    splitStack.addArrangedSubview(paneRow)
                                    paneRow.leadingAnchor.constraint(equalTo: splitStack.leadingAnchor).isActive = true
                                    paneRow.trailingAnchor.constraint(equalTo: splitStack.trailingAnchor).isActive = true
                                }
                            }

                            tabsStack.addArrangedSubview(splitGroup)
                            splitGroup.leadingAnchor.constraint(equalTo: tabsStack.leadingAnchor, constant: 2).isActive = true
                            splitGroup.trailingAnchor.constraint(equalTo: tabsStack.trailingAnchor, constant: -2).isActive = true
                        }

                    } else if hasActivity, let terminal {
                        // ── Rich terminal activity card (non-split) ──
                        let card = makeTerminalActivityCard(
                            terminal: terminal,
                            isActive: isTabActive,
                            tab: tab,
                            wsIndex: capturedWsIndex,
                            tabIndex: capturedTabIndex,
                            workspace: workspace
                        )
                        tabsStack.addArrangedSubview(card)
                        card.leadingAnchor.constraint(equalTo: tabsStack.leadingAnchor, constant: 2).isActive = true
                        card.trailingAnchor.constraint(equalTo: tabsStack.trailingAnchor, constant: -2).isActive = true
                    } else {
                        // ── Standard tab row (non-split) ──
                        let tabRow = SidebarRow(height: 32)
                        let tabCloseBtn = NSButton()
                        tabRow.configure { view in
                            // One palette across every tab type. Inactive labels were sitting
                            // at white(0.50) which read as muted-grey on the sidebar fill;
                            // bumped to 0.72 so Terminal / Browser / Flow / Editor titles all
                            // share the same legibility level.
                            let tc: NSColor = isTabActive
                                ? NSColor.white
                                : NSColor(white: 0.72, alpha: 1.0)

                            let icon = NSImageView()
                            if let favicon = tab.favicon {
                                icon.image = favicon
                                icon.imageScaling = .scaleProportionallyDown
                            } else {
                                // Use a single point size + weight for every tab type so
                                // Terminal / Browser / Flow / Editor icons read at the same
                                // visual weight. When the row is active the icon sits on a
                                // blue fill, so tint with white (not the accent colour, which
                                // would vanish into the background).
                                let iconCfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
                                let iconName = (tab.view as? TerminalSurface)?.programIcon ?? tab.type.icon
                                icon.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?.withSymbolConfiguration(iconCfg)
                                icon.contentTintColor = tc
                                icon.imageScaling = .scaleProportionallyDown
                            }
                            view.addSub(icon, leading: 14, centerY: true, width: 16, height: 16)

                            if tab.isPinned {
                                let pinIcon = NSImageView()
                                let pinCfg = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
                                pinIcon.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?.withSymbolConfiguration(pinCfg)
                                pinIcon.contentTintColor = isTabActive ? NSColor.white : NSColor(white: 0.55, alpha: 1.0)
                                view.addSub(pinIcon, leading: 2, centerY: true, width: 9, height: 9)
                            }

                            let title = NSTextField(labelWithString: tab.title)
                            title.font = .systemFont(ofSize: 11, weight: isTabActive ? .medium : .regular)
                            title.textColor = tc
                            title.lineBreakMode = .byTruncatingTail
                            view.addSub(title, leading: 36, centerY: true, trailingOffset: 26)

                            tabCloseBtn.translatesAutoresizingMaskIntoConstraints = false
                            tabCloseBtn.bezelStyle = .texturedRounded
                            tabCloseBtn.isBordered = false
                            tabCloseBtn.title = ""
                            let closeCfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
                            tabCloseBtn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?.withSymbolConfiguration(closeCfg)
                            tabCloseBtn.contentTintColor = NSColor(white: 0.5, alpha: 1.0)
                            tabCloseBtn.alphaValue = 0
                            tabCloseBtn.target = self
                            tabCloseBtn.action = #selector(closeTabButtonTapped(_:))
                            tabCloseBtn.identifier = NSUserInterfaceItemIdentifier("closeTab-\(capturedWsIndex)-\(capturedTabIndex)")
                            view.addSub(tabCloseBtn, trailing: 6, centerY: true, width: 20, height: 20)

                            if let terminal, terminal.detectedProgram != nil {
                                let statusDot = NSView()
                                statusDot.translatesAutoresizingMaskIntoConstraints = false
                                statusDot.wantsLayer = true
                                statusDot.layer?.backgroundColor = terminal.statusColor.cgColor
                                statusDot.layer?.cornerRadius = 3
                                view.addSubview(statusDot)
                                NSLayoutConstraint.activate([
                                    statusDot.trailingAnchor.constraint(equalTo: tabCloseBtn.leadingAnchor, constant: -4),
                                    statusDot.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                                    statusDot.widthAnchor.constraint(equalToConstant: 6),
                                    statusDot.heightAnchor.constraint(equalToConstant: 6),
                                ])
                            }
                        }

                        if isTabActive {
                            tabRow.bgActive = ClomeMacColor.accent
                        }
                        tabRow.bgHover = ClomeMacColor.hoverFill
                        tabRow.cornerRadius = 6
                        tabRow.onHoverChange = { hovering in
                            NSAnimationContext.runAnimationGroup { ctx in
                                ctx.duration = 0.15
                                tabCloseBtn.animator().alphaValue = hovering ? 1.0 : 0.0
                            }
                        }

                        tabRow.onClick = { [weak self] _ in
                            self?.workspaceManager.switchTo(index: capturedWsIndex)
                            workspace.selectTab(capturedTabIndex)
                            // Don't call reloadWorkspaces() here — it destroys the view
                            // being clicked, causing flickering and missed clicks.
                            // The tab bar and content area update via callbacks.
                        }
                        tabRow.onDoubleClick = { [weak self] in
                            self?.startRenameTab(workspace: workspace, tabIndex: capturedTabIndex)
                        }
                        tabRow.onRightClick = { [weak self] event in
                            self?.showTabContextMenu(workspace: workspace, wsIndex: capturedWsIndex, tabIndex: capturedTabIndex, event: event)
                        }
                        tabRow.onDragBegan = { [weak self] point in
                            self?.isDraggingTab = true
                            self?.onDragTabBegan?(capturedWsIndex, capturedTabIndex)
                        }
                        tabRow.onDragMoved = { [weak self] point in
                            self?.onDragTabMoved?(capturedWsIndex, capturedTabIndex, point)
                        }
                        tabRow.onDragEnded = { [weak self] point in
                            self?.onDragTabEnded?(capturedWsIndex, capturedTabIndex, point)
                            self?.isDraggingTab = false
                            self?.setNeedsReload()
                        }
                        // Vertical drag → reorder this tab within its workspace
                        tabRow.onDragReorder = { [weak self] delta in
                            self?.handleTabDrag(workspace: workspace, from: capturedTabIndex, delta: delta)
                        }

                        tabsStack.addArrangedSubview(tabRow)
                        tabRow.leadingAnchor.constraint(equalTo: tabsStack.leadingAnchor, constant: 2).isActive = true
                        tabRow.trailingAnchor.constraint(equalTo: tabsStack.trailingAnchor, constant: -2).isActive = true
                    }

                    // ── File explorer inline for active project tab ──
                    if isActive && isTabActive && tab.type == .project,
                       let projectPanel = tab.view as? ProjectPanel {

                        // Divider with built-in vertical spacing
                        let dividerWrap = NSView()
                        dividerWrap.translatesAutoresizingMaskIntoConstraints = false
                        let divider = NSView()
                        divider.translatesAutoresizingMaskIntoConstraints = false
                        divider.wantsLayer = true
                        divider.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
                        dividerWrap.addSubview(divider)
                        NSLayoutConstraint.activate([
                            divider.leadingAnchor.constraint(equalTo: dividerWrap.leadingAnchor, constant: 8),
                            divider.trailingAnchor.constraint(equalTo: dividerWrap.trailingAnchor, constant: -8),
                            divider.centerYAnchor.constraint(equalTo: dividerWrap.centerYAnchor),
                            divider.heightAnchor.constraint(equalToConstant: 1),
                        ])
                        tabsStack.addArrangedSubview(dividerWrap)
                        NSLayoutConstraint.activate([
                            dividerWrap.leadingAnchor.constraint(equalTo: tabsStack.leadingAnchor),
                            dividerWrap.trailingAnchor.constraint(equalTo: tabsStack.trailingAnchor),
                            dividerWrap.heightAnchor.constraint(equalToConstant: 8),
                        ])

                        // File tree with fixed height from explorerHeight
                        let explorer = projectPanel.fileExplorer
                        explorer.translatesAutoresizingMaskIntoConstraints = false

                        // Deactivate any previous height constraint to avoid conflicts
                        if let old = self.explorerHeightConstraint {
                            old.isActive = false
                        }

                        tabsStack.addArrangedSubview(explorer)
                        let heightConstraint = explorer.heightAnchor.constraint(equalToConstant: self.explorerHeight)
                        self.explorerHeightConstraint = heightConstraint
                        NSLayoutConstraint.activate([
                            explorer.leadingAnchor.constraint(equalTo: tabsStack.leadingAnchor),
                            explorer.trailingAnchor.constraint(equalTo: tabsStack.trailingAnchor),
                            heightConstraint,
                        ])

                        // Drag handle at the bottom edge of the explorer
                        let handle = ExplorerResizeHandle()
                        handle.translatesAutoresizingMaskIntoConstraints = false
                        handle.onDrag = { [weak self] delta in
                            guard let self else { return }
                            let newHeight = max(100, min(600, self.explorerHeight - delta))
                            self.explorerHeight = newHeight
                            self.explorerHeightConstraint?.constant = newHeight
                        }
                        handle.onDragBegan = { [weak self] in
                            self?.isExplorerResizing = true
                        }
                        handle.onDragEnded = { [weak self] in
                            guard let self else { return }
                            self.isExplorerResizing = false
                            if self.needsReloadAfterResize {
                                self.needsReloadAfterResize = false
                                self.reloadWorkspaces()
                            }
                        }
                        tabsStack.addArrangedSubview(handle)
                        NSLayoutConstraint.activate([
                            handle.leadingAnchor.constraint(equalTo: tabsStack.leadingAnchor),
                            handle.trailingAnchor.constraint(equalTo: tabsStack.trailingAnchor),
                            handle.heightAnchor.constraint(equalToConstant: 12),
                        ])
                    }
                }

                // ── New tab cards (revealed by "+" in header) ──
                if revealedNewTab.contains(workspace.id) {
                    let cardsContainer = NSView()
                    cardsContainer.translatesAutoresizingMaskIntoConstraints = false
                    cardsContainer.wantsLayer = true

                    let cardStack = NSStackView()
                    cardStack.orientation = .horizontal
                    cardStack.spacing = 8
                    cardStack.distribution = .fillEqually
                    cardStack.translatesAutoresizingMaskIntoConstraints = false
                    cardsContainer.addSubview(cardStack)

                    let terminalCard = NewTabCard(icon: "terminal", label: "Terminal")
                    terminalCard.onClick = { [weak self] in
                        self?.workspaceManager.switchTo(index: capturedWsIndex)
                        workspace.addTerminalTab()
                        self?.revealedNewTab.remove(workspace.id)
                        self?.reloadWorkspaces()
                        self?.notifyTabsChanged()
                    }

                    let browserCard = NewTabCard(icon: "globe", label: "Browser")
                    browserCard.onClick = { [weak self] in
                        self?.workspaceManager.switchTo(index: capturedWsIndex)
                        workspace.addBrowserTab()
                        self?.revealedNewTab.remove(workspace.id)
                        self?.reloadWorkspaces()
                        self?.notifyTabsChanged()
                    }

                    let projectCard = NewTabCard(icon: "folder", label: "Project")
                    projectCard.onClick = { [weak self] in
                        self?.revealedNewTab.remove(workspace.id)
                        self?.openDirectoryForProject(workspace: workspace, wsIndex: capturedWsIndex)
                    }

                    let editorCard = NewTabCard(icon: "doc.text", label: "File")
                    editorCard.onClick = { [weak self] in
                        self?.workspaceManager.switchTo(index: capturedWsIndex)
                        _ = try? workspace.addEditorTab()
                        self?.revealedNewTab.remove(workspace.id)
                        self?.reloadWorkspaces()
                        self?.notifyTabsChanged()
                    }

                    cardStack.addArrangedSubview(terminalCard)
                    cardStack.addArrangedSubview(browserCard)
                    cardStack.addArrangedSubview(projectCard)
                    cardStack.addArrangedSubview(editorCard)

                    tabsStack.addArrangedSubview(cardsContainer)
                    NSLayoutConstraint.activate([
                        cardsContainer.leadingAnchor.constraint(equalTo: tabsStack.leadingAnchor, constant: 4),
                        cardsContainer.trailingAnchor.constraint(equalTo: tabsStack.trailingAnchor, constant: -4),
                        cardsContainer.heightAnchor.constraint(equalToConstant: 52),

                        cardStack.leadingAnchor.constraint(equalTo: cardsContainer.leadingAnchor),
                        cardStack.trailingAnchor.constraint(equalTo: cardsContainer.trailingAnchor),
                        cardStack.topAnchor.constraint(equalTo: cardsContainer.topAnchor, constant: 6),
                        cardStack.bottomAnchor.constraint(equalTo: cardsContainer.bottomAnchor, constant: -6),
                    ])
                }

                // Add the indented tabs container to the workspace group
                wsStack.addArrangedSubview(tabsContainer)
                tabsContainer.leadingAnchor.constraint(equalTo: wsStack.leadingAnchor).isActive = true
                tabsContainer.trailingAnchor.constraint(equalTo: wsStack.trailingAnchor).isActive = true
            }

            // Add workspace group to main stack
            stackView.addArrangedSubview(wsGroup)
            wsGroup.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
            wsGroup.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
        }

        // Restore scroll position after rebuild
        stackView.layoutSubtreeIfNeeded()
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: savedScrollY))
    }

    // MARK: - Terminal Activity Card

    private func makeTerminalActivityCard(
        terminal: TerminalSurface,
        isActive: Bool,
        tab: WorkspaceTab,
        wsIndex: Int,
        tabIndex: Int,
        workspace: Workspace
    ) -> NSView {
        let card: NSView = isActive ? OpaqueCardView() : NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        if isActive {
            card.layer?.backgroundColor = ClomeMacColor.accent.cgColor
        }
        card.layer?.cornerRadius = 8
        card.layer?.cornerCurve = .continuous

        let programName = terminal.detectedProgram ?? "Terminal"
        
        // Only show preview when active, has content, and program is doing something
        let rawPreview = isActive ? (terminal.lastNotification ?? terminal.outputPreview) : nil
        // Hide preview when idle (nothing interesting to show)
        let preview = (terminal.activityState == .idle) ? nil : rawPreview
        // Only show info row when there's a git branch or a meaningful path (not just ~)
        let hasMeaningfulPath = terminal.shortPath != nil && terminal.shortPath != "~"
        let hasGitInfo = terminal.gitBranch != nil || hasMeaningfulPath

        let vPad: CGFloat = 8  // symmetric top/bottom padding

        // ── Program icon + title row ──
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let iconCfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        iconView.image = NSImage(systemSymbolName: terminal.programIcon, accessibilityDescription: nil)?.withSymbolConfiguration(iconCfg)
        iconView.contentTintColor = isActive ? .white : NSColor(white: 0.6, alpha: 1.0)
        card.addSubview(iconView)

        let titleLabel = NSTextField(labelWithString: programName)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = isActive ? .white : NSColor(white: 0.7, alpha: 1.0)
        titleLabel.lineBreakMode = .byTruncatingTail
        card.addSubview(titleLabel)

        // Close button (hidden until hover)
        let closeBtn = NSButton()
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.bezelStyle = .texturedRounded
        closeBtn.isBordered = false
        closeBtn.title = ""
        let closeCfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        closeBtn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?.withSymbolConfiguration(closeCfg)
        closeBtn.contentTintColor = isActive ? NSColor(white: 1.0, alpha: 0.8) : NSColor(white: 0.6, alpha: 1.0)
        closeBtn.alphaValue = 0
        closeBtn.target = self
        closeBtn.action = #selector(closeTabButtonTapped(_:))
        closeBtn.identifier = NSUserInterfaceItemIdentifier("closeTab-\(wsIndex)-\(tabIndex)")
        card.addSubview(closeBtn)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            iconView.topAnchor.constraint(equalTo: card.topAnchor, constant: vPad),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeBtn.leadingAnchor, constant: -4),

            closeBtn.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            closeBtn.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            closeBtn.widthAnchor.constraint(equalToConstant: 16),
            closeBtn.heightAnchor.constraint(equalToConstant: 16),
        ])

        var lastBottom = iconView.bottomAnchor

        // ── Claude Code status section ──
        if terminal.detectedProgram == "Claude Code", let claudeState = terminal.claudeCodeState {
            let statusText: String
            let statusColor: NSColor
            
            switch claudeState {
            case .thinking:
                statusText = "Thinking..."
                statusColor = NSColor(red: 1.0, green: 0.8, blue: 0.4, alpha: 1.0) // Warm yellow
            case .doneWithTask:
                statusText = "Done with task."
                statusColor = NSColor(red: 0.4, green: 0.8, blue: 0.4, alpha: 1.0) // Green
            case .awaitingSelection:
                statusText = "Awaiting selection..."
                statusColor = NSColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 1.0) // Blue
            case .awaitingPermission:
                statusText = "Awaiting permission..."
                statusColor = NSColor(red: 1.0, green: 0.6, blue: 0.4, alpha: 1.0) // Orange
            }
            
            let statusLabel = NSTextField(labelWithString: statusText)
            statusLabel.translatesAutoresizingMaskIntoConstraints = false
            statusLabel.font = .systemFont(ofSize: 10, weight: .medium)
            statusLabel.textColor = isActive ? NSColor(white: 1.0, alpha: 0.85) : statusColor
            statusLabel.lineBreakMode = .byTruncatingTail
            card.addSubview(statusLabel)

            NSLayoutConstraint.activate([
                statusLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
                statusLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
                statusLabel.topAnchor.constraint(equalTo: lastBottom, constant: 4),
            ])
            lastBottom = statusLabel.bottomAnchor
        }

        // ── Output preview ──
        if let preview, !preview.isEmpty {
            let previewLabel = NSTextField(labelWithString: preview)
            previewLabel.translatesAutoresizingMaskIntoConstraints = false
            previewLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            previewLabel.textColor = isActive ? NSColor(white: 1.0, alpha: 0.7) : NSColor(white: 0.55, alpha: 1.0)
            previewLabel.lineBreakMode = .byTruncatingTail
            previewLabel.maximumNumberOfLines = 3
            previewLabel.cell?.wraps = true
            previewLabel.cell?.truncatesLastVisibleLine = true
            card.addSubview(previewLabel)

            NSLayoutConstraint.activate([
                previewLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
                previewLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
                previewLabel.topAnchor.constraint(equalTo: lastBottom, constant: 6),
            ])
            lastBottom = previewLabel.bottomAnchor
        }

        // ── Git branch + path row ──
        if hasGitInfo {
            var infoText = ""
            if let branch = terminal.gitBranch {
                infoText += branch
                if let wd = terminal.workingDirectory {
                    let statusPath = "\(wd)/.git/index"
                    if FileManager.default.fileExists(atPath: statusPath) {
                        infoText += "*"
                    }
                }
            }
            if let path = terminal.shortPath {
                if !infoText.isEmpty { infoText += " \u{2022} " }
                infoText += path
            }

            let infoLabel = NSTextField(labelWithString: infoText)
            infoLabel.translatesAutoresizingMaskIntoConstraints = false
            infoLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            infoLabel.textColor = isActive ? NSColor(white: 1.0, alpha: 0.7) : NSColor(white: 0.50, alpha: 1.0)
            infoLabel.lineBreakMode = .byTruncatingTail
            card.addSubview(infoLabel)

            NSLayoutConstraint.activate([
                infoLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
                infoLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
                infoLabel.topAnchor.constraint(equalTo: lastBottom, constant: 4),
            ])
            lastBottom = infoLabel.bottomAnchor
        }

        // Pin last element to bottom with same padding as top
        lastBottom.constraint(equalTo: card.bottomAnchor, constant: -vPad).isActive = true

        // ── Interaction ──
        // Use a ClickableCardView so clicks work without a gesture recognizer
        // (gesture recognizers swallow clicks on child buttons)
        let clickCard = ClickableCardView(wrapping: card)
        clickCard.translatesAutoresizingMaskIntoConstraints = false
        clickCard.onHoverChange = { hovering in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                closeBtn.animator().alphaValue = hovering ? 1.0 : 0.0
            }
        }
        clickCard.onClick = { [weak self] in
            self?.workspaceManager.switchTo(index: wsIndex)
            self?.workspaceManager.workspaces[wsIndex].selectTab(tabIndex)
            self?.reloadWorkspaces()
        }
        clickCard.onDragBegan = { [weak self] point in
            self?.isDraggingTab = true
            self?.onDragTabBegan?(wsIndex, tabIndex)
        }
        clickCard.onDragMoved = { [weak self] point in
            self?.onDragTabMoved?(wsIndex, tabIndex, point)
        }
        clickCard.onDragEnded = { [weak self] point in
            self?.onDragTabEnded?(wsIndex, tabIndex, point)
            self?.isDraggingTab = false
            self?.setNeedsReload()
        }

        return clickCard
    }

    // MARK: - Split Pane Activity Card

    /// Compact activity view for a terminal pane within a split tab.
    /// No background chrome — just icon, title, status, and preview with indentation.
    private func makePaneActivityCard(
        terminal: TerminalSurface,
        isFocused: Bool,
        onClick: @escaping () -> Void
    ) -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true

        let programName = terminal.detectedProgram ?? "Terminal"
        let vPad: CGFloat = 4
        let leading: CGFloat = 14

        // ── Icon + title row ──
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let iconCfg = NSImage.SymbolConfiguration(pointSize: 10, weight: isFocused ? .semibold : .regular)
        iconView.image = NSImage(systemSymbolName: terminal.programIcon, accessibilityDescription: nil)?.withSymbolConfiguration(iconCfg)
        iconView.contentTintColor = isFocused ? NSColor.controlAccentColor : NSColor(white: 0.50, alpha: 1.0)
        card.addSubview(iconView)

        let titleLabel = NSTextField(labelWithString: programName)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 11, weight: isFocused ? .medium : .regular)
        titleLabel.textColor = isFocused ? NSColor(white: 0.85, alpha: 1.0) : NSColor(white: 0.50, alpha: 1.0)
        titleLabel.lineBreakMode = .byTruncatingTail
        card.addSubview(titleLabel)

        var constraints: [NSLayoutConstraint] = [
            iconView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: leading),
            iconView.topAnchor.constraint(equalTo: card.topAnchor, constant: vPad),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -8),
        ]

        var lastBottom = iconView.bottomAnchor
        let infoLeading: CGFloat = leading + 20  // align under title text

        // ── Claude Code status ──
        if terminal.detectedProgram == "Claude Code", let claudeState = terminal.claudeCodeState {
            let statusText: String
            let statusColor: NSColor

            switch claudeState {
            case .thinking:
                statusText = "Thinking..."
                statusColor = NSColor(red: 1.0, green: 0.8, blue: 0.4, alpha: 1.0)
            case .doneWithTask:
                statusText = "Done with task."
                statusColor = NSColor(red: 0.4, green: 0.8, blue: 0.4, alpha: 1.0)
            case .awaitingSelection:
                statusText = "Awaiting selection..."
                statusColor = NSColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 1.0)
            case .awaitingPermission:
                statusText = "Awaiting permission..."
                statusColor = NSColor(red: 1.0, green: 0.6, blue: 0.4, alpha: 1.0)
            }

            let statusLabel = NSTextField(labelWithString: statusText)
            statusLabel.translatesAutoresizingMaskIntoConstraints = false
            statusLabel.font = .systemFont(ofSize: 10, weight: .medium)
            statusLabel.textColor = statusColor
            statusLabel.lineBreakMode = .byTruncatingTail
            card.addSubview(statusLabel)

            constraints.append(contentsOf: [
                statusLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: infoLeading),
                statusLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
                statusLabel.topAnchor.constraint(equalTo: lastBottom, constant: 2),
            ])
            lastBottom = statusLabel.bottomAnchor
        }

        // ── Output preview (2 lines max) ──
        let rawPreview = terminal.lastNotification ?? terminal.outputPreview
        let preview = (terminal.activityState == .idle) ? nil : rawPreview
        if let preview, !preview.isEmpty {
            let previewLabel = NSTextField(labelWithString: preview)
            previewLabel.translatesAutoresizingMaskIntoConstraints = false
            previewLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            previewLabel.textColor = NSColor(white: 0.40, alpha: 1.0)
            previewLabel.lineBreakMode = .byTruncatingTail
            previewLabel.maximumNumberOfLines = 2
            previewLabel.cell?.wraps = true
            previewLabel.cell?.truncatesLastVisibleLine = true
            card.addSubview(previewLabel)

            constraints.append(contentsOf: [
                previewLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: infoLeading),
                previewLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
                previewLabel.topAnchor.constraint(equalTo: lastBottom, constant: 2),
            ])
            lastBottom = previewLabel.bottomAnchor
        }

        // ── Git branch + path ──
        let hasMeaningfulPath = terminal.shortPath != nil && terminal.shortPath != "~"
        if let branch = terminal.gitBranch ?? (hasMeaningfulPath ? terminal.shortPath : nil) {
            let infoLabel = NSTextField(labelWithString: branch)
            infoLabel.translatesAutoresizingMaskIntoConstraints = false
            infoLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            infoLabel.textColor = NSColor(white: 0.35, alpha: 1.0)
            infoLabel.lineBreakMode = .byTruncatingTail
            card.addSubview(infoLabel)

            constraints.append(contentsOf: [
                infoLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: infoLeading),
                infoLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
                infoLabel.topAnchor.constraint(equalTo: lastBottom, constant: 2),
            ])
            lastBottom = infoLabel.bottomAnchor
        }

        // Pin bottom
        constraints.append(lastBottom.constraint(equalTo: card.bottomAnchor, constant: -vPad))
        NSLayoutConstraint.activate(constraints)

        // ── Interaction ──
        let clickCard = ClickableCardView(wrapping: card)
        clickCard.translatesAutoresizingMaskIntoConstraints = false
        clickCard.onClick = onClick

        return clickCard
    }

    @objc private func closeTabButtonTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              id.hasPrefix("closeTab-") else { return }
        let parts = id.replacingOccurrences(of: "closeTab-", with: "").split(separator: "-")
        guard parts.count == 2,
              let wsIndex = Int(parts[0]),
              let tabIndex = Int(parts[1]),
              wsIndex < workspaceManager.workspaces.count else { return }
        let ws = workspaceManager.workspaces[wsIndex]
        ws.closeTab(tabIndex)
        if ws.tabs.isEmpty { workspaceManager.removeWorkspace(at: wsIndex) }
        reloadWorkspaces()
    }

    // MARK: - New Tab Helpers

    private func openDirectoryForProject(workspace: Workspace, wsIndex: Int) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a directory to open as a project"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.workspaceManager.switchTo(index: wsIndex)
            workspace.addProjectRoot(path: url.path)
            WelcomeView.addRecentProject(url.path)
            self?.reloadWorkspaces()
            self?.notifyTabsChanged()
        }
    }

    private func openFileForEditor(workspace: Workspace) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a file to open in the editor"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try workspace.addEditorTab(path: url.path)
                self?.reloadWorkspaces()
                self?.notifyTabsChanged()
            } catch {
                NSLog("Failed to open file: \(error)")
            }
        }
    }

    private func notifyTabsChanged() {
        workspaceManager.activeWorkspace?.onTabsChanged?()
    }

    // MARK: - Expand/Collapse

    private func toggleExpand(_ id: UUID) {
        if expandedWorkspaces.contains(id) { expandedWorkspaces.remove(id) }
        else { expandedWorkspaces.insert(id) }
        reloadWorkspaces()
    }

    private func toggleNewTabReveal(_ id: UUID) {
        if revealedNewTab.contains(id) { revealedNewTab.remove(id) }
        else { revealedNewTab.insert(id) }
        reloadWorkspaces()
    }

    // MARK: - Rename

    private func startRenameWorkspace(at index: Int) {
        guard index < workspaceManager.workspaces.count else { return }
        showRenameAlert(currentName: workspaceManager.workspaces[index].name, title: "Rename Workspace") { [weak self] name in
            self?.workspaceManager.renameWorkspace(at: index, to: name)
            self?.reloadWorkspaces()
        }
    }

    private func startRenameTab(workspace: Workspace, tabIndex: Int) {
        guard tabIndex < workspace.tabs.count else { return }
        showRenameAlert(currentName: workspace.tabs[tabIndex].title, title: "Rename Tab") { [weak self] name in
            workspace.renameTab(tabIndex, to: name)
            self?.reloadWorkspaces()
        }
    }

    private func showRenameAlert(currentName: String, title: String, completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = currentName
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { completion(name) }
        }
    }

    // MARK: - Context Menus

    private func showWorkspaceContextMenu(at index: Int, event: NSEvent) {
        let menu = NSMenu()
        let rename = NSMenuItem(title: "Rename Workspace", action: #selector(ctxRenameWorkspace(_:)), keyEquivalent: "")
        rename.target = self; rename.representedObject = index; menu.addItem(rename)

        // Color submenu
        let colorItem = NSMenuItem(title: "Change Color", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        for color in WorkspaceColor.allCases {
            let item = NSMenuItem(title: color.displayName, action: #selector(ctxChangeColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ["index": index, "color": color.rawValue] as [String: Any]
            // Show a checkmark for the current color
            if index < workspaceManager.workspaces.count && workspaceManager.workspaces[index].color == color {
                item.state = .on
            }
            colorMenu.addItem(item)
        }
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)

        menu.addItem(NSMenuItem.separator())
        let delete = NSMenuItem(title: "Delete Workspace", action: #selector(ctxDeleteWorkspace(_:)), keyEquivalent: "")
        delete.target = self; delete.representedObject = index; menu.addItem(delete)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func showTabContextMenu(workspace: Workspace, wsIndex: Int, tabIndex: Int, event: NSEvent) {
        let menu = NSMenu()
        let rename = NSMenuItem(title: "Rename Tab", action: #selector(ctxRenameTab(_:)), keyEquivalent: "")
        rename.target = self; rename.representedObject = ["workspace": workspace, "tabIndex": tabIndex] as [String: Any]; menu.addItem(rename)
        let isPinned = (tabIndex >= 0 && tabIndex < workspace.tabs.count) ? workspace.tabs[tabIndex].isPinned : false
        let pin = NSMenuItem(title: isPinned ? "Unpin Tab" : "Pin Tab", action: #selector(ctxTogglePinTab(_:)), keyEquivalent: "")
        pin.target = self; pin.representedObject = ["workspace": workspace, "tabIndex": tabIndex] as [String: Any]; menu.addItem(pin)
        menu.addItem(NSMenuItem.separator())
        let close = NSMenuItem(title: "Close Tab", action: #selector(ctxCloseTab(_:)), keyEquivalent: "")
        close.target = self; close.representedObject = ["workspace": workspace, "wsIndex": wsIndex, "tabIndex": tabIndex] as [String: Any]; menu.addItem(close)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func ctxRenameWorkspace(_ sender: NSMenuItem) {
        guard let i = sender.representedObject as? Int else { return }
        startRenameWorkspace(at: i)
    }
    @objc private func ctxDeleteWorkspace(_ sender: NSMenuItem) {
        guard let i = sender.representedObject as? Int else { return }
        workspaceManager.removeWorkspace(at: i); reloadWorkspaces()
    }
    @objc private func ctxChangeColor(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let index = info["index"] as? Int,
              let rawColor = info["color"] as? String,
              let color = WorkspaceColor(rawValue: rawColor),
              index < workspaceManager.workspaces.count else { return }
        workspaceManager.workspaces[index].color = color
        reloadWorkspaces()
    }
    @objc private func ctxRenameTab(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let ws = info["workspace"] as? Workspace, let ti = info["tabIndex"] as? Int else { return }
        startRenameTab(workspace: ws, tabIndex: ti)
    }
    @objc private func ctxCloseTab(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let ws = info["workspace"] as? Workspace, let wsi = info["wsIndex"] as? Int, let ti = info["tabIndex"] as? Int else { return }
        ws.closeTab(ti)
        if ws.tabs.isEmpty { workspaceManager.removeWorkspace(at: wsi) }
        reloadWorkspaces()
    }

    private func handleWorkspaceDrag(from index: Int, delta: CGFloat) {
        if delta < -20 && index > 0 {
            workspaceManager.moveWorkspace(from: index, to: index - 1)
            persistSession()
            reloadWorkspaces()
        } else if delta > 20 && index < workspaceManager.workspaces.count - 1 {
            workspaceManager.moveWorkspace(from: index, to: index + 1)
            persistSession()
            reloadWorkspaces()
        }
    }

    /// Handle vertical drag-reorder of a sidebar tab row within its workspace.
    /// Pinned tabs may only swap with other pinned tabs; unpinned only with unpinned.
    private func handleTabDrag(workspace: Workspace, from index: Int, delta: CGFloat) {
        guard index >= 0, index < workspace.tabs.count else { return }
        let isPinned = workspace.tabs[index].isPinned
        let targetIndex: Int
        if delta < -20 {
            targetIndex = index - 1
        } else if delta > 20 {
            targetIndex = index + 1
        } else {
            return
        }
        guard targetIndex >= 0, targetIndex < workspace.tabs.count else { return }
        // Don't cross the pin/unpin boundary
        guard workspace.tabs[targetIndex].isPinned == isPinned else { return }
        workspace.moveTab(from: index, to: targetIndex)
        persistSession()
        reloadWorkspaces()
    }

    private func persistSession() {
        SessionState.shared.saveWorkspaces(
            workspaceManager.workspaces,
            activeIndex: workspaceManager.activeWorkspaceIndex
        )
    }

    @objc private func ctxTogglePinTab(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let ws = info["workspace"] as? Workspace,
              let ti = info["tabIndex"] as? Int,
              ti >= 0, ti < ws.tabs.count else { return }
        ws.setTabPinned(ti, pinned: !ws.tabs[ti].isPinned)
        persistSession()
        reloadWorkspaces()
    }
}

// MARK: - NSPopoverDelegate

extension SidebarView: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        sessionsRefreshTimer?.invalidate()
        sessionsRefreshTimer = nil
        sessionsPopover = nil
        sessionsBtn.contentTintColor = ClomeMacColor.textSecondary
    }
}

// MARK: - MultiRootExplorerDelegate

extension SidebarView: MultiRootExplorerDelegate {
    func multiRootExplorer(_ explorer: MultiRootExplorerView, didSelectFile path: String) {
        guard let workspace = workspaceManager.activeWorkspace else { return }
        workspace.openFileAsTab(path)
    }

    func multiRootExplorer(_ explorer: MultiRootExplorerView, didDoubleClickFile path: String) {
        guard let workspace = workspaceManager.activeWorkspace else { return }
        workspace.openFileAsTab(path)
    }

    func multiRootExplorer(_ explorer: MultiRootExplorerView, didRequestAddRoot sender: Any?) {
        guard let workspace = workspaceManager.activeWorkspace else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to add to workspace"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            workspace.addProjectRoot(path: url.path)
            WelcomeView.addRecentProject(url.path)
            self?.reloadWorkspaces()
            self?.updateSourceControl()
        }
    }

    /// Update the source control section with current git status.
    func updateSourceControl() {
        guard let workspace = workspaceManager.activeWorkspace else { return }
        sourceControlSection?.update(roots: workspace.projectRoots)
    }

    func multiRootExplorer(_ explorer: MultiRootExplorerView, didRequestRemoveRoot root: ProjectRoot) {
        guard let workspace = workspaceManager.activeWorkspace else { return }
        workspace.removeProjectRoot(root)
        reloadWorkspaces()
    }
}

// MARK: - Clickable Card View (wraps a card view, forwards clicks without eating button clicks)

/// Borderless icon button for the sidebar footer. Paints a subtle hover fill
/// (≈ 6% white) and a slightly darker pressed fill, matching the affordance
/// AppKit gives system source-list status buttons.
class FooterIconButton: NSButton {
    private var isHovered = false
    private var isPressed = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; refreshFill() }
    override func mouseExited(with event: NSEvent)  { isHovered = false; refreshFill() }

    override func mouseDown(with event: NSEvent) {
        isPressed = true; refreshFill()
        super.mouseDown(with: event)
        isPressed = false; refreshFill()
    }

    private func refreshFill() {
        let fill: NSColor
        if isPressed {
            fill = ClomeMacColor.buttonSurfacePressed
        } else if isHovered {
            fill = ClomeMacColor.hoverFill
        } else {
            fill = NSColor.clear
        }
        layer?.backgroundColor = fill.cgColor
    }
}

class ClickableCardView: NSView {
    var onClick: (() -> Void)?
    var onDragBegan: ((NSPoint) -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    private var dragStartPoint: NSPoint = .zero
    private var isDragging = false
    private var hitButton = false  // true if mouseDown landed on a button

    init(wrapping inner: NSView) {
        super.init(frame: .zero)
        inner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: trailingAnchor),
            inner.topAnchor.constraint(equalTo: topAnchor),
            inner.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        hitButton = findButton(at: loc) != nil
        if hitButton {
            super.mouseDown(with: event)
            return
        }
        dragStartPoint = event.locationInWindow
        isDragging = false
        subviews.first?.layer?.opacity = 0.8
    }

    override func mouseDragged(with event: NSEvent) {
        if hitButton { return }
        guard onDragBegan != nil else { return }
        let dx = abs(event.locationInWindow.x - dragStartPoint.x)
        // 20px threshold — same as SidebarRow, avoids accidental drags in a vertical list
        if dx > 20 {
            if !isDragging {
                isDragging = true
                subviews.first?.layer?.opacity = 0.5
                onDragBegan?(event.locationInWindow)
            }
            onDragMoved?(event.locationInWindow)
        }
    }

    override func mouseUp(with event: NSEvent) {
        subviews.first?.layer?.opacity = 1.0
        if isDragging {
            isDragging = false
            onDragEnded?(event.locationInWindow)
            return
        }
        if hitButton {
            hitButton = false
            super.mouseUp(with: event)
            return
        }
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) {
            onClick?()
        }
    }

    private func findButton(at point: NSPoint) -> NSButton? {
        func search(in view: NSView, point: NSPoint) -> NSButton? {
            for sub in view.subviews {
                let local = sub.convert(point, from: self)
                if sub is NSButton && sub.bounds.contains(local) {
                    return sub as? NSButton
                }
                if let found = search(in: sub, point: point) {
                    return found
                }
            }
            return nil
        }
        return search(in: self, point: point)
    }
}

// MARK: - New Tab Card

class NewTabCard: NSView {
    var onClick: (() -> Void)?

    init(icon: String, label: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = ClomeMacColor.buttonSurface.cgColor
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let iconCfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: label)?.withSymbolConfiguration(iconCfg)
        iconView.contentTintColor = ClomeMacColor.textPrimary
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        let titleLabel = NSTextField(labelWithString: label)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        titleLabel.textColor = ClomeMacColor.textPrimary
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 2),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = ClomeMacColor.buttonSurfacePressed.cgColor
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = ClomeMacColor.buttonSurfaceHover.cgColor
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { onClick?() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = ClomeMacColor.buttonSurfaceHover.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = ClomeMacColor.buttonSurface.cgColor
    }
}

// MARK: - Generic Sidebar Row

class SidebarRow: NSView {
    var onClick: ((NSPoint) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onDragReorder: ((CGFloat) -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var onDragBegan: ((NSPoint) -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?

    override var allowsVibrancy: Bool { bgActive != nil ? false : super.allowsVibrancy }

    var bgActive: NSColor? {
        didSet {
            layer?.backgroundColor = (bgActive ?? NSColor.clear).cgColor
        }
    }
    var bgHover: NSColor?
    var cornerRadius: CGFloat = 6 { didSet { layer?.cornerRadius = cornerRadius } }
    var borderColor: NSColor? {
        didSet {
            layer?.borderColor = borderColor?.cgColor ?? NSColor.clear.cgColor
            layer?.borderWidth = borderColor != nil ? 1.0 : 0.0
        }
    }
    var showAccentBar: Bool = false {
        didSet {
            if showAccentBar {
                if accentBar == nil {
                    let bar = NSView()
                    bar.translatesAutoresizingMaskIntoConstraints = false
                    bar.wantsLayer = true
                    bar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                    bar.layer?.cornerRadius = 1
                    addSubview(bar)
                    NSLayoutConstraint.activate([
                        bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
                        bar.centerYAnchor.constraint(equalTo: centerYAnchor),
                        bar.widthAnchor.constraint(equalToConstant: 2),
                        bar.heightAnchor.constraint(equalToConstant: 16),
                    ])
                    accentBar = bar
                }
                accentBar?.isHidden = false
            } else {
                accentBar?.isHidden = true
            }
        }
    }
    private var accentBar: NSView?

    private let rowHeight: CGFloat
    private var dragStartY: CGFloat = 0
    private var dragStartPoint: NSPoint = .zero
    private var isDragToSplit = false
    private var mouseDownConsumed = false

    init(height: CGFloat) {
        self.rowHeight = height
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ builder: (SidebarRow) -> Void) { builder(self) }

    func addSub(_ view: NSView, leading: CGFloat? = nil, trailing: CGFloat? = nil, centerY: Bool = false, width: CGFloat? = nil, height: CGFloat? = nil, trailingOffset: CGFloat? = nil) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        if let l = leading {
            let c = view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: l)
            c.priority = .defaultHigh
            c.isActive = true
        }
        if let t = trailing {
            let c = view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -t)
            c.priority = .defaultHigh
            c.isActive = true
        }
        if centerY { view.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true }
        if let w = width { view.widthAnchor.constraint(equalToConstant: w).isActive = true }
        if let h = height { view.heightAnchor.constraint(equalToConstant: h).isActive = true }
        if let to = trailingOffset {
            let c = view.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -to)
            c.priority = .defaultHigh
            c.isActive = true
        }
    }

    func pinToStack(_ stack: NSStackView) {
        let lead = leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 6)
        lead.priority = .defaultHigh
        lead.isActive = true
        let trail = trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -6)
        trail.priority = .defaultHigh
        trail.isActive = true
    }

    override func mouseDown(with event: NSEvent) {
        dragStartY = event.locationInWindow.y
        dragStartPoint = event.locationInWindow
        isDragToSplit = false
        mouseDownConsumed = false

        if event.clickCount == 2 { mouseDownConsumed = true; onDoubleClick?(); return }

        // Defer onClick to mouseUp if drag callbacks are set (to avoid selecting while dragging)
        if onDragBegan == nil {
            mouseDownConsumed = true
            onClick?(convert(event.locationInWindow, from: nil))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if mouseDownConsumed { return }

        let dx = event.locationInWindow.x - dragStartPoint.x
        let dy = event.locationInWindow.y - dragStartY

        // Drag-to-split: require 20px horizontal movement (sidebar is vertical, avoid accidental drags)
        if onDragBegan != nil && abs(dx) > 20 {
            if !isDragToSplit {
                isDragToSplit = true
                layer?.opacity = 0.5
                onDragBegan?(event.locationInWindow)
            }
            onDragMoved?(event.locationInWindow)
            return
        }

        // Vertical drag → reorder workspaces
        if abs(dy) > 8 { onDragReorder?(dy); dragStartY = event.locationInWindow.y }
    }

    override func mouseUp(with event: NSEvent) {
        if isDragToSplit {
            layer?.opacity = 1.0
            isDragToSplit = false
            onDragEnded?(event.locationInWindow)
        } else if !mouseDownConsumed && onDragBegan != nil {
            // Deferred click (when drag handlers are set but no drag occurred)
            onClick?(convert(event.locationInWindow, from: nil))
        }
        mouseDownConsumed = false
    }

    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        if bgActive == nil, let h = bgHover { layer?.backgroundColor = h.cgColor }
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        if bgActive == nil { layer?.backgroundColor = NSColor.clear.cgColor }
        onHoverChange?(false)
    }
}

// MARK: - Explorer Resize Handle

class ExplorerResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?
    private var lastY: CGFloat = 0
    private var isDragging = false
    private let indicator = NSView()

    override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        wantsLayer = true

        // Small centered pill indicator
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = NSColor.clear.cgColor
        indicator.layer?.cornerRadius = 1.5
        addSubview(indicator)

        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 32),
            indicator.heightAnchor.constraint(equalToConstant: 3),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            indicator.animator().layer?.backgroundColor = ClomeMacColor.borderStrong.cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            indicator.animator().layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        lastY = event.locationInWindow.y
        isDragging = true
        onDragBegan?()
        indicator.layer?.backgroundColor = ClomeMacColor.hoverFill.cgColor
    }

    override func mouseDragged(with event: NSEvent) {
        let currentY = event.locationInWindow.y
        let delta = lastY - currentY  // dragging down = positive delta = taller
        lastY = currentY
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        onDragEnded?()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            indicator.animator().layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

// MARK: - Opaque Card View (opts out of NSVisualEffectView vibrancy)

class OpaqueCardView: NSView {
    override var allowsVibrancy: Bool { false }
}

// MARK: - Flipped Clip View (pins content to top)

class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

private struct RemotePopoverContent: View {
    let connectedDeviceNames: [String]
    let pairedDeviceCount: Int
    let currentPairingCode: String?
    let isPairingMode: Bool
    let cloudStatusSummary: String
    let isCloudHostingEnabled: Bool
    let onStartPairing: () -> Void
    let onStopPairing: () -> Void
    let onDisconnectAll: () -> Void
    let onResetTrust: () -> Void
    let onToggleCloudHosting: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(elevatedSurface)
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Remote Center")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(textPrimary)
                    Text(statusText)
                        .font(.system(size: 12))
                        .foregroundStyle(textSecondary)
                }

                Spacer(minLength: 8)

                Text(statusBadge)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusBadgeColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(statusBadgeColor.opacity(0.14), in: Capsule())
            }

            if let currentPairingCode, isPairingMode {
                remoteCard {
                    VStack(alignment: .leading, spacing: 8) {
                        label("Pairing Code")
                        Text(currentPairingCode)
                            .font(.system(size: 32, weight: .bold, design: .monospaced))
                            .foregroundStyle(textPrimary)
                        Text("Open Clome Flow on iPhone and enter this code.")
                            .font(.system(size: 12))
                            .foregroundStyle(textSecondary)
                    }
                }
            }

            HStack(spacing: 10) {
                remoteStat(label: "Connected", value: "\(connectedDeviceNames.count)")
                remoteStat(label: "Trusted", value: "\(pairedDeviceCount)")
            }

            if !connectedDeviceNames.isEmpty {
                remoteCard {
                    VStack(alignment: .leading, spacing: 10) {
                        label("Connected Devices")
                        ForEach(connectedDeviceNames, id: \.self) { device in
                            HStack(spacing: 10) {
                                Image(systemName: "iphone")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(accent)
                                Text(device)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(textPrimary)
                                Spacer()
                            }
                        }
                    }
                }
            }

            remoteCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        label("Remote Anywhere")
                        Spacer()
                        Text(isCloudHostingEnabled ? "On" : "Off")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isCloudHostingEnabled ? success : textTertiary)
                    }
                    Text(cloudStatusSummary)
                        .font(.system(size: 12))
                        .foregroundStyle(textSecondary)
                }
            }

            VStack(spacing: 8) {
                actionButton(
                    title: isPairingMode ? "Refresh Pairing Code" : "Start Pairing",
                    systemImage: "link.badge.plus",
                    tint: accent,
                    isPrimary: true,
                    action: onStartPairing
                )

                if isPairingMode {
                    actionButton(
                        title: "Stop Pairing",
                        systemImage: "xmark",
                        tint: textSecondary,
                        action: onStopPairing
                    )
                }

                actionButton(
                    title: isCloudHostingEnabled ? "Pause Remote Anywhere" : "Enable Remote Anywhere",
                    systemImage: isCloudHostingEnabled ? "pause.circle" : "bolt.horizontal.circle",
                    tint: textSecondary,
                    action: { onToggleCloudHosting(!isCloudHostingEnabled) }
                )

                actionButton(
                    title: "Disconnect All Clients",
                    systemImage: "iphone.slash",
                    tint: warning,
                    action: onDisconnectAll
                )

                actionButton(
                    title: "Reset Trusted Devices",
                    systemImage: "trash",
                    tint: error,
                    action: onResetTrust
                )
            }
        }
        .padding(18)
        .frame(width: 336, alignment: .leading)
        .background(windowBackground)
    }

    private var statusText: String {
        if !connectedDeviceNames.isEmpty {
            return connectedDeviceNames.joined(separator: ", ")
        }
        if isPairingMode {
            return "Ready to pair a nearby iPhone"
        }
        return "No active iPhone session"
    }

    private var statusBadge: String {
        if !connectedDeviceNames.isEmpty { return "Connected" }
        if isPairingMode { return "Pairing" }
        return "Idle"
    }

    private var statusBadgeColor: Color {
        if !connectedDeviceNames.isEmpty { return success }
        if isPairingMode { return accent }
        return textTertiary
    }

    private func remoteStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            self.label(label)
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(elevatedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(border, lineWidth: 1)
        )
    }

    private func actionButton(
        title: String,
        systemImage: String,
        tint: Color,
        isPrimary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(isPrimary ? textOnAccent : tint)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isPrimary ? tint : elevatedSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isPrimary ? tint.opacity(0.18) : border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func remoteCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(border, lineWidth: 1)
            )
    }

    private func label(_ value: String) -> some View {
        Text(value.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.4)
            .foregroundStyle(textTertiary)
    }

    private var windowBackground: Color { Color(nsColor: ClomeMacColor.windowBackground) }
    private var surface: Color { Color(nsColor: ClomeMacColor.chromeSurface) }
    private var elevatedSurface: Color { Color(nsColor: ClomeMacColor.elevatedSurface) }
    private var border: Color { Color(nsColor: ClomeMacColor.border) }
    private var textPrimary: Color { Color(nsColor: ClomeMacColor.textPrimary) }
    private var textSecondary: Color { Color(nsColor: ClomeMacColor.textSecondary) }
    private var textTertiary: Color { Color(nsColor: ClomeMacColor.textTertiary) }
    private var accent: Color { Color(nsColor: ClomeMacColor.accent) }
    private var success: Color { Color(nsColor: ClomeMacColor.success) }
    private var warning: Color { Color(nsColor: ClomeMacColor.warning) }
    private var error: Color { Color(nsColor: ClomeMacColor.error) }
    private var textOnAccent: Color { Color.white }
}
