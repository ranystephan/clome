import AppKit

/// Provides Claude Code sessions to the launcher.
@MainActor
class SessionProvider: LauncherProvider {
    let sectionTitle = "Sessions"
    let sectionIcon = "bubble.left.and.bubble.right"

    private weak var workspaceManager: WorkspaceManager?

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    func search(query: String) -> [LauncherItem] {
        let sessions = ClaudeSessionManager.shared.discoverAllSessions()
        let lowQuery = query.lowercased()

        var items: [LauncherItem] = []
        for session in sessions.prefix(20) {  // Limit to 20 most recent
            let title = session.displayName
            let projectName = (session.projectPath as NSString).lastPathComponent
            let subtitle = projectName

            // Filter by query
            if !lowQuery.isEmpty {
                let searchable = "\(title) \(projectName) \(session.projectPath)".lowercased()
                if !searchable.contains(lowQuery) { continue }
            }

            // Icon, color, status label based on state
            let iconColor: NSColor
            let icon: String
            let priority: Int
            let statusLabel: String

            if let wsName = session.activeInWorkspace {
                icon = "bolt.circle.fill"
                iconColor = NSColor(red: 0.40, green: 0.87, blue: 0.47, alpha: 1.0)  // green
                priority = 20
                statusLabel = "Active in \(wsName)"
            } else if session.pinned {
                icon = "pin.fill"
                iconColor = NSColor(red: 1.00, green: 0.62, blue: 0.30, alpha: 1.0)  // orange
                priority = 15
                statusLabel = relativeTime(from: session.lastActiveAt)
            } else {
                icon = "clock.arrow.circlepath"
                iconColor = NSColor(white: 0.45, alpha: 1.0)  // dim gray for inactive
                priority = 0
                statusLabel = relativeTime(from: session.lastActiveAt)
            }

            // Subtitle: project name + cost if significant
            let costStr = session.estimatedCost >= 0.01
                ? String(format: " · $%.2f", session.estimatedCost)
                : ""
            let displaySubtitle = "\(projectName)\(costStr)"

            items.append(LauncherItem(
                id: "session-\(session.id)",
                icon: icon,
                iconColor: iconColor,
                title: title,
                subtitle: displaySubtitle,
                metadata: statusLabel,
                provider: "session",
                payload: SessionPayload(session: session),
                priority: priority
            ))
        }

        return items
    }

    func actions(for item: LauncherItem) -> [LauncherAction] {
        guard item.provider == "session",
              let payload = item.payload as? SessionPayload else { return [] }
        let session = payload.session

        var actions: [LauncherAction] = []

        actions.append(LauncherAction(
            title: "Resume Session",
            icon: "play.fill",
            shortcut: "Enter"
        ) {
            // Resume is handled by the overlay's item activation
        })

        if session.activeInWorkspace != nil {
            actions.append(LauncherAction(
                title: "Go to Workspace",
                icon: "arrow.right",
                shortcut: "\u{2318}Enter"
            ) { })
        }

        return actions
    }

    // MARK: - Helpers

    private func relativeTime(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        if interval < 604800 { return "\(Int(interval / 86400))d ago" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return formatter.string(from: date)
    }
}

/// Payload for session items.
@MainActor
class SessionPayload: NSObject {
    let session: ClaudeSession

    init(session: ClaudeSession) {
        self.session = session
    }
}
