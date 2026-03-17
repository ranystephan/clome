import AppKit

/// Handles keyboard navigation between splits and workspaces.
/// Shortcuts:
///   ⌘⌥←/→/↑/↓ - Navigate between splits
///   ⌘1-9       - Switch workspace by index
///   ⌘⇧]        - Next workspace
///   ⌘⇧[        - Previous workspace
///   ⌘⇧T        - Open browser tab
@MainActor
class KeyboardNavigationHandler {
    weak var window: ClomeWindow?

    init(window: ClomeWindow) {
        self.window = window
        setupMonitor()
    }

    private func setupMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleKeyEvent(event) == true {
                return nil // Consumed
            }
            return event
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard let window else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Route Ctrl+key combos directly to focused terminal surface
        // (Ctrl+C, Ctrl+Z, Ctrl+D, etc.) — AppKit swallows these otherwise
        if mods == .control || mods == [.control, .shift] {
            if let terminal = window.firstResponder as? TerminalSurface {
                terminal.keyDown(with: event)
                return true
            }
        }

        // ⌘⌥ + Arrow keys: navigate between splits
        if mods == [.command, .option] {
            switch event.keyCode {
            case 123: // Left arrow
                navigateSplit(.left, in: window)
                return true
            case 124: // Right arrow
                navigateSplit(.right, in: window)
                return true
            case 125: // Down arrow
                navigateSplit(.down, in: window)
                return true
            case 126: // Up arrow
                navigateSplit(.up, in: window)
                return true
            default:
                break
            }
        }

        // ⌘1-9: switch workspace
        if mods == .command {
            if let char = event.charactersIgnoringModifiers, let digit = Int(char), digit >= 1, digit <= 9 {
                window.workspaceManager.switchTo(index: digit - 1)
                return true
            }
        }

        // ⌘⇧] / ⌘⇧[: next/previous workspace
        if mods == [.command, .shift] {
            if event.charactersIgnoringModifiers == "]" {
                let next = window.workspaceManager.activeWorkspaceIndex + 1
                if next < window.workspaceManager.workspaces.count {
                    window.workspaceManager.switchTo(index: next)
                }
                return true
            }
            if event.charactersIgnoringModifiers == "[" {
                let prev = window.workspaceManager.activeWorkspaceIndex - 1
                if prev >= 0 {
                    window.workspaceManager.switchTo(index: prev)
                }
                return true
            }
        }

        // ⌘⇧T: new browser tab
        if mods == [.command, .shift] && event.charactersIgnoringModifiers == "T" {
            window.workspaceManager.activeWorkspace?.addBrowserSurface()
            return true
        }

        // ⌘D: split right
        if mods == .command && event.charactersIgnoringModifiers == "d" {
            window.workspaceManager.activeWorkspace?.splitActivePane(direction: .right)
            window.updateTabBar()
            return true
        }

        // ⌘⇧D: split down
        if mods == [.command, .shift] && event.charactersIgnoringModifiers == "D" {
            window.workspaceManager.activeWorkspace?.splitActivePane(direction: .down)
            window.updateTabBar()
            return true
        }

        // ⌘⇧Enter: toggle maximize current split
        if mods == [.command, .shift] && event.keyCode == 36 {
            // TODO: implement split maximize toggle
            return true
        }

        // ⌘⇧W: close split pane (or tab if no splits)
        if mods == [.command, .shift] && event.charactersIgnoringModifiers == "W" {
            window.workspaceManager.activeWorkspace?.closeSplitPane()
            window.updateTabBar()
            return true
        }

        return false
    }

    private func navigateSplit(_ direction: SplitDirection, in window: ClomeWindow) {
        guard let workspace = window.workspaceManager.activeWorkspace else { return }
        workspace.navigateSplit(direction)
    }
}
