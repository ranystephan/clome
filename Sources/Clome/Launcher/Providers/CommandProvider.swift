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
        let keywords: String
    }

    private static let green = NSColor(red: 0.40, green: 0.87, blue: 0.47, alpha: 1.0)
    private static let blue = NSColor(red: 0.40, green: 0.62, blue: 1.00, alpha: 1.0)
    private static let purple = NSColor(red: 0.69, green: 0.49, blue: 1.00, alpha: 1.0)
    private static let gray = NSColor(white: 0.55, alpha: 1.0)

    private static let commandList: [Command] = [
        Command(title: "New Terminal", icon: "terminal", iconColor: green, keywords: "terminal shell tab"),
        Command(title: "New Browser Tab", icon: "globe", iconColor: blue, keywords: "browser web"),
        Command(title: "Split Right", icon: "rectangle.split.2x1", iconColor: gray, keywords: "split right horizontal"),
        Command(title: "Split Down", icon: "rectangle.split.1x2", iconColor: gray, keywords: "split down vertical"),
        Command(title: "Close Split Pane", icon: "xmark.rectangle", iconColor: gray, keywords: "close pane remove"),
        Command(title: "Toggle Sidebar", icon: "sidebar.left", iconColor: gray, keywords: "sidebar toggle hide show"),
        Command(title: "New Workspace", icon: "plus.rectangle.on.folder", iconColor: purple, keywords: "workspace new create"),
        Command(title: "Settings", icon: "gearshape", iconColor: gray, keywords: "settings preferences config"),
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
