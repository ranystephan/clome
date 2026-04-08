import SwiftUI
import SQLite3
import Combine
import ClomeModels

// MARK: - BlockStore
//
// Unified read-through store for Blocks. Owns native user-created blocks in
// `blocks.db` and merges in read-only proxies for EventKit events,
// FlowSyncService todos/deadlines, and EKReminders. The week view observes
// `blocks` for rendering and never touches the underlying sources directly.

@MainActor
final class BlockStore: ObservableObject {
    static let shared = BlockStore()

    // MARK: - Published

    /// Merged view of all blocks (native + adapters). Recomputed on change.
    @Published private(set) var blocks: [Block] = []

    // MARK: - Private state

    private var db: OpaquePointer?
    private let dbPath: String
    private var nativeBlocks: [UUID: Block] = [:]
    private var nativeAttachments: [UUID: [BlockAttachment]] = [:]
    private let calendar = CalendarDataManager.shared
    private var cancellables = Set<AnyCancellable>()

    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - Init

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let clomeDir = appSupport.appendingPathComponent("Clome")
        try? FileManager.default.createDirectory(at: clomeDir, withIntermediateDirectories: true)
        dbPath = clomeDir.appendingPathComponent("blocks.db").path

        openDatabase()
        createTables()
        loadNative()
        observeSources()
        recompute()
    }

    // Singleton; lives for app lifetime. SQLite handle closes on process exit.

    // MARK: - Database

    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            NSLog("[BlockStore] Failed to open db at \(dbPath)")
            db = nil
            return
        }
        sqlite3_exec(db, "PRAGMA journal_mode = WAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous = NORMAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil)
        sqlite3_busy_timeout(db, 5000)
    }

    private func createTables() {
        guard db != nil else { return }
        let sql = """
        CREATE TABLE IF NOT EXISTS blocks (
            id           TEXT PRIMARY KEY,
            title        TEXT NOT NULL,
            start_ts     REAL NOT NULL,
            end_ts       REAL NOT NULL,
            is_all_day   INTEGER NOT NULL DEFAULT 0,
            is_pinned    INTEGER NOT NULL DEFAULT 0,
            kind         TEXT NOT NULL DEFAULT 'focus',
            color_hex    TEXT,
            status       TEXT NOT NULL DEFAULT 'planned',
            notes        TEXT NOT NULL DEFAULT '',
            is_completed INTEGER NOT NULL DEFAULT 0,
            created_at   REAL NOT NULL,
            updated_at   REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS block_attachments (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            block_id    TEXT NOT NULL,
            position    INTEGER NOT NULL,
            payload     TEXT NOT NULL,
            FOREIGN KEY (block_id) REFERENCES blocks(id) ON DELETE CASCADE
        );

        CREATE INDEX IF NOT EXISTS idx_blocks_start ON blocks(start_ts);
        CREATE INDEX IF NOT EXISTS idx_attach_block ON block_attachments(block_id);

        CREATE TABLE IF NOT EXISTS blocks_meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    // MARK: - Observation

    private func observeSources() {
        // Re-merge when the EventKit-backed CalendarDataManager refreshes.
        calendar.$items
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)

        FlowSyncService.shared.$todos
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)

        FlowSyncService.shared.$deadlines
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
    }

    // MARK: - Public API — create / update / delete (native)

    /// Creates a new native block and returns its id.
    @discardableResult
    func create(title: String, start: Date, end: Date,
                kind: BlockKind = .focus,
                isPinned: Bool = false,
                color: Color? = nil,
                attachments: [BlockAttachment] = []) -> UUID {
        let id = UUID()
        let block = Block(
            source: .native(id),
            title: title,
            start: start,
            end: end,
            isAllDay: false,
            isPinned: isPinned,
            kind: kind,
            color: color ?? kind.defaultColor,
            status: .planned,
            notes: "",
            attachments: attachments,
            isCompleted: false
        )
        nativeBlocks[id] = block
        persist(block)
        persistAttachments(id: id, attachments: attachments)
        recompute()
        return id
    }

    // MARK: - Attachments

    /// Appends an attachment to a native block and persists.
    func addAttachment(_ attachment: BlockAttachment, toNativeID id: UUID) {
        guard var block = nativeBlocks[id] else { return }
        block.attachments.append(attachment)
        nativeBlocks[id] = block
        persistAttachments(id: id, attachments: block.attachments)
        recompute()
    }

    /// Removes an attachment at a position from a native block.
    func removeAttachment(at index: Int, fromNativeID id: UUID) {
        guard var block = nativeBlocks[id], index < block.attachments.count else { return }
        block.attachments.remove(at: index)
        nativeBlocks[id] = block
        persistAttachments(id: id, attachments: block.attachments)
        recompute()
    }

    private func persistAttachments(id: UUID, attachments: [BlockAttachment]) {
        guard db != nil else { return }
        // Replace the whole list (simpler than diff for M2).
        var del: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM block_attachments WHERE block_id = ?", -1, &del, nil) == SQLITE_OK {
            sqlite3_bind_text(del, 1, (id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_step(del)
            sqlite3_finalize(del)
        }
        let encoder = JSONEncoder()
        for (pos, att) in attachments.enumerated() {
            guard let data = try? encoder.encode(att),
                  let json = String(data: data, encoding: .utf8) else { continue }
            var stmt: OpaquePointer?
            let sql = "INSERT INTO block_attachments (block_id, position, payload) VALUES (?, ?, ?)"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 2, Int32(pos))
                sqlite3_bind_text(stmt, 3, (json as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    private func loadAttachments(for id: UUID) -> [BlockAttachment] {
        guard db != nil else { return [] }
        let sql = "SELECT payload FROM block_attachments WHERE block_id = ? ORDER BY position"
        var stmt: OpaquePointer?
        var out: [BlockAttachment] = []
        let decoder = JSONDecoder()
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let ptr = sqlite3_column_text(stmt, 0) {
                    let json = String(cString: ptr)
                    if let data = json.data(using: .utf8),
                       let att = try? decoder.decode(BlockAttachment.self, from: data) {
                        out.append(att)
                    }
                }
            }
            sqlite3_finalize(stmt)
        }
        return out
    }

    /// Updates a native block. Silently ignores non-native ids — callers
    /// should route EventKit edits through CalendarDataManager.
    func update(_ id: UUID,
                title: String? = nil,
                start: Date? = nil,
                end: Date? = nil,
                notes: String? = nil,
                status: BlockStatus? = nil,
                isCompleted: Bool? = nil,
                isPinned: Bool? = nil,
                kind: BlockKind? = nil) {
        guard var block = nativeBlocks[id] else { return }
        if let title { block.title = title }
        if let start { block.start = start }
        if let end { block.end = end }
        if let notes { block.notes = notes }
        if let status { block.status = status }
        if let isCompleted { block.isCompleted = isCompleted }
        if let isPinned { block.isPinned = isPinned }
        if let kind {
            block.kind = kind
            block.color = kind.defaultColor
        }
        nativeBlocks[id] = block
        persist(block)
        recompute()
    }

    func delete(_ id: UUID) {
        nativeBlocks.removeValue(forKey: id)
        nativeAttachments.removeValue(forKey: id)
        deleteRow(id)
        recompute()
    }

    /// Looks up a block by its stable string id (used by the UI).
    func block(withID id: String) -> Block? {
        blocks.first { $0.id == id }
    }

    /// Returns the native UUID backing a block id, if any.
    func nativeID(for blockID: String) -> UUID? {
        guard blockID.hasPrefix("native-") else { return nil }
        return UUID(uuidString: String(blockID.dropFirst("native-".count)))
    }

    // MARK: - Persistence

    private func persist(_ block: Block) {
        guard db != nil, case let .native(id) = block.source else { return }
        let sql = """
        INSERT INTO blocks
            (id, title, start_ts, end_ts, is_all_day, is_pinned, kind,
             color_hex, status, notes, is_completed, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title=excluded.title,
            start_ts=excluded.start_ts,
            end_ts=excluded.end_ts,
            is_all_day=excluded.is_all_day,
            is_pinned=excluded.is_pinned,
            kind=excluded.kind,
            color_hex=excluded.color_hex,
            status=excluded.status,
            notes=excluded.notes,
            is_completed=excluded.is_completed,
            updated_at=excluded.updated_at
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("[BlockStore] prepare failed: \(errMsg())")
            return
        }
        defer { sqlite3_finalize(stmt) }
        let now = Date().timeIntervalSince1970
        sqlite3_bind_text(stmt, 1, (id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (block.title as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 3, block.start.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 4, block.end.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 5, block.isAllDay ? 1 : 0)
        sqlite3_bind_int(stmt, 6, block.isPinned ? 1 : 0)
        sqlite3_bind_text(stmt, 7, (block.kind.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
        let hex = block.color.hexString
        sqlite3_bind_text(stmt, 8, (hex as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 9, (block.status.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 10, (block.notes as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 11, block.isCompleted ? 1 : 0)
        sqlite3_bind_double(stmt, 12, now)
        sqlite3_bind_double(stmt, 13, now)
        if sqlite3_step(stmt) != SQLITE_DONE {
            NSLog("[BlockStore] insert failed: \(errMsg())")
        }
    }

    private func deleteRow(_ id: UUID) {
        guard db != nil else { return }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM blocks WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    private func loadNative() {
        guard db != nil else { return }
        let sql = """
        SELECT id, title, start_ts, end_ts, is_all_day, is_pinned, kind,
               color_hex, status, notes, is_completed
        FROM blocks
        ORDER BY start_ts
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idPtr = sqlite3_column_text(stmt, 0),
                  let id = UUID(uuidString: String(cString: idPtr)) else { continue }
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let start = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            let end = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            let isAllDay = sqlite3_column_int(stmt, 4) != 0
            let isPinned = sqlite3_column_int(stmt, 5) != 0
            let kindStr = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "focus"
            let kind = BlockKind(rawValue: kindStr) ?? .focus
            let hex = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? ""
            let color = Color(hex: hex) ?? kind.defaultColor
            let statusStr = sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? "planned"
            let status = BlockStatus(rawValue: statusStr) ?? .planned
            let notes = sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? ""
            let isCompleted = sqlite3_column_int(stmt, 10) != 0

            let atts = loadAttachments(for: id)
            let block = Block(
                source: .native(id),
                title: title,
                start: start,
                end: end,
                isAllDay: isAllDay,
                isPinned: isPinned,
                kind: kind,
                color: color,
                status: status,
                notes: notes,
                attachments: atts,
                isCompleted: isCompleted
            )
            nativeBlocks[id] = block
        }
    }

    // MARK: - Merging adapters

    /// Rebuilds `blocks` by merging native + EventKit + todos + deadlines + reminders.
    private func recompute() {
        var merged: [Block] = Array(nativeBlocks.values)
        for item in calendar.items {
            if let block = blockFromCalendarItem(item) {
                merged.append(block)
            }
        }
        merged.sort { $0.start < $1.start }
        blocks = merged
    }

    private func blockFromCalendarItem(_ item: any CalendarItemProtocol) -> Block? {
        switch item.kind {
        case .systemEvent:
            guard let sys = item as? SystemEventItem else { return nil }
            return Block(
                source: .eventKit(sys.eventIdentifier),
                title: sys.title,
                start: sys.startDate,
                end: sys.endDate,
                isAllDay: sys.isAllDay,
                isPinned: false,
                kind: .meeting,
                color: sys.calendarColor,
                status: .planned,
                notes: sys.notes ?? "",
                attachments: [],
                isCompleted: false
            )
        case .todo:
            guard let todo = item as? ScheduledTodoItem else { return nil }
            return Block(
                source: .todo(todo.todo.id),
                title: todo.title,
                start: todo.startDate,
                end: todo.endDate,
                isAllDay: false,
                isPinned: false,
                kind: .task,
                color: item.displayColor,
                status: todo.isCompleted ? .done : .planned,
                notes: "",
                attachments: [],
                isCompleted: todo.isCompleted
            )
        case .deadline:
            guard let d = item as? DeadlineCalendarItem else { return nil }
            // Give deadlines a 30-min render window so they're visible.
            let end = d.startDate.addingTimeInterval(30 * 60)
            return Block(
                source: .deadline(d.deadline.id),
                title: d.title,
                start: d.startDate,
                end: end,
                isAllDay: false,
                isPinned: false,
                kind: .deadline,
                color: item.displayColor,
                status: d.isCompleted ? .done : .planned,
                notes: "",
                attachments: [],
                isCompleted: d.isCompleted
            )
        case .reminder:
            guard let r = item as? ReminderCalendarItem else { return nil }
            let end = r.startDate.addingTimeInterval(30 * 60)
            return Block(
                source: .reminder(r.reminderIdentifier),
                title: r.title,
                start: r.startDate,
                end: end,
                isAllDay: false,
                isPinned: false,
                kind: .reminder,
                color: item.displayColor,
                status: r.isCompleted ? .done : .planned,
                notes: "",
                attachments: [],
                isCompleted: r.isCompleted
            )
        }
    }

    // MARK: - Routed edits for non-native sources

    /// Update for any block id. Routes native edits to SQLite and
    /// EventKit edits to CalendarDataManager.
    func updateAny(id: String, title: String? = nil, start: Date? = nil, end: Date? = nil) {
        if let nid = nativeID(for: id) {
            update(nid, title: title, start: start, end: end)
            return
        }
        if id.hasPrefix("ek-") {
            let ek = String(id.dropFirst("ek-".count))
            if let title { calendar.updateSystemEvent(identifier: ek, title: title) }
            if let start, let end {
                calendar.moveSystemEvent(identifier: ek, newStart: start, newEnd: end)
            }
        }
    }

    func deleteAny(id: String) {
        if let nid = nativeID(for: id) {
            delete(nid)
            return
        }
        if id.hasPrefix("ek-") {
            let ek = String(id.dropFirst("ek-".count))
            calendar.deleteSystemEvent(identifier: ek)
        }
    }

    // MARK: - Utils

    private func errMsg() -> String {
        if let p = sqlite3_errmsg(db) { return String(cString: p) }
        return "?"
    }
}

// MARK: - Color hex helpers

extension Color {
    /// Serializes to `#RRGGBBAA`.
    var hexString: String {
        #if canImport(AppKit)
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        let a = Int((ns.alphaComponent * 255).rounded())
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
        #else
        return "#FFFFFFFF"
        #endif
    }

    init?(hex: String) {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if s.count == 6 { s += "FF" }
        guard s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r = Double((v >> 24) & 0xFF) / 255
        let g = Double((v >> 16) & 0xFF) / 255
        let b = Double((v >> 8)  & 0xFF) / 255
        let a = Double(v & 0xFF) / 255
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
