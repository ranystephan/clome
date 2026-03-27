import AppKit
import QuartzCore

/// An NSView that hosts a single Ghostty terminal surface.
/// This is the core rendering view for terminal content.
class TerminalSurface: NSView {
    private(set) var surface: ghostty_surface_t?
    private weak var ghosttyApp: GhosttyAppManager?
    private var trackingArea: NSTrackingArea?

    var title: String = "Terminal" {
        didSet {
            detectProgram()
            NotificationCenter.default.post(name: .terminalSurfaceTitleChanged, object: self)
        }
    }

    /// Current working directory (updated via OSC 7 or pwd action from ghostty).
    var workingDirectory: String? {
        didSet {
            if let wd = workingDirectory {
                gitBranch = TerminalSurface.detectGitBranch(at: wd)
                shortPath = TerminalSurface.shortenPath(wd)
            }
        }
    }

    /// Git branch detected from working directory.
    var gitBranch: String?

    /// Shortened display path (e.g. ~/desktop/clome).
    var shortPath: String?

    /// Detected foreground program name (e.g. "Claude Code", "vim", "node").
    var detectedProgram: String?

    /// SF Symbol for the detected program.
    var programIcon: String = "terminal"

    /// Whether a command is currently running (vs shell idle).
    var isCommandRunning: Bool = false

    /// Last notification body received from this terminal.
    var lastNotification: String?

    /// Last few lines of visible terminal output (for preview).
    var outputPreview: String?

    /// Whether this terminal needs user attention (e.g. Claude Code waiting for input).
    var needsAttention: Bool = false

    /// Per-surface command override (e.g. a restore wrapper script). Set before the surface is added to a window.
    var restoreCommand: String?

    /// Per-surface working directory override. Set before the surface is added to a window.
    var restoreWorkingDirectory: String?

    /// Claude Code session ID if this terminal was launched to resume a session.
    var claudeSessionId: String?

    init(ghosttyApp: GhosttyAppManager) {
        self.ghosttyApp = ghosttyApp
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = AppearanceSettings.shared.backgroundBgColor.cgColor

        // Register for file/text drag and drop
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && surface == nil {
            // Defer surface creation to layout() so the view has a real
            // frame size.  Creating the surface while the frame is still
            // zero triggers Ghostty's "very small terminal grid detected
            // with padding set" warning twice (once for columns, once for
            // rows).
            needsSurfaceCreation = true
            needsLayout = true
        }
    }

    /// Set when the view is added to a window but the frame is not yet sized.
    private var needsSurfaceCreation = false

    override func layout() {
        super.layout()

        // Create the surface on the first layout pass that gives us a
        // reasonable frame (at least 100x50 backing pixels ≈ a few cells).
        if needsSurfaceCreation && window != nil && surface == nil {
            let backingSize = convertToBacking(bounds.size)
            if backingSize.width >= 100 && backingSize.height >= 50 {
                needsSurfaceCreation = false
                createSurface()
            }
        }

        guard let surface else { return }
        let scaleFactor = window?.backingScaleFactor ?? 2.0
        let size = convertToBacking(bounds.size)
        ghostty_surface_set_content_scale(surface, scaleFactor, scaleFactor)
        ghostty_surface_set_size(surface, UInt32(size.width), UInt32(size.height))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface {
            ghostty_surface_set_focus(surface, true)
        }
        if result {
            NotificationCenter.default.post(name: .terminalSurfaceFocused, object: self)
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

    // MARK: - Surface Creation

    private func createSurface() {
        guard let app = ghosttyApp, let ghosttyAppInstance = app.app else { return }

        var cfg = app.makeSurfaceConfig(for: self)

        // Hold NSString references so their .utf8String pointers stay valid
        // through the ghostty_surface_new call.
        let wdNS = restoreWorkingDirectory.map { $0 as NSString }
        let cmdNS = restoreCommand.map { $0 as NSString }
        cfg.working_directory = wdNS?.utf8String
        cfg.command = cmdNS?.utf8String

        surface = ghostty_surface_new(ghosttyAppInstance, &cfg)

        // prevent the compiler from releasing the NSStrings before this point
        withExtendedLifetime((wdNS, cmdNS)) {}

        if surface != nil {
            // Trigger initial layout
            layout()
            // Register with activity monitor
            TerminalActivityMonitor.shared.register(self)
        }

        // Clear restore properties after use
        restoreCommand = nil
        restoreWorkingDirectory = nil
    }

    func destroySurface() {
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
        }
    }

    // MARK: - Keyboard Input

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              let surface,
              window?.firstResponder === self,
              event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }

