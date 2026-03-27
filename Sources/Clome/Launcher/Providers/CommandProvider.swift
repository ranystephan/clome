import AppKit

/// Provides built-in commands to the launcher (new terminal, split, sidebar toggle, etc.).
@MainActor
class CommandProvider: LauncherProvider {
    let sectionTitle = "Commands"
    let sectionIcon = "command"

    private weak var workspaceManager: WorkspaceManager?
    private weak var window: ClomeWindow?

    init(workspaceManager: WorkspaceManager, window: ClomeWindow) {
        self.workspaceManager = workspaceManager
        self.window = window
    }

    private struct Command {
        let title: String
        let icon: String
        let iconColor: NSColor
        let shortcut: String?
        let keywords: String
    }

    private static let green = NSColor(red: 0.40, green: 0.87, blue: 0.47, alpha: 1.0)
    private static let blue = NSColor(red: 0.40, green: 0.62, blue: 1.00, alpha: 1.0)
    private static let purple = NSColor(red: 0.69, green: 0.49, blue: 1.00, alpha: 1.0)
    private static let orange = NSColor(red: 0.90, green: 0.60, blue: 0.25, alpha: 1.0)
    private static let gray = NSColor(white: 0.55, alpha: 1.0)

    private static let commandList: [Command] = [
        // Terminal
        Command(title: "New Terminal", icon: "terminal", iconColor: green, shortcut: nil, keywords: "terminal shell tab"),
        Command(title: "New Browser Tab", icon: "globe", iconColor: blue, shortcut: nil, keywords: "browser web"),

        // Splits
        Command(title: "Split Right", icon: "rectangle.split.2x1", iconColor: gray, shortcut: "\u{2318}\u{2325}\u{2192}", keywords: "split right horizontal"),
        Command(title: "Split Down", icon: "rectangle.split.1x2", iconColor: gray, shortcut: "\u{2318}\u{2325}\u{2193}", keywords: "split down vertical"),
        Command(title: "Close Split Pane", icon: "xmark.rectangle", iconColor: gray, shortcut: nil, keywords: "close pane remove"),

        // Navigation
        Command(title: "Toggle Sidebar", icon: "sidebar.left", iconColor: gray, shortcut: "\u{2318}B", keywords: "sidebar toggle hide show"),
        Command(title: "Next Tab", icon: "arrow.right.square", iconColor: gray, shortcut: "\u{2318}\u{21E7}]", keywords: "next tab forward"),
        Command(title: "Previous Tab", icon: "arrow.left.square", iconColor: gray, shortcut: "\u{2318}\u{21E7}[", keywords: "previous tab back"),

        // File operations
        Command(title: "Open File...", icon: "doc", iconColor: blue, shortcut: "\u{2318}O", keywords: "open file browse"),
        Command(title: "Save", icon: "square.and.arrow.down", iconColor: gray, shortcut: "\u{2318}S", keywords: "save file"),
        Command(title: "Find in File", icon: "magnifyingglass", iconColor: gray, shortcut: "\u{2318}F", keywords: "find search"),
        Command(title: "Find & Replace", icon: "arrow.left.arrow.right", iconColor: gray, shortcut: "\u{2318}H", keywords: "find replace"),
        Command(title: "Close Tab", icon: "xmark", iconColor: gray, shortcut: "\u{2318}W", keywords: "close tab"),

        // Workspace
        Command(title: "New Workspace", icon: "plus.rectangle.on.folder", iconColor: purple, shortcut: nil, keywords: "workspace new create"),
        Command(title: "Next Workspace", icon: "arrow.right.circle", iconColor: purple, shortcut: "\u{2318}1-9", keywords: "workspace next switch"),

        // Editor
        Command(title: "Go to Definition", icon: "arrow.turn.down.right", iconColor: blue, shortcut: "F12", keywords: "goto definition jump"),
        Command(title: "Toggle Minimap", icon: "chart.bar.doc.horizontal", iconColor: gray, shortcut: nil, keywords: "minimap overview"),
        Command(title: "Select All", icon: "selection.pin.in.out", iconColor: gray, shortcut: "\u{2318}A", keywords: "select all"),

        // Claude / Agent
        Command(title: "Review Agent Changes", icon: "sparkles", iconColor: orange, shortcut: nil, keywords: "claude agent changes diff review"),
        Command(title: "Accept All Agent Changes", icon: "checkmark.circle", iconColor: green, shortcut: nil, keywords: "claude agent accept all"),

        // App
        Command(title: "Settings", icon: "gearshape", iconColor: gray, shortcut: "\u{2318},", keywords: "settings preferences config"),
        Command(title: "Reload File Explorer", icon: "arrow.clockwise", iconColor: gray, shortcut: nil, keywords: "refresh reload explorer"),
    ]

    func search(query: String) -> [LauncherItem] {
        let lowQuery = query.lowercased()

        var items: [LauncherItem] = []
        for (index, cmd) in Self.commandList.enumerated() {
            if !lowQuery.isEmpty {
                let searchable = "\(cmd.title) \(cmd.keywords)".lowercased()
                if !searchable.contains(lowQuery) { continue }
            }

            items.append(LauncherItem(
                id: "cmd-\(index)",
                icon: cmd.icon,
                iconColor: cmd.iconColor,
                title: cmd.title,
                metadata: cmd.shortcut,
                provider: "command",
                payload: CommandPayload(handler: makeHandler(for: cmd.title)),
                priority: cmd.title.lowercased().hasPrefix(lowQuery) ? 10 : 0
            ))
        }

        return items
    }

    func actions(for item: LauncherItem) -> [LauncherAction] {
        guard item.provider == "command" else { return [] }
        return [
            LauncherAction(title: "Run", icon: "play.fill", shortcut: "Enter") { },
        ]
    }

    private func makeHandler(for title: String) -> @MainActor @Sendable () -> Void {
        let wm = workspaceManager
        let win = window
        return { @MainActor @Sendable in
            switch title {
            case "New Terminal":
                wm?.activeWorkspace?.addTerminalTab()
            case "New Browser Tab":
                wm?.activeWorkspace?.addBrowserSurface()
            case "Split Right":
                wm?.activeWorkspace?.splitActivePane(direction: .right)
            case "Split Down":
                wm?.activeWorkspace?.splitActivePane(direction: .down)
            case "Close Split Pane":
                wm?.activeWorkspace?.closeSplitPane()
            case "Toggle Sidebar":
                win?.toggleSidebar()
            case "New Workspace":
                wm?.addWorkspace()
            case "Settings":
                SettingsWindowController.show()
            case "Close Tab":
                wm?.activeWorkspace?.closeActiveTab()
            case "Review Agent Changes":
                AgentFileTracker.shared.pendingChanges.first.map { change in
                    NotificationCenter.default.post(
                        name: .openDiffReview,
                        object: nil,
                        userInfo: ["path": change.path, "oldContent": change.oldContent ?? "", "newContent": change.newContent ?? ""]
                    )
                }
            case "Accept All Agent Changes":
                AgentFileTracker.shared.acceptAll()
            default:
                break
            }
        }
    }
}

/// Payload for command items.
@MainActor
class CommandPayload: NSObject {
    let handler: @MainActor () -> Void

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }
}
