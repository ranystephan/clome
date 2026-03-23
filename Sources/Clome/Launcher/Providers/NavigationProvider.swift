import AppKit

/// Provides workspace, tab, and pane navigation items to the launcher.
@MainActor
class NavigationProvider: LauncherProvider {
    let sectionTitle = "Navigation"
    let sectionIcon = "rectangle.stack"

    private weak var workspaceManager: WorkspaceManager?

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    func search(query: String) -> [LauncherItem] {
        guard let wm = workspaceManager else { return [] }
        var items: [LauncherItem] = []
        let lowQuery = query.lowercased()

        for (wsIndex, workspace) in wm.workspaces.enumerated() {
            let isActive = wsIndex == wm.activeWorkspaceIndex

            // Add workspace item
            let wsMatches = lowQuery.isEmpty || workspace.name.lowercased().contains(lowQuery)

            for (tabIndex, tab) in workspace.tabs.enumerated() {
                let leafViews = tab.splitContainer.allLeafViews

                if leafViews.count <= 1 {
                    // Single pane tab — show as one item
                    let (icon, title) = WorkspaceTab.paneLabel(for: tab.view)
                    let fullTitle = title
                    let subtitle = "\(workspace.name) \u{2022} Tab \(tabIndex + 1)"

                    if wsMatches || fullTitle.lowercased().contains(lowQuery) || subtitle.lowercased().contains(lowQuery) {
                        let item = LauncherItem(
                            id: "nav-\(wsIndex)-\(tabIndex)",
                            icon: icon,
                            iconColor: iconColor(for: tab.view, workspaceColor: workspace.color),
                            title: fullTitle,
                            subtitle: subtitle,
                            metadata: isActive && tabIndex == workspace.activeTabIndex ? "Active" : nil,
                            provider: "navigation",
                            payload: NavigationPayload(workspaceIndex: wsIndex, tabIndex: tabIndex),
                            priority: isActive ? 10 : 0
                        )
                        items.append(item)
                    }
                } else {
                    // Multi-pane tab — show each pane
                    for (paneIndex, paneView) in leafViews.enumerated() {
                        let (icon, title) = WorkspaceTab.paneLabel(for: paneView)
                        let subtitle = "\(workspace.name) \u{2022} Tab \(tabIndex + 1) \u{2022} Pane \(paneIndex + 1)"

                        if wsMatches || title.lowercased().contains(lowQuery) || subtitle.lowercased().contains(lowQuery) {
                            let isFocused = isActive
                                && tabIndex == workspace.activeTabIndex
                                && paneView === tab.splitContainer.focusedPane

                            let item = LauncherItem(
                                id: "nav-\(wsIndex)-\(tabIndex)-\(paneIndex)",
                                icon: icon,
                                iconColor: iconColor(for: paneView, workspaceColor: workspace.color),
                                title: title,
                                subtitle: subtitle,
                                metadata: isFocused ? "Focused" : nil,
                                provider: "navigation",
                                payload: NavigationPayload(workspaceIndex: wsIndex, tabIndex: tabIndex, paneView: paneView),
                                priority: isFocused ? 15 : (isActive ? 10 : 0)
                            )
                            items.append(item)
                        }
                    }
                }
            }
        }

        // Sort by priority descending, then by name
        items.sort { $0.priority > $1.priority }
        return items
    }

    func actions(for item: LauncherItem) -> [LauncherAction] {
        guard item.provider == "navigation" else { return [] }
        return [
            LauncherAction(title: "Go to", icon: "arrow.right", shortcut: "Enter") { },
        ]
    }

    // MARK: - Helpers

    private func iconColor(for view: NSView, workspaceColor: WorkspaceColor) -> NSColor {
        if view is TerminalSurface {
            return NSColor(red: 0.40, green: 0.87, blue: 0.47, alpha: 1.0) // green
        } else if view is BrowserPanel {
            return NSColor(red: 0.40, green: 0.62, blue: 1.00, alpha: 1.0) // blue
        } else if view is EditorPanel {
            return NSColor(red: 0.69, green: 0.49, blue: 1.00, alpha: 1.0) // purple
        } else if view is PDFPanel {
            return NSColor(red: 1.00, green: 0.42, blue: 0.42, alpha: 1.0) // red
        } else if view is NotebookPanel {
            return NSColor(red: 1.00, green: 0.62, blue: 0.30, alpha: 1.0) // orange
        }
        return workspaceColor.nsColor
    }
}
