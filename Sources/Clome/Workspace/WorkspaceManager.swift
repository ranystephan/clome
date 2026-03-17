import AppKit

protocol WorkspaceManagerDelegate: AnyObject {
    func workspaceManager(_ manager: WorkspaceManager, didSwitchTo workspace: Workspace)
}

/// Manages the collection of workspaces in Clome.
@MainActor
class WorkspaceManager {
    weak var delegate: WorkspaceManagerDelegate?
    weak var ghosttyApp: GhosttyAppManager? {
        didSet {
            // Propagate to all existing workspaces (fixes Workspace 1 created before ghosttyApp was set)
            for workspace in workspaces {
                workspace.ghosttyApp = ghosttyApp
            }
        }
    }

    private(set) var workspaces: [Workspace] = []
    private(set) var activeWorkspaceIndex: Int = -1

    var activeWorkspace: Workspace? {
        guard activeWorkspaceIndex >= 0, activeWorkspaceIndex < workspaces.count else { return nil }
        return workspaces[activeWorkspaceIndex]
    }

    @discardableResult
    func addWorkspace(name: String? = nil) -> Workspace {
        let index = workspaces.count + 1
        let workspace = Workspace(
            name: name ?? "Workspace \(index)",
            icon: "terminal",
            color: WorkspaceColor.color(at: workspaces.count),
            ghosttyApp: ghosttyApp
        )
        workspaces.append(workspace)
        switchTo(index: workspaces.count - 1)
        return workspace
    }

    func removeWorkspace(at index: Int) {
        guard index >= 0, index < workspaces.count else { return }
        // Close all tabs in the workspace
        let workspace = workspaces[index]
        while !workspace.tabs.isEmpty {
            workspace.closeTab(0)
        }
        workspaces.remove(at: index)
        if workspaces.isEmpty {
            activeWorkspaceIndex = -1
        } else if activeWorkspaceIndex >= workspaces.count {
            switchTo(index: workspaces.count - 1)
        } else {
            switchTo(index: min(activeWorkspaceIndex, workspaces.count - 1))
        }
    }

    func switchTo(index: Int) {
        guard index >= 0, index < workspaces.count else { return }
        activeWorkspaceIndex = index
        delegate?.workspaceManager(self, didSwitchTo: workspaces[index])
    }

    func moveWorkspace(from: Int, to: Int) {
        guard from >= 0, from < workspaces.count, to >= 0, to < workspaces.count, from != to else { return }
        let workspace = workspaces.remove(at: from)
        workspaces.insert(workspace, at: to)
        // Track active workspace
        if activeWorkspaceIndex == from {
            activeWorkspaceIndex = to
        } else if from < activeWorkspaceIndex && to >= activeWorkspaceIndex {
            activeWorkspaceIndex -= 1
        } else if from > activeWorkspaceIndex && to <= activeWorkspaceIndex {
            activeWorkspaceIndex += 1
        }
    }

    func renameWorkspace(at index: Int, to name: String) {
        guard index >= 0, index < workspaces.count else { return }
        workspaces[index].name = name
    }
}
