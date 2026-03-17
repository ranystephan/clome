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

    /// Context window usage percentage for Claude Code sessions (0-100), nil if not detected.
    var contextPercentage: Int?

    init(ghosttyApp: GhosttyAppManager) {
        self.ghosttyApp = ghosttyApp
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = AppearanceSettings.shared.mainPanelBgColor.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && surface == nil {
            createSurface()
        }
    }

    override func layout() {
        super.layout()
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

    // MARK: - Surface Creation

    private func createSurface() {
        guard let app = ghosttyApp, let ghosttyAppInstance = app.app else { return }

        var cfg = app.makeSurfaceConfig(for: self)
        surface = ghostty_surface_new(ghosttyAppInstance, &cfg)

        if surface != nil {
            // Trigger initial layout
            layout()
            // Register with activity monitor
            TerminalActivityMonitor.shared.register(self)
        }
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

    /// Current detected activity state.
    var activityState: ActivityState = .idle

    private func detectProgram() {
        let lower = title.lowercased()

        if lower.contains("claude") {
            detectedProgram = "Claude Code"
            programIcon = "sparkle"
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

        // Extract context percentage if this is a Claude Code session
        if detectedProgram == "Claude Code" {
            // Primary: read from Clome bridge file (written by status line script)
            if let bridgePct = ClaudeContextBridge.shared.contextPercentage(forDirectory: workingDirectory) {
                contextPercentage = bridgePct
            } else {
                // Fallback: try to parse from visible terminal text
                contextPercentage = Self.extractContextPercentage(from: allLines)
            }
        } else {
            contextPercentage = nil
        }

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

    private func detectStateFromContent(lastLine: String, lines: [String]) {
        let lower = lastLine.lowercased()

        // Detect if output is actively changing (something is producing text)
        let currentSnapshot = lines.suffix(4).joined(separator: "\n")
        outputIsChanging = (previousOutputSnapshot != nil && previousOutputSnapshot != currentSnapshot)
        previousOutputSnapshot = currentSnapshot

        if detectedProgram == "Claude Code" {
            if Self.isClaudeCodeWaitingForInput(lastLine: lastLine, lines: lines) {
                activityState = .waitingInput
                needsAttention = true
            } else if outputIsChanging {
                // Output is actively changing → Claude is working
                activityState = .running
                needsAttention = false
            } else {
                // Output stable, not at a prompt → could be thinking or just idle
                // Don't show "Running" unless we see output changing
                activityState = .idle
                needsAttention = false
            }
            return
        }

        // Generic shell/program detection
        if Self.isShellPrompt(lastLine) {
            activityState = .idle
            needsAttention = false
        } else if lower.contains("press") || lower.contains("enter") || lower.contains("(y/n)")
                    || lower.contains("[y/n]") || lower.contains("continue?") {
            activityState = .waitingInput
            needsAttention = true
        } else if outputIsChanging {
            // Only show running when output is actively changing
            activityState = .running
            needsAttention = false
        } else {
            activityState = .idle
            needsAttention = false
        }
    }

    /// Detect if Claude Code is waiting for user input by checking output patterns.
    private static func isClaudeCodeWaitingForInput(lastLine: String, lines: [String]) -> Bool {
        let lower = lastLine.lowercased()
        let trimmed = lastLine.trimmingCharacters(in: .whitespacesAndNewlines)

        // Claude Code shows ">" prompt when waiting for user input
        if trimmed == ">" || trimmed == "❯" || trimmed.hasSuffix("> ") {
            return true
        }

        // Check for common Claude Code waiting patterns in recent lines
        let recentContent = lines.suffix(4).joined(separator: " ").lowercased()

        // "Do you want to proceed?" / approval prompts
        if recentContent.contains("do you want") || recentContent.contains("approve")
            || recentContent.contains("accept") || recentContent.contains("deny")
            || recentContent.contains("(y)es") || recentContent.contains("reject") {
            return true
        }

        // Tool use permission prompts
        if recentContent.contains("allow") && (recentContent.contains("tool") || recentContent.contains("permission")) {
            return true
        }

        // "waiting for" patterns
        if recentContent.contains("waiting for") || recentContent.contains("press enter") {
            return true
        }

        // Empty prompt line after output (Claude finished and showing prompt)
        if trimmed.isEmpty && lines.count > 1 {
            let prevLine = lines[lines.count - 2].lowercased()
            if prevLine.contains("completed") || prevLine.contains("done") || prevLine.contains("finished")
                || prevLine.contains("created") || prevLine.contains("updated") {
                return true
            }
        }

        return false
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
            "●", "○", "◆", "◇", "◉", "◎",
            "…", "·", "•",
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

    /// Extract Claude Code context percentage from terminal lines.
    /// Scans for patterns from Claude Code status line output.
    private static func extractContextPercentage(from lines: [String]) -> Int? {
        for line in lines {
            let lower = line.lowercased()

            // Pattern: "XX% context" or "context XX%" or "context: XX%"
            if lower.contains("context") {
                if let match = line.range(of: #"(\d{1,3})%"#, options: .regularExpression) {
                    let numStr = line[match].dropLast()
                    if let pct = Int(numStr), pct >= 0, pct <= 100 {
                        return pct
                    }
                }
            }

            // Pattern: token counts like "12.3k / 200k tokens" → compute percentage
            if lower.contains("token") {
                if let match = line.range(of: #"([\d.]+)k?\s*/\s*([\d.]+)k?\s*token"#, options: .regularExpression) {
                    let parts = String(line[match]).components(separatedBy: "/")
                    if parts.count == 2 {
                        let usedStr = parts[0].trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: "k", with: "")
                        let totalStr = parts[1].trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: "k", with: "")
                            .replacingOccurrences(of: " token", with: "")
                            .replacingOccurrences(of: " tokens", with: "")
                        if let used = Double(usedStr), let total = Double(totalStr), total > 0 {
                            let pct = Int((used / total) * 100)
                            if pct >= 0, pct <= 100 { return pct }
                        }
                    }
                }
            }
        }

        // Fallback: read from Clome context bridge file
        return nil
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

    deinit {
        destroySurface()
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let terminalSurfaceTitleChanged = Notification.Name("terminalSurfaceTitleChanged")
    static let terminalActivityChanged = Notification.Name("terminalActivityChanged")
}
