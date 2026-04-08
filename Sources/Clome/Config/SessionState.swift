import AppKit
import SQLite3

/// Manages persistent session state (workspace layouts, scroll positions, etc.)
/// Uses SQLite for ACID-safe storage.
@MainActor
class SessionState {
    static let shared = SessionState()

    private var db: OpaquePointer?
    private let dbPath: String

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let clomeDir = appSupport.appendingPathComponent("Clome")
        try? FileManager.default.createDirectory(at: clomeDir, withIntermediateDirectories: true)
        dbPath = clomeDir.appendingPathComponent("session.db").path
        openDatabase()
        guard db != nil else { return }
        createTables()
        migrateSchema()
    }

    func close() {
        sqlite3_close(db)
        db = nil
    }

    // MARK: - Database

    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("Failed to open session database at \(dbPath)")
            db = nil
            return
        }
        // Performance and safety pragmas
        sqlite3_exec(db, "PRAGMA journal_mode = WAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous = NORMAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil)
        sqlite3_busy_timeout(db, 5000)
    }

    private func createTables() {
        guard db != nil else { return }
        let sql = """
        CREATE TABLE IF NOT EXISTS workspaces (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            icon TEXT NOT NULL DEFAULT 'terminal',
            position INTEGER NOT NULL,
            created_at REAL NOT NULL,
            color TEXT NOT NULL DEFAULT 'blue'
        );

        CREATE TABLE IF NOT EXISTS surfaces (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL,
            type TEXT NOT NULL DEFAULT 'terminal',
            working_directory TEXT,
            title TEXT,
            position INTEGER NOT NULL,
            split_path TEXT,
            url TEXT,
            FOREIGN KEY (workspace_id) REFERENCES workspaces(id)
        );

        CREATE TABLE IF NOT EXISTS window_state (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func migrateSchema() {
        guard db != nil else { return }
        let version = Int(getValue(key: "schema_version") ?? "0") ?? 0
        if version < 1 {
            // Add color column (idempotent — ALTER TABLE fails silently if column already exists)
            sqlite3_exec(db, "ALTER TABLE workspaces ADD COLUMN color TEXT NOT NULL DEFAULT 'blue'", nil, nil, nil)
            upsert(key: "schema_version", value: "1")
        }
        if version < 2 {
            let sql = """
            CREATE TABLE IF NOT EXISTS pinned_files (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                path TEXT NOT NULL UNIQUE,
                position INTEGER NOT NULL
            )
            """
            sqlite3_exec(db, sql, nil, nil, nil)
            upsert(key: "schema_version", value: "2")
        }
        if version < 3 {
            let sql = """
            CREATE TABLE IF NOT EXISTS claude_sessions (
                session_id TEXT PRIMARY KEY,
                name TEXT,
                pinned INTEGER NOT NULL DEFAULT 0,
                last_opened REAL
            )
            """
            sqlite3_exec(db, sql, nil, nil, nil)
            upsert(key: "schema_version", value: "3")
        }
        if version < 4 {
            let sql = """
            CREATE TABLE IF NOT EXISTS project_roots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                workspace_id TEXT NOT NULL,
                path TEXT NOT NULL,
                position INTEGER NOT NULL,
                FOREIGN KEY (workspace_id) REFERENCES workspaces(id)
            );
            CREATE TABLE IF NOT EXISTS open_editors (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                workspace_id TEXT NOT NULL,
                path TEXT NOT NULL,
                position INTEGER NOT NULL,
                is_preview INTEGER NOT NULL DEFAULT 0,
                FOREIGN KEY (workspace_id) REFERENCES workspaces(id)
            );
            """
            sqlite3_exec(db, sql, nil, nil, nil)
            upsert(key: "schema_version", value: "4")
        }
        if version < 5 {
            // Pinned tab support — idempotent ALTER (fails silently if column already exists)
            sqlite3_exec(db, "ALTER TABLE surfaces ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0", nil, nil, nil)
            upsert(key: "schema_version", value: "5")
        }
    }

    // MARK: - Pinned Files

    func savePinnedFiles(_ paths: [String]) {
        guard db != nil else { return }
        guard beginTransaction() else { return }
        sqlite3_exec(db, "DELETE FROM pinned_files", nil, nil, nil)
        let sql = "INSERT INTO pinned_files (path, position) VALUES (?, ?)"
        for (index, path) in paths.enumerated() {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (path as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 2, Int32(index))
                let rc = sqlite3_step(stmt)
                if rc != SQLITE_DONE {
                    print("SessionState: INSERT pinned_file failed: \(errorMessage())")
                }
                sqlite3_finalize(stmt)
            }
        }
        commitTransaction()
    }

    func restorePinnedFiles() -> [String] {
        guard db != nil else { return [] }
        var paths: [String] = []
        let sql = "SELECT path FROM pinned_files ORDER BY position"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let ptr = sqlite3_column_text(stmt, 0) {
                    paths.append(String(cString: ptr))
                }
            }
            sqlite3_finalize(stmt)
        }
        return paths
    }

    // MARK: - Transaction Helpers

    private func beginTransaction() -> Bool {
        let rc = sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        if rc != SQLITE_OK {
            print("SessionState: BEGIN IMMEDIATE failed: \(errorMessage())")
            return false
        }
        return true
    }

    private func commitTransaction() {
        let rc = sqlite3_exec(db, "COMMIT", nil, nil, nil)
        if rc != SQLITE_OK {
            print("SessionState: COMMIT failed: \(errorMessage())")
        }
    }

    /// SQLITE_TRANSIENT tells SQLite to copy the string immediately,
    /// so the caller's temporary NSString can be safely released.
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func rollbackTransaction() {
        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
    }

    private func errorMessage() -> String {
        if let errPtr = sqlite3_errmsg(db) {
            return String(cString: errPtr)
        }
        return "unknown error"
    }

    // MARK: - Save

    func saveWindowFrame(_ frame: NSRect) {
        guard db != nil else { return }
        let value = NSStringFromRect(frame)
        upsert(key: "window_frame", value: value)
    }

    func saveSidebarVisible(_ visible: Bool) {
        guard db != nil else { return }
        upsert(key: "sidebar_visible", value: visible ? "1" : "0")
    }

    func saveWorkspaces(_ workspaces: [Workspace], activeIndex: Int) {
        guard db != nil else { return }
        guard beginTransaction() else { return }

        // Clear old scrollback files before saving new ones
        clearAllScrollback()

        var success = true

        // Clear existing — delete child tables BEFORE parent (foreign key constraints)
        sqlite3_exec(db, "DELETE FROM surfaces", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM project_roots", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM open_editors", nil, nil, nil)  // May exist from migration
        if sqlite3_exec(db, "DELETE FROM workspaces", nil, nil, nil) != SQLITE_OK {
            print("SessionState: DELETE FROM workspaces failed: \(errorMessage())")
            success = false
        }

        if success {
            for (index, workspace) in workspaces.enumerated() {
                let sql = "INSERT INTO workspaces (id, name, icon, position, created_at, color) VALUES (?, ?, ?, ?, ?, ?)"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    let idStr = workspace.id.uuidString
                    sqlite3_bind_text(stmt, 1, (idStr as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 2, (workspace.name as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 3, (workspace.icon as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int(stmt, 4, Int32(index))
                    sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
                    let colorValue = workspace.color.rawValue
                    sqlite3_bind_text(stmt, 6, (colorValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    let rc = sqlite3_step(stmt)
                    if rc != SQLITE_DONE {
                        print("SessionState: INSERT workspace failed: \(errorMessage())")
                        success = false
                    }
                    sqlite3_finalize(stmt)

                    if success {
                        // Save tabs for this workspace (inside the same transaction)
                        saveTabs(workspace.tabs, workspaceId: idStr, activeTabIndex: workspace.activeTabIndex)
                        // Save project roots
                        saveProjectRoots(workspace.projectRoots, workspaceId: idStr)
                    }
                } else {
                    print("SessionState: prepare INSERT workspace failed: \(errorMessage())")
                    success = false
                }
                if !success { break }
            }
        }

        if success {
            // Save active workspace index inside the same transaction
            upsert(key: "active_workspace_index", value: "\(activeIndex)")
            commitTransaction()
        } else {
            rollbackTransaction()
        }
    }

    private func saveTabs(_ tabs: [WorkspaceTab], workspaceId: String, activeTabIndex: Int) {
        for (index, tab) in tabs.enumerated() {
            if tab.type == .diff { continue } // Skip transient diff tabs

            // Determine the path/URL and optional extra data for the tab
            var resourcePath = ""
            var extraData = "" // JSON for project open files or split layout
            switch tab.type {
            case .terminal:
                if let terminal = tab.view as? TerminalSurface, let pwd = terminal.workingDirectory {
                    resourcePath = pwd
                }
            case .browser:
                if let browser = tab.view as? BrowserPanel {
                    resourcePath = browser.currentURL?.absoluteString ?? ""
                }
            case .editor:
                if let editor = tab.view as? EditorPanel {
                    resourcePath = editor.filePath ?? ""
                }
            case .project:
                if let project = tab.view as? ProjectPanel {
                    resourcePath = project.rootDirectory
                    let openPaths = project.openFilePaths
                    if !openPaths.isEmpty,
                       let data = try? JSONSerialization.data(withJSONObject: openPaths),
                       let json = String(data: data, encoding: .utf8) {
                        extraData = json
                    }
                }
            case .pdf:
                if let pdf = tab.view as? PDFPanel {
                    resourcePath = pdf.filePath ?? ""
                }
            case .notebook:
                if let notebook = tab.view as? NotebookPanel {
                    resourcePath = notebook.filePath ?? ""
                }
            case .diff:
                break
            case .flow:
                break
            }

            let surfaceId = UUID().uuidString

            // For terminal tabs, save the scrollback content to a file
            if tab.type == .terminal, let terminal = tab.view as? TerminalSurface {
                if let scrollback = terminal.readFullScrollback(), !scrollback.isEmpty {
                    saveTerminalScrollback(scrollback, forSurfaceId: surfaceId)
                }
            }

            let sql = "INSERT INTO surfaces (id, workspace_id, type, working_directory, title, position, url, split_path, pinned) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (surfaceId as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, (workspaceId as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, (tab.type.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, (resourcePath as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 5, (tab.title as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 6, Int32(index))
                sqlite3_bind_text(stmt, 7, (resourcePath as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 8, (extraData as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 9, tab.isPinned ? 1 : 0)
                let rc = sqlite3_step(stmt)
                if rc != SQLITE_DONE {
                    print("SessionState: INSERT surface failed: \(errorMessage())")
                }
                sqlite3_finalize(stmt)
            } else {
                print("SessionState: prepare INSERT surface failed: \(errorMessage())")
            }
        }

        // Save active tab index for this workspace (inside the caller's transaction)
        upsert(key: "active_tab_\(workspaceId)", value: "\(activeTabIndex)")
    }

    private func saveProjectRoots(_ roots: [ProjectRoot], workspaceId: String) {
        let sql = "INSERT INTO project_roots (workspace_id, path, position) VALUES (?, ?, ?)"
        for (index, root) in roots.enumerated() {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (workspaceId as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, (root.path as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 3, Int32(index))
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    // MARK: - Restore

    func restoreWindowFrame() -> NSRect? {
        guard db != nil else { return nil }
        guard let value = getValue(key: "window_frame") else { return nil }
        let rect = NSRectFromString(value)
        return rect == .zero ? nil : rect
    }

    func restoreSidebarVisible() -> Bool {
        guard db != nil else { return true }
        return getValue(key: "sidebar_visible") != "0"
    }

    func restoreActiveWorkspaceIndex() -> Int {
        guard db != nil else { return 0 }
        guard let value = getValue(key: "active_workspace_index") else { return 0 }
        return Int(value) ?? 0
    }

    struct SavedTab {
        let id: String        // surface UUID (used for scrollback file lookup)
        let type: String      // terminal, browser, editor, project, pdf, notebook
        let title: String
        let resourcePath: String  // file path, URL, or working directory
        let position: Int
        let extraData: String // JSON for project open files, split layout, etc.
        let pinned: Bool
    }

    struct SavedWorkspace {
        let id: String
        let name: String
        let icon: String
        let position: Int
        let color: String
        var tabs: [SavedTab]
        var activeTabIndex: Int
        var projectRootPaths: [String]
    }

    func restoreWorkspaces() -> [SavedWorkspace] {
        guard db != nil else { return [] }
        var workspaces: [SavedWorkspace] = []
        let sql = "SELECT id, name, icon, position, color FROM workspaces ORDER BY position"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idPtr = sqlite3_column_text(stmt, 0),
                      let namePtr = sqlite3_column_text(stmt, 1),
                      let iconPtr = sqlite3_column_text(stmt, 2) else {
                    continue
                }
                let id = String(cString: idPtr)
                let name = String(cString: namePtr)
                let icon = String(cString: iconPtr)
                let position = Int(sqlite3_column_int(stmt, 3))
                let color: String
                if let colorPtr = sqlite3_column_text(stmt, 4) {
                    color = String(cString: colorPtr)
                } else {
                    color = "blue"
                }

                let tabs = restoreTabs(forWorkspaceId: id)
                let activeTab = Int(getValue(key: "active_tab_\(id)") ?? "0") ?? 0
                let projectRoots = restoreProjectRoots(forWorkspaceId: id)

                workspaces.append(SavedWorkspace(
                    id: id, name: name, icon: icon, position: position,
                    color: color, tabs: tabs, activeTabIndex: activeTab,
                    projectRootPaths: projectRoots
                ))
            }
            sqlite3_finalize(stmt)
        }
        return workspaces
    }

    private func restoreTabs(forWorkspaceId workspaceId: String) -> [SavedTab] {
        var tabs: [SavedTab] = []
        let sql = "SELECT id, type, title, working_directory, position, split_path, pinned FROM surfaces WHERE workspace_id = ? ORDER BY position"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (workspaceId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idPtr = sqlite3_column_text(stmt, 0),
                      let typePtr = sqlite3_column_text(stmt, 1),
                      let titlePtr = sqlite3_column_text(stmt, 2) else {
                    continue
                }
                let id = String(cString: idPtr)
                let type = String(cString: typePtr)
                let title = String(cString: titlePtr)
                let resourcePath: String
                if let ptr = sqlite3_column_text(stmt, 3) {
                    resourcePath = String(cString: ptr)
                } else {
                    resourcePath = ""
                }
                let position = Int(sqlite3_column_int(stmt, 4))
                let extraData: String
                if let ptr = sqlite3_column_text(stmt, 5) {
                    extraData = String(cString: ptr)
                } else {
                    extraData = ""
                }
                let pinned = sqlite3_column_int(stmt, 6) != 0
                tabs.append(SavedTab(id: id, type: type, title: title, resourcePath: resourcePath, position: position, extraData: extraData, pinned: pinned))
            }
            sqlite3_finalize(stmt)
        }
        return tabs
    }

    private func restoreProjectRoots(forWorkspaceId workspaceId: String) -> [String] {
        var paths: [String] = []
        let sql = "SELECT path FROM project_roots WHERE workspace_id = ? ORDER BY position"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (workspaceId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let ptr = sqlite3_column_text(stmt, 0) {
                    paths.append(String(cString: ptr))
                }
            }
            sqlite3_finalize(stmt)
        }
        return paths
    }

    // MARK: - Appearance

    struct SavedAppearance {
        let backgroundColor: NSColor
        let backgroundOpacity: CGFloat
    }

    func saveAppearance(backgroundColor: NSColor, backgroundOpacity: CGFloat) {
        guard db != nil else { return }
        guard beginTransaction() else { return }
        upsert(key: "bg_color", value: colorToHex(backgroundColor))
        upsert(key: "bg_opacity", value: "\(backgroundOpacity)")
        commitTransaction()
    }

    func restoreAppearance() -> SavedAppearance? {
        guard db != nil else { return nil }
        guard let bc = getValue(key: "bg_color") else { return nil }
        let bo = getValue(key: "bg_opacity").flatMap { CGFloat(Double($0) ?? -1) } ?? 0.92
        return SavedAppearance(
            backgroundColor: hexToColor(bc),
            backgroundOpacity: bo
        )
    }

    private func colorToHex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int(c.redComponent * 255)
        let g = Int(c.greenComponent * 255)
        let b = Int(c.blueComponent * 255)
        return String(format: "%02x%02x%02x", r, g, b)
    }

    private func hexToColor(_ hex: String) -> NSColor {
        var h = hex
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        guard h.count == 6, let val = UInt64(h, radix: 16) else {
            return NSColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
        }
        let r = CGFloat((val >> 16) & 0xFF) / 255.0
        let g = CGFloat((val >> 8) & 0xFF) / 255.0
        let b = CGFloat(val & 0xFF) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    // MARK: - Terminal Scrollback Persistence

    /// Directory where terminal scrollback files are stored.
    private var scrollbackDir: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Clome/scrollback").path
    }

    /// Ensure the scrollback directory exists.
    private func ensureScrollbackDir() {
        try? FileManager.default.createDirectory(atPath: scrollbackDir, withIntermediateDirectories: true)
    }

    /// Save terminal scrollback text for a given surface ID.
    func saveTerminalScrollback(_ text: String, forSurfaceId surfaceId: String) {
        ensureScrollbackDir()
        let path = (scrollbackDir as NSString).appendingPathComponent("\(surfaceId).txt")
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Path to the scrollback file for a given surface ID, or nil if it doesn't exist.
    func scrollbackPath(forSurfaceId surfaceId: String) -> String? {
        let path = (scrollbackDir as NSString).appendingPathComponent("\(surfaceId).txt")
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Remove a scrollback file after it has been restored.
    func removeScrollback(forSurfaceId surfaceId: String) {
        let path = (scrollbackDir as NSString).appendingPathComponent("\(surfaceId).txt")
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Remove all scrollback files (called before saving new ones).
    func clearAllScrollback() {
        let dir = scrollbackDir
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for file in files where file.hasSuffix(".txt") {
            try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(file))
        }
    }

    // MARK: - LSP Custom Paths

    func saveLSPCustomPaths(_ paths: [String: String]) {
        guard db != nil else { return }
        if let data = try? JSONSerialization.data(withJSONObject: paths),
           let json = String(data: data, encoding: .utf8) {
            upsert(key: "lsp_custom_paths", value: json)
        }
    }

    func restoreLSPCustomPaths() -> [String: String] {
        guard db != nil else { return [:] }
        guard let value = getValue(key: "lsp_custom_paths"),
              let data = value.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return obj
    }

    // MARK: - Claude Sessions

    /// Saves or updates a user-assigned name for a Claude session.
    func saveClaudeSessionName(sessionId: String, name: String) {
        guard db != nil else { return }
        let sql = "INSERT INTO claude_sessions (session_id, name) VALUES (?, ?) ON CONFLICT(session_id) DO UPDATE SET name = excluded.name"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (name as NSString).utf8String, -1, SQLITE_TRANSIENT)
            let rc = sqlite3_step(stmt)
            if rc != SQLITE_DONE {
                print("SessionState: saveClaudeSessionName failed: \(errorMessage())")
            }
            sqlite3_finalize(stmt)
        }
    }

    /// Retrieves the user-assigned name for a Claude session, or nil if none.
    func getClaudeSessionName(sessionId: String) -> String? {
        guard db != nil else { return nil }
        let sql = "SELECT name FROM claude_sessions WHERE session_id = ?"
        var stmt: OpaquePointer?
        var result: String?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW, let ptr = sqlite3_column_text(stmt, 0) {
                result = String(cString: ptr)
            }
            sqlite3_finalize(stmt)
        }
        return result
    }

    /// Returns all saved Claude session metadata (name and pinned state).
    func getAllClaudeSessionNames() -> [String: (name: String?, pinned: Bool)] {
        guard db != nil else { return [:] }
        var results: [String: (name: String?, pinned: Bool)] = [:]
        let sql = "SELECT session_id, name, pinned FROM claude_sessions"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idPtr = sqlite3_column_text(stmt, 0) else { continue }
                let sessionId = String(cString: idPtr)
                let name: String?
                if let namePtr = sqlite3_column_text(stmt, 1) {
                    name = String(cString: namePtr)
                } else {
                    name = nil
                }
                let pinned = sqlite3_column_int(stmt, 2) != 0
                results[sessionId] = (name: name, pinned: pinned)
            }
            sqlite3_finalize(stmt)
        }
        return results
    }

    /// Pins or unpins a Claude session.
    func pinClaudeSession(sessionId: String, pinned: Bool) {
        guard db != nil else { return }
        let sql = "INSERT INTO claude_sessions (session_id, pinned) VALUES (?, ?) ON CONFLICT(session_id) DO UPDATE SET pinned = excluded.pinned"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, pinned ? 1 : 0)
            let rc = sqlite3_step(stmt)
            if rc != SQLITE_DONE {
                print("SessionState: pinClaudeSession failed: \(errorMessage())")
            }
            sqlite3_finalize(stmt)
        }
    }

    /// Gets the last-opened timestamp for a Claude session.
    func getClaudeSessionLastOpened(sessionId: String) -> Date? {
        guard db != nil else { return nil }
        let sql = "SELECT last_opened FROM claude_sessions WHERE session_id = ?"
        var stmt: OpaquePointer?
        var result: Date?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let val = sqlite3_column_double(stmt, 0)
                if val > 0 { result = Date(timeIntervalSince1970: val) }
            }
            sqlite3_finalize(stmt)
        }
        return result
    }

    /// Updates the last-opened timestamp for a Claude session to now.
    func updateClaudeSessionLastOpened(sessionId: String) {
        guard db != nil else { return }
        let sql = "INSERT INTO claude_sessions (session_id, last_opened) VALUES (?, ?) ON CONFLICT(session_id) DO UPDATE SET last_opened = excluded.last_opened"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            let rc = sqlite3_step(stmt)
            if rc != SQLITE_DONE {
                print("SessionState: updateClaudeSessionLastOpened failed: \(errorMessage())")
            }
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Helpers

    private func upsert(key: String, value: String) {
        let sql = "INSERT OR REPLACE INTO window_state (key, value) VALUES (?, ?)"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
            let rc = sqlite3_step(stmt)
            if rc != SQLITE_DONE {
                print("SessionState: upsert '\(key)' failed: \(errorMessage())")
            }
            sqlite3_finalize(stmt)
        } else {
            print("SessionState: prepare upsert '\(key)' failed: \(errorMessage())")
        }
    }

    private func getValue(key: String) -> String? {
        let sql = "SELECT value FROM window_state WHERE key = ?"
        var stmt: OpaquePointer?
        var result: String?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                if let ptr = sqlite3_column_text(stmt, 0) {
                    result = String(cString: ptr)
                }
            }
            sqlite3_finalize(stmt)
        }
        return result
    }
}
