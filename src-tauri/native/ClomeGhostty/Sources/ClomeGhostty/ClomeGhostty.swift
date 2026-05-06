import AppKit
import CGhostty
import Foundation
import UserNotifications

private func runOnMain<T>(_ block: () -> T) -> T {
    if Thread.isMainThread {
        return block()
    }
    return DispatchQueue.main.sync(execute: block)
}

private func copyCString(_ value: String?, to buffer: UnsafeMutablePointer<CChar>?, capacity: Int) {
    guard let buffer, capacity > 0 else { return }
    buffer[0] = 0
    guard let value else { return }
    let bytes = Array(value.utf8.prefix(capacity - 1))
    for (index, byte) in bytes.enumerated() {
        buffer[index] = CChar(bitPattern: byte)
    }
    buffer[bytes.count] = 0
}

@_silgen_name("clome_terminal_metadata_event")
private func clome_terminal_metadata_event(
    _ tabId: UnsafePointer<CChar>?,
    _ title: UnsafePointer<CChar>?,
    _ cwd: UnsafePointer<CChar>?,
    _ running: UInt8,
    _ exitCode: Int16,
    _ duration: UInt64
)

@_silgen_name("clome_terminal_focus_event")
private func clome_terminal_focus_event(_ tabId: UnsafePointer<CChar>?)

@_silgen_name("clome_terminal_shortcut_event")
private func clome_terminal_shortcut_event(
    _ tabId: UnsafePointer<CChar>?,
    _ shortcut: UnsafePointer<CChar>?
)

@_silgen_name("clome_app_shortcut_event")
private func clome_app_shortcut_event(_ shortcut: UnsafePointer<CChar>?)

