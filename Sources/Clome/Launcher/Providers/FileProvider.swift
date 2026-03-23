import AppKit

/// Provides file search across all project roots in the active workspace.
@MainActor
class FileProvider: LauncherProvider {
    let sectionTitle = "Files"
    let sectionIcon = "doc"

    private weak var workspaceManager: WorkspaceManager?

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    func search(query: String) -> [LauncherItem] {
        guard let wm = workspaceManager else { return [] }
        let lowQuery = query.lowercased()

        // If no query, show nothing (files are too many to show all)
        if lowQuery.isEmpty { return [] }

        var items: [LauncherItem] = []
        let maxResults = 15

        // Search across all workspaces' project roots
        for workspace in wm.workspaces {
            for root in workspace.projectRoots {
                searchTree(root.fileTree, query: lowQuery, rootPath: root.path, items: &items, limit: maxResults, depth: 0)
                if items.count >= maxResults { break }
            }
            if items.count >= maxResults { break }
        }

        return Array(items.prefix(maxResults))
    }

    func actions(for item: LauncherItem) -> [LauncherAction] {
        guard item.provider == "file" else { return [] }

        return [
            LauncherAction(title: "Open", icon: "doc", shortcut: "Enter") { },
            LauncherAction(title: "Reveal in Finder", icon: "folder", shortcut: "\u{2318}Enter") {
                if let payload = item.payload as? FilePayload {
                    NSWorkspace.shared.selectFile(payload.filePath, inFileViewerRootedAtPath: "")
                }
            },
        ]
    }

    // MARK: - Tree Search

    private static let maxSearchDepth = 3

    private func searchTree(_ node: FileTreeNode, query: String, rootPath: String, items: inout [LauncherItem], limit: Int, depth: Int) {
        guard items.count < limit else { return }
        guard depth <= Self.maxSearchDepth else { return }

        if !node.isDirectory {
            let name = node.name.lowercased()
            if name.contains(query) {
                // Relative path from project root
                let relativePath = node.path.hasPrefix(rootPath)
                    ? String(node.path.dropFirst(rootPath.count))
                    : node.path

                let rootName = (rootPath as NSString).lastPathComponent
                let icon = fileIcon(for: node.name)

                items.append(LauncherItem(
                    id: "file-\(node.path)",
                    icon: icon,
                    iconColor: NSColor(white: 0.55, alpha: 1.0),
                    title: node.name,
                    subtitle: "\(rootName)\(relativePath.hasPrefix("/") ? "" : "/")\((relativePath as NSString).deletingLastPathComponent)",
                    provider: "file",
                    payload: FilePayload(filePath: node.path),
                    priority: name == query ? 100 : (name.hasPrefix(query) ? 50 : 0)
                ))
            }
        }

        // Recurse into children — load lazily for unexpanded directories
        if node.isDirectory && node.children == nil {
            node.loadChildren()
        }
        if let children = node.children {
            for child in children {
                searchTree(child, query: query, rootPath: rootPath, items: &items, limit: limit, depth: depth + 1)
                if items.count >= limit { return }
            }
        }
    }

    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "py": return "doc.text"
        case "js", "ts", "jsx", "tsx": return "doc.text"
        case "rs": return "doc.text"
        case "go": return "doc.text"
        case "md": return "doc.richtext"
        case "json", "yml", "yaml", "toml": return "gearshape"
        case "html", "css": return "globe"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }
}

/// Payload for file items.
@MainActor
class FilePayload: NSObject {
    let filePath: String

    init(filePath: String) {
        self.filePath = filePath
    }
}
