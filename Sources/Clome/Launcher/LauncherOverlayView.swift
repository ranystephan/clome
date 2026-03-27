import AppKit

/// Full-window overlay that hosts the launcher panel.
/// Added as a subview of ClomeWindow's contentView, above all other content.
@MainActor
class LauncherOverlayView: NSView {

    private let panel = LauncherPanelView()
    private weak var workspaceManager: WorkspaceManager?

    /// The first responder before the launcher was shown, so we can restore it on dismiss.
    private weak var previousFirstResponder: NSResponder?

    /// Called when the launcher wants to dismiss itself.
    var onDismiss: (() -> Void)?

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
        super.init(frame: .zero)
        setupViews()
        setupProviders()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    /// Shadow wrapper view — carries the shadow so the panel can clip its corners.
    private let shadowWrapper = NSView()

    private func setupViews() {
        wantsLayer = true
        // Semi-transparent dark scrim
        layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.4).cgColor

        // Shadow wrapper: no clipping, only provides the drop shadow
        shadowWrapper.translatesAutoresizingMaskIntoConstraints = false
        shadowWrapper.wantsLayer = true
        shadowWrapper.layer?.shadowColor = NSColor.black.cgColor
        shadowWrapper.layer?.shadowOpacity = 0.3
        shadowWrapper.layer?.shadowRadius = 20
        shadowWrapper.layer?.shadowOffset = NSSize(width: 0, height: -10)
        shadowWrapper.layer?.masksToBounds = false
        addSubview(shadowWrapper)

        panel.translatesAutoresizingMaskIntoConstraints = false
        shadowWrapper.addSubview(panel)

