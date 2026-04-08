import AppKit

/// Manages file access to TCC-protected directories (Desktop, Documents, Downloads).
///
/// On non-sandboxed apps, TCC consent is granted per code-signing identity. During
/// development the app is re-signed every build, so macOS treats it as a new app and
/// asks again. To avoid this, we use security-scoped bookmarks obtained from
/// `NSOpenPanel` (which grants implicit user-intent access) and persist them across
/// launches. On subsequent launches (or rebuilds), we resolve the bookmark and call
/// `startAccessingSecurityScopedResource()` to restore access without a prompt.
///
/// For directories we've never opened via `NSOpenPanel`, we attempt a lightweight probe
/// (`fileExists`) which does NOT trigger a TCC prompt on its own. If the probe fails
/// or the directory is known-protected and we have no bookmark, we present an open panel
/// once to get user consent.
@MainActor
class FileAccessManager {
    static let shared = FileAccessManager()

    /// Directories that have been successfully accessed (TCC consent granted or bookmark resolved).
    private var grantedDirectories: Set<String> = []

    /// Security-scoped bookmark data keyed by directory path.
    private var bookmarks: [String: Data] = [:]

    /// URLs currently being accessed via security-scoped resources (must be stopped on quit).
    private var activeSecurityScopedURLs: [String: URL] = [:]

    private let bookmarkKey = "FileAccessBookmarks"

    private init() {
        loadBookmarks()
    }

    deinit {
        // Balance all startAccessingSecurityScopedResource() calls
        for (_, url) in activeSecurityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - Pre-warming

    /// Call once at app launch to restore bookmarked access silently.
    /// Does NOT trigger any TCC prompts — only resolves existing bookmarks.
    func prewarmAccess() {
        restoreBookmarkedAccess()
    }

    /// Request access to a specific protected directory via NSOpenPanel.
    /// Only call this when the user is actively trying to open something in that directory.
    /// Returns true if access was granted.
    @discardableResult
    func requestAccessIfNeeded(for directoryPath: String) -> Bool {
        // Try resolving existing bookmark first
        if let data = bookmarks[directoryPath], resolveBookmark(data: data, forPath: directoryPath) {
            return true
        }

        // If we only have transient TCC access, still escalate to NSOpenPanel so we can
        // create a durable bookmark and stop future rebuilds/terminal launches from
        // falling back to the system permission sheet again.
        if hasPersistentAccess(for: directoryPath) {
            return true
        }

        // Show open panel — the user is actively trying to access this directory
        requestAccessViaOpenPanel(directoryPath: directoryPath)
        return grantedDirectories.contains(directoryPath)
    }

    /// Attempt to access a directory. Returns true if already granted.
    /// Does NOT trigger TCC prompts — use `ensureAccess(to:)` for that.
    @discardableResult
    func accessDirectory(_ path: String) -> Bool {
        if grantedDirectories.contains(path) { return true }

        // Try resolving a bookmark
        if let data = bookmarks[path] {
            if resolveBookmark(data: data, forPath: path) {
                return true
            }
        }

        // Lightweight probe — fileExists usually doesn't trigger TCC for directories
        if probeAccess(path) {
            grantedDirectories.insert(path)
            return true
        }

        return false
    }

    /// Record that a path was opened via NSOpenPanel (which implicitly grants access).
    /// Saves a security-scoped bookmark for persistent access across launches/rebuilds.
    /// Also bookmarks the parent TCC-protected directory if applicable.
    func recordOpenPanelAccess(url: URL) {
        let path = url.path
        grantedDirectories.insert(path)
        saveBookmark(for: url, path: path)

        // Also bookmark the parent protected directory so future access within it works
        let home = NSHomeDirectory()
        for dir in ["\(home)/Desktop", "\(home)/Documents", "\(home)/Downloads"] {
            if path.hasPrefix(dir), !grantedDirectories.contains(dir) {
                let dirURL = URL(fileURLWithPath: dir)
                grantedDirectories.insert(dir)
                saveBookmark(for: dirURL, path: dir)
                break
            }
        }
    }

    /// Check if a path is within a TCC-protected directory.
    func isProtectedPath(_ path: String) -> Bool {
        protectedDirectory(containing: path) != nil
    }

    /// Returns the top-level TCC-protected directory that contains the path.
    func protectedDirectory(containing path: String) -> String? {
        let home = NSHomeDirectory()
        let protectedDirs = [
            "\(home)/Desktop",
            "\(home)/Documents",
            "\(home)/Downloads",
        ]

        return protectedDirs.first { dir in
            path == dir || path.hasPrefix(dir + "/")
        }
    }

    /// Check if we already have access to a path's parent TCC-protected directory.
    /// Returns true if access is already granted (via bookmark or TCC consent).
    /// Does NOT show any prompts — use `requestAccessIfNeeded(for:)` for that.
    @discardableResult
    func ensureAccess(to path: String) -> Bool {
        guard let dir = protectedDirectory(containing: path) else { return true }
        return accessDirectory(dir)
    }

    /// Prompts once for a durable bookmark when a terminal/project is about to use a
    /// protected path as its working directory. Returns false if the user declines.
    @discardableResult
    func requestPersistentAccess(for path: String) -> Bool {
        guard let dir = protectedDirectory(containing: path) else { return true }
        return requestAccessIfNeeded(for: dir)
    }

    // MARK: - Probing (no TCC prompt)

    /// Lightweight check that avoids triggering TCC prompts.
    /// Only uses `fileExists(atPath:)` which does NOT trigger TCC.
    /// NOTE: `attributesOfItem` and `contentsOfDirectory` DO trigger TCC — never use them here.
    private func probeAccess(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - NSOpenPanel Access

    /// Shows an NSOpenPanel pre-set to the given directory. On approval, saves a
    /// security-scoped bookmark so we never need to ask again (even across rebuilds).
    private func requestAccessViaOpenPanel(directoryPath: String) {
        let url = URL(fileURLWithPath: directoryPath)
        let dirName = url.lastPathComponent

        let panel = NSOpenPanel()
        panel.message = "Clome needs access to your \(dirName) folder for project files.\nSelect the \(dirName) folder to grant permanent access."
        panel.prompt = "Grant Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = url
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = false

        let response = panel.runModal()
        if response == .OK, let selectedURL = panel.url {
            grantedDirectories.insert(selectedURL.path)
            // Also mark the intended directory if user selected it
            if selectedURL.path == directoryPath || selectedURL.standardizedFileURL.path == url.standardizedFileURL.path {
                grantedDirectories.insert(directoryPath)
            }
            saveBookmark(for: selectedURL, path: directoryPath)
            print("[FileAccessManager] Access granted to \(dirName) via open panel")
        } else {
            print("[FileAccessManager] User declined access to \(dirName)")
        }
    }

    // MARK: - Bookmark Persistence

    private func saveBookmark(for url: URL, path: String) {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            bookmarks[path] = data
            persistBookmarks()
        } catch {
            // Fallback: try without security scope (still useful for non-sandboxed apps)
            if let data = try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                bookmarks[path] = data
                persistBookmarks()
            }
            print("[FileAccessManager] Failed to create security-scoped bookmark for \(path): \(error)")
        }
    }