private final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private var booted = false
    private var surfaces: [String: ClomeTerminalSurface] = [:]
    /// Overlay clip in WebView coordinates (top-left origin). When set,
    /// each surface gets a CALayer mask so the overlay region is
    /// excluded — HTML can paint there without the surface drawing on
    /// top. nil = no clipping. Persisted across show/hide so re-attached
    /// surfaces inherit the current overlay state.
    private var overlayClipWeb: NSRect? = nil
    /// Local NSEvent monitor that intercepts app-level shortcuts (Cmd+K,
    /// Cmd+Shift+K, Cmd+,) before any focused NSView (incl. ghostty
    /// surfaces) processes them. Without this, JS-side keydown handlers
    /// never fire while a terminal is focused.
    private var appShortcutMonitor: Any?
    private static let foregroundZ: CGFloat = 1_000

    func boot(resourcesRoot: String) {
        if booted { return }
        booted = true

        let ghosttyDir = (resourcesRoot as NSString).appendingPathComponent("ghostty")
        let terminfoDir = (resourcesRoot as NSString).appendingPathComponent("terminfo")
        setenv("GHOSTTY_RESOURCES_DIR", ghosttyDir, 1)
        setenv("TERMINFO_DIRS", "\(terminfoDir):/usr/share/terminfo", 1)

        ghostty_init(0, nil)

        let cfg = ghostty_config_new()
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let overrides = [
            "command=\(shell) -l",
            "term=xterm-ghostty",
            "window-padding-x=2",
            "window-padding-y=2",
            "window-padding-balance=true",
            "background-opacity=1.0",
        ].joined(separator: "\n") + "\n"

        let overrideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clome-ghostty-override.conf")
        try? overrides.write(to: overrideURL, atomically: true, encoding: .utf8)
        ghostty_config_load_file(cfg, overrideURL.path)
        ghostty_config_finalize(cfg)
        config = cfg

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { userdata in
            guard let userdata else { return }
            DispatchQueue.main.async {
                let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
                runtime.tick()
            }
        }
        runtime.action_cb = { app, target, action in
            guard let app else { return false }
            guard let userdata = ghostty_app_userdata(app) else { return false }
            let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
            return runtime.handleAction(target: target, action: action)
        }
        runtime.read_clipboard_cb = { surfaceUD, _, state in
            guard let surfaceUD else { return false }
            let terminal = Unmanaged<ClomeTerminalSurface>.fromOpaque(surfaceUD).takeUnretainedValue()
            guard let surface = terminal.surface else { return false }
            guard let string = NSPasteboard.general.string(forType: .string) else { return false }
            guard let state else { return false }
            string.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, true)
            }
            return true
        }
        runtime.confirm_read_clipboard_cb = nil
        runtime.write_clipboard_cb = { _, clipboard, contents, contentsLen, _ in
            guard clipboard == GHOSTTY_CLIPBOARD_STANDARD else { return }
            guard let contents, contentsLen > 0 else { return }
            guard let data = contents.pointee.data else { return }
            let string = String(cString: data)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        }
        runtime.close_surface_cb = nil

        app = ghostty_app_new(&runtime, cfg)
    }

    func show(tabId: String, window: NSWindow, cwd: String?, resourcesRoot: String, frame: NSRect, focus: Bool) -> Bool {
        boot(resourcesRoot: resourcesRoot)
        guard app != nil, let contentView = window.contentView else { return false }
        let clampedFrame = frame.intersection(contentView.bounds)
        guard clampedFrame.width >= 8, clampedFrame.height >= 8 else {
            hide(tabId: tabId)
            return false
        }

        let surface = surfaces[tabId] ?? {
            let next = ClomeTerminalSurface(runtime: self, id: tabId, cwd: cwd)
            surfaces[tabId] = next
            return next
        }()
        surface.restoreWorkingDirectory = cwd?.isEmpty == false ? cwd : nil

        // Only re-parent on first attach. Re-adding mid-session cancels the
        // implicit mouse grab — if the user is dragging when ResizeObserver
        // fires `show`, mouseUp goes nowhere and ghostty stays in
        // button-pressed state, turning every subsequent mouseMoved into a
        // selection drag. zPosition (set below) keeps surface drawn above
        // the WebView regardless of subview order.
        if surface.superview !== contentView {
            surface.removeFromSuperview()
            contentView.addSubview(surface, positioned: .above, relativeTo: nil)
        }
        surface.layer?.zPosition = GhosttyRuntime.foregroundZ
        surface.frame = clampedFrame
        applyOverlayClip(to: surface, window: window)
        surface.autoresizingMask = []
        surface.isHidden = false
        surface.needsLayout = true
        surface.prepareForDisplay()
        // Don't emitMetadataChanged here — show() fires on every
        // ResizeObserver tick. Real metadata changes already emit via
        // setTitle / setWorkingDirectory / commandFinished. Initial state
        // is fetched by the JS-side terminal_native_snapshot poll.

        if focus {
            window.makeFirstResponder(surface)
        }
        tick()
        return true
    }

    func hide(tabId: String) {
        guard let surface = surfaces[tabId] else { return }
        removeFromHierarchy(surface)
    }

    func hideAll() {
        for surface in surfaces.values {
            removeFromHierarchy(surface)
        }
    }

    func close(tabId: String) {
        guard let surface = surfaces.removeValue(forKey: tabId) else { return }
        surface.destroySurface()
        surface.removeFromSuperview()
    }

    func snapshot(tabId: String) -> TerminalSnapshot? {
        surfaces[tabId]?.snapshot()
    }

    func setOverlayClip(_ rect: NSRect?) {
        overlayClipWeb = rect
        for surface in surfaces.values {
            guard let window = surface.window else { continue }
            applyOverlayClip(to: surface, window: window)
        }
    }

    /// Computes a CALayer mask that excludes the overlay region (in web
    /// coords) from the surface's layer. Result: terminal stays visible
    /// everywhere except where the HTML overlay needs to paint.
    private func applyOverlayClip(to surface: ClomeTerminalSurface, window: NSWindow) {
        guard let layer = surface.layer else { return }
        guard let webRect = overlayClipWeb else {
            layer.mask = nil
            surface.isHidden = false
            return
        }

        guard let contentView = window.contentView else { return }
        let contentH = contentView.bounds.height
        // Web rect (top-left origin) → AppKit window coords (bottom-left).
        let appkitRect = NSRect(
            x: webRect.minX,
            y: contentH - webRect.maxY,
            width: webRect.width,
            height: webRect.height
        )
        // Project into surface-local coords.
        let frame = surface.frame
        let localOverlay = NSRect(
            x: appkitRect.minX - frame.minX,
            y: appkitRect.minY - frame.minY,
            width: appkitRect.width,
            height: appkitRect.height
        )
        let localBounds = NSRect(origin: .zero, size: frame.size)
        let intersected = localBounds.intersection(localOverlay)

        if intersected.isEmpty {
            // Overlay misses this surface entirely — nothing to mask.
            layer.mask = nil
            surface.isHidden = false
            return
        }
        if intersected.equalTo(localBounds) {
            // Overlay fully covers — cheaper to hide than mask.
            layer.mask = nil
            surface.isHidden = true
            return
        }

        // Even-odd fill: outer rect + hole. Areas under the hole render
        // transparent in the mask, so the layer doesn't composite there
        // and HTML below shows through.
        let path = CGMutablePath()
        path.addRect(localBounds)
        path.addRect(intersected)
        let mask = CAShapeLayer()
        mask.frame = localBounds
        mask.path = path
        mask.fillRule = .evenOdd
        layer.mask = mask
        surface.isHidden = false
    }

    func installAppShortcutMonitor() {
        if appShortcutMonitor != nil { return }
        appShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let cmd: NSEvent.ModifierFlags = .command
            let cmdShift: NSEvent.ModifierFlags = [.command, .shift]
            let shortcut: String? = {
                if mods == cmd && key == "k" { return "cmd+k" }
                if mods == cmdShift && key == "k" { return "cmd+shift+k" }
                if mods == cmd && key == "," { return "cmd+," }
                return nil
            }()
            guard let shortcut else { return event }
            shortcut.withCString { ptr in
                clome_app_shortcut_event(ptr)
            }
            return nil
        }
    }

    /// Pre-warms the heavy ghostty initialization (config load, GPU
    /// pipeline, font atlas) so the first user-visible terminal attach
    /// is sub-frame instead of multi-hundred-millisecond.
    func prewarm(resourcesRoot: String) {
        boot(resourcesRoot: resourcesRoot)
    }

    private func removeFromHierarchy(_ surface: ClomeTerminalSurface) {
        surface.isHidden = true
        surface.frame = .zero
        surface.removeFromSuperview()
    }

    fileprivate func makeSurfaceConfig(for view: ClomeTerminalSurface) -> ghostty_surface_config_s {
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
        cfg.userdata = Unmanaged.passUnretained(view).toOpaque()
        cfg.scale_factor = Double(view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
        cfg.font_size = 0
        cfg.context = GHOSTTY_SURFACE_CONTEXT_SPLIT
        return cfg
    }

    fileprivate var ghosttyApp: ghostty_app_t? { app }

    private func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    private func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            if let titlePtr = action.action.set_title.title {
                let title = String(cString: titlePtr)
                surface(for: target)?.setTitle(title)
            }
            return true
        case GHOSTTY_ACTION_PWD:
            if let pwdPtr = action.action.pwd.pwd {
                surface(for: target)?.setWorkingDirectory(String(cString: pwdPtr))
            }
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            if let bodyPtr = action.action.desktop_notification.body {
                let body = String(cString: bodyPtr)
                let title = action.action.desktop_notification.title.map { String(cString: $0) } ?? "Clome"
                let notification = UNMutableNotificationContent()
                notification.title = title
                notification.body = body
                UNUserNotificationCenter.current().add(
                    UNNotificationRequest(
                        identifier: UUID().uuidString,
                        content: notification,
                        trigger: nil
                    )
                )
            }
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            if let urlPtr = action.action.open_url.url,
               let url = URL(string: String(cString: urlPtr)) {
                NSWorkspace.shared.open(url)
            }
            return true
        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
            return true
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            surface(for: target)?.commandFinished(
                exitCode: action.action.command_finished.exit_code,
                duration: action.action.command_finished.duration
            )
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

    private func surface(for target: ghostty_target_s) -> ClomeTerminalSurface? {
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return nil }
        let targetSurface = target.target.surface
        return surfaces.values.first { $0.surface == targetSurface }
    }
}

