import AppKit

// MARK: - Design Tokens (matching onboarding/sidebar palette)

private enum SB {
    static let void       = NSColor(red: 0.024, green: 0.024, blue: 0.039, alpha: 1.0)  // #06060A
    static let voidSoft   = NSColor(red: 0.047, green: 0.047, blue: 0.078, alpha: 1.0)
    static let surface    = NSColor(red: 0.063, green: 0.063, blue: 0.102, alpha: 1.0)
    static let border     = NSColor(red: 0.110, green: 0.110, blue: 0.157, alpha: 1.0)
    static let copper     = NSColor(red: 0.710, green: 0.380, blue: 0.247, alpha: 1.0)  // #B5613F
    static let copperLight = NSColor(red: 0.831, green: 0.518, blue: 0.369, alpha: 1.0) // #D4845E
    static let text       = NSColor(red: 0.941, green: 0.929, blue: 0.910, alpha: 1.0)  // #F0EDE8
    static let textDim    = NSColor(red: 0.941, green: 0.929, blue: 0.910, alpha: 0.60)
    static let textMuted  = NSColor(red: 0.941, green: 0.929, blue: 0.910, alpha: 0.30)
    static let green      = NSColor(red: 0.30, green: 0.75, blue: 0.45, alpha: 1.0)
    static let amber      = NSColor(red: 0.90, green: 0.75, blue: 0.30, alpha: 1.0)

    static let popoverWidth: CGFloat = 300
    static let hPad: CGFloat = 14
    static let rowHeight: CGFloat = 32
    static let sectionGap: CGFloat = 6
}

// MARK: - StatusBarController

@MainActor
class StatusBarController {
    private var statusItem: NSStatusItem
    private var popover: NSPopover
    private weak var window: ClomeWindow?
    private var popoverVC: StatusBarPopoverViewController

    init(window: ClomeWindow) {
        self.window = window
        self.statusItem = NSStatusBar.system.statusItem(withLength: 34)
        self.popoverVC = StatusBarPopoverViewController(window: window)
        self.popover = NSPopover()

        popover.contentViewController = popoverVC
        popover.behavior = .transient
        popover.animates = true

        setupButton()
        observeNotifications()
    }

    // MARK: - Setup