    private func hasPersistentAccess(for path: String) -> Bool {
        bookmarks[path] != nil || activeSecurityScopedURLs[path] != nil
    }

    private func persistBookmarks() {
        UserDefaults.standard.set(bookmarks, forKey: bookmarkKey)
    }

    private func loadBookmarks() {
        if let saved = UserDefaults.standard.dictionary(forKey: bookmarkKey) as? [String: Data] {
            bookmarks = saved
        }
    }

    private func restoreBookmarkedAccess() {
        var toRemove: [String] = []

        for (path, data) in bookmarks {
            if !resolveBookmark(data: data, forPath: path) {
                toRemove.append(path)
            }
        }

        // Remove invalid bookmarks
        for path in toRemove {
            bookmarks.removeValue(forKey: path)
        }
        if !toRemove.isEmpty {
            persistBookmarks()
        }
    }

    /// Resolve a bookmark and start accessing the security-scoped resource.
    /// Returns true on success.
    private func resolveBookmark(data: Data, forPath path: String) -> Bool {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            // Start accessing the security-scoped resource
            if url.startAccessingSecurityScopedResource() {
                activeSecurityScopedURLs[path] = url
                grantedDirectories.insert(url.path)
                grantedDirectories.insert(path)

                if isStale {
                    // Refresh the bookmark while we have access
                    saveBookmark(for: url, path: path)
                }
                return true
            }
        } catch {
            // Try without security scope flag
            do {
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                grantedDirectories.insert(url.path)
                grantedDirectories.insert(path)
                if isStale {
                    saveBookmark(for: url, path: path)
                }
                return true
            } catch {
                print("[FileAccessManager] Failed to resolve bookmark for \(path): \(error)")
            }
        }
        return false
    }
}