private struct TerminalSnapshot {
    let title: String?
    let workingDirectory: String?
    let running: Bool
    let exitCode: Int16
    let duration: UInt64
}

private final class ClomeTerminalSurface: NSView {
    fileprivate var surface: ghostty_surface_t?
    fileprivate weak var runtime: GhosttyRuntime?
    fileprivate let id: String
    fileprivate var restoreWorkingDirectory: String?
    fileprivate var title = "Terminal"
    fileprivate var workingDirectory: String?
    private var running = false
    private var lastExitCode: Int16 = -1
    private var lastCommandDuration: UInt64 = 0
    private var trackingAreaRef: NSTrackingArea?
    private var needsSurfaceCreation = false
    // Dedup: shells emit `\033]0;...` title escapes per prompt redraw.
    // Forwarding identical metadata to JS triggers a re-render storm
    // (3 store setters × N events/sec) that starves the UI event loop.
    private var hasEmittedMetadata = false
    private var lastEmittedTitle = ""
    private var lastEmittedCwd = ""
    private var lastEmittedRunning = false
    private var lastEmittedExitCode: Int16 = 0
    private var lastEmittedDuration: UInt64 = 0

    init(runtime: GhosttyRuntime, id: String, cwd: String?) {
        self.runtime = runtime
        self.id = id
        self.restoreWorkingDirectory = cwd?.isEmpty == false ? cwd : nil
        self.workingDirectory = cwd?.isEmpty == false
            ? cwd
            : FileManager.default.homeDirectoryForCurrentUser.path
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    fileprivate func setTitle(_ nextTitle: String) {
        title = nextTitle
        if titleLooksProcessLike(nextTitle) {
            running = true
            lastExitCode = -1
            lastCommandDuration = 0
        }
        emitMetadataChanged()
    }

    fileprivate func setWorkingDirectory(_ nextWorkingDirectory: String) {
        workingDirectory = nextWorkingDirectory
        if !titleLooksProcessLike(title) {
            running = false
        }
        emitMetadataChanged()
    }

    fileprivate func commandFinished(exitCode: Int16, duration: UInt64) {
        running = false
        lastExitCode = exitCode
        lastCommandDuration = duration
        emitMetadataChanged()
    }

    fileprivate func emitMetadataChanged() {
        let cwdValue = workingDirectory ?? ""
        if hasEmittedMetadata
            && title == lastEmittedTitle
            && cwdValue == lastEmittedCwd
            && running == lastEmittedRunning
            && lastExitCode == lastEmittedExitCode
            && lastCommandDuration == lastEmittedDuration {
            return
        }
        hasEmittedMetadata = true
        lastEmittedTitle = title
        lastEmittedCwd = cwdValue
        lastEmittedRunning = running
        lastEmittedExitCode = lastExitCode
        lastEmittedDuration = lastCommandDuration

        id.withCString { idPtr in
            title.withCString { titlePtr in
                cwdValue.withCString { cwdPtr in
                    clome_terminal_metadata_event(
                        idPtr,
                        titlePtr,
                        cwdPtr,
                        running ? 1 : 0,
                        lastExitCode,
                        lastCommandDuration
                    )
                }
            }
        }
    }

    fileprivate func snapshot() -> TerminalSnapshot {
        TerminalSnapshot(
            title: title.isEmpty ? nil : title,
            workingDirectory: workingDirectory,
            running: running,
            exitCode: lastExitCode,
            duration: lastCommandDuration
        )
    }

    private func titleLooksProcessLike(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        let lower = trimmed.lowercased()
        if ["terminal", "zsh", "bash", "fish", "sh", "login", "shell"].contains(lower) {
            return false
        }
        if lower.contains("@") && lower.contains(":") {
            return false
        }
        if lower.hasPrefix("/") || lower.hasPrefix("~") {
            return false
        }
        if let workingDirectory, trimmed.contains(workingDirectory) {
            return false
        }
        if let cwdName = workingDirectory.map({ URL(fileURLWithPath: $0).lastPathComponent.lowercased() }),
           cwdName == lower {
            return false
        }
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && surface == nil {
            needsSurfaceCreation = true
            prepareForDisplay()
        }
    }

    override func layout() {
        super.layout()
        ensureSurfaceReady()
        syncSurfaceSize()
    }

    fileprivate func prepareForDisplay() {
        if surface == nil {
            needsSurfaceCreation = true
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        ensureSurfaceReady()
        syncSurfaceSize()
        needsDisplay = true
    }

    private func ensureSurfaceReady() {
        guard needsSurfaceCreation && window != nil && surface == nil else { return }
        let backingSize = convertToBacking(bounds.size)
        if backingSize.width >= 100 && backingSize.height >= 50 {
            needsSurfaceCreation = false
            createSurface()
        }
    }

    private func syncSurfaceSize() {
        guard let surface else { return }
        let scaleFactor = window?.backingScaleFactor ?? 2.0
        let size = convertToBacking(bounds.size)
        guard size.width >= 1 && size.height >= 1 else { return }
        ghostty_surface_set_content_scale(surface, scaleFactor, scaleFactor)
        ghostty_surface_set_size(surface, UInt32(size.width), UInt32(size.height))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface {
            ghostty_surface_set_focus(surface, true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, let surface {
            ghostty_surface_set_focus(surface, false)
        }
        return result
    }

    private func createSurface() {
        guard surface == nil else { return }
        guard let runtime, let app = runtime.ghosttyApp else { return }
        var cfg = runtime.makeSurfaceConfig(for: self)
        let wd = restoreWorkingDirectory.map { $0 as NSString }
        cfg.working_directory = wd?.utf8String
        surface = ghostty_surface_new(app, &cfg)
        withExtendedLifetime(wd) {}
        if surface != nil {
            syncSurfaceSize()
        }
    }

    fileprivate func destroySurface() {
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              let surface,
              window?.firstResponder === self,
              event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }

        // Multiplexer shortcuts intercepted before ghostty sees them. We
        // match on the keyCode (layout-independent) + modifier set so
        // alt/option layouts don't break the binding.
        let mods = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let cmd: NSEvent.ModifierFlags = .command
        let cmdShift: NSEvent.ModifierFlags = [.command, .shift]
        let key = event.keyCode
        let shortcut: String? = {
            if mods == cmd && key == 0x02 { return "split-right" }   // Cmd+D
            if mods == cmdShift && key == 0x02 { return "split-down" } // Cmd+Shift+D
            if mods == cmd && key == 0x0D { return "close-pane" }     // Cmd+W (closes pane; falls back to tab if last pane)
            if mods == cmdShift && key == 0x0D { return "close-pane" } // Cmd+Shift+W (also)
            if mods == cmd && key == 0x11 { return "new-terminal" }   // Cmd+T
            if mods == cmd && key == 0x21 { return "focus-prev" }     // Cmd+[
            if mods == cmd && key == 0x1E { return "focus-next" }     // Cmd+]
            return nil
        }()
        if let shortcut {
            id.withCString { idPtr in
                shortcut.withCString { sPtr in
                    clome_terminal_shortcut_event(idPtr, sPtr)
                }
            }
            return true
        }

        var input = ghostty_input_key_s()
        input.action = GHOSTTY_ACTION_PRESS
        input.mods = translateMods(event.modifierFlags)
        input.keycode = UInt32(event.keyCode)
        input.composing = false
        input.consumed_mods = translateMods(event.modifierFlags.subtracting([.control, .command]))
        if let chars = event.characters(byApplyingModifiers: []),
           let codepoint = chars.unicodeScalars.first {
            input.unshifted_codepoint = codepoint.value
        }

        var flags = ghostty_binding_flags_e(0)
        if ghostty_surface_key_is_binding(surface, input, &flags) {
            keyDown(with: event)
            return true
        }
        return false
    }

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            super.keyDown(with: event)
            return
        }
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        var input = ghostty_input_key_s()
        input.action = action
        input.mods = translateMods(event.modifierFlags)
        input.keycode = UInt32(event.keyCode)
        input.composing = false
        input.consumed_mods = translateMods(event.modifierFlags.subtracting([.control, .command]))
        if let chars = event.characters(byApplyingModifiers: []),
           let codepoint = chars.unicodeScalars.first {
            input.unshifted_codepoint = codepoint.value
        }

        let text: String? = {
            guard let characters = event.characters else { return nil }
            if characters.count == 1, let scalar = characters.unicodeScalars.first {
                if scalar.value < 0x20 {
                    return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
                }
                if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                    return nil
                }
            }
            return characters
        }()

        if let text, !text.isEmpty, let first = text.utf8.first, first >= 0x20 {
            text.withCString { ptr in
                input.text = ptr
                ghostty_surface_key(surface, input)
            }
        } else {
            ghostty_surface_key(surface, input)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        var input = ghostty_input_key_s()
        input.action = GHOSTTY_ACTION_RELEASE
        input.mods = translateMods(event.modifierFlags)
        input.keycode = UInt32(event.keyCode)
        input.consumed_mods = translateMods(event.modifierFlags.subtracting([.control, .command]))
        if let chars = event.characters(byApplyingModifiers: []),
           let codepoint = chars.unicodeScalars.first {
            input.unshifted_codepoint = codepoint.value
        }
        ghostty_surface_key(surface, input)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface else { return }
        var input = ghostty_input_key_s()
        input.mods = translateMods(event.modifierFlags)
        input.keycode = UInt32(event.keyCode)
        input.action = event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty
            ? GHOSTTY_ACTION_RELEASE
            : GHOSTTY_ACTION_PRESS
        ghostty_surface_key(surface, input)
    }

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        window?.makeFirstResponder(self)
        id.withCString { idPtr in
            clome_terminal_focus_event(idPtr)
        }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, translateMods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, translateMods(event.modifierFlags))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, translateMods(event.modifierFlags))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, translateMods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, frame.height - point.y, translateMods(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var mods: Int32 = 0
        if event.hasPreciseScrollingDeltas { mods |= 1 }
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, mods)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let types = sender.draggingPasteboard.types ?? []
        let accepted: Set<NSPasteboard.PasteboardType> = [.fileURL, .URL, .string]
        return Set(types).isDisjoint(with: accepted) ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let surface else { return false }
        let pb = sender.draggingPasteboard
        let text: String?
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            text = urls.map { shellEscape($0.path) }.joined(separator: " ")
        } else if let urlString = pb.string(forType: .URL) {
            text = shellEscape(urlString)
        } else {
            text = pb.string(forType: .string)
        }
        guard let text, !text.isEmpty else { return false }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
        return true
    }

    private func translateMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = 0
        if flags.contains(.shift) { mods |= UInt32(GHOSTTY_MODS_SHIFT.rawValue) }
        if flags.contains(.control) { mods |= UInt32(GHOSTTY_MODS_CTRL.rawValue) }
        if flags.contains(.option) { mods |= UInt32(GHOSTTY_MODS_ALT.rawValue) }
        if flags.contains(.command) { mods |= UInt32(GHOSTTY_MODS_SUPER.rawValue) }
        if flags.contains(.capsLock) { mods |= UInt32(GHOSTTY_MODS_CAPS.rawValue) }
        return ghostty_input_mods_e(rawValue: mods)
    }

    private func shellEscape(_ path: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/-_.~"))
        if path.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return path
        }
        return "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