    private func setupButton() {
        guard let button = statusItem.button else { return }
        updateIcon(hasUnread: false)
        button.target = self
        button.action = #selector(statusBarClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func observeNotifications() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(onNotificationChange(_:)),
            name: .clomeNotificationCountChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(onActivityChange(_:)),
            name: .terminalActivityChanged, object: nil
        )
    }

    // MARK: - Icon

    private func updateIcon(hasUnread: Bool) {
        guard let button = statusItem.button else { return }
        let size = NSSize(width: 30, height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            // Draw the Clome wave logo from asset catalog
            if let logo = NSImage(named: "StatusBarIcon") {
                logo.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }

            if hasUnread {
                let d: CGFloat = 6
                let dotRect = NSRect(x: rect.maxX - d - 1, y: rect.maxY - d - 1, width: d, height: d)
                SB.copper.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            }
            return true
        }
        image.isTemplate = false
        button.image = image
    }

    // MARK: - Actions

    @objc private func statusBarClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSView) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popoverVC.refresh()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let show = NSMenuItem(title: "Show Clome", action: #selector(showWindow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        let ws = NSMenuItem(title: "New Workspace", action: #selector(newWorkspace), keyEquivalent: "")
        ws.target = self
        menu.addItem(ws)

        menu.addItem(NSMenuItem.separator())

        let issue = NSMenuItem(title: "Report an Issue\u{2026}", action: #selector(reportIssue), keyEquivalent: "")
        issue.target = self
        menu.addItem(issue)

        let settings = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit Clome", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.menu = nil
        }
    }

    @objc private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func newWorkspace() {
        window?.workspaceManager.addWorkspace()
        window?.sidebarView?.reloadWorkspaces()
        showWindow()
    }

    @objc private func reportIssue() {
        if let url = URL(string: "https://github.com/ranystephan/clome/issues/new?labels=bug&template=bug_report.md") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openSettings() {
        SettingsWindowController.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Notification Handlers

    @objc private func onNotificationChange(_ notification: Notification) {
        let hasUnread = NotificationSystem.shared.unreadCounts.values.contains { $0 > 0 }
        updateIcon(hasUnread: hasUnread)
        if popover.isShown { popoverVC.refresh() }
    }

    @objc private func onActivityChange(_ notification: Notification) {
        if popover.isShown { popoverVC.refresh() }
    }
}

// MARK: - Popover View Controller

@MainActor
class StatusBarPopoverViewController: NSViewController {
    private weak var window: ClomeWindow?
    private var contentStack: NSStackView!

    init(window: ClomeWindow) {
        self.window = window
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func loadView() {
        // Vibrancy host: dark ultra-thin material for semi-transparent blur
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: SB.popoverWidth, height: 200))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true

        // Tint overlay for the void feel
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = SB.void.withAlphaComponent(0.55).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(tint)
        NSLayoutConstraint.activate([
            tint.topAnchor.constraint(equalTo: effect.topAnchor),
            tint.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            tint.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        // Content stack directly in the effect view (no scroll)
        contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 0
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: effect.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            contentStack.widthAnchor.constraint(equalToConstant: SB.popoverWidth),
        ])

        self.view = effect
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refresh()
    }

    // MARK: - Refresh

    func refresh() {
        loadViewIfNeeded()
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard let window = window else { return }
        let mgr = window.workspaceManager

        addVerticalSpace(10)
        addHeader(workspaceCount: mgr.workspaces.count)
        addVerticalSpace(SB.sectionGap)

        addSeparator()
        addSectionLabel("ACTIVE TERMINALS")
        addActiveTerminals(mgr: mgr)
        addVerticalSpace(SB.sectionGap)

        addSeparator()
        addSectionLabel("WORKSPACES")
        addWorkspaces(mgr: mgr)
        addVerticalSpace(SB.sectionGap)

        addSeparator()
        addVerticalSpace(4)
        addFooter()
        addVerticalSpace(8)
    }

    // MARK: - Header

    private func addHeader(workspaceCount: Int) {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Clome")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = SB.copper
        title.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(title)

        let countStr = "\(workspaceCount) workspace\(workspaceCount == 1 ? "" : "s")"
        let count = NSTextField(labelWithString: countStr)
        count.font = .systemFont(ofSize: 11, weight: .regular)
        count.textColor = SB.textMuted
        count.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(count)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: SB.hPad),
            title.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            count.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -SB.hPad),
            count.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.heightAnchor.constraint(equalToConstant: 28),
        ])

        addFullWidthView(row)
    }

    // MARK: - Active Terminals

    private func addActiveTerminals(mgr: WorkspaceManager) {
        var hasActive = false

        for (wsIndex, workspace) in mgr.workspaces.enumerated() {
            for tab in workspace.tabs {
                for leaf in tab.splitContainer.allLeafViews {
                    guard let terminal = leaf as? TerminalSurface else { continue }
                    
                    // Include Claude Code terminals with specific states, or other terminals with activity
                    let isClaudeActive = terminal.detectedProgram == "Claude Code" && terminal.claudeCodeState != nil
                    let hasGeneralActivity = terminal.activityState == .running || terminal.activityState == .waitingInput
                    
                    guard isClaudeActive || hasGeneralActivity else { continue }
                    hasActive = true
                    addTerminalRow(terminal: terminal, wsIndex: wsIndex)
                }
            }
        }

        if !hasActive {
            let label = NSTextField(labelWithString: "All terminals idle")
            label.font = .systemFont(ofSize: 11, weight: .regular)
            label.textColor = SB.textMuted
            label.translatesAutoresizingMaskIntoConstraints = false

            let wrap = NSView()
            wrap.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: SB.hPad),
                label.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 6),
                label.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -6),
            ])
            addFullWidthView(wrap)
        }
    }

    private func addTerminalRow(terminal: TerminalSurface, wsIndex: Int) {
        let row = PopoverRow { [weak self] in
            self?.switchToWorkspace(index: wsIndex)
        }
        row.translatesAutoresizingMaskIntoConstraints = false

        // Icon
        let iconCfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: terminal.programIcon, accessibilityDescription: nil)?
            .withSymbolConfiguration(iconCfg)
        iconView.contentTintColor = SB.copper
        iconView.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(iconView)

        // Activity dot with Claude Code specific colors
        let dot = NSView()
        dot.wantsLayer = true
        
        let dotColor: NSColor
        if terminal.detectedProgram == "Claude Code", let claudeState = terminal.claudeCodeState {
            switch claudeState {
            case .thinking:
                dotColor = NSColor(red: 1.0, green: 0.8, blue: 0.4, alpha: 1.0) // Warm yellow
            case .doneWithTask:
                dotColor = SB.green
            case .awaitingSelection:
                dotColor = NSColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 1.0) // Blue
            case .awaitingPermission:
                dotColor = NSColor(red: 1.0, green: 0.6, blue: 0.4, alpha: 1.0) // Orange
            }
        } else {
            dotColor = terminal.activityState == .running ? SB.green : SB.amber
        }
        
        dot.layer?.backgroundColor = dotColor.cgColor
        dot.layer?.cornerRadius = 3
        // Glow
        dot.layer?.shadowColor = dotColor.cgColor
        dot.layer?.shadowRadius = 4
        dot.layer?.shadowOpacity = 0.6
        dot.layer?.shadowOffset = .zero
        dot.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(dot)

        // Text column - show Claude Code status if available
        let program = terminal.detectedProgram ?? terminal.title
        var displayName = program
        
        if terminal.detectedProgram == "Claude Code", let claudeState = terminal.claudeCodeState {
            switch claudeState {
            case .thinking:
                displayName = "Claude Code • Thinking..."
            case .doneWithTask:
                displayName = "Claude Code • Done with task."
            case .awaitingSelection:
                displayName = "Claude Code • Awaiting selection..."
            case .awaitingPermission:
                displayName = "Claude Code • Awaiting permission..."
            }
        }
        
        let nameLabel = NSTextField(labelWithString: displayName)
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = SB.text
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(nameLabel)

        var bottomAnchorView: NSView = nameLabel
        var bottomConstant: CGFloat = -8

        if let path = terminal.shortPath {
            let pathLabel = NSTextField(labelWithString: path)
            pathLabel.font = .systemFont(ofSize: 10, weight: .regular)
            pathLabel.textColor = SB.textDim
            pathLabel.lineBreakMode = .byTruncatingTail
            pathLabel.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(pathLabel)
            NSLayoutConstraint.activate([
                pathLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
                pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -SB.hPad),
                pathLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            ])
            bottomAnchorView = pathLabel
            bottomConstant = -8
        }

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: SB.hPad),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            iconView.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),

            dot.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            dot.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -SB.hPad),
            nameLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 8),

            bottomAnchorView.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: bottomConstant),
        ])

        addFullWidthView(row)
    }

    // MARK: - Workspaces

    private func addWorkspaces(mgr: WorkspaceManager) {
        for (index, workspace) in mgr.workspaces.enumerated() {
            let isActive = index == mgr.activeWorkspaceIndex
            addWorkspaceRow(workspace: workspace, index: index, isActive: isActive)
        }
    }

    private func addWorkspaceRow(workspace: Workspace, index: Int, isActive: Bool) {
        let row = PopoverRow { [weak self] in
            self?.switchToWorkspace(index: index)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: SB.rowHeight).isActive = true

        // Color dot
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = workspace.color.nsColor.cgColor
        dot.layer?.cornerRadius = 4
        if isActive {
            dot.layer?.shadowColor = workspace.color.nsColor.cgColor
            dot.layer?.shadowRadius = 4
            dot.layer?.shadowOpacity = 0.5
            dot.layer?.shadowOffset = .zero
        }
        dot.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(dot)

        // Name
        let name = NSTextField(labelWithString: workspace.name)
        name.font = .systemFont(ofSize: 12, weight: isActive ? .semibold : .regular)
        name.textColor = isActive ? SB.text : SB.textDim
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(name)

        // Trailing items: badge + tab count
        let trailing = NSStackView()
        trailing.orientation = .horizontal
        trailing.spacing = 6
        trailing.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(trailing)

        let unread = NotificationSystem.shared.unreadCount(for: workspace.id)
        if unread > 0 {
            trailing.addArrangedSubview(makeBadge(count: unread))
        }

        let tabCount = NSTextField(labelWithString: "\(workspace.tabs.count)")
        tabCount.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        tabCount.textColor = SB.textMuted
        trailing.addArrangedSubview(tabCount)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: SB.hPad),
            dot.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            name.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -8),
            trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -SB.hPad),
            trailing.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        addFullWidthView(row)
    }

    // MARK: - Footer

    private func addFooter() {
        addFooterButton("Show Clome", color: SB.copper, icon: "macwindow") { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKeyAndOrderFront(nil)
        }

        addFooterButton("Report an Issue", color: SB.textMuted, icon: "exclamationmark.bubble") {
            if let url = URL(string: "https://github.com/ranystephan/clome/issues/new?labels=bug&template=bug_report.md") {
                NSWorkspace.shared.open(url)
            }
        }

        addFooterButton("Quit", color: SB.textMuted, icon: "power") { _ = NSApp.terminate(nil) }
    }

    private func addFooterButton(_ title: String, color: NSColor, icon: String, action: @escaping () -> Void) {
        let row = PopoverRow(action: action)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let iconCfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?.withSymbolConfiguration(iconCfg)
        iconView.contentTintColor = color
        iconView.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(iconView)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: SB.hPad),
            iconView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        addFullWidthView(row)
    }

    // MARK: - Actions

    private func switchToWorkspace(index: Int) {
        guard let window = window else { return }
        window.workspaceManager.switchTo(index: index)
        window.sidebarView?.reloadWorkspaces()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Shared Helpers

    private func addSectionLabel(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = SB.textMuted
        label.translatesAutoresizingMaskIntoConstraints = false

        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: SB.hPad),
            label.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -4),
        ])
        addFullWidthView(wrap)
    }

    private func addSeparator() {
        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        sep.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(sep)
        NSLayoutConstraint.activate([
            sep.heightAnchor.constraint(equalToConstant: 1),
            sep.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor, constant: SB.hPad),
            sep.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor, constant: -SB.hPad),
        ])
    }

    private func addVerticalSpace(_ height: CGFloat) {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: height).isActive = true
        contentStack.addArrangedSubview(spacer)
    }

    private func addFullWidthView(_ view: NSView) {
        contentStack.addArrangedSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
        ])
    }

    private func makeBadge(count: Int) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = SB.copper.cgColor
        container.layer?.cornerRadius = 7
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "\(count)")
        label.font = .monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            container.heightAnchor.constraint(equalToConstant: 14),
        ])

        return container
    }
}

// MARK: - Popover Row (hover-highlight, click action)

private class PopoverRow: NSView {
    private let action: () -> Void
    private var trackingArea: NSTrackingArea?

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            action()
        }
    }
}
