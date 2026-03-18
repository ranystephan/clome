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

        // Clear existing
        if sqlite3_exec(db, "DELETE FROM surfaces", nil, nil, nil) != SQLITE_OK {
            print("SessionState: DELETE FROM surfaces failed: \(errorMessage())")
            success = false
        }
        if success && sqlite3_exec(db, "DELETE FROM workspaces", nil, nil, nil) != SQLITE_OK {
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
            }

            let surfaceId = UUID().uuidString

            // For terminal tabs, save the scrollback content to a file
            if tab.type == .terminal, let terminal = tab.view as? TerminalSurface {
                if let scrollback = terminal.readFullScrollback(), !scrollback.isEmpty {
                    saveTerminalScrollback(scrollback, forSurfaceId: surfaceId)
                }
            }

            let sql = "INSERT INTO surfaces (id, workspace_id, type, working_directory, title, position, url, split_path) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
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
    }

    struct SavedWorkspace {
        let id: String
        let name: String
        let icon: String
        let position: Int
        let color: String
        var tabs: [SavedTab]
        var activeTabIndex: Int
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

                workspaces.append(SavedWorkspace(
                    id: id, name: name, icon: icon, position: position,
                    color: color, tabs: tabs, activeTabIndex: activeTab
                ))
            }
            sqlite3_finalize(stmt)
        }
        return workspaces
    }

    private func restoreTabs(forWorkspaceId workspaceId: String) -> [SavedTab] {
        var tabs: [SavedTab] = []
        let sql = "SELECT id, type, title, working_directory, position, split_path FROM surfaces WHERE workspace_id = ? ORDER BY position"
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
                tabs.append(SavedTab(id: id, type: type, title: title, resourcePath: resourcePath, position: position, extraData: extraData))
            }
            sqlite3_finalize(stmt)
        }
        return tabs
    }

    // MARK: - Appearance

    struct SavedAppearance {
        let sidebarColor: NSColor
        let sidebarOpacity: CGFloat
        let mainPanelColor: NSColor
        let mainPanelOpacity: CGFloat
    }

    func saveAppearance(sidebarColor: NSColor, sidebarOpacity: CGFloat, mainPanelColor: NSColor, mainPanelOpacity: CGFloat) {
        guard db != nil else { return }
        guard beginTransaction() else { return }
        upsert(key: "sidebar_color", value: colorToHex(sidebarColor))
        upsert(key: "sidebar_opacity", value: "\(sidebarOpacity)")
        upsert(key: "main_panel_color", value: colorToHex(mainPanelColor))
        upsert(key: "main_panel_opacity", value: "\(mainPanelOpacity)")
        commitTransaction()
    }

    func restoreAppearance() -> SavedAppearance? {
        guard db != nil else { return nil }
        guard let sc = getValue(key: "sidebar_color") else { return nil }
        let so = getValue(key: "sidebar_opacity").flatMap { CGFloat(Double($0) ?? -1) } ?? 0.15
        let mc = getValue(key: "main_panel_color") ?? ""
        let mo = getValue(key: "main_panel_opacity").flatMap { CGFloat(Double($0) ?? -1) } ?? 0.92
        return SavedAppearance(
            sidebarColor: hexToColor(sc),
            sidebarOpacity: so,
            mainPanelColor: mc.isEmpty ? NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0) : hexToColor(mc),
            mainPanelOpacity: mo
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