@_cdecl("clome_ghostty_show")
public func clome_ghostty_show(
    _ nsWindowRaw: UnsafeMutableRawPointer?,
    _ tabIdRaw: UnsafePointer<CChar>?,
    _ cwdRaw: UnsafePointer<CChar>?,
    _ resourcesRootRaw: UnsafePointer<CChar>?,
    _ x: Double,
    _ y: Double,
    _ width: Double,
    _ height: Double,
    _ focus: Bool
) -> Bool {
    guard let nsWindowRaw, let tabIdRaw, let resourcesRootRaw else { return false }
    let windowAddress = UInt(bitPattern: nsWindowRaw)
    let tabId = String(cString: tabIdRaw)
    let cwd = cwdRaw.map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
    let resourcesRoot = String(cString: resourcesRootRaw)

    return runOnMain {
        guard let raw = UnsafeRawPointer(bitPattern: windowAddress) else { return false }
        let window = Unmanaged<NSWindow>.fromOpaque(raw).takeUnretainedValue()
        guard let contentView = window.contentView else { return false }
        let contentHeight = contentView.bounds.height
        let frame = NSRect(
            x: x,
            y: max(0, contentHeight - y - height),
            width: max(1, width),
            height: max(1, height)
        )
        return GhosttyRuntime.shared.show(
            tabId: tabId,
            window: window,
            cwd: cwd,
            resourcesRoot: resourcesRoot,
            frame: frame,
            focus: focus
        )
    }
}

