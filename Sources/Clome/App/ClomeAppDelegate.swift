import AppKit

@MainActor
class ClomeAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private(set) var mainWindow: ClomeWindow?
    private(set) var ghosttyApp: GhosttyAppManager?
    private var socketServer: SocketServer?
    private var keyboardHandler: KeyboardNavigationHandler?
    private var statusBarController: StatusBarController?
    private var autoSaveTimer: Timer?
    private var isSaving = false
    private var debouncedSaveWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()

        // Initialize the Ghostty terminal backend
        ghosttyApp = GhosttyAppManager()

        // Start terminal activity monitoring
        _ = TerminalActivityMonitor.shared

        // Restore or create window
        let window = ClomeWindow()
        window.ghosttyApp = ghosttyApp

        // Restore session state (workspaces + tabs), or create a default workspace
        if !window.workspaceManager.restoreFromSession() {
            window.workspaceManager.addWorkspace()
        }

        window.makeKeyAndOrderFront(nil)
        mainWindow = window

        // Restore saved window frame (validate it's visible on a connected screen)
        if let frame = SessionState.shared.restoreWindowFrame() {
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                window.setFrame(frame, display: true)
            } else {
                window.center()
            }
        }

        // Start socket server for external automation
        socketServer = SocketServer()
        socketServer?.window = window
        socketServer?.start()

        // Keyboard navigation
        keyboardHandler = KeyboardNavigationHandler(window: window)

        // Nil out mainWindow when the window closes to avoid dangling references
        window.delegate = self

        // Auto-save session state periodically
        autoSaveTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.saveSession()
            }
        }

        // Status bar item
        statusBarController = StatusBarController(window: window)

        NSApp.activate(ignoringOtherApps: true)

        // Show onboarding on first launch
        OnboardingWindowController.showIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        autoSaveTimer?.invalidate()
        autoSaveTimer = nil
        saveSession()
        socketServer?.stop()

        // Destroy all terminal surfaces BEFORE freeing the ghostty app.
        // Otherwise TerminalSurface.deinit calls ghostty_surface_free on
        // surfaces whose parent app has already been freed → EXC_BAD_ACCESS.
        if let window = mainWindow {
            for workspace in window.workspaceManager.workspaces {
                for tab in workspace.tabs {
                    for pane in tab.splitContainer.allLeafViews {
                        if let terminal = pane as? TerminalSurface {
                            terminal.destroySurface()
                        }
                    }
                }
            }
        }

        ghosttyApp?.shutdown()
    }

    func applicationDidResignActive(_ notification: Notification) {
        // Save immediately when losing focus — critical for Xcode re-run (SIGKILL)
        saveSession()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Re-show the main window when the user clicks the dock icon while the app is running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow else { return }
        debouncedSaveWork?.cancel()
        mainWindow = nil
    }

    /// Schedule a save 2 seconds from now. Resets on each call so rapid changes batch into one save.
    func scheduleSave() {
        debouncedSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.saveSession()
            }
        }
        debouncedSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func saveSession() {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        guard let window = mainWindow else { return }
        SessionState.shared.saveWindowFrame(window.frame)
        SessionState.shared.saveWorkspaces(
            window.workspaceManager.workspaces,
            activeIndex: window.workspaceManager.activeWorkspaceIndex
        )
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Clome", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Welcome to Clome…", action: #selector(showOnboarding(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Clome", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Workspace", action: #selector(newWorkspace(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "t")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Open File...", action: #selector(openFile(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "New Browser Tab", action: #selector(newBrowserTab(_:)), keyEquivalent: "t")
        fileMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Resume Claude Session...", action: #selector(resumeClaudeSession(_:)), keyEquivalent: "r")
        fileMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "Continue Last Claude Session", action: #selector(continueLastClaudeSession(_:)), keyEquivalent: "c")
        fileMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Import Browser Data...", action: #selector(importBrowserData(_:)), keyEquivalent: "i")
        fileMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeTab(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        editMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Split Right", action: #selector(splitRight(_:)), keyEquivalent: "d")
        viewMenu.items.last?.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(withTitle: "Split Down", action: #selector(splitDown(_:)), keyEquivalent: "d")
        viewMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar(_:)), keyEquivalent: "s")
        viewMenu.items.last?.keyEquivalentModifierMask = [.command, .control]
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Next Workspace", action: #selector(nextWorkspace(_:)), keyEquivalent: "]")
        windowMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(withTitle: "Previous Workspace", action: #selector(prevWorkspace(_:)), keyEquivalent: "[")
        windowMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Actions

    @objc private func showOnboarding(_ sender: Any?) {
        OnboardingWindowController.show()
    }

    @objc private func openSettings(_ sender: Any?) {
        SettingsWindowController.show()
    }

    @objc private func newWorkspace(_ sender: Any?) {
        mainWindow?.workspaceManager.addWorkspace()
        mainWindow?.sidebarView?.setNeedsReload()
    }

    @objc private func newTab(_ sender: Any?) {
        mainWindow?.workspaceManager.activeWorkspace?.addSurface()
    }

    @objc private func openFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let path = url.path
            do {
                if path.lowercased().hasSuffix(".pdf") {
                    self?.mainWindow?.workspaceManager.activeWorkspace?.openPDF(path)
                } else if path.lowercased().hasSuffix(".ipynb") {
                    try self?.mainWindow?.workspaceManager.activeWorkspace?.openNotebook(path)
                } else {
                    try self?.mainWindow?.workspaceManager.activeWorkspace?.openFile(path)
                }
            } catch {
                print("Failed to open file: \(error)")
            }
        }
    }

    @objc private func importBrowserData(_ sender: Any?) {
        BrowserImportWindowController.show()
    }

    @objc private func newBrowserTab(_ sender: Any?) {
        mainWindow?.workspaceManager.activeWorkspace?.addBrowserSurface()
    }

    @objc private func resumeClaudeSession(_ sender: Any?) {
        mainWindow?.sidebarView?.toggleSessionsPopover()
    }

    @objc private func continueLastClaudeSession(_ sender: Any?) {
        mainWindow?.workspaceManager.activeWorkspace?.addClaudeSessionTab()
    }

    @objc private func closeTab(_ sender: Any?) {
        mainWindow?.workspaceManager.activeWorkspace?.closeActiveSurface()
    }

    @objc private func splitRight(_ sender: Any?) {
        mainWindow?.workspaceManager.activeWorkspace?.splitActivePane(direction: .right)
    }

    @objc private func splitDown(_ sender: Any?) {
        mainWindow?.workspaceManager.activeWorkspace?.splitActivePane(direction: .down)
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        mainWindow?.toggleSidebar()
    }

    @objc private func nextWorkspace(_ sender: Any?) {
        guard let mgr = mainWindow?.workspaceManager else { return }
        let next = mgr.activeWorkspaceIndex + 1
        if next < mgr.workspaces.count {
            mgr.switchTo(index: next)
            mainWindow?.sidebarView?.setNeedsReload()
        }
    }

    @objc private func prevWorkspace(_ sender: Any?) {
        guard let mgr = mainWindow?.workspaceManager else { return }
        let prev = mgr.activeWorkspaceIndex - 1
        if prev >= 0 {
            mgr.switchTo(index: prev)
            mainWindow?.sidebarView?.setNeedsReload()
        }
    }
}
