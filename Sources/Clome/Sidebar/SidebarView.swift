import AppKit

/// Zen Browser-inspired sidebar with workspaces and tab list.
class SidebarView: NSView {
    private let workspaceManager: WorkspaceManager
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()

    private let bgColor = NSColor.clear

    /// File shelf
    private var bottomBar: NSView!
    private var scrollViewBottomConstraint: NSLayoutConstraint!
    private var fileShelfView: FileShelfView?
    private var isShelfVisible = false
    private var shelfBtn: NSButton!

    /// Which workspaces are expanded
    private var expandedWorkspaces: Set<UUID> = []

    /// Which workspaces have the new-tab cards revealed
    private var revealedNewTab: Set<UUID> = []

    /// User-resizable explorer height
    private var explorerHeight: CGFloat = 220

    /// Stored height constraint for the file explorer (to avoid accumulation)
    private var explorerHeightConstraint: NSLayoutConstraint?

    /// Whether the explorer resize handle is being dragged
    private var isExplorerResizing: Bool = false

    /// Debounce timer for activity updates
    private var activityDebounceTimer: Timer?

    /// Whether auto-expand has run on first load
    private var hasAutoExpanded = false

    /// Coalescing flag for setNeedsReload()
    private var reloadScheduled = false

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
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = bgColor.cgColor

        // ──── Top navigation bar (traffic light space + sidebar toggle) ────
        let navBar = NSView()
        navBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(navBar)

        // Sidebar toggle button (next to traffic lights)
        let sidebarBtn = makeNavButton(symbol: "sidebar.left", action: #selector(sidebarToggleTapped))
        navBar.addSubview(sidebarBtn)

        // Notification bell button
        let bellBtn = makeNavButton(symbol: "bell", action: #selector(bellTapped))
        navBar.addSubview(bellBtn)

        // New tab plus button
        let plusBtn = makeNavButton(symbol: "plus", action: #selector(plusTapped))
        navBar.addSubview(plusBtn)

        // ──── Scrollable workspace/tab list ────
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        stackView.orientation = .vertical
        stackView.spacing = 4
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
        bottomBar.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.03).cgColor
        addSubview(bottomBar)

        // Shelf toggle button (smaller icon)
        shelfBtn = makeNavButton(symbol: "tray.and.arrow.down.fill", action: #selector(shelfToggleTapped))
        let smallCfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        shelfBtn.image = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: nil)?.withSymbolConfiguration(smallCfg)
        bottomBar.addSubview(shelfBtn)

        // ──── Layout ────
        scrollViewBottomConstraint = scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor)

        NSLayoutConstraint.activate([
            // Nav bar
            navBar.topAnchor.constraint(equalTo: topAnchor),
            navBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            navBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            navBar.heightAnchor.constraint(equalToConstant: 44),

            // Sidebar toggle button (aligned with traffic lights center)
            sidebarBtn.leadingAnchor.constraint(equalTo: navBar.leadingAnchor, constant: 76),
            sidebarBtn.topAnchor.constraint(equalTo: navBar.topAnchor, constant: 3),
            sidebarBtn.widthAnchor.constraint(equalToConstant: 28),
            sidebarBtn.heightAnchor.constraint(equalToConstant: 28),

            // Bell button
            bellBtn.leadingAnchor.constraint(equalTo: sidebarBtn.trailingAnchor, constant: 8),
            bellBtn.centerYAnchor.constraint(equalTo: sidebarBtn.centerYAnchor),
            bellBtn.widthAnchor.constraint(equalToConstant: 28),
            bellBtn.heightAnchor.constraint(equalToConstant: 28),

            // Plus button
            plusBtn.leadingAnchor.constraint(equalTo: bellBtn.trailingAnchor, constant: 8),
            plusBtn.centerYAnchor.constraint(equalTo: sidebarBtn.centerYAnchor),
            plusBtn.widthAnchor.constraint(equalToConstant: 28),
            plusBtn.heightAnchor.constraint(equalToConstant: 28),

            // Scrollable list
            scrollView.topAnchor.constraint(equalTo: navBar.bottomAnchor, constant: 2),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollViewBottomConstraint,

            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),

            // Bottom bar
            bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 36),

            // Shelf button on the left of bottom bar
            shelfBtn.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 8),
            shelfBtn.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            shelfBtn.widthAnchor.constraint(equalToConstant: 28),
            shelfBtn.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func makeNavButton(symbol: String, action: Selector?) -> NSButton {
        let btn = NSButton()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.bezelStyle = .texturedRounded
        btn.isBordered = false
        btn.title = ""
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        btn.contentTintColor = NSColor(white: 1.0, alpha: 0.9)
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
    }