@_cdecl("clome_ghostty_hide")
public func clome_ghostty_hide(_ tabIdRaw: UnsafePointer<CChar>?) {
    guard let tabIdRaw else { return }
    let tabId = String(cString: tabIdRaw)
    runOnMain {
        GhosttyRuntime.shared.hide(tabId: tabId)
    }
}

@_cdecl("clome_ghostty_close")
public func clome_ghostty_close(_ tabIdRaw: UnsafePointer<CChar>?) {
    guard let tabIdRaw else { return }
    let tabId = String(cString: tabIdRaw)
    runOnMain {
        GhosttyRuntime.shared.close(tabId: tabId)
    }
}

@_cdecl("clome_ghostty_hide_all")
public func clome_ghostty_hide_all() {
    runOnMain {
        GhosttyRuntime.shared.hideAll()
    }
}

@_cdecl("clome_ghostty_set_overlay_clip")
public func clome_ghostty_set_overlay_clip(
    _ hasRect: Bool,
    _ x: Double,
    _ y: Double,
    _ w: Double,
    _ h: Double
) {
    runOnMain {
        let rect: NSRect? = hasRect
            ? NSRect(x: x, y: y, width: max(0, w), height: max(0, h))
            : nil
        GhosttyRuntime.shared.setOverlayClip(rect)
    }
}