        // Build input struct for ghostty binding check
        var input = ghostty_input_key_s()
        input.action = GHOSTTY_ACTION_PRESS
        input.mods = translateMods(event.modifierFlags)
        input.keycode = UInt32(event.keyCode)
        input.composing = false

        let consumedFlags = event.modifierFlags.subtracting([.control, .command])
        input.consumed_mods = translateMods(consumedFlags)

        if let chars = event.characters(byApplyingModifiers: []),
           let codepoint = chars.unicodeScalars.first {
            input.unshifted_codepoint = codepoint.value
        }

        // Ask ghostty if it has a binding for this key combo
        var flags = ghostty_binding_flags_e(0)
        if ghostty_surface_key_is_binding(surface, input, &flags) {
            self.keyDown(with: event)
            return true
        }

        // Not a ghostty binding — let AppKit/menu handle it
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

        // consumed_mods: control and command never contribute to text translation
        // (matches ghostty's NSEvent+Extension heuristic)
        let consumedFlags = event.modifierFlags.subtracting([.control, .command])
        input.consumed_mods = translateMods(consumedFlags)

        // unshifted_codepoint: the character with no modifiers applied,
        // needed for ghostty keybinding matching (e.g. super+c → copy)
        if event.type == .keyDown || event.type == .keyUp {
            if let chars = event.characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first {
                input.unshifted_codepoint = codepoint.value
            }
        }

