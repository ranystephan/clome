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
        createTables()
    }

    func close() {
        sqlite3_close(db)
        db = nil
    }

    // MARK: - Database

    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("Failed to open session database at \(dbPath)")
        }
    }

    private func createTables() {
        let sql = """
        CREATE TABLE IF NOT EXISTS workspaces (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            icon TEXT NOT NULL DEFAULT 'terminal',
            position INTEGER NOT NULL,
            created_at REAL NOT NULL
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

    // MARK: - Save

    func saveWindowFrame(_ frame: NSRect) {
        let value = NSStringFromRect(frame)
        upsert(key: "window_frame", value: value)
    }

    func saveSidebarVisible(_ visible: Bool) {
        upsert(key: "sidebar_visible", value: visible ? "1" : "0")
    }

    func saveWorkspaces(_ workspaces: [Workspace], activeIndex: Int) {
        // Clear existing
        sqlite3_exec(db, "DELETE FROM surfaces", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM workspaces", nil, nil, nil)

        for (index, workspace) in workspaces.enumerated() {
            let sql = "INSERT INTO workspaces (id, name, icon, position, created_at) VALUES (?, ?, ?, ?, ?)"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                let idStr = workspace.id.uuidString
                sqlite3_bind_text(stmt, 1, (idStr as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (workspace.name as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (workspace.icon as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 4, Int32(index))
                sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }

        upsert(key: "active_workspace_index", value: "\(activeIndex)")
    }

    // MARK: - Restore

    func restoreWindowFrame() -> NSRect? {
        guard let value = getValue(key: "window_frame") else { return nil }
        let rect = NSRectFromString(value)
        return rect == .zero ? nil : rect
    }

    func restoreSidebarVisible() -> Bool {
        getValue(key: "sidebar_visible") != "0"
    }

    func restoreActiveWorkspaceIndex() -> Int {
        guard let value = getValue(key: "active_workspace_index") else { return 0 }
        return Int(value) ?? 0
    }

    struct SavedWorkspace {
        let id: String
        let name: String
        let icon: String
        let position: Int
    }

    func restoreWorkspaces() -> [SavedWorkspace] {
        var workspaces: [SavedWorkspace] = []
        let sql = "SELECT id, name, icon, position FROM workspaces ORDER BY position"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let name = String(cString: sqlite3_column_text(stmt, 1))
                let icon = String(cString: sqlite3_column_text(stmt, 2))
                let position = Int(sqlite3_column_int(stmt, 3))
                workspaces.append(SavedWorkspace(id: id, name: name, icon: icon, position: position))
            }
            sqlite3_finalize(stmt)
        }
        return workspaces
    }

    // MARK: - Appearance

    struct SavedAppearance {
        let sidebarColor: NSColor
        let sidebarOpacity: CGFloat
        let mainPanelColor: NSColor
        let mainPanelOpacity: CGFloat
    }

    func saveAppearance(sidebarColor: NSColor, sidebarOpacity: CGFloat, mainPanelColor: NSColor, mainPanelOpacity: CGFloat) {
        upsert(key: "sidebar_color", value: colorToHex(sidebarColor))
        upsert(key: "sidebar_opacity", value: "\(sidebarOpacity)")
        upsert(key: "main_panel_color", value: colorToHex(mainPanelColor))
        upsert(key: "main_panel_opacity", value: "\(mainPanelOpacity)")
    }

    func restoreAppearance() -> SavedAppearance? {
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

    // MARK: - LSP Custom Paths

    func saveLSPCustomPaths(_ paths: [String: String]) {
        if let data = try? JSONSerialization.data(withJSONObject: paths),
           let json = String(data: data, encoding: .utf8) {
            upsert(key: "lsp_custom_paths", value: json)
        }
    }

    func restoreLSPCustomPaths() -> [String: String] {
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
            sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (value as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    private func getValue(key: String) -> String? {
        let sql = "SELECT value FROM window_state WHERE key = ?"
        var stmt: OpaquePointer?
        var result: String?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
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