@_cdecl("clome_ghostty_install_app_shortcuts")
public func clome_ghostty_install_app_shortcuts() {
    runOnMain {
        GhosttyRuntime.shared.installAppShortcutMonitor()
    }
}

@_cdecl("clome_ghostty_prewarm")
public func clome_ghostty_prewarm(_ resourcesRootRaw: UnsafePointer<CChar>?) {
    guard let resourcesRootRaw else { return }
    let resourcesRoot = String(cString: resourcesRootRaw)
    runOnMain {
        GhosttyRuntime.shared.prewarm(resourcesRoot: resourcesRoot)
    }
}

@_cdecl("clome_window_set_traffic_lights_hidden")
public func clome_window_set_traffic_lights_hidden(
    _ nsWindowRaw: UnsafeMutableRawPointer?,
    _ hidden: Bool
) {
    guard let nsWindowRaw else { return }
    let windowAddress = UInt(bitPattern: nsWindowRaw)
    runOnMain {
        guard let raw = UnsafeRawPointer(bitPattern: windowAddress) else { return }
        let window = Unmanaged<NSWindow>.fromOpaque(raw).takeUnretainedValue()
        for kind in [NSWindow.ButtonType.closeButton,
                     .miniaturizeButton,
                     .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = hidden
        }
    }
}

