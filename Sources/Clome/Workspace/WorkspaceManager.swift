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

    /// Restore workspaces from saved session state. Returns true if restoration occurred.
    @discardableResult
    func restoreFromSession() -> Bool {
        let saved = SessionState.shared.restoreWorkspaces()
        guard !saved.isEmpty else { return false }

        // Remove the default workspace created at init
        workspaces.removeAll()
        activeWorkspaceIndex = -1

        for savedWs in saved {
            let color = WorkspaceColor(rawValue: savedWs.color) ?? WorkspaceColor.color(at: savedWs.position)
            let workspace = Workspace(
                name: savedWs.name,
                icon: savedWs.icon,
                color: color,
                ghosttyApp: ghosttyApp,
                skipInitialTab: true
            )
            workspaces.append(workspace)

            // Restore project roots
            for rootPath in savedWs.projectRootPaths {
                guard FileManager.default.fileExists(atPath: rootPath) else { continue }
                workspace.addProjectRoot(path: rootPath)
            }

            // Restore tabs
            for tab in savedWs.tabs {
                let beforeCount = workspace.tabs.count
                restoreTab(tab, into: workspace)
                if tab.pinned, workspace.tabs.count > beforeCount {
                    workspace.tabs[workspace.tabs.count - 1].isPinned = true
                }
            }

            // Re-enable auto-terminal creation now that restore is complete
            workspace.finishRestore()

            // If no tabs were restored, add a default terminal
            if workspace.tabs.isEmpty {
                workspace.addTerminalTab()
            }

            // Restore active tab (fall back to 0 if some tabs failed to restore)
            if savedWs.activeTabIndex >= 0 && savedWs.activeTabIndex < workspace.tabs.count {
                workspace.selectTab(savedWs.activeTabIndex)
            } else if !workspace.tabs.isEmpty {
                workspace.selectTab(0)
            }
        }

        // Restore active workspace
        let activeIndex = SessionState.shared.restoreActiveWorkspaceIndex()
        if activeIndex >= 0 && activeIndex < workspaces.count {
            switchTo(index: activeIndex)
        } else if !workspaces.isEmpty {
            switchTo(index: 0)
        }

        return true
    }

    private func restoreTab(_ savedTab: SessionState.SavedTab, into workspace: Workspace) {
        guard let tabType = WorkspaceTab.TabType(rawValue: savedTab.type) else {
            print("[Session] Unknown tab type in session: '\(savedTab.type)', skipping")
            return
        }

        switch tabType {
        case .terminal:
            let workingDir = savedTab.resourcePath.isEmpty ? nil : savedTab.resourcePath
            var restoreCmd: String? = nil

            if let scrollbackPath = SessionState.shared.scrollbackPath(forSurfaceId: savedTab.id) {
                let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                // Write a temporary restore script that displays saved scrollback,
                // cleans up both files, then execs the user's login shell
                let scriptPath = NSTemporaryDirectory() + "clome-restore-\(savedTab.id).sh"
                let script = """
                #!/bin/sh
                cat "\(scrollbackPath)" 2>/dev/null
                rm -f "\(scrollbackPath)" 2>/dev/null
                rm -f "\(scriptPath)" 2>/dev/null
                exec \(shell) -l
                """
                try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: scriptPath
                )
                restoreCmd = scriptPath
            }

            workspace.addTerminalTab(workingDirectory: workingDir, restoreCommand: restoreCmd)

        case .browser:
            let urlStr = savedTab.resourcePath.isEmpty ? nil : savedTab.resourcePath
            if let urlStr, URL(string: urlStr) == nil {
                print("[Session] Invalid browser URL: \(urlStr), opening blank")
                workspace.addBrowserTab(url: nil)
            } else {
                workspace.addBrowserTab(url: urlStr)
            }

        case .editor:
            guard !savedTab.resourcePath.isEmpty else { return }
            guard FileManager.default.fileExists(atPath: savedTab.resourcePath) else {
                print("[Session] Skipping editor tab: file not found at \(savedTab.resourcePath)")
                return
            }
            try? workspace.addEditorTab(path: savedTab.resourcePath)

        case .project:
            // Saved .project tabs are restored as project roots + editor tabs
            guard !savedTab.resourcePath.isEmpty else { return }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: savedTab.resourcePath, isDirectory: &isDir),
                  isDir.boolValue else {
                print("[Session] Skipping project: directory not found at \(savedTab.resourcePath)")
                return
            }
            workspace.addProjectRoot(path: savedTab.resourcePath)
            // Restore open sub-files as editor tabs
            if !savedTab.extraData.isEmpty,
               let data = savedTab.extraData.data(using: .utf8),
               let paths = try? JSONSerialization.jsonObject(with: data) as? [String] {
                for filePath in paths {
                    guard FileManager.default.fileExists(atPath: filePath) else { continue }
                    try? workspace.addEditorTab(path: filePath)
                }
            }

        case .pdf:
            guard !savedTab.resourcePath.isEmpty else { return }
            guard FileManager.default.fileExists(atPath: savedTab.resourcePath) else {
                print("[Session] Skipping pdf tab: file not found at \(savedTab.resourcePath)")
                return
            }
            workspace.addPDFTab(path: savedTab.resourcePath)

        case .notebook:
            guard !savedTab.resourcePath.isEmpty else { return }
            guard FileManager.default.fileExists(atPath: savedTab.resourcePath) else {
                print("[Session] Skipping notebook tab: file not found at \(savedTab.resourcePath)")
                return
            }
            try? workspace.addNotebookTab(path: savedTab.resourcePath)

        case .diff:
            break  // Transient, skip

        case .flow:
            workspace.addFlowTab()
        }
    }
}