        // Center the shadow wrapper, offset slightly upward
        NSLayoutConstraint.activate([
            shadowWrapper.centerXAnchor.constraint(equalTo: centerXAnchor),
            shadowWrapper.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),

            // Panel fills shadow wrapper
            panel.topAnchor.constraint(equalTo: shadowWrapper.topAnchor),
            panel.leadingAnchor.constraint(equalTo: shadowWrapper.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: shadowWrapper.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: shadowWrapper.bottomAnchor),
        ])

        panel.onDismiss = { [weak self] in
            self?.deactivate()
        }

        panel.onItemActivated = { [weak self] item in
            self?.handleItemActivation(item)
        }

        isHidden = true
    }

    private func setupProviders() {
        guard let wm = workspaceManager else { return }
        panel.workspaceManager = wm
        panel.registerProvider(NavigationProvider(workspaceManager: wm))
        panel.registerProvider(TerminalProvider(workspaceManager: wm))
        panel.registerProvider(SessionProvider(workspaceManager: wm))
        panel.registerProvider(FileProvider(workspaceManager: wm))
    }

    /// Register providers that need the window reference (called after overlay is added to window).
    func registerWindowProviders() {
        guard let wm = workspaceManager, let win = window as? ClomeWindow else { return }
        panel.registerProvider(CommandProvider(workspaceManager: wm, window: win))
    }

    // MARK: - Activation

    override var acceptsFirstResponder: Bool { true }

    func activate() {
        previousFirstResponder = window?.firstResponder
        isHidden = false

        // Animate in (fade only — scale transform doesn't animate via animator)
        shadowWrapper.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            shadowWrapper.animator().alphaValue = 1
        }

        panel.searchField.clear()
        panel.refreshResults()
        panel.startLivePreview()
        panel.searchField.focus()
    }

    func deactivate() {
        panel.stopLivePreview()
        onDismiss?()

        // Animate out
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            shadowWrapper.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async {
                self?.isHidden = true
                self?.shadowWrapper.alphaValue = 1

                // Restore previous first responder after animation completes
                if let prev = self?.previousFirstResponder {
                    self?.window?.makeFirstResponder(prev)
                }
            }
        })
    }

    var isActive: Bool { !isHidden }

    // MARK: - Click Outside to Dismiss

    override func mouseDown(with event: NSEvent) {
        // Default hitTest returns self only when no subview contains the click
        // (i.e. click was on the dark scrim, outside the panel). Dismiss.
        deactivate()
    }

    // MARK: - Item Activation

    private func handleItemActivation(_ item: LauncherItem) {
        guard let wm = workspaceManager else { return }

        // Execute the primary action based on provider type
        switch item.provider {
        case "navigation":
            handleNavigationActivation(item, workspaceManager: wm)
            deactivate()
        case "terminal":
            handleTerminalActivation(item, workspaceManager: wm)
            deactivate()
        case "file":
            handleFileActivation(item, workspaceManager: wm)
            deactivate()
        case "session":
            handleSessionActivation(item, workspaceManager: wm)
            deactivate()
        case "command":
            if let payload = item.payload as? CommandPayload {
                deactivate()
                payload.handler()
            } else {
                deactivate()
            }
        default:
            deactivate()
        }
    }

    private func handleNavigationActivation(_ item: LauncherItem, workspaceManager wm: WorkspaceManager) {
        // Payload contains navigation info as [String: Any]
        guard let info = item.payload as? NavigationPayload else { return }

        // Switch to workspace
        if info.workspaceIndex >= 0 && info.workspaceIndex < wm.workspaces.count {
            wm.switchTo(index: info.workspaceIndex)

            // Switch to tab within workspace
            let workspace = wm.workspaces[info.workspaceIndex]
            if info.tabIndex >= 0 && info.tabIndex < workspace.tabs.count {
                workspace.selectTab(info.tabIndex)

                // Focus specific pane if provided
                if let paneView = info.paneView {
                    workspace.tabs[info.tabIndex].splitContainer.focusedPane = paneView
                    window?.makeFirstResponder(paneView)
                }
            }
        }
    }

    private func handleTerminalActivation(_ item: LauncherItem, workspaceManager wm: WorkspaceManager) {
        guard let payload = item.payload as? TerminalPayload else { return }

        // Navigate to the terminal's workspace/tab
        if payload.workspaceIndex >= 0 && payload.workspaceIndex < wm.workspaces.count {
            wm.switchTo(index: payload.workspaceIndex)
            let workspace = wm.workspaces[payload.workspaceIndex]
            if payload.tabIndex >= 0 && payload.tabIndex < workspace.tabs.count {
                workspace.selectTab(payload.tabIndex)
                if let terminal = payload.terminal {
                    workspace.tabs[payload.tabIndex].splitContainer.focusedPane = terminal
                    window?.makeFirstResponder(terminal)
                }
            }
        }
    }

    private func handleFileActivation(_ item: LauncherItem, workspaceManager wm: WorkspaceManager) {
        guard let payload = item.payload as? FilePayload else { return }

        // Open file in the active workspace
        if let workspace = wm.activeWorkspace {
            workspace.openFileAsTab(payload.filePath)
        }
    }

    private func handleSessionActivation(_ item: LauncherItem, workspaceManager wm: WorkspaceManager) {
        guard let payload = item.payload as? SessionPayload else { return }
        let session = payload.session

        // If session is active in a workspace, navigate there
        if let wsName = session.activeInWorkspace {
            if let idx = wm.workspaces.firstIndex(where: { $0.name == wsName }) {
                wm.switchTo(index: idx)
                return
            }
        }

        // Otherwise, resume the session in the active workspace's terminal
        if let workspace = wm.activeWorkspace,
           let terminal = workspace.activeSurface {
            terminal.injectText("claude --resume \(session.id)")
            terminal.injectReturn()
        }
    }

    // MARK: - Keyboard Shortcuts

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd+Y: Accept Claude permission on selected terminal
        if mods == .command && event.charactersIgnoringModifiers == "y" {
            if let item = panel.resultsView.selectedItem,
               let payload = item.payload as? TerminalPayload,
               let terminal = payload.terminal,
               terminal.claudeCodeState == .awaitingPermission {
                terminal.injectText("y")
                terminal.injectReturn()
                // Refresh after a brief delay for state to update
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.panel.refreshResults()
                }
                return
            }
        }

        // Cmd+N: Reject Claude permission on selected terminal
        if mods == .command && event.charactersIgnoringModifiers == "n" {
            if let item = panel.resultsView.selectedItem,
               let payload = item.payload as? TerminalPayload,
               let terminal = payload.terminal,
               terminal.claudeCodeState == .awaitingPermission {
                terminal.injectText("n")
                terminal.injectReturn()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.panel.refreshResults()
                }
                return
            }
        }

        // Cmd+Enter: Focus terminal input in preview
        if mods == .command && event.keyCode == 36 {
            panel.focusTerminalInput()
            return
        }

        // Swallow unhandled keys to prevent beep
    }
}

/// Payload for navigation items, carrying workspace/tab/pane info.
@MainActor
class NavigationPayload: NSObject {
    let workspaceIndex: Int
    let tabIndex: Int
    weak var paneView: NSView?

    init(workspaceIndex: Int, tabIndex: Int, paneView: NSView? = nil) {
        self.workspaceIndex = workspaceIndex
        self.tabIndex = tabIndex
        self.paneView = paneView
    }
}