        // Build text, matching ghostty's approach:
        // - Control characters (< 0x20): skip text so ghostty handles encoding
        // - PUA characters (U+F700–U+F8FF): skip (macOS function key virtuals)
        // - Everything else: pass as text
        let text: String? = {
            guard let characters = event.characters else { return nil }
            if characters.count == 1, let scalar = characters.unicodeScalars.first {
                if scalar.value < 0x20 {
                    // Control character — let ghostty encode it from the keycode
                    return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
                }
                if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                    return nil
                }
            }
            return characters
        }()

        if let text, !text.isEmpty,
           let first = text.utf8.first, first >= 0x20 {
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
        let consumedFlags = event.modifierFlags.subtracting([.control, .command])
        input.consumed_mods = translateMods(consumedFlags)
        if let chars = event.characters(byApplyingModifiers: []),
           let codepoint = chars.unicodeScalars.first {
            input.unshifted_codepoint = codepoint.value
        }
        ghostty_surface_key(surface, input)
    }

    override func flagsChanged(with event: NSEvent) {
        // Handle modifier key changes
        guard let surface else { return }
        var input = ghostty_input_key_s()
        input.mods = translateMods(event.modifierFlags)
        input.keycode = UInt32(event.keyCode)
        input.action = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.control) ||
                       event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command)
                       ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        ghostty_surface_key(surface, input)
    }

    // MARK: - Mouse Input

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        window?.makeFirstResponder(self)
        let mods = translateMods(event.modifierFlags)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        let mods = translateMods(event.modifierFlags)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return }
        let mods = translateMods(event.modifierFlags)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        let mods = translateMods(event.modifierFlags)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        let mods = translateMods(event.modifierFlags)
        ghostty_surface_mouse_pos(surface, point.x, frame.height - point.y, mods)
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

    // MARK: - Key Translation

    private func translateKey(_ event: NSEvent) -> ghostty_input_key_e {
        // Map common keys. libghostty does most translation internally
        // via the keycode, so we primarily pass through.
        return GHOSTTY_KEY_UNIDENTIFIED
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

    // MARK: - Activity Detection

    /// Terminal activity state detected from output content.
    enum ActivityState {
        case idle           // Shell prompt visible, nothing running
        case running        // Command/program actively producing output
        case waitingInput   // Interactive program waiting for user input (e.g. Claude Code prompt)
        case completed      // Command just finished, showing result
    }

    /// Claude Code specific state detected from terminal output patterns.
    enum ClaudeCodeState {
        case thinking           // Claude is thinking (spinners, "(thinking)" text)
        case doneWithTask      // Claude completed a task (⏺ response marker)
        case awaitingSelection // Claude showing selection menu (Enter to select)
        case awaitingPermission // Claude asking for permission (Do you want to allow...)
    }

    /// Current detected activity state.
    var activityState: ActivityState = .idle
    
    /// Current Claude Code specific state (only set when detectedProgram == "Claude Code").
    var claudeCodeState: ClaudeCodeState?

    private func detectProgram() {
        let lower = title.lowercased()

        if lower.contains("claude") {
            detectedProgram = "Claude Code"
            // Keep a neutral icon; Claude renders its own brand glyph in the title text.
            programIcon = "terminal"
        } else if lower.contains("vim") || lower.contains("nvim") || lower.contains("neovim") {
            detectedProgram = "Vim"
            programIcon = "doc.text.fill"
        } else if lower.contains("htop") || lower.contains("top ") || lower == "top" {
            detectedProgram = "htop"
            programIcon = "chart.bar.fill"
        } else if lower.contains("python") {
            detectedProgram = "Python"
            programIcon = "chevron.left.forwardslash.chevron.right"
        } else if lower.contains("node") || lower.contains("npm") || lower.contains("yarn") || lower.contains("pnpm") {
            detectedProgram = "Node.js"
            programIcon = "chevron.left.forwardslash.chevron.right"
        } else if lower.contains("cargo") || lower.contains("rustc") {
            detectedProgram = "Cargo"
            programIcon = "hammer.fill"
        } else if lower.contains("docker") {
            detectedProgram = "Docker"
            programIcon = "shippingbox.fill"
        } else if lower.contains("ssh") {
            detectedProgram = "SSH"
            programIcon = "network"
        } else if lower.contains("git") && !lower.contains("digital") {
            detectedProgram = "Git"
            programIcon = "arrow.triangle.branch"
        } else if lower.contains("make") || lower.contains("cmake") || lower.contains("xcodebuild") || lower.contains("zig build") {
            detectedProgram = "Build"
            programIcon = "hammer.fill"
        } else {
            detectedProgram = nil
            programIcon = "terminal"
        }
    }

    /// Read the entire scrollback buffer + visible screen as a single string.
    func readFullScrollback() -> String? {
        guard let surface else { return nil }

        // Use GHOSTTY_POINT_SCREEN to capture the full scrollback history
        var selection = ghostty_selection_s()
        selection.top_left = ghostty_point_s(
            tag: GHOSTTY_POINT_SCREEN,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        selection.bottom_right = ghostty_point_s(
            tag: GHOSTTY_POINT_SCREEN,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 999,
            y: UInt32.max / 2  // Large value to capture all scrollback
        )
        selection.rectangle = false

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text),
              let ptr = text.text, text.text_len > 0 else { return nil }

        let rawStr = String(cString: ptr)
        ghostty_surface_free_text(surface, &text)

        // Strip trailing blank lines to reduce file size
        let lines = rawStr.split(separator: "\n", omittingEmptySubsequences: false)
        let trimmed = lines.reversed()
            .drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            .reversed()
        return trimmed.joined(separator: "\n")
    }

    /// Read the full visible terminal viewport as a single string.
    private func readViewportText() -> String? {
        guard let surface else { return nil }

        let size = ghostty_surface_size(surface)
        let rows = size.height_px / max(size.cell_height_px, 1)
        guard rows > 0 else { return nil }

        var selection = ghostty_selection_s()
        selection.top_left = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        selection.bottom_right = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 999,
            y: UInt32(rows - 1)
        )
        selection.rectangle = false

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text),
              let ptr = text.text, text.text_len > 0 else { return nil }

        let rawStr = String(cString: ptr)
        ghostty_surface_free_text(surface, &text)
        return rawStr
    }

    /// Read visible terminal text and derive status + preview from content.
    func readOutputAndDetectState() {
        guard let rawStr = readViewportText() else { return }

        // Strip ANSI escape codes
        let stripped = Self.stripAnsiCodes(rawStr)

        // Split into meaningful lines
        let allLines = stripped.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // Find the last non-empty lines (skip trailing blanks)
        let meaningfulLines = allLines.reversed()
            .drop(while: { $0.isEmpty })
            .reversed()
            .suffix(6)
            .map { String($0) }

        guard !meaningfulLines.isEmpty else {
            activityState = .idle
            outputPreview = nil
            return
        }

        let lastLine = meaningfulLines.last ?? ""
        let lastFewLines = Array(meaningfulLines)

        // ── Detect state from content ──
        detectStateFromContent(lastLine: lastLine, lines: lastFewLines)

        // ── Build a clean preview ──
        buildPreview(from: lastFewLines)
    }

    /// Previous output snapshot for change detection.
    private var previousOutputSnapshot: String?

    /// Tracks whether output has changed between polls (= actively producing output).
    var outputIsChanging: Bool = false

    /// Timestamp of last detected running state (for grace period).
    private var lastRunningTimestamp: Date?

    private func detectStateFromContent(lastLine: String, lines: [String]) {
        let lower = lastLine.lowercased()

        // Detect if output is actively changing (something is producing text)
        // while ignoring cursor blink artifacts.
        let currentSnapshot = lines
            .suffix(4)
            .map { Self.normalizeLineForActivityComparison($0) }
            .joined(separator: "\n")
        outputIsChanging = (previousOutputSnapshot != nil && previousOutputSnapshot != currentSnapshot)
        previousOutputSnapshot = currentSnapshot

        // Detect Claude Code specific states when Claude Code is running
        if detectedProgram == "Claude Code" {
            claudeCodeState = detectClaudeCodeState(lastLine: lastLine, lines: lines)
        } else {
            claudeCodeState = nil
        }

        if Self.isShellPrompt(lastLine) {
            activityState = .idle
            needsAttention = false
        } else if lower.contains("press") || lower.contains("enter") || lower.contains("(y/n)")
                    || lower.contains("[y/n]") || lower.contains("continue?") {
            activityState = .waitingInput
            needsAttention = true
        } else if outputIsChanging {
            activityState = .running
            needsAttention = false
        } else {
            activityState = .idle
            needsAttention = false
        }
    }

    /// Remove cursor glyph artifacts from a line so blinking cursors do not
    /// look like meaningful output changes.
    private static func normalizeLineForActivityComparison(_ line: String) -> String {
        line
            .replacingOccurrences(of: "[▌▋▊▉█▐▍▎▏_]+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Check if a line looks like a shell prompt (zsh, bash, fish, etc.).
    private static func isShellPrompt(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }

        // Common prompt endings
        let promptEndings = ["$ ", "% ", "# ", "❯ ", "➜ ", "→ ", "λ "]
        for ending in promptEndings {
            if trimmed.hasSuffix(ending) { return true }
        }

        // Bare prompt characters at the end
        if trimmed == "$" || trimmed == "%" || trimmed == "#" || trimmed == "❯" || trimmed == "➜" {
            return true
        }

        // user@host:path$ pattern
        if trimmed.contains("@") && (trimmed.hasSuffix("$") || trimmed.hasSuffix("%") || trimmed.hasSuffix("#")) {
            return true
        }

        return false
    }

    /// Check if a line is TUI chrome (box-drawing, borders, input fields, decorations).
    private static func isTUIChrome(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }

        // Count how many characters are box-drawing / decorative vs normal text
        let boxChars: Set<Character> = [
            "─", "━", "│", "┃", "┌", "┐", "└", "┘", "├", "┤", "┬", "┴", "┼",
            "╔", "╗", "╚", "╝", "╠", "╣", "╦", "╩", "╬", "║", "═",
            "╭", "╮", "╯", "╰", "╱", "╲",
            "▔", "▁", "▏", "▕", "▐", "▌",
            "█", "▓", "▒", "░",
            "○", "◆", "◇", "◉", "◎",
            "…",
            "⎯", "⎸", "⎹",
        ]
        let letterCount = trimmed.filter { $0.isLetter || $0.isNumber }.count
        let boxCount = trimmed.filter { boxChars.contains($0) }.count

        // If line is mostly box-drawing characters, it's TUI chrome
        if boxCount > 0 && letterCount == 0 { return true }
        if trimmed.count > 3 && boxCount > trimmed.count / 2 { return true }

        // Lines that are just repeated dashes, underscores, or equals
        let stripped = trimmed.filter { $0 != " " }
        if stripped.count > 2 && stripped.allSatisfy({ "─━-_=~".contains($0) }) { return true }

        return false
    }

    private func buildPreview(from lines: [String]) {
        // Filter out noisy lines for preview
        let filtered = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return false }
            if Self.isShellPrompt(trimmed) { return false }
            if Self.isTUIChrome(trimmed) { return false }
            // Skip very short lines that are just cursor artifacts
            if trimmed.count <= 1 && !trimmed.contains(where: { $0.isLetter }) { return false }
            return true
        }

        if filtered.isEmpty {
            outputPreview = nil
            return
        }

        // Take the last 2-3 meaningful lines, truncated for sidebar width
        let previewLines = filtered.suffix(3).map { line -> String in
            if line.count > 60 {
                return String(line.prefix(57)) + "..."
            }
            return line
        }
        outputPreview = previewLines.joined(separator: "\n")
    }

    /// Strip ANSI escape codes from terminal text.
    private static func stripAnsiCodes(_ str: String) -> String {
        // Match ESC[ ... (letter) sequences and OSC sequences
        let esc = "\u{1b}"
        let bel = "\u{07}"
        let pattern = "\(esc)\\[[0-9;]*[A-Za-z]|\(esc)\\][^\(bel)]*\(bel)|\(esc)\\[\\?[0-9;]*[A-Za-z]|\(esc)[()][A-Z0-9]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return str }
        let range = NSRange(str.startIndex..., in: str)
        return regex.stringByReplacingMatches(in: str, options: [], range: range, withTemplate: "")
    }

    /// Status text for sidebar display.
    var statusText: String {
        switch activityState {
        case .idle:
            return "Idle"
        case .running:
            return "Running"
        case .waitingInput:
            return "Needs input"
        case .completed:
            return "Completed"
        }
    }

    /// Status icon for sidebar display.
    var statusIcon: String {
        switch activityState {
        case .idle: return "circle.fill"
        case .running: return "bolt.fill"
        case .waitingInput: return "questionmark.circle.fill"
        case .completed: return "checkmark.circle.fill"
        }
    }

    /// Status color for sidebar display.
    var statusColor: NSColor {
        switch activityState {
        case .idle: return NSColor(white: 0.4, alpha: 1.0)
        case .running: return NSColor.systemGreen
        case .waitingInput: return NSColor.systemYellow
        case .completed: return NSColor.systemBlue
        }
    }

    // MARK: - Utilities

    static func detectGitBranch(at path: String) -> String? {
        var current = path
        while current != "/" {
            let headPath = "\(current)/.git/HEAD"
            if let contents = try? String(contentsOfFile: headPath, encoding: .utf8) {
                if contents.hasPrefix("ref: refs/heads/") {
                    return String(contents.dropFirst("ref: refs/heads/".count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return String(contents.prefix(7))
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    static func shortenPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Drag and Drop

    // MARK: - Drop Zone Overlay

    private var dropOverlay: NSView?
    private var activeToast: NSView?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        guard let types = pb.types else { return [] }
        let accepted: Set<NSPasteboard.PasteboardType> = [.fileURL, .URL, .string]
        guard !Set(types).isDisjoint(with: accepted) else { return [] }

        showDropOverlay(sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideDropOverlay()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideDropOverlay()
        guard let surface else { return false }

        let pb = sender.draggingPasteboard

        // Resolve what was dropped into text to paste
        let text: String?
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            // File URLs — shell-escape and join
            let escaped = urls.map { shellEscape($0.path) }
            text = escaped.joined(separator: " ")
            showDropToast(for: urls)
        } else if let urlString = pb.string(forType: .URL) {
            text = shellEscape(urlString)
            showDropToast(label: "Pasted URL", detail: urlString)
        } else if let str = pb.string(forType: .string) {
            // Plain text — don't shell-escape (might be a command)
            text = str
        } else {
            text = nil
        }

        guard let text, !text.isEmpty else { return false }

        // Use bulk text insertion — much faster than character-by-character key events
        pasteText(text, into: surface)
        return true
    }

    /// Paste text into the terminal using the fast bulk API.
    private func pasteText(_ text: String, into surface: ghostty_surface_t) {
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
    }

    /// Shell-escape a file path for safe pasting into a terminal.
    private func shellEscape(_ path: String) -> String {
        let safeChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/-_.~"))
        if path.unicodeScalars.allSatisfy({ safeChars.contains($0) }) {
            return path
        }
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    // MARK: - Drop Visual Feedback

    private func showDropOverlay(_ sender: NSDraggingInfo) {
        guard dropOverlay == nil else { return }

        let overlay = NSView(frame: bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor(red: 0.20, green: 0.30, blue: 0.50, alpha: 0.25).cgColor
        overlay.layer?.borderColor = NSColor(red: 0.45, green: 0.65, blue: 0.90, alpha: 0.6).cgColor
        overlay.layer?.borderWidth = 2
        overlay.layer?.cornerRadius = 8

        // Determine label text from pasteboard
        let pb = sender.draggingPasteboard
        let labelText: String
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let fileCount = urls.count
            let hasImages = urls.contains { isImageFile($0.pathExtension) }
            if fileCount == 1 {
                let name = urls[0].lastPathComponent
                labelText = hasImages ? "Drop image: \(name)" : "Drop file: \(name)"
            } else {
                labelText = "Drop \(fileCount) files"
            }
        } else {
            labelText = "Drop to paste"
        }

        let label = NSTextField(labelWithString: labelText)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(red: 0.65, green: 0.80, blue: 1.0, alpha: 1.0)
        label.alignment = .center
        overlay.addSubview(label)

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: "Drop")
        icon.contentTintColor = NSColor(red: 0.45, green: 0.65, blue: 0.90, alpha: 0.8)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .light)
        overlay.addSubview(icon)

        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: -12),
            label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 6),
        ])

        addSubview(overlay)
        dropOverlay = overlay

        // Fade in
        overlay.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            overlay.animator().alphaValue = 1
        }
    }

    private func hideDropOverlay() {
        guard let overlay = dropOverlay else { return }
        dropOverlay = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            overlay.animator().alphaValue = 0
        }, completionHandler: {
            overlay.removeFromSuperview()
        })
    }

    // MARK: - Drop Toast

    /// Remove any existing toast before showing a new one.
    private func dismissActiveToast() {
        activeToast?.removeFromSuperview()
        activeToast = nil
    }

    /// Show a brief toast notification after files are dropped.
    private func showDropToast(for urls: [URL]) {
        dismissActiveToast()
        let toast = NSView()
        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.wantsLayer = true
        toast.layer?.backgroundColor = NSColor(red: 0.12, green: 0.16, blue: 0.22, alpha: 0.95).cgColor
        toast.layer?.cornerRadius = 8
        toast.layer?.borderColor = NSColor(red: 0.25, green: 0.35, blue: 0.50, alpha: 0.4).cgColor
        toast.layer?.borderWidth = 1

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        toast.addSubview(stack)

        // Header
        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.spacing = 6

        let checkIcon = NSImageView()
        checkIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        checkIcon.contentTintColor = NSColor(red: 0.4, green: 0.8, blue: 0.5, alpha: 1.0)
        checkIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        headerStack.addArrangedSubview(checkIcon)

        let headerLabel = NSTextField(labelWithString: urls.count == 1 ? "Pasted into terminal" : "Pasted \(urls.count) paths")
        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.textColor = NSColor(white: 0.85, alpha: 1.0)
        headerStack.addArrangedSubview(headerLabel)
        stack.addArrangedSubview(headerStack)

        // File list (max 4 shown)
        for url in urls.prefix(4) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 4

            let fileIcon = NSImageView()
            let iconName = isImageFile(url.pathExtension) ? "photo" : "doc"
            fileIcon.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
            fileIcon.contentTintColor = NSColor(white: 0.5, alpha: 1.0)
            fileIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
            row.addArrangedSubview(fileIcon)

            let nameLabel = NSTextField(labelWithString: url.lastPathComponent)
            nameLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            nameLabel.textColor = NSColor(white: 0.65, alpha: 1.0)
            nameLabel.lineBreakMode = .byTruncatingMiddle
            nameLabel.maximumNumberOfLines = 1
            row.addArrangedSubview(nameLabel)

            stack.addArrangedSubview(row)
        }
        if urls.count > 4 {
            let moreLabel = NSTextField(labelWithString: "  +\(urls.count - 4) more")
            moreLabel.font = .systemFont(ofSize: 10, weight: .regular)
            moreLabel.textColor = NSColor(white: 0.45, alpha: 1.0)
            stack.addArrangedSubview(moreLabel)
        }

        addSubview(toast)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: toast.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: toast.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: toast.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: toast.trailingAnchor, constant: -10),

            toast.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            toast.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            toast.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
        ])

        animateToast(toast)
    }

    /// Show a simple label+detail toast (for URL drops, etc.)
    private func showDropToast(label: String, detail: String) {
        dismissActiveToast()
        let toast = NSView()
        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.wantsLayer = true
        toast.layer?.backgroundColor = NSColor(red: 0.12, green: 0.16, blue: 0.22, alpha: 0.95).cgColor
        toast.layer?.cornerRadius = 8
        toast.layer?.borderColor = NSColor(red: 0.25, green: 0.35, blue: 0.50, alpha: 0.4).cgColor
        toast.layer?.borderWidth = 1

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        toast.addSubview(stack)

        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.spacing = 6

        let checkIcon = NSImageView()
        checkIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        checkIcon.contentTintColor = NSColor(red: 0.4, green: 0.8, blue: 0.5, alpha: 1.0)
        checkIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        headerStack.addArrangedSubview(checkIcon)

        let headerLabel = NSTextField(labelWithString: label)
        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.textColor = NSColor(white: 0.85, alpha: 1.0)
        headerStack.addArrangedSubview(headerLabel)
        stack.addArrangedSubview(headerStack)

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = NSColor(white: 0.55, alpha: 1.0)
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.maximumNumberOfLines = 1
        stack.addArrangedSubview(detailLabel)

        addSubview(toast)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: toast.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: toast.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: toast.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: toast.trailingAnchor, constant: -10),

            toast.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            toast.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            toast.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
        ])

        animateToast(toast)
    }

    /// Shared toast animation: fade in, hold, fade out.
    private func animateToast(_ toast: NSView) {
        activeToast = toast
        toast.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            toast.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            // Only auto-dismiss if this is still the active toast
            guard self?.activeToast === toast else { return }
            self?.activeToast = nil
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                toast.animator().alphaValue = 0
            }, completionHandler: {
                toast.removeFromSuperview()
            })
        }
    }

    private func isImageFile(_ ext: String) -> Bool {
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "bmp", "tiff", "heic"]
        return imageExts.contains(ext.lowercased())
    }

    // MARK: - Keystroke Injection

    /// Inject a text string into the terminal using the fast bulk API.
    func injectText(_ text: String) {
        guard let surface else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
    }

    /// Inject a Return/Enter keystroke into the terminal.
    func injectReturn() {
        guard let surface else { return }
        var input = ghostty_input_key_s()
        input.action = GHOSTTY_ACTION_PRESS
        input.mods = ghostty_input_mods_e(rawValue: 0)
        input.keycode = 36
        input.composing = false
        "\r".withCString { ptr in
            input.text = ptr
            input.unshifted_codepoint = 13
            ghostty_surface_key(surface, input)
        }
    }

    /// Detect Claude Code specific state from terminal output patterns.
    private func detectClaudeCodeState(lastLine: String, lines: [String]) -> ClaudeCodeState? {
        let lastFewLines = Array(lines.suffix(10)).joined(separator: " ").lowercased()

        // Priority 1: Permission requests (highest priority)
        if lastFewLines.contains("do you want to allow claude to") ||
           lastFewLines.contains("claude wants to") {
            return .awaitingPermission
        }

        // Priority 2: Active thinking - check before selection to avoid false positives
        // when Claude is actively processing but output contains numbered lists
        if hasThinkingActionWords(lines) {
            return .thinking
        }

        // Priority 3: Selection prompts - require explicit selection UI indicators
        // or ❯ appearing as an inline selector on the same line as a numbered option
        if lastFewLines.contains("enter to select") && lastFewLines.contains("↑/↓ to navigate") {
            return .awaitingSelection
        }
        if hasSelectionMenu(lines) {
            return .awaitingSelection
        }

        // Priority 4: Permission with numbered choices (e.g. "1. Allow  2. Deny")
        if hasNumberedPermissionMenu(lines) {
            return .awaitingPermission
        }

        // Priority 5: Done with task - if we see ⏺ recently and no active thinking
        let largerWindow = Array(lines.suffix(20)).joined(separator: " ")
        if largerWindow.contains("⏺") {
            return .doneWithTask
        }

        return nil
    }
    
    /// Check if recent lines contain an actual selection menu (❯ as inline selector before a numbered option on the same line).
    /// This avoids false positives from shell prompts (❯) appearing near unrelated numbered lists in Claude output.
    private func hasSelectionMenu(_ lines: [String]) -> Bool {
        for line in lines.suffix(10) {
            let stripped = Self.stripAnsiCodes(line).trimmingCharacters(in: .whitespaces)
            // Match lines like "❯ 1. Some option" or "  ❯ SomeChoice" - the ❯ is the cursor in a selection menu
            if stripped.hasPrefix("❯") {
                let afterCursor = stripped.dropFirst().trimmingCharacters(in: .whitespaces)
                // Selection menu item: starts with a number+dot or is a non-empty choice
                if afterCursor.range(of: #"^\d+\."#, options: .regularExpression) != nil {
                    return true
                }
            }
        }
        return false
    }

    /// Check for numbered permission/choice menus (e.g. "1. Allow  2. Deny" with ❯ on same or adjacent line).
    private func hasNumberedPermissionMenu(_ lines: [String]) -> Bool {
        let recent = Array(lines.suffix(8))
        for (i, line) in recent.enumerated() {
            let stripped = Self.stripAnsiCodes(line).lowercased()
            if stripped.contains("❯") && stripped.contains("1.") && stripped.contains("2.") {
                return true
            }
            // ❯ on one line, numbered options on adjacent lines
            if stripped.contains("❯"), i + 1 < recent.count {
                let next = Self.stripAnsiCodes(recent[i + 1]).lowercased()
                if next.contains("1.") && (next.contains("allow") || next.contains("deny") || next.contains("yes") || next.contains("no")) {
                    return true
                }
            }
        }
        return false
    }

    /// Check for actual thinking action words (most reliable indicator)
    private func hasThinkingActionWords(_ lines: [String]) -> Bool {
        // ULTRA SIMPLE: just detect any ellipsis anywhere (what was working)
        for line in lines.suffix(8) {
            if line.contains("…") {
                return true
            }
            
            let stripped = Self.stripAnsiCodes(line)
            if stripped.contains("…") {
                return true
            }
            
            if stripped.lowercased().contains("(thinking)") {
                return true
            }
        }
        
        return false
    }
    
    

    deinit {
        destroySurface()
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let terminalSurfaceTitleChanged = Notification.Name("terminalSurfaceTitleChanged")
    static let terminalActivityChanged = Notification.Name("terminalActivityChanged")
    static let terminalSurfaceFocused = Notification.Name("terminalSurfaceFocused")
}
