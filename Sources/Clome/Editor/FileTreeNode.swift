import Foundation

/// Git status for a file in the working tree.
enum GitFileStatus: String {
    case modified = "M"        // Modified in working tree
    case staged = "A"          // Staged (added to index)
    case stagedModified = "SM" // Staged + modified in working tree
    case deleted = "D"         // Deleted
    case renamed = "R"         // Renamed
    case untracked = "?"       // Untracked
    case conflict = "U"        // Merge conflict
    case ignored = "!"         // Ignored
}

/// Tracks git status for files in a repository.
class GitStatusTracker {
    private(set) var fileStatuses: [String: GitFileStatus] = [:]
    private(set) var isGitRepo: Bool = false
    private(set) var gitRoot: String?

    func refresh(for rootPath: String) {
        // Find git root
        var dir = rootPath
        while dir != "/" {
            if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
                gitRoot = dir
                isGitRepo = true
                break
            }
            dir = (dir as NSString).deletingLastPathComponent
        }

        guard isGitRepo, let root = gitRoot else {
            fileStatuses = [:]
            return
        }

        // Run git status --porcelain=v1
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["status", "--porcelain=v1", "-uall"]
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            fileStatuses = [:]
            return
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            fileStatuses = [:]
            return
        }

        var statuses: [String: GitFileStatus] = [:]
        for line in output.components(separatedBy: "\n") where line.count >= 4 {
            let index = line[line.startIndex]          // index status (X)
            let workTree = line[line.index(after: line.startIndex)] // work-tree status (Y)
            let filePath = String(line.dropFirst(3))
            let absPath = (root as NSString).appendingPathComponent(filePath)

            let status: GitFileStatus
            if index == "?" && workTree == "?" {
                status = .untracked
            } else if index == "!" && workTree == "!" {
                status = .ignored
            } else if index == "U" || workTree == "U" || (index == "A" && workTree == "A") || (index == "D" && workTree == "D") {
                status = .conflict
            } else if index == "A" || index == "M" || index == "R" || index == "C" {
                if workTree == "M" {
                    status = .stagedModified
                } else {
                    status = .staged
                }
            } else if workTree == "M" {
                status = .modified
            } else if index == "D" || workTree == "D" {
                status = .deleted
            } else if index == "R" {
                status = .renamed
            } else {
                status = .modified
            }
            statuses[absPath] = status

            // Propagate status up to parent directories
            var parent = (absPath as NSString).deletingLastPathComponent
            while parent.count > root.count {
                if let existing = statuses[parent] {
                    // Keep the "most important" status for directories
                    if statusPriority(status) > statusPriority(existing) {
                        statuses[parent] = status
                    }
                } else {
                    statuses[parent] = status
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }

        fileStatuses = statuses
    }

    func status(for path: String) -> GitFileStatus? {
        return fileStatuses[path]
    }

    private func statusPriority(_ status: GitFileStatus) -> Int {
        switch status {
        case .conflict: return 6
        case .stagedModified: return 5
        case .staged: return 4
        case .modified: return 3
        case .deleted: return 2
        case .untracked: return 1
        case .renamed: return 3
        case .ignored: return 0
        }
    }
}

/// Represents a node in a file system tree (file or directory).
class FileTreeNode {
    let name: String
    let path: String
    let isDirectory: Bool
    var children: [FileTreeNode]?
    var isExpanded: Bool = false

    /// Whether this is a temporary placeholder for inline creation.
    var isPlaceholder: Bool = false

    init(path: String) {
        self.path = path
        self.name = (path as NSString).lastPathComponent

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        self.isDirectory = isDir.boolValue
    }

    /// Private init for placeholders.
    private init(name: String, path: String, isDirectory: Bool, placeholder: Bool) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isPlaceholder = placeholder
    }

    /// Creates a placeholder node for inline file/folder creation.
    static func placeholder(parentPath: String, isDirectory: Bool) -> FileTreeNode {
        let node = FileTreeNode(
            name: "",
            path: (parentPath as NSString).appendingPathComponent("__clome_placeholder__"),
            isDirectory: isDirectory,
            placeholder: true
        )
        if isDirectory { node.children = [] }
        return node
    }

    /// Lazily loads children for a directory node.
    func loadChildren() {
        guard isDirectory, children == nil else { return }
        let fm = FileManager.default
        do {
            let items = try fm.contentsOfDirectory(atPath: path)
            children = items
                .filter { !$0.hasPrefix(".") } // hide dotfiles
                .map { FileTreeNode(path: (path as NSString).appendingPathComponent($0)) }
                .sorted { a, b in
                    // Directories first, then alphabetical
                    if a.isDirectory != b.isDirectory { return a.isDirectory }
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
        } catch {
            children = []
        }
    }

    /// Reloads children from disk.
    func reload() {
        children = nil
        loadChildren()
    }

    /// Returns the file extension (lowercase), or nil for directories.
    var fileExtension: String? {
        isDirectory ? nil : (name as NSString).pathExtension.lowercased()
    }

    /// SF Symbol name for this node.
    var iconName: String {
        if isDirectory {
            return isExpanded ? "folder.fill" : "folder"
        }
        switch fileExtension {
        case "swift": return "swift"
        case "js", "jsx", "ts", "tsx": return "j.square"
        case "py": return "p.square"
        case "rs": return "r.square"
        case "go": return "g.square"
        case "c", "cpp", "h", "hpp": return "c.square"
        case "zig": return "z.square"
        case "json": return "curlybraces"
        case "md", "txt": return "doc.text"
        case "html", "css": return "globe"
        case "yaml", "yml", "toml": return "gearshape"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo"
        case "pdf": return "doc.richtext"
        case "ipynb": return "book"
        default: return "doc"
        }
    }
}
