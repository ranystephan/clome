import AppKit

/// Provides terminal surfaces to the launcher, with Claude Code attention items elevated.
@MainActor
class TerminalProvider: LauncherProvider {
    let sectionTitle = "Terminals"
    let sectionIcon = "terminal"

    private weak var workspaceManager: WorkspaceManager?

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    func search(query: String) -> [LauncherItem] {
        guard let wm = workspaceManager else { return [] }
        var items: [LauncherItem] = []
        let lowQuery = query.lowercased()

        for (wsIndex, workspace) in wm.workspaces.enumerated() {
            for (tabIndex, tab) in workspace.tabs.enumerated() {
                let terminals = tab.splitContainer.allLeafViews.compactMap { $0 as? TerminalSurface }
                for terminal in terminals {
                    let rawTitle = terminal.detectedProgram ?? terminal.title
                    let title = rawTitle.isEmpty ? "Shell" : rawTitle
                    let path = terminal.shortPath ?? terminal.workingDirectory ?? ""
                    let subtitle = "\(workspace.name) \u{2022} \(path)"

                    // Check if matches query
                    if !lowQuery.isEmpty {
                        let searchable = "\(title) \(path) \(workspace.name)".lowercased()
                        if !searchable.contains(lowQuery) { continue }
                    }

                    // Determine priority and icon
                    let isAwaitingPermission = terminal.claudeCodeState == .awaitingPermission
                    let isAwaitingSelection = terminal.claudeCodeState == .awaitingSelection
                    let priority: Int
                    let icon: String
                    let iconColor: NSColor

                    if isAwaitingPermission {
                        priority = 1000  // Attention: top of list
                        icon = "exclamationmark.triangle.fill"
                        iconColor = NSColor(red: 1.0, green: 0.75, blue: 0.25, alpha: 1.0) // amber
                    } else if isAwaitingSelection {
                        priority = 900
                        icon = "list.bullet"
                        iconColor = NSColor(red: 0.40, green: 0.62, blue: 1.00, alpha: 1.0) // blue
                    } else if terminal.detectedProgram == "Claude Code" {
                        priority = 50
                        icon = "sparkle"
                        iconColor = NSColor(red: 0.69, green: 0.49, blue: 1.00, alpha: 1.0) // purple
                    } else {
                        priority = 0
                        icon = "terminal"
                        iconColor = NSColor(red: 0.40, green: 0.87, blue: 0.47, alpha: 1.0) // green
                    }

                    // Build metadata
                    let metadata: String?
                    if isAwaitingPermission {
                        metadata = "Accept?"
                    } else if isAwaitingSelection {
                        metadata = "Select"
                    } else {
                        switch terminal.activityState {
                        case .running: metadata = "Running"
                        case .waitingInput: metadata = "Waiting"
                        case .completed: metadata = "Done"
                        case .idle: metadata = nil
                        }
                    }

                    // Use output preview as extended subtitle for attention items
                    let displaySubtitle: String
                    if isAwaitingPermission, let preview = terminal.outputPreview {
                        let firstLine = preview.components(separatedBy: "\n").first ?? ""
                        displaySubtitle = firstLine.isEmpty ? subtitle : firstLine
                    } else {
                        displaySubtitle = subtitle
                    }

                    let payload = TerminalPayload(
                        terminal: terminal,
                        workspaceIndex: wsIndex,
                        tabIndex: tabIndex
                    )

                    let terminalID = String(UInt(bitPattern: ObjectIdentifier(terminal)))
                    items.append(LauncherItem(
                        id: "terminal-\(wsIndex)-\(tabIndex)-\(terminalID)",
                        icon: icon,
                        iconColor: iconColor,
                        title: title,
                        subtitle: displaySubtitle,
                        metadata: metadata,
                        provider: "terminal",
                        payload: payload,
                        priority: priority
                    ))
                }
            }
        }

        items.sort { $0.priority > $1.priority }
        return items
    }

    func actions(for item: LauncherItem) -> [LauncherAction] {
        guard item.provider == "terminal",
              let payload = item.payload as? TerminalPayload,
              let terminal = payload.terminal else { return [] }

        var actions: [LauncherAction] = []

        // Primary: navigate to the terminal
        actions.append(LauncherAction(
            title: "Go to Terminal",
            icon: "arrow.right",
            shortcut: "Enter"
        ) { })

        // Claude Code permission actions
        if terminal.claudeCodeState == .awaitingPermission {
            actions.append(LauncherAction(
                title: "Accept",
                icon: "checkmark.circle.fill",
                shortcut: "\u{2318}Y"
            ) {
                terminal.injectText("y")
                terminal.injectReturn()
            })

            actions.append(LauncherAction(
                title: "Reject",
                icon: "xmark.circle.fill",
                shortcut: "\u{2318}N"
            ) {
                terminal.injectText("n")
                terminal.injectReturn()
            })
        }

        return actions
    }
}

/// Payload for terminal items.
@MainActor
class TerminalPayload: NSObject {
    weak var terminal: TerminalSurface?
    let workspaceIndex: Int
    let tabIndex: Int

    init(terminal: TerminalSurface, workspaceIndex: Int, tabIndex: Int) {
        self.terminal = terminal
        self.workspaceIndex = workspaceIndex
        self.tabIndex = tabIndex
    }
}
