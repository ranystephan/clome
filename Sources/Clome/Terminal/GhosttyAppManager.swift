import AppKit
import UserNotifications

/// Manages the lifecycle of the Ghostty application instance.
/// This is the bridge between Clome and libghostty.
@MainActor
class GhosttyAppManager {
    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?

    init() {
        // Point Ghostty at the bundled resources directory so it can find
        // terminfo entries (ghostty / xterm-ghostty) and shell-integration
        // scripts.  The bundle layout is:
        //   Contents/Resources/ghostty/          — shell-integration, themes
        //   Contents/Resources/terminfo/78/xterm-ghostty  — terminfo sentinel
        // Ghostty's resourcesDir() auto-detects this by walking up from the
        // executable, but we also set the env var as a reliable fallback
        // (e.g. when launched from Xcode DerivedData via symlinks).
        if let resourcePath = Bundle.main.resourcePath {
            let ghosttyResDir = (resourcePath as NSString).appendingPathComponent("ghostty")
            setenv("GHOSTTY_RESOURCES_DIR", ghosttyResDir, 1)
        }

        // Initialize ghostty
        ghostty_init(0, nil)

        // Create and load config
        let cfg = ghostty_config_new()
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)

        // Override command to launch the user's shell directly instead of
        // using /usr/bin/login, which fails with PermissionDenied for
        // ad-hoc signed apps due to macOS SIP.
        // Also set reasonable padding to avoid "very small terminal grid"
        // warnings when the window starts at a compact size.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var overrideLines = [
            "command=\(shell) -l",
            "window-padding-x=2",
            "window-padding-y=2",
            "window-padding-balance=true",
        ]
        // Ensure TERM is set to xterm-ghostty now that we bundle the terminfo
        overrideLines.append("term=xterm-ghostty")
        let overrideConfig = overrideLines.joined(separator: "\n") + "\n"
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("clome-ghostty-override.conf")
        try? overrideConfig.write(to: tmpURL, atomically: true, encoding: .utf8)
        ghostty_config_load_file(cfg, tmpURL.path)

        ghostty_config_finalize(cfg)
        self.config = cfg

        // Set up runtime callbacks
        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = false
        runtimeConfig.wakeup_cb = { userdata in
            guard let userdata else { return }
            DispatchQueue.main.async { @Sendable in
                let mgr = Unmanaged<GhosttyAppManager>.fromOpaque(userdata).takeUnretainedValue()
                mgr.tick()
            }
        }
        runtimeConfig.action_cb = { app, target, action in
            guard let app else { return false }
            let userdata = ghostty_app_userdata(app)
            guard let userdata else { return false }
            let mgr = Unmanaged<GhosttyAppManager>.fromOpaque(userdata).takeUnretainedValue()
            return mgr.handleAction(target: target, action: action)
        }
        // NOTE: Clipboard callbacks receive SURFACE-level userdata (the TerminalSurface),
        // not the app-level userdata (GhosttyAppManager).
        runtimeConfig.read_clipboard_cb = { surfaceUD, clipboard, state in
            guard let surfaceUD else { return false }
            let terminal = Unmanaged<TerminalSurface>.fromOpaque(surfaceUD).takeUnretainedValue()
            guard let surface = terminal.surface else { return false }
            guard let string = NSPasteboard.general.string(forType: .string) else { return false }
            guard let state else { return false }
            string.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, true)
            }
            return true
        }
        runtimeConfig.confirm_read_clipboard_cb = nil
        runtimeConfig.write_clipboard_cb = { surfaceUD, clipboard, contents, contentsLen, confirm in
            guard let contents, contentsLen > 0 else { return }
            if let data = contents.pointee.data {
                let string = String(cString: data)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(string, forType: .string)
            }
        }
        runtimeConfig.close_surface_cb = nil

        // Create the app
        self.app = ghostty_app_new(&runtimeConfig, cfg)
    }

    func shutdown() {
        if let app {
            ghostty_app_free(app)
            self.app = nil
        }
        if let config {
            ghostty_config_free(config)
            self.config = nil
        }
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    /// Create a new terminal surface configuration for a given TerminalSurface.
    /// NOTE: working_directory and command are set by TerminalSurface.createSurface()
    /// which manages the C string lifetimes properly.
    func makeSurfaceConfig(for view: TerminalSurface) -> ghostty_surface_config_s {
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
        cfg.userdata = Unmanaged.passUnretained(view).toOpaque()
        cfg.scale_factor = Double(view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
        cfg.font_size = 0 // use config default
        cfg.context = GHOSTTY_SURFACE_CONTEXT_SPLIT
        return cfg
    }

    // MARK: - Callbacks

    private func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            if let titlePtr = action.action.set_title.title {
                let title = String(cString: titlePtr)
                NotificationCenter.default.post(
                    name: .ghosttySurfaceTitleChanged,
                    object: nil,
                    userInfo: ["title": title, "target": target]
                )
            }
            return true

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            if let bodyPtr = action.action.desktop_notification.body {
                let body = String(cString: bodyPtr)
                let title: String
                if let titlePtr = action.action.desktop_notification.title {
                    title = String(cString: titlePtr)
                } else {
                    title = "Clome"
                }
                sendNotification(title: title, body: body)
                // Also post for activity monitoring
                NotificationCenter.default.post(
                    name: .ghosttyDesktopNotification,
                    object: nil,
                    userInfo: ["body": body, "title": title, "target": target]
                )
            }
            return true

        case GHOSTTY_ACTION_PWD:
            if let pwdPtr = action.action.pwd.pwd {
                let pwd = String(cString: pwdPtr)
                NotificationCenter.default.post(
                    name: .ghosttySurfacePwdChanged,
                    object: nil,
                    userInfo: ["pwd": pwd, "target": target]
                )
            }
            return true

        case GHOSTTY_ACTION_COMMAND_FINISHED:
            let exitCode = action.action.command_finished.exit_code
            NotificationCenter.default.post(
                name: .ghosttyCommandFinished,
                object: nil,
                userInfo: ["exit_code": exitCode, "target": target]
            )
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            if let urlPtr = action.action.open_url.url {
                let urlString = String(cString: urlPtr)
                openURLFromTerminal(urlString, target: target)
            }
            return true

        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
            return true

        case GHOSTTY_ACTION_NEW_SPLIT,
             GHOSTTY_ACTION_CLOSE_WINDOW,
             GHOSTTY_ACTION_RENDER,
             GHOSTTY_ACTION_CELL_SIZE,
             GHOSTTY_ACTION_INITIAL_SIZE,
             GHOSTTY_ACTION_MOUSE_SHAPE,
             GHOSTTY_ACTION_MOUSE_VISIBILITY,
             GHOSTTY_ACTION_SCROLLBAR,
             GHOSTTY_ACTION_SIZE_LIMIT,
             GHOSTTY_ACTION_COLOR_CHANGE,
             GHOSTTY_ACTION_CONFIG_CHANGE,
             GHOSTTY_ACTION_RENDERER_HEALTH:
            return true

        default:
            return false
        }
    }

    private func openURLFromTerminal(_ urlString: String, target: ghostty_target_s) {
        guard let url = URL(string: urlString) else { return }
        let scheme = url.scheme?.lowercased() ?? ""

        // Only intercept http/https URLs
        guard scheme == "http" || scheme == "https" else {
            NSWorkspace.shared.open(url)
            return
        }

        // Check user preference
        guard AppearanceSettings.shared.openLinksInClomeBrowser else {
            NSWorkspace.shared.open(url)
            return
        }

        // Find the source terminal surface and split a browser next to it
        guard let appDelegate = NSApp.delegate as? ClomeAppDelegate,
              let workspace = appDelegate.mainWindow?.workspaceManager.activeWorkspace else {
            NSWorkspace.shared.open(url)
            return
        }

        // Find the TerminalSurface that triggered this action
        let sourceSurface: TerminalSurface? = {
            guard target.tag == GHOSTTY_TARGET_SURFACE else { return nil }
            let targetSurface = target.target.surface
            for tab in workspace.tabs {
                for view in tab.splitContainer.allLeafViews {
                    if let terminal = view as? TerminalSurface, terminal.surface == targetSurface {
                        return terminal
                    }
                }
            }
            return nil
        }()

        // Create a browser and split it next to the source terminal
        let browser = BrowserPanel()
        browser.loadURL(urlString)

        if let terminal = sourceSurface, let tab = workspace.activeTab {
            tab.splitContainer.split(view: terminal, with: browser, direction: .right)
            tab.splitContainer.focusedPane = browser
            workspace.onTabsChanged?()
        } else {
            // Fallback: open as a new tab
            workspace.addBrowserTab(url: urlString)
        }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let ghosttySurfaceTitleChanged = Notification.Name("ghosttySurfaceTitleChanged")
    static let ghosttySurfacePwdChanged = Notification.Name("ghosttySurfacePwdChanged")
    static let ghosttyCommandFinished = Notification.Name("ghosttyCommandFinished")
}