@_cdecl("clome_ghostty_snapshot")
public func clome_ghostty_snapshot(
    _ tabIdRaw: UnsafePointer<CChar>?,
    _ titleBuffer: UnsafeMutablePointer<CChar>?,
    _ titleCapacity: Int,
    _ cwdBuffer: UnsafeMutablePointer<CChar>?,
    _ cwdCapacity: Int,
    _ runningOut: UnsafeMutablePointer<UInt8>?,
    _ exitCodeOut: UnsafeMutablePointer<Int16>?,
    _ durationOut: UnsafeMutablePointer<UInt64>?
) -> Bool {
    guard let tabIdRaw else { return false }
    let tabId = String(cString: tabIdRaw)
    return runOnMain {
        guard let snapshot = GhosttyRuntime.shared.snapshot(tabId: tabId) else {
            copyCString(nil, to: titleBuffer, capacity: titleCapacity)
            copyCString(nil, to: cwdBuffer, capacity: cwdCapacity)
            runningOut?.pointee = 0
            exitCodeOut?.pointee = -1
            durationOut?.pointee = 0
            return false
        }
        copyCString(snapshot.title, to: titleBuffer, capacity: titleCapacity)
        copyCString(snapshot.workingDirectory, to: cwdBuffer, capacity: cwdCapacity)
        runningOut?.pointee = snapshot.running ? 1 : 0
        exitCodeOut?.pointee = snapshot.exitCode
        durationOut?.pointee = snapshot.duration
        return true
    }
}