    @objc private func onNotificationChange(_ n: Notification) {
        if n.name == .terminalActivityChanged {
            // Debounce activity updates to avoid sidebar flickering
            activityDebounceTimer?.invalidate()
            activityDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                self?.reloadWorkspaces()
            }
        } else {
            reloadWorkspaces()
        }
    }
    @objc private func sidebarToggleTapped() { onToggleSidebar?() }
    @objc private func bellTapped() {
        // Future: show notifications panel
    }
    @objc private func shelfToggleTapped() {
        if isShelfVisible {
            hideFileShelf()
        } else {
            showFileShelf()
        }
    }

    private func showFileShelf() {
        guard fileShelfView == nil else { return }
        isShelfVisible = true
        shelfBtn.contentTintColor = NSColor.controlAccentColor

        let shelf = FileShelfView()
        shelf.translatesAutoresizingMaskIntoConstraints = false
        shelf.alphaValue = 0
        addSubview(shelf)
        fileShelfView = shelf

        // Swap scroll view bottom constraint
        scrollViewBottomConstraint.isActive = false
        scrollViewBottomConstraint = scrollView.bottomAnchor.constraint(equalTo: shelf.topAnchor)
        scrollViewBottomConstraint.isActive = true

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
        shelfBtn.contentTintColor = NSColor(white: 1.0, alpha: 0.9)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            shelf.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            shelf.cleanup()
            shelf.removeFromSuperview()
            self.fileShelfView = nil
            self.scrollViewBottomConstraint.isActive = false
            self.scrollViewBottomConstraint = self.scrollView.bottomAnchor.constraint(equalTo: self.bottomBar.topAnchor)
            self.scrollViewBottomConstraint.isActive = true
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
            guard let self else { return }
            self.reloadScheduled = false
            self.reloadWorkspaces()
        }
    }

    // MARK: - Reload

    private var needsReloadAfterResize = false

    func reloadWorkspaces() {
        // Cancel any pending coalesced reload to avoid double-reload
        reloadScheduled = false

        // Don't rebuild views while user is dragging the explorer resize handle
        if isExplorerResizing {
            needsReloadAfterResize = true
            return
        }

        // Auto-expand all workspaces on first load only
        if !hasAutoExpanded {
            hasAutoExpanded = true
            for ws in workspaceManager.workspaces {
                expandedWorkspaces.insert(ws.id)
            }
        }
        stackView.arrangedSubviews.forEach { stackView.removeArrangedSubview($0); $0.removeFromSuperview() }

        for (wsIndex, workspace) in workspaceManager.workspaces.enumerated() {
            let isActive = wsIndex == workspaceManager.activeWorkspaceIndex
            let isExpanded = expandedWorkspaces.contains(workspace.id)
            let capturedWsIndex = wsIndex

            // ── Workspace group container (rounded background when active) ──
            let wsGroup = NSView()
            wsGroup.translatesAutoresizingMaskIntoConstraints = false
            wsGroup.wantsLayer = true
            wsGroup.layer?.cornerRadius = 8
            wsGroup.layer?.cornerCurve = .continuous
            wsGroup.layer?.backgroundColor = isActive ? NSColor(white: 1.0, alpha: 0.08).cgColor : NSColor.clear.cgColor

            let wsStack = NSStackView()
            wsStack.orientation = .vertical
            wsStack.spacing = 2
            wsStack.alignment = .leading
            wsStack.translatesAutoresizingMaskIntoConstraints = false
            wsGroup.addSubview(wsStack)

            NSLayoutConstraint.activate([
                wsStack.leadingAnchor.constraint(equalTo: wsGroup.leadingAnchor),
                wsStack.trailingAnchor.constraint(equalTo: wsGroup.trailingAnchor),
                wsStack.topAnchor.constraint(equalTo: wsGroup.topAnchor, constant: 4),
                wsStack.bottomAnchor.constraint(equalTo: wsGroup.bottomAnchor, constant: -4),
            ])

            // ── Workspace header ──
            let header = SidebarRow(height: 32)
            let plusIcon = NSImageView()
            header.configure { view in
                let tc = isActive ? NSColor(white: 0.92, alpha: 1.0) : NSColor(white: 0.55, alpha: 1.0)

                let folderIcon = NSImageView()
                let folderCfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                let folderName = isExpanded ? "folder.fill" : "folder"
                folderIcon.image = NSImage(systemSymbolName: folderName, accessibilityDescription: nil)?.withSymbolConfiguration(folderCfg)
                folderIcon.contentTintColor = isActive ? workspace.color.nsColor : workspace.color.nsColor.withAlphaComponent(0.6)
                folderIcon.imageScaling = .scaleProportionallyDown
                view.addSub(folderIcon, leading: 8, centerY: true, width: 18, height: 16)

                let title = NSTextField(labelWithString: workspace.name)
                title.font = .systemFont(ofSize: 12, weight: .semibold)
                title.textColor = tc
                title.lineBreakMode = .byTruncatingTail
                view.addSub(title, leading: 30, centerY: true, trailingOffset: 28)

                // Small "+" icon on the right, hidden until hover
                let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
                plusIcon.translatesAutoresizingMaskIntoConstraints = false
                plusIcon.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")?.withSymbolConfiguration(cfg)
                plusIcon.contentTintColor = NSColor(white: tc.whiteComponent, alpha: 0.5)
                plusIcon.imageScaling = .scaleProportionallyDown
                plusIcon.alphaValue = 0
                view.addSub(plusIcon, trailing: 6, centerY: true, width: 20, height: 20)
            }

            header.bgHover = isActive ? nil : NSColor(white: 1.0, alpha: 0.04)
            header.onHoverChange = { hovering in
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
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
            header.leadingAnchor.constraint(equalTo: wsStack.leadingAnchor, constant: 4).isActive = true
            header.trailingAnchor.constraint(equalTo: wsStack.trailingAnchor, constant: -4).isActive = true

            // ── Tab rows ──
            if isExpanded {
                for (tabIndex, tab) in workspace.tabs.enumerated() {
                    let isTabActive = isActive && tabIndex == workspace.activeTabIndex
                    let capturedTabIndex = tabIndex

                    // Check if this is a terminal tab with activity info
                    let terminal = tab.view as? TerminalSurface
                    let hasActivity = terminal != nil && (terminal?.detectedProgram != nil || terminal?.outputPreview != nil)

                    if hasActivity, let terminal {
                        // ── Rich terminal activity card ──
                        let card = makeTerminalActivityCard(
                            terminal: terminal,
                            isActive: isTabActive,
                            tab: tab,
                            wsIndex: capturedWsIndex,
                            tabIndex: capturedTabIndex,
                            workspace: workspace
                        )
                        wsStack.addArrangedSubview(card)
                        card.leadingAnchor.constraint(equalTo: wsStack.leadingAnchor, constant: 4).isActive = true
                        card.trailingAnchor.constraint(equalTo: wsStack.trailingAnchor, constant: -4).isActive = true
                    } else {
                        // ── Standard tab row ──
                        let tabRow = SidebarRow(height: 32)
                        let tabCloseBtn = NSButton()
                        tabRow.configure { view in
                            let tc = isTabActive ? NSColor(white: 0.95, alpha: 1.0) : NSColor(white: 0.50, alpha: 1.0)

                            let icon = NSImageView()
                            if let favicon = tab.favicon {
                                icon.image = favicon
                                icon.imageScaling = .scaleProportionallyDown
                            } else {
                                let iconCfg = NSImage.SymbolConfiguration(pointSize: 13, weight: isTabActive ? .semibold : .regular)
                                let iconName = (tab.view as? TerminalSurface)?.programIcon ?? tab.type.icon
                                icon.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?.withSymbolConfiguration(iconCfg)
                                icon.contentTintColor = isTabActive ? NSColor.controlAccentColor : tc
                                icon.imageScaling = .scaleProportionallyDown
                            }
                            view.addSub(icon, leading: 14, centerY: true, width: 16, height: 16)

                            // Show split description or plain title
                            let titleText = tab.isSplit ? tab.splitDescription : tab.title
                            let title = NSTextField(labelWithString: titleText)
                            title.font = .systemFont(ofSize: 11, weight: isTabActive ? .medium : .regular)
                            title.textColor = tc
                            title.lineBreakMode = .byTruncatingTail
                            view.addSub(title, leading: 36, centerY: true, trailingOffset: 26)

                            // Close button (hidden until hover)
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

                            // Terminal activity mini-indicator (for non-active terminal tabs)
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

                            // Split icon indicator
                            if tab.isSplit {
                                let splitIcon = NSImageView()
                                let sCfg = NSImage.SymbolConfiguration(pointSize: 8, weight: .medium)
                                splitIcon.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)?.withSymbolConfiguration(sCfg)
                                splitIcon.contentTintColor = NSColor.controlAccentColor.withAlphaComponent(0.6)
                                view.addSub(splitIcon, trailing: 26, centerY: true, width: 12, height: 12)
                            }
                        }

                        tabRow.bgActive = isTabActive ? NSColor.controlAccentColor.withAlphaComponent(0.12) : nil
                        tabRow.borderColor = isTabActive ? NSColor.controlAccentColor.withAlphaComponent(0.35) : nil
                        tabRow.bgHover = NSColor(white: 1.0, alpha: 0.06)
                        tabRow.cornerRadius = 6
                        tabRow.showAccentBar = isTabActive
                        tabRow.onHoverChange = { hovering in
                            NSAnimationContext.runAnimationGroup { ctx in
                                ctx.duration = 0.15
                                tabCloseBtn.animator().alphaValue = hovering ? 1.0 : 0.0
                            }
                        }

                        tabRow.onClick = { [weak self] _ in
                            self?.workspaceManager.switchTo(index: capturedWsIndex)
                            workspace.selectTab(capturedTabIndex)
                            self?.reloadWorkspaces()
                        }
                        tabRow.onDoubleClick = { [weak self] in
                            self?.startRenameTab(workspace: workspace, tabIndex: capturedTabIndex)
                        }
                        tabRow.onRightClick = { [weak self] event in
                            self?.showTabContextMenu(workspace: workspace, wsIndex: capturedWsIndex, tabIndex: capturedTabIndex, event: event)
                        }
                        tabRow.onDragBegan = { [weak self] point in
                            self?.onDragTabBegan?(capturedWsIndex, capturedTabIndex)
                        }
                        tabRow.onDragMoved = { [weak self] point in
                            self?.onDragTabMoved?(capturedWsIndex, capturedTabIndex, point)
                        }
                        tabRow.onDragEnded = { [weak self] point in
                            self?.onDragTabEnded?(capturedWsIndex, capturedTabIndex, point)
                        }

                        wsStack.addArrangedSubview(tabRow)
                        tabRow.leadingAnchor.constraint(equalTo: wsStack.leadingAnchor, constant: 4).isActive = true
                        tabRow.trailingAnchor.constraint(equalTo: wsStack.trailingAnchor, constant: -4).isActive = true
                    }

                    // ── Pane sub-rows for split tabs ──
                    if tab.isSplit && isTabActive {
                        for paneView in tab.splitContainer.allLeafViews {
                            let (paneIcon, paneTitle) = WorkspaceTab.paneLabel(for: paneView)
                            let isFocused = paneView === tab.focusedPane
                            let paneRow = SidebarRow(height: 26)
                            paneRow.configure { view in
                                let tc = isFocused ? NSColor(white: 0.8, alpha: 1.0) : NSColor(white: 0.45, alpha: 1.0)

                                let icon = NSImageView()
                                let iconCfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
                                icon.image = NSImage(systemSymbolName: paneIcon, accessibilityDescription: nil)?.withSymbolConfiguration(iconCfg)
                                icon.contentTintColor = tc
                                view.addSub(icon, leading: 30, centerY: true, width: 14, height: 14)

                                let title = NSTextField(labelWithString: paneTitle)
                                title.font = .systemFont(ofSize: 11)
                                title.textColor = tc
                                title.lineBreakMode = .byTruncatingTail
                                view.addSub(title, leading: 48, centerY: true, trailingOffset: 10)

                                if isFocused {
                                    let dot = NSView()
                                    dot.translatesAutoresizingMaskIntoConstraints = false
                                    dot.wantsLayer = true
                                    dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                                    dot.layer?.cornerRadius = 2
                                    view.addSubview(dot)
                                    NSLayoutConstraint.activate([
                                        dot.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
                                        dot.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                                        dot.widthAnchor.constraint(equalToConstant: 4),
                                        dot.heightAnchor.constraint(equalToConstant: 4),
                                    ])
                                }
                            }

                            paneRow.bgActive = isFocused ? NSColor(white: 1.0, alpha: 0.05) : nil
                            paneRow.bgHover = NSColor(white: 1.0, alpha: 0.03)
                            paneRow.cornerRadius = 6

                            let capturedPane = paneView
                            paneRow.onClick = { [weak self] _ in
                                self?.workspaceManager.switchTo(index: capturedWsIndex)
                                workspace.selectTab(capturedTabIndex)
                                tab.focusedPane = capturedPane
                                tab.splitContainer.focusedPane = capturedPane
                                if let terminal = capturedPane as? TerminalSurface {
                                    terminal.window?.makeFirstResponder(terminal)
                                }
                                self?.reloadWorkspaces()
                            }

                            wsStack.addArrangedSubview(paneRow)
                            paneRow.leadingAnchor.constraint(equalTo: wsStack.leadingAnchor, constant: 12).isActive = true
                            paneRow.trailingAnchor.constraint(equalTo: wsStack.trailingAnchor, constant: -4).isActive = true
                        }
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
                        wsStack.addArrangedSubview(dividerWrap)
                        NSLayoutConstraint.activate([
                            dividerWrap.leadingAnchor.constraint(equalTo: wsStack.leadingAnchor),
                            dividerWrap.trailingAnchor.constraint(equalTo: wsStack.trailingAnchor),
                            dividerWrap.heightAnchor.constraint(equalToConstant: 8),
                        ])

                        // File tree with fixed height from explorerHeight
                        let explorer = projectPanel.fileExplorer
                        explorer.translatesAutoresizingMaskIntoConstraints = false

                        // Deactivate any previous height constraint to avoid conflicts
                        if let old = self.explorerHeightConstraint {
                            old.isActive = false
                        }

                        wsStack.addArrangedSubview(explorer)
                        let heightConstraint = explorer.heightAnchor.constraint(equalToConstant: self.explorerHeight)
                        self.explorerHeightConstraint = heightConstraint
                        NSLayoutConstraint.activate([
                            explorer.leadingAnchor.constraint(equalTo: wsStack.leadingAnchor),
                            explorer.trailingAnchor.constraint(equalTo: wsStack.trailingAnchor),
                            heightConstraint,
                        ])

                        // Drag handle at the bottom edge of the explorer
                        let handle = ExplorerResizeHandle()
                        handle.translatesAutoresizingMaskIntoConstraints = false
                        handle.onDrag = { [weak self] delta in
                            guard let self else { return }
                            let newHeight = max(100, min(600, self.explorerHeight + delta))
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
                        wsStack.addArrangedSubview(handle)
                        NSLayoutConstraint.activate([
                            handle.leadingAnchor.constraint(equalTo: wsStack.leadingAnchor),
                            handle.trailingAnchor.constraint(equalTo: wsStack.trailingAnchor),
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
                        try? workspace.addEditorTab()
                        self?.revealedNewTab.remove(workspace.id)
                        self?.reloadWorkspaces()
                        self?.notifyTabsChanged()
                    }

                    cardStack.addArrangedSubview(terminalCard)
                    cardStack.addArrangedSubview(browserCard)
                    cardStack.addArrangedSubview(projectCard)
                    cardStack.addArrangedSubview(editorCard)

                    wsStack.addArrangedSubview(cardsContainer)
                    NSLayoutConstraint.activate([
                        cardsContainer.leadingAnchor.constraint(equalTo: wsStack.leadingAnchor, constant: 4),
                        cardsContainer.trailingAnchor.constraint(equalTo: wsStack.trailingAnchor, constant: -4),
                        cardsContainer.heightAnchor.constraint(equalToConstant: 52),

                        cardStack.leadingAnchor.constraint(equalTo: cardsContainer.leadingAnchor),
                        cardStack.trailingAnchor.constraint(equalTo: cardsContainer.trailingAnchor),
                        cardStack.topAnchor.constraint(equalTo: cardsContainer.topAnchor, constant: 6),
                        cardStack.bottomAnchor.constraint(equalTo: cardsContainer.bottomAnchor, constant: -6),
                    ])
                }

            }

            // Add workspace group to main stack
            stackView.addArrangedSubview(wsGroup)
            wsGroup.leadingAnchor.constraint(equalTo: stackView.leadingAnchor, constant: 4).isActive = true
            wsGroup.trailingAnchor.constraint(equalTo: stackView.trailingAnchor, constant: -4).isActive = true
        }
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
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.backgroundColor = isActive
            ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            : NSColor(white: 1.0, alpha: 0.08).cgColor
        card.layer?.cornerRadius = 8
        card.layer?.cornerCurve = .continuous
        if isActive {
            card.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
            card.layer?.borderWidth = 1.0
        }

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
        iconView.contentTintColor = isActive ? NSColor(white: 0.9, alpha: 1.0) : NSColor(white: 0.6, alpha: 1.0)
        card.addSubview(iconView)

        let titleLabel = NSTextField(labelWithString: programName)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = isActive ? NSColor(white: 0.95, alpha: 1.0) : NSColor(white: 0.7, alpha: 1.0)
        titleLabel.lineBreakMode = .byTruncatingTail
        card.addSubview(titleLabel)

        // Close button
        let closeBtn = NSButton()
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.bezelStyle = .texturedRounded
        closeBtn.isBordered = false
        closeBtn.title = ""
        let closeCfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        closeBtn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?.withSymbolConfiguration(closeCfg)
        closeBtn.contentTintColor = NSColor(white: 0.6, alpha: 1.0)
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
            statusLabel.textColor = statusColor
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
            previewLabel.textColor = NSColor(white: 0.55, alpha: 1.0)
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
            infoLabel.textColor = NSColor(white: 0.50, alpha: 1.0)
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
        clickCard.onClick = { [weak self] in
            self?.workspaceManager.switchTo(index: wsIndex)
            self?.workspaceManager.workspaces[wsIndex].selectTab(tabIndex)
            self?.reloadWorkspaces()
        }

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
            workspace.addProjectTab(directory: url.path)
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
            workspaceManager.moveWorkspace(from: index, to: index - 1); reloadWorkspaces()
        } else if delta > 20 && index < workspaceManager.workspaces.count - 1 {
            workspaceManager.moveWorkspace(from: index, to: index + 1); reloadWorkspaces()
        }
    }
}

// MARK: - Clickable Card View (wraps a card view, forwards clicks without eating button clicks)

class ClickableCardView: NSView {
    var onClick: (() -> Void)?

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

    override func mouseDown(with event: NSEvent) {
        // Check if click hit a button — if so, let it handle it
        let loc = convert(event.locationInWindow, from: nil)
        if hitTestButton(at: loc) != nil {
            super.mouseDown(with: event)
            return
        }
        // Visual feedback
        subviews.first?.layer?.opacity = 0.8
    }

    override func mouseUp(with event: NSEvent) {
        subviews.first?.layer?.opacity = 1.0
        let loc = convert(event.locationInWindow, from: nil)
        if hitTestButton(at: loc) != nil {
            super.mouseUp(with: event)
            return
        }
        if bounds.contains(loc) {
            onClick?()
        }
    }

    private func hitTestButton(at point: NSPoint) -> NSButton? {
        func findButton(in view: NSView, point: NSPoint) -> NSButton? {
            for sub in view.subviews {
                let local = sub.convert(point, from: self)
                if sub is NSButton && sub.bounds.contains(local) {
                    return sub as? NSButton
                }
                if let found = findButton(in: sub, point: point) {
                    return found
                }
            }
            return nil
        }
        return findButton(in: self, point: point)
    }
}

// MARK: - New Tab Card

class NewTabCard: NSView {
    var onClick: (() -> Void)?

    private static func sidebarIsLight() -> Bool {
        let s = AppearanceSettings.shared
        let c = s.sidebarColor.usingColorSpace(.sRGB) ?? s.sidebarColor
        let o = s.sidebarOpacity
        let base: CGFloat = 0.1
        let r = base * (1 - o) + c.redComponent * o
        let g = base * (1 - o) + c.greenComponent * o
        let b = base * (1 - o) + c.blueComponent * o
        let luminance = r * 0.299 + g * 0.587 + b * 0.114
        return luminance > 0.35
    }
    private static var fgWhite: CGFloat { sidebarIsLight() ? 0.0 : 1.0 }

    init(icon: String, label: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        let fg = Self.fgWhite
        layer?.backgroundColor = NSColor(white: fg, alpha: 0.10).cgColor
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let iconCfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: label)?.withSymbolConfiguration(iconCfg)
        iconView.contentTintColor = NSColor(white: fg, alpha: 0.85)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        let titleLabel = NSTextField(labelWithString: label)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        titleLabel.textColor = NSColor(white: fg, alpha: 0.80)
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
        let fg = Self.fgWhite
        layer?.backgroundColor = NSColor(white: fg, alpha: 0.20).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        let fg = Self.fgWhite
        layer?.backgroundColor = NSColor(white: fg, alpha: 0.15).cgColor
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { onClick?() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        let fg = Self.fgWhite
        layer?.backgroundColor = NSColor(white: fg, alpha: 0.15).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        let fg = Self.fgWhite
        layer?.backgroundColor = NSColor(white: fg, alpha: 0.10).cgColor
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

    var bgActive: NSColor? { didSet { layer?.backgroundColor = (bgActive ?? NSColor.clear).cgColor } }
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
        if let l = leading { view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: l).isActive = true }
        if let t = trailing { view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -t).isActive = true }
        if centerY { view.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true }
        if let w = width { view.widthAnchor.constraint(equalToConstant: w).isActive = true }
        if let h = height { view.heightAnchor.constraint(equalToConstant: h).isActive = true }
        if let to = trailingOffset { view.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -to).isActive = true }
    }

    func pinToStack(_ stack: NSStackView) {
        leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 6).isActive = true
        trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -6).isActive = true
    }

    override func mouseDown(with event: NSEvent) {
        dragStartY = event.locationInWindow.y
        dragStartPoint = event.locationInWindow
        isDragToSplit = false
        if event.clickCount == 2 { onDoubleClick?(); return }
        // Defer onClick to mouseUp if drag callbacks are set (to avoid selecting while dragging)
        if onDragBegan == nil {
            onClick?(convert(event.locationInWindow, from: nil))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let dx = event.locationInWindow.x - dragStartPoint.x
        let dy = event.locationInWindow.y - dragStartY

        // Horizontal drag → drag-to-split (if handler set)
        if onDragBegan != nil && abs(dx) > 6 {
            if !isDragToSplit {
                isDragToSplit = true
                layer?.opacity = 0.5
                onDragBegan?(event.locationInWindow)
            }
            onDragMoved?(event.locationInWindow)
            return
        }

        // Vertical drag → reorder
        if abs(dy) > 8 { onDragReorder?(dy); dragStartY = event.locationInWindow.y }
    }

    override func mouseUp(with event: NSEvent) {
        if isDragToSplit {
            layer?.opacity = 1.0
            isDragToSplit = false
            onDragEnded?(event.locationInWindow)
        } else if onDragBegan != nil {
            // Deferred click (when drag handlers are set)
            onClick?(convert(event.locationInWindow, from: nil))
        }
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
        indicator.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.0).cgColor
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
            indicator.animator().layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.15).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            indicator.animator().layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.0).cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        lastY = event.locationInWindow.y
        isDragging = true
        onDragBegan?()
        indicator.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.20).cgColor
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
            indicator.animator().layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.0).cgColor
        }
    }
}

// MARK: - Flipped Clip View (pins content to top)

class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
