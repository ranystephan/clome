import AppKit

/// A floating panel that hosts the launcher UI.
/// Behaves like Spotlight/Raycast: appears above all windows without activating Clome.
/// Only activates Clome when the user selects an action that requires it.
@MainActor
class LauncherWindow: NSPanel {

    private let panel = LauncherPanelView()
    private weak var workspaceManager: WorkspaceManager?
    private weak var clomeWindow: ClomeWindow?

    /// Track whether we need to activate Clome after dismissal.
    private var shouldActivateClome = false

    init(workspaceManager: WorkspaceManager, clomeWindow: ClomeWindow) {
        self.workspaceManager = workspaceManager
        self.clomeWindow = clomeWindow

        // Use the main screen size for the scrim
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        super.init(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Panel properties for Spotlight/Raycast-like behavior
        self.level = .floating
        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.isMovableByWindowBackground = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.isReleasedWhenClosed = false
        self.animationBehavior = .none

        setupContent()
        setupProviders()
    }

    override var canBecomeKey: Bool { true }

    private func setupContent() {
        let rootView = LauncherRootView()
        rootView.translatesAutoresizingMaskIntoConstraints = false
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.25).cgColor
        rootView.onClickOutside = { [weak self] in
            self?.dismiss()
        }

        // Shadow wrapper for the panel
        let shadowWrapper = NSView()
        shadowWrapper.translatesAutoresizingMaskIntoConstraints = false
        shadowWrapper.wantsLayer = true
        shadowWrapper.layer?.shadowColor = NSColor.black.cgColor
        shadowWrapper.layer?.shadowOpacity = 0.4
        shadowWrapper.layer?.shadowRadius = 25
        shadowWrapper.layer?.shadowOffset = NSSize(width: 0, height: -8)
        shadowWrapper.layer?.masksToBounds = false
        rootView.addSubview(shadowWrapper)

        panel.translatesAutoresizingMaskIntoConstraints = false
        shadowWrapper.addSubview(panel)

        NSLayoutConstraint.activate([
            shadowWrapper.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            shadowWrapper.centerYAnchor.constraint(equalTo: rootView.centerYAnchor, constant: -60),

            panel.topAnchor.constraint(equalTo: shadowWrapper.topAnchor),
            panel.leadingAnchor.constraint(equalTo: shadowWrapper.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: shadowWrapper.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: shadowWrapper.bottomAnchor),
        ])

        panel.onDismiss = { [weak self] in
            self?.dismiss()
        }

        panel.onItemActivated = { [weak self] item in
            self?.handleItemActivation(item)
        }

        contentView = rootView
    }

    private func setupProviders() {
        guard let wm = workspaceManager else { return }
        panel.workspaceManager = wm
        panel.registerProvider(NavigationProvider(workspaceManager: wm))
        panel.registerProvider(TerminalProvider(workspaceManager: wm))
        panel.registerProvider(SessionProvider(workspaceManager: wm))
        panel.registerProvider(FileProvider(workspaceManager: wm))
        if let win = clomeWindow {
            panel.registerProvider(CommandProvider(workspaceManager: wm, window: win))
        }
    }

    // MARK: - Show / Dismiss

    var isActive: Bool { isVisible }

    func show() {
        // Resize to current screen
        if let screen = NSScreen.main {
            setFrame(screen.frame, display: false)
        }

        shouldActivateClome = false
        panel.searchField.clear()
        panel.refreshResults()
        panel.startLivePreview()

        // Show the panel without activating the app
        orderFrontRegardless()
        makeKey()

        // Focus the search field
        panel.searchField.focus()

        // Fade in
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
    }

