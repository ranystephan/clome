import AppKit
import Firebase
import FirebaseAuth
import GoogleSignIn

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
    private var remoteServer: RemoteServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Disable macOS window restoration — Clome manages its own session state via SQLite.
        // This prevents "Unable to find className=(null)" errors from NSWindowRestoration.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")

        // Restore saved security-scoped bookmarks for TCC-protected directories.
        // This does NOT show any prompts — only resolves previously-saved bookmarks.
        FileAccessManager.shared.prewarmAccess()

        // Firebase is initialized in main.swift before NSApplication.run()

        // Apply user's theme preference (light/dark/system).
        // The hook ensures NSApp.appearance is set BEFORE the notification fires,
        // so views re-resolve dynamic colors against the new appearance.
        ClomeSettings.shared.onThemeWillChange = { ClomeMacTheme.applyTheme() }
        ClomeMacTheme.applyTheme()

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

        // Access to TCC-protected directories (Desktop, Documents, Downloads) is now
        // requested lazily — only when the user actually opens a project in one of them.
        // This avoids bombarding the user with permission prompts on every launch.

        // Restore saved window frame (validate it's visible on a connected screen)
        if let frame = SessionState.shared.restoreWindowFrame() {
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                window.setFrame(frame, display: true)
            } else {
                window.center()
            }
        }
        fitWindowToVisibleScreen(window)
        window.makeKeyAndOrderFront(nil)
        mainWindow = window

        // Start socket server for external automation
        socketServer = SocketServer()
        socketServer?.window = window
        socketServer?.start()

        // Keyboard navigation
        keyboardHandler = KeyboardNavigationHandler(window: window)

        // Start remote control server (Bonjour + Multipeer for iOS Clome Flow)
        remoteServer = RemoteServer.shared
        remoteServer?.workspaceManager = window.workspaceManager
        remoteServer?.start()

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

        // Register for system memory pressure notifications
        setupMemoryPressureHandler()

        NSApp.activate(ignoringOtherApps: true)

        // Show onboarding on first launch
        OnboardingWindowController.showIfNeeded()
    }

    // MARK: - Memory Pressure Handling

    private var memoryPressureSource: DispatchSourceMemoryPressure?

    private func setupMemoryPressureHandler() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.handleMemoryPressure()
        }
        source.resume()
        memoryPressureSource = source
    }

    private func handleMemoryPressure() {
        NSLog("[Clome] System memory pressure detected — releasing caches")
        guard let window = mainWindow else { return }
        for workspace in window.workspaceManager.workspaces {
            workspace.handleMemoryPressure()
        }
        // Also clear any global caches
        URLCache.shared.removeAllCachedResponses()
    }

    func applicationWillTerminate(_ notification: Notification) {
        autoSaveTimer?.invalidate()
        autoSaveTimer = nil
        saveSession()
        remoteServer?.stop()
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
        CrashReporter.shared.logCleanShutdown()
    }

    func applicationDidResignActive(_ notification: Notification) {
        // Save immediately when losing focus — critical for Xcode re-run (SIGKILL)
        saveSession()
    }

    /// Handle Google Sign-In OAuth callback URL
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            GIDSignIn.sharedInstance.handle(url)
        }
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

    private func fitWindowToVisibleScreen(_ window: NSWindow) {
        let currentFrame = window.frame
        let screen = window.screen
            ?? NSScreen.screens.first(where: { $0.visibleFrame.intersects(currentFrame) })
            ?? NSScreen.main
        guard let screen else { return }

        let visible = screen.visibleFrame
        let fittedWidth = min(currentFrame.width, visible.width)
        let fittedHeight = min(currentFrame.height, visible.height)
        let fittedX = min(max(currentFrame.minX, visible.minX), visible.maxX - fittedWidth)
        let fittedY = min(max(currentFrame.minY, visible.minY), visible.maxY - fittedHeight)
        let fittedFrame = NSRect(x: fittedX, y: fittedY, width: fittedWidth, height: fittedHeight)

        if !NSEqualRects(currentFrame, fittedFrame) {
            window.setFrame(fittedFrame, display: true)
        }
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
        fileMenu.addItem(withTitle: "New Workspace", action: #selector(newWorkspace(_:)), keyEquivalent: "w")
        fileMenu.addItem(withTitle: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "t")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Open...", action: #selector(openFile(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "New Browser Tab", action: #selector(newBrowserTab(_:)), keyEquivalent: "t")
        fileMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "New Flow Tab", action: #selector(newFlowTab(_:)), keyEquivalent: "f")
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
        fileMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
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

        // Browser menu
        let browserMenuItem = NSMenuItem()
        let browserMenu = NSMenu(title: "Browser")
        browserMenu.addItem(withTitle: "Back", action: #selector(browserBack(_:)), keyEquivalent: "[")
        browserMenu.items.last?.keyEquivalentModifierMask = [.command]
        browserMenu.addItem(withTitle: "Forward", action: #selector(browserForward(_:)), keyEquivalent: "]")
        browserMenu.items.last?.keyEquivalentModifierMask = [.command]
        browserMenu.addItem(NSMenuItem.separator())
        browserMenu.addItem(withTitle: "Reload", action: #selector(browserReload(_:)), keyEquivalent: "r")
        browserMenu.items.last?.keyEquivalentModifierMask = [.command]
        browserMenu.addItem(withTitle: "Reload From Origin", action: #selector(browserReloadFromOrigin(_:)), keyEquivalent: "r")
        browserMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        browserMenu.addItem(withTitle: "Open Location", action: #selector(browserOpenLocation(_:)), keyEquivalent: "l")
        browserMenu.items.last?.keyEquivalentModifierMask = [.command]
        browserMenu.addItem(withTitle: "Show Start Page", action: #selector(browserShowStartPage(_:)), keyEquivalent: "l")
        browserMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        browserMenu.addItem(NSMenuItem.separator())
        browserMenu.addItem(withTitle: "Save Site", action: #selector(browserToggleSavedSite(_:)), keyEquivalent: "")
        browserMenuItem.submenu = browserMenu
        mainMenu.addItem(browserMenuItem)

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
        guard let workspace = mainWindow?.workspaceManager.activeWorkspace else { return }
        // Open a new tab matching the type of the currently active tab
        switch workspace.activeTab?.type {
        case .browser:
            workspace.addBrowserSurface()
        case .editor:
            try? workspace.addEditorTab()
        case .project:
            // Can't duplicate a project tab without a directory — fall back to terminal
            workspace.addSurface()
        case .notebook, .pdf, .diff, .flow:
            // These need file paths or are special — fall back to terminal
            workspace.addSurface()
        case .terminal, .none:
            workspace.addSurface()
        }
    }

    @objc private func openFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let path = url.path

            // Record access from NSOpenPanel — this grants persistent TCC access
            // and prevents repeated permission prompts for this directory.
            FileAccessManager.shared.recordOpenPanelAccess(url: url)

            // Check if it's a directory — add as project root
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                self?.mainWindow?.workspaceManager.activeWorkspace?.addProjectRoot(path: path)
                WelcomeView.addRecentProject(path)
                self?.mainWindow?.sidebarView.reloadWorkspaces()
                return
            }

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

    private func activeBrowserPanel() -> BrowserPanel? {
        guard let workspace = mainWindow?.workspaceManager.activeWorkspace else { return nil }
        if let browser = workspace.activeTab?.focusedPane as? BrowserPanel {
            return browser
        }
        return workspace.activeTab?.view as? BrowserPanel
    }

    @objc private func browserBack(_ sender: Any?) {
        activeBrowserPanel()?.navigateBack()
    }

    @objc private func browserForward(_ sender: Any?) {
        activeBrowserPanel()?.navigateForward()
    }

    @objc private func browserReload(_ sender: Any?) {
        activeBrowserPanel()?.reloadPage()
    }

    @objc private func browserReloadFromOrigin(_ sender: Any?) {
        activeBrowserPanel()?.reloadPage(fromOrigin: true)
    }

    @objc private func browserOpenLocation(_ sender: Any?) {
        activeBrowserPanel()?.focusAddressBar()
    }

    @objc private func browserShowStartPage(_ sender: Any?) {
        activeBrowserPanel()?.showStartPage()
    }

    @objc private func browserToggleSavedSite(_ sender: Any?) {
        activeBrowserPanel()?.toggleSavedSite()
    }

    @objc private func newFlowTab(_ sender: Any?) {
        mainWindow?.workspaceManager.activeWorkspace?.addFlowTab()
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
