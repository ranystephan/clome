import Foundation

/// Represents a project root directory within a workspace.
/// A workspace can contain multiple project roots (e.g., frontend + backend).
@MainActor
class ProjectRoot: Identifiable, Equatable {
    let id = UUID()
    let path: String
    let name: String
    let fileTree: FileTreeNode
    let gitTracker: GitStatusTracker
    private var fileWatcher: FileWatcher?
    var isCollapsed: Bool = false

    /// Called when files change on disk (from FileWatcher). Debounced.
    var onFilesChanged: (() -> Void)?

    /// Debounce timer for file change notifications.
    private var fileChangeDebounceTimer: Timer?

    init(path: String) {
        self.path = path
        self.name = (path as NSString).lastPathComponent
        self.fileTree = FileTreeNode(path: path)
        self.gitTracker = GitStatusTracker()

        // Initialize file tree
        fileTree.loadChildren()
        fileTree.isExpanded = true

        // Initial git status
        refreshGitStatus()

        // Watch for file changes — debounced to avoid notification storms during
        // builds, git operations, or npm install.
        let rootPath = path
        fileWatcher = FileWatcher(paths: [rootPath], latency: 2.0) { _ in
            NotificationCenter.default.post(name: .projectRootFilesChanged, object: rootPath)
        }
        fileWatcher?.start()

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleFilesChanged(_:)),
            name: .projectRootFilesChanged, object: path
        )
    }

    @objc private func handleFilesChanged(_ notification: Notification) {
        // Debounce: coalesce rapid file changes into a single reload.
        // Use a longer interval (3s) to avoid flooding TCC-protected directories
        // with repeated file access during active editing (e.g., Claude Code sessions).
        fileChangeDebounceTimer?.invalidate()
        fileChangeDebounceTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.fileTree.reload()
                self.refreshGitStatus()
                self.onFilesChanged?()
            }
        }
    }

    func refreshGitStatus() {
        let rootPath = path
        let tracker = gitTracker
        DispatchQueue.global(qos: .utility).async {
            tracker.refresh(for: rootPath)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .projectRootGitStatusChanged, object: rootPath)
            }
        }
    }

    func stopWatching() {
        fileChangeDebounceTimer?.invalidate()
        fileChangeDebounceTimer = nil
        fileWatcher?.stop()
        fileWatcher = nil
        NotificationCenter.default.removeObserver(self, name: .projectRootFilesChanged, object: path)
    }

    deinit {
        // stopWatching() is @MainActor — schedule cleanup on main if needed.
        // NotificationCenter removal is safe from any thread.
        NotificationCenter.default.removeObserver(self)
    }

    nonisolated static func == (lhs: ProjectRoot, rhs: ProjectRoot) -> Bool {
        lhs.id == rhs.id
    }
}

extension Notification.Name {
    static let projectRootFilesChanged = Notification.Name("projectRootFilesChanged")
    static let projectRootGitStatusChanged = Notification.Name("projectRootGitStatusChanged")
}