    func dismiss() {
        panel.stopLivePreview()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async {
                self?.orderOut(nil)
                self?.alphaValue = 1

                // If an action was taken, now activate Clome
                if self?.shouldActivateClome == true {
                    self?.shouldActivateClome = false
                    NSApp.activate(ignoringOtherApps: true)
                    self?.clomeWindow?.makeKeyAndOrderFront(nil)
                }
            }
        })
    }

    func toggle() {
        if isActive {
            dismiss()
        } else {
            show()
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Esc: dismiss
        if event.keyCode == 53 {
            dismiss()
            return
        }

        // Cmd+Y: Accept Claude permission
        if mods == .command && event.charactersIgnoringModifiers == "y" {
            if let item = panel.resultsView.selectedItem,
               let payload = item.payload as? TerminalPayload,
               let terminal = payload.terminal,
               terminal.claudeCodeState == .awaitingPermission {
                terminal.injectText("y")
                terminal.injectReturn()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.panel.refreshResults()
                }
                return
            }
        }

        // Cmd+N: Reject Claude permission
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

        // Swallow other unhandled keys
    }

    // MARK: - Item Activation

    private func handleItemActivation(_ item: LauncherItem) {
        guard let wm = workspaceManager else { return }

        switch item.provider {
        case "navigation":
            shouldActivateClome = true
            handleNavigationActivation(item, workspaceManager: wm)
        case "terminal":
            shouldActivateClome = true
            handleTerminalActivation(item, workspaceManager: wm)
        case "file":
            shouldActivateClome = true
            handleFileActivation(item, workspaceManager: wm)
        case "session":
            shouldActivateClome = true
            handleSessionActivation(item, workspaceManager: wm)
        case "command":
            shouldActivateClome = true
            if let payload = item.payload as? CommandPayload {
                dismiss()
                payload.handler()
                return
            }
        default:
            break
        }

        dismiss()
    }

    private func handleNavigationActivation(_ item: LauncherItem, workspaceManager wm: WorkspaceManager) {
        guard let info = item.payload as? NavigationPayload else { return }
        if info.workspaceIndex >= 0 && info.workspaceIndex < wm.workspaces.count {
            wm.switchTo(index: info.workspaceIndex)
            let workspace = wm.workspaces[info.workspaceIndex]
            if info.tabIndex >= 0 && info.tabIndex < workspace.tabs.count {
                workspace.selectTab(info.tabIndex)
                if let paneView = info.paneView {
                    workspace.tabs[info.tabIndex].splitContainer.focusedPane = paneView
                    clomeWindow?.makeFirstResponder(paneView)
                }
            }
        }
    }

    private func handleTerminalActivation(_ item: LauncherItem, workspaceManager wm: WorkspaceManager) {
        guard let payload = item.payload as? TerminalPayload else { return }
        if payload.workspaceIndex >= 0 && payload.workspaceIndex < wm.workspaces.count {
            wm.switchTo(index: payload.workspaceIndex)
            let workspace = wm.workspaces[payload.workspaceIndex]
            if payload.tabIndex >= 0 && payload.tabIndex < workspace.tabs.count {
                workspace.selectTab(payload.tabIndex)
                if let terminal = payload.terminal {
                    workspace.tabs[payload.tabIndex].splitContainer.focusedPane = terminal
                    clomeWindow?.makeFirstResponder(terminal)
                }
            }
        }
    }

    private func handleFileActivation(_ item: LauncherItem, workspaceManager wm: WorkspaceManager) {
        guard let payload = item.payload as? FilePayload else { return }
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

        // Resume inactive session: create a new terminal tab in the project directory
        guard let workspace = wm.activeWorkspace else { return }

        // Create a new terminal tab in the session's project directory
        let projectDir = session.projectPath
        if let tab = workspace.addTerminalTab(workingDirectory: projectDir) {
            // Give the shell a moment to initialize, then resume the session
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let terminal = tab.view as? TerminalSurface {
                    terminal.injectText("claude --resume \(session.id)")
                    terminal.injectReturn()
                }
            }
        }
    }
}

// MARK: - Root View (handles click-outside-to-dismiss)

/// Root content view for the launcher window. Detects clicks on the scrim (outside the panel).
@MainActor
class LauncherRootView: NSView {
    var onClickOutside: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        // This only fires when no subview handles the click (i.e. click on scrim)
        onClickOutside?()
    }

    override var acceptsFirstResponder: Bool { true }
}
