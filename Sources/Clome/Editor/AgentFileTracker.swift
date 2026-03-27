import Foundation

/// Notification posted when agent file changes are detected or review state changes.
extension Notification.Name {
    static let agentFileChanged = Notification.Name("clomeAgentFileChanged")
    static let agentFileReviewStateChanged = Notification.Name("clomeAgentFileReviewStateChanged")
    static let agentTrackingStateChanged = Notification.Name("clomeAgentTrackingStateChanged")
    static let openDiffReview = Notification.Name("clomeOpenDiffReview")
}

/// Tracks file modifications made by Claude Code (or other agents) with before/after
/// content snapshots, enabling diff review and accept/reject workflows.
@MainActor
class AgentFileTracker {
    static let shared = AgentFileTracker()

    // MARK: - Types

    enum ChangeType {
        case created
        case modified
        case deleted
    }

    enum ReviewState {
        case pending
        case accepted
        case rejected
    }

    struct FileChange {
        let path: String
        let changeType: ChangeType
        let oldContent: String?
        let newContent: String?
        let timestamp: Date
        var reviewState: ReviewState

        var addedLines: Int {
            guard let old = oldContent, let new = newContent else {
                return newContent?.components(separatedBy: "\n").count ?? 0
            }
            let oldLines = Set(old.components(separatedBy: "\n"))
            let newLines = new.components(separatedBy: "\n")
            return newLines.filter { !oldLines.contains($0) }.count
        }

        var removedLines: Int {
            guard let old = oldContent, let new = newContent else {
                return oldContent?.components(separatedBy: "\n").count ?? 0
            }
            let newLines = Set(new.components(separatedBy: "\n"))
            let oldLines = old.components(separatedBy: "\n")
            return oldLines.filter { !newLines.contains($0) }.count
        }
    }

    // MARK: - State

    /// All tracked file changes keyed by absolute path.
    private(set) var changes: [String: FileChange] = [:]

    /// Content snapshots captured before agent edits, keyed by path.
    private var snapshots: [String: String] = [:]

    /// Whether we're actively tracking (Claude Code is running).
    private(set) var isTracking: Bool = false

    /// Directory watcher for the active project.
    private var directoryWatcher: FileWatcher?

    /// Paths currently being watched.
    private var watchedRoots: Set<String> = []

    /// Timer to auto-clear accepted changes after a delay.
    private var cleanupTimer: Timer?

    /// Paths currently being reverted by a reject action — suppresses re-detection.
    private var revertingPaths: Set<String> = []

    // MARK: - Tracking Lifecycle

    /// Begin tracking file changes in the given project directories.
    /// Called when Claude Code is detected as active.
    func startTracking(roots: [String]) {
        guard !isTracking else { return }
        isTracking = true
        watchedRoots = Set(roots)

        // Start directory watcher with short latency for responsiveness
        directoryWatcher?.stop()
        directoryWatcher = FileWatcher(paths: roots, latency: 0.5) { [weak self] paths in
            Task { @MainActor in
                self?.handleFileSystemChanges(paths)
            }
        }
        directoryWatcher?.start()

        NotificationCenter.default.post(name: .agentTrackingStateChanged, object: self)
    }

