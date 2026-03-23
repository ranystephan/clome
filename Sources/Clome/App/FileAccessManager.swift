import Foundation

/// Manages file access to TCC-protected directories (Desktop, Documents, Downloads).
/// Pre-warms access at app launch and caches security-scoped bookmarks to avoid
/// repeated macOS permission prompts.
@MainActor
class FileAccessManager {
    static let shared = FileAccessManager()

    /// Directories that have been successfully accessed (TCC consent granted).
    private var grantedDirectories: Set<String> = []

    /// Security-scoped bookmark data keyed by directory path.
    private var bookmarks: [String: Data] = [:]

    /// Paths currently being accessed via security-scoped resources.
    private var activeAccessPaths: Set<String> = []

    private let bookmarkKey = "FileAccessBookmarks"

    private init() {
        loadBookmarks()
    }

    // MARK: - Pre-warming

    /// Call once at app launch to pre-warm access to common TCC-protected directories.
    /// This triggers a single TCC prompt per directory (if not already granted)
    /// rather than repeated prompts from individual subsystems.
    func prewarmAccess() {
        let home = NSHomeDirectory()
        let protectedDirs = [
            "\(home)/Desktop",
            "\(home)/Documents",
            "\(home)/Downloads",
        ]

        for dir in protectedDirs {
            _ = accessDirectory(dir)
        }

        // Also restore any saved bookmarks
        restoreBookmarkedAccess()
    }

    /// Attempt to access a directory, triggering TCC consent if needed.
    /// Returns true if access was granted.
    @discardableResult
    func accessDirectory(_ path: String) -> Bool {
        // Already granted in this session
        if grantedDirectories.contains(path) { return true }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }

        // Attempt to list directory — this triggers TCC if needed.
        // A single successful access grants consent for the process lifetime.
        if let _ = try? fm.contentsOfDirectory(atPath: path) {
            grantedDirectories.insert(path)
            return true
        }

        return false
    }

    /// Record that a directory was opened via NSOpenPanel (which implicitly grants access).
    /// Saves a security-scoped bookmark for persistent access across launches.
    func recordOpenPanelAccess(url: URL) {
        let path = url.path
        grantedDirectories.insert(path)

        // Save bookmark for future launches
        if let bookmarkData = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            bookmarks[path] = bookmarkData
            saveBookmarks()
        }
    }

    /// Check if a path is within a TCC-protected directory.
    func isProtectedPath(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        let protectedPrefixes = [
            "\(home)/Desktop",
            "\(home)/Documents",
            "\(home)/Downloads",
        ]
        return protectedPrefixes.contains { path.hasPrefix($0) }
    }

    /// Ensure access to a path's parent TCC-protected directory.
    /// Call this before file operations on potentially protected paths.
    @discardableResult
    func ensureAccess(to path: String) -> Bool {
        guard isProtectedPath(path) else { return true }

        let home = NSHomeDirectory()
        let protectedDirs = [
            "\(home)/Desktop",
            "\(home)/Documents",
            "\(home)/Downloads",
        ]

        for dir in protectedDirs {
            if path.hasPrefix(dir) {
                return accessDirectory(dir)
            }
        }

        return true
    }

    // MARK: - Bookmark Persistence

    private func saveBookmarks() {
        UserDefaults.standard.set(bookmarks, forKey: bookmarkKey)
    }

    private func loadBookmarks() {
        if let saved = UserDefaults.standard.dictionary(forKey: bookmarkKey) as? [String: Data] {
            bookmarks = saved
        }
    }

    private func restoreBookmarkedAccess() {
        for (path, data) in bookmarks {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                if isStale {
                    // Refresh bookmark
                    if let newData = try? url.bookmarkData(
                        options: [],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    ) {
                        bookmarks[path] = newData
                    }
                }
                grantedDirectories.insert(url.path)
            } else {
                // Bookmark is invalid, remove it
                bookmarks.removeValue(forKey: path)
            }
        }
        saveBookmarks()
    }
}