    /// Stop tracking. Called when Claude Code exits or goes idle.
    func stopTracking() {
        guard isTracking else { return }
        isTracking = false
        directoryWatcher?.stop()
        directoryWatcher = nil
        watchedRoots.removeAll()

        NotificationCenter.default.post(name: .agentTrackingStateChanged, object: self)

        // Start cleanup timer — remove accepted changes after 10s
        cleanupTimer?.invalidate()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.clearAcceptedChanges()
            }
        }
    }

    // MARK: - Snapshot Management

    /// Explicitly snapshot a file's current content (called by editors on open or before agent runs).
    func snapshotFile(at path: String) {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        snapshots[path] = content
    }

    /// Snapshot content directly (when buffer content is already available).
    func snapshotContent(_ content: String, forPath path: String) {
        snapshots[path] = content
    }

    // MARK: - Change Detection

    private func handleFileSystemChanges(_ paths: [String]) {
        for path in paths {
            // Skip paths being reverted by a reject action
            if revertingPaths.contains(path) {
                revertingPaths.remove(path)
                continue
            }

            // Skip hidden files, build artifacts, .git directory
            let components = path.components(separatedBy: "/")
            if components.contains(where: { $0.hasPrefix(".") && $0 != ".env" }) { continue }
            if components.contains("DerivedData") || components.contains("build") { continue }
            if components.contains("node_modules") { continue }

            let fm = FileManager.default
            let exists = fm.fileExists(atPath: path)

            // Only track text files
            if exists {
                guard isTextFile(path) else { continue }
            }

            if !exists && snapshots[path] != nil {
                // File was deleted
                recordChange(path: path, type: .deleted, oldContent: snapshots[path], newContent: nil)
            } else if exists && snapshots[path] == nil {
                // File was created
                let newContent = try? String(contentsOfFile: path, encoding: .utf8)
                recordChange(path: path, type: .created, oldContent: nil, newContent: newContent)
            } else if exists {
                // File was modified — compare with snapshot
                guard let newContent = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                let oldContent = snapshots[path]
                if newContent != oldContent {
                    recordChange(path: path, type: .modified, oldContent: oldContent, newContent: newContent)
                }
            }
        }
    }

    private func recordChange(path: String, type: ChangeType, oldContent: String?, newContent: String?) {
        let change = FileChange(
            path: path,
            changeType: type,
            oldContent: oldContent,
            newContent: newContent,
            timestamp: Date(),
            reviewState: .pending
        )
        changes[path] = change

        NotificationCenter.default.post(
            name: .agentFileChanged,
            object: self,
            userInfo: ["path": path, "change": change]
        )
    }

    /// Record a change explicitly (e.g. from socket API with provided content).
    func recordExternalChange(path: String, oldContent: String?, newContent: String?) {
        // Skip if both nil or content is identical
        if oldContent == nil && newContent == nil { return }
        if oldContent == newContent { return }

        let type: ChangeType
        if oldContent == nil {
            type = .created
        } else if newContent == nil {
            type = .deleted
        } else {
            type = .modified
        }
        recordChange(path: path, type: type, oldContent: oldContent, newContent: newContent)
    }

    // MARK: - Review Actions

    func acceptChange(at path: String) {
        guard var change = changes[path] else { return }
        change.reviewState = .accepted
        changes[path] = change

        // Update snapshot to new content
        if let newContent = change.newContent {
            snapshots[path] = newContent
        } else {
            snapshots.removeValue(forKey: path)
        }

        NotificationCenter.default.post(name: .agentFileReviewStateChanged, object: self, userInfo: ["path": path])
    }

    func rejectChange(at path: String) {
        guard var change = changes[path] else { return }
        change.reviewState = .rejected
        changes[path] = change

        // Mark path as reverting so file watchers ignore the disk write
        revertingPaths.insert(path)

        // Revert file to old content
        if let oldContent = change.oldContent {
            try? oldContent.write(toFile: path, atomically: true, encoding: .utf8)
            snapshots[path] = oldContent
        } else if change.changeType == .created {
            // Remove the created file
            try? FileManager.default.removeItem(atPath: path)
            snapshots.removeValue(forKey: path)
        }

        NotificationCenter.default.post(name: .agentFileReviewStateChanged, object: self, userInfo: ["path": path])
    }

    func acceptAll() {
        let pendingPaths = changes.filter { $0.value.reviewState == .pending }.map { $0.key }
        for path in pendingPaths {
            acceptChange(at: path)
        }
    }

    func rejectAll() {
        let pendingPaths = changes.filter { $0.value.reviewState == .pending }.map { $0.key }
        for path in pendingPaths {
            rejectChange(at: path)
        }
    }

    // MARK: - Queries

    var pendingChanges: [FileChange] {
        changes.values.filter { $0.reviewState == .pending }.sorted { $0.timestamp > $1.timestamp }
    }

    var pendingCount: Int {
        changes.values.filter { $0.reviewState == .pending }.count
    }

    var allChanges: [FileChange] {
        changes.values.sorted { $0.timestamp > $1.timestamp }
    }

    func change(for path: String) -> FileChange? {
        changes[path]
    }

    // MARK: - Cleanup

    func clearAll() {
        changes.removeAll()
        snapshots.removeAll()
        NotificationCenter.default.post(name: .agentFileReviewStateChanged, object: self)
    }

    private func clearAcceptedChanges() {
        let accepted = changes.filter { $0.value.reviewState != .pending }
        for path in accepted.keys {
            changes.removeValue(forKey: path)
        }
        if !accepted.isEmpty {
            NotificationCenter.default.post(name: .agentFileReviewStateChanged, object: self)
        }
    }

    // MARK: - Helpers

    private func isTextFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        let textExtensions: Set<String> = [
            "swift", "rs", "py", "js", "ts", "jsx", "tsx", "go", "c", "h", "cpp", "hpp",
            "java", "kt", "cs", "rb", "php", "zig", "lua", "sh", "bash", "zsh", "fish",
            "json", "yaml", "yml", "toml", "xml", "html", "css", "scss", "sass", "less",
            "md", "txt", "rst", "tex", "bib", "sql", "graphql", "proto", "dockerfile",
            "makefile", "cmake", "gradle", "env", "ini", "cfg", "conf", "lock",
            "gitignore", "gitattributes", "editorconfig", "eslintrc", "prettierrc",
        ]
        if textExtensions.contains(ext) { return true }
        // Extensionless files that are commonly text
        let name = (path as NSString).lastPathComponent.lowercased()
        let textNames: Set<String> = ["dockerfile", "makefile", "rakefile", "gemfile", "procfile", ".env", ".gitignore"]
        return textNames.contains(name)
    }

    private init() {}
}
