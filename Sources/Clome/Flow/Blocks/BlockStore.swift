import SwiftUI
import SQLite3
import Combine
import EventKit
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

    /// Currently selected block id, if any. Drives the Block Inspector.
    @Published var selectedBlockID: String?

    /// The id of the currently running block (if any).
    @Published private(set) var runningBlockID: String?
    /// When the running block was started (persistent across app launches).
    @Published private(set) var runningStartedAt: Date?

    /// Undo/redo depth published so UI can enable/disable controls.
    @Published private(set) var canUndo: Bool = false
    @Published private(set) var canRedo: Bool = false

    // In-memory action log (not persisted across launches). Bounded.
    private var undoStack: [BlockAction] = []
    private var redoStack: [BlockAction] = []
    private let undoLimit = 50
    private var isApplyingUndo = false

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
        loadRunningState()
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
        record(.created(id: id))
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
        if let block = nativeBlocks[id] {
            record(.deleted(block: block))
        }
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

    // MARK: - Push to system calendar
    //
    // One-way mirror: a native block can be "pushed" to the system
    // calendar (EventKit). The EK event identifier is stored in
    // blocks_meta keyed by ek_mirror:<native-uuid>. Subsequent pushes
    // update the same event; remove deletes it from EK.

    /// Returns the EK event identifier mirroring the given native block, if any.
    func mirroredEKID(for nativeID: UUID) -> String? {
        readMeta("ek_mirror:\(nativeID.uuidString)")
    }

    /// Pushes a native block to EventKit. Creates if no mirror exists,
    /// updates in place otherwise. Returns true on success.
    @discardableResult
    func pushNativeToCalendar(_ id: UUID) -> Bool {
        guard let block = nativeBlocks[id],
              calendar.hasCalendarAccess else { return false }

        let ek = EKEventStore()
        if let mirrorID = mirroredEKID(for: id),
           let existing = ek.event(withIdentifier: mirrorID) {
            existing.title = block.title
            existing.startDate = block.start
            existing.endDate = block.end
            existing.notes = block.notes + "\n\n[clome:block:\(id.uuidString)]"
            do {
                try ek.save(existing, span: .thisEvent)
                calendar.refresh()
                return true
            } catch {
                NSLog("[BlockStore] update EK mirror failed: \(error.localizedDescription)")
                return false
            }
        } else {
            let event = EKEvent(eventStore: ek)
            event.title = block.title
            event.startDate = block.start
            event.endDate = block.end
            event.notes = (block.notes.isEmpty ? "" : block.notes + "\n\n") + "[clome:block:\(id.uuidString)]"
            event.calendar = ek.defaultCalendarForNewEvents
            do {
                try ek.save(event, span: .thisEvent)
                if let ekid = event.eventIdentifier {
                    saveMeta("ek_mirror:\(id.uuidString)", ekid)
                }
                calendar.refresh()
                return true
            } catch {
                NSLog("[BlockStore] create EK mirror failed: \(error.localizedDescription)")
                return false
            }
        }
    }

    /// Removes the EK mirror for a native block, if any.
    func removeFromCalendar(_ id: UUID) {
        guard let mirrorID = mirroredEKID(for: id) else { return }
        let ek = EKEventStore()
        if let existing = ek.event(withIdentifier: mirrorID) {
            try? ek.remove(existing, span: .thisEvent)
        }
        deleteMeta("ek_mirror:\(id.uuidString)")
        calendar.refresh()
    }

    // MARK: - Start / End block flow

    /// Starts a block: marks it running, ends any other running block,
    /// and fires side effects for its attachments (open files, URLs,
    /// switch workspace).
    func startBlock(id: String) {
        if let current = runningBlockID, current != id {
            endBlock(id: current, generateJournal: true)
        }
        guard let block = block(withID: id) else { return }

        runningBlockID = id
        runningStartedAt = Date()
        saveMeta("running_block_id", id)
        saveMeta("running_started_at", String(runningStartedAt!.timeIntervalSince1970))

        if let nid = nativeID(for: id) {
            update(nid, status: .running)
        }

        BlockRunner.fireStartSideEffects(for: block)
    }

    /// Ends a block: clears running state, marks status done, appends a
    /// short elapsed-time stub to the notes (real AI journal in a later
    /// milestone).
    func endBlock(id: String, generateJournal: Bool = true) {
        guard let block = block(withID: id) else {
            clearRunning()
            return
        }
        let started = runningStartedAt ?? Date()
        let minutes = Int(Date().timeIntervalSince(started) / 60)

        if let nid = nativeID(for: id) {
            var notes = block.notes
            if generateJournal {
                let stamp = Self.journalStamp(started: started, minutes: minutes)
                notes = notes.isEmpty ? stamp : "\(notes)\n\n\(stamp)"
            }
            update(nid, notes: notes, status: .done)
        }

        clearRunning()
    }

    private func clearRunning() {
        runningBlockID = nil
        runningStartedAt = nil
        deleteMeta("running_block_id")
        deleteMeta("running_started_at")
    }

    private static func journalStamp(started: Date, minutes: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        let left = f.string(from: started)
        f.dateFormat = "h:mm a"
        let right = f.string(from: Date())
        return "— ran \(left) – \(right) (\(minutes) min)"
    }

    // MARK: - blocks_meta helpers

    private func saveMeta(_ key: String, _ value: String) {
        guard db != nil else { return }
        let sql = "INSERT INTO blocks_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    private func readMeta(_ key: String) -> String? {
        guard db != nil else { return nil }
        var stmt: OpaquePointer?
        var out: String?
        if sqlite3_prepare_v2(db, "SELECT value FROM blocks_meta WHERE key = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW, let ptr = sqlite3_column_text(stmt, 0) {
                out = String(cString: ptr)
            }
            sqlite3_finalize(stmt)
        }
        return out
    }

    private func deleteMeta(_ key: String) {
        guard db != nil else { return }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM blocks_meta WHERE key = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    private func loadRunningState() {
        if let id = readMeta("running_block_id") {
            runningBlockID = id
        }
        if let ts = readMeta("running_started_at"), let v = Double(ts) {
            runningStartedAt = Date(timeIntervalSince1970: v)
        }
    }

    // MARK: - Undo / Redo

    /// A reversible mutation. Only covers the subset of actions the user
    /// is likely to want to undo (create/delete/move). Title and notes
    /// edits are intentionally excluded for M10a simplicity.
    enum BlockAction {
        case created(id: UUID)
        case deleted(block: Block)
        case moved(id: String, oldStart: Date, oldEnd: Date, newStart: Date, newEnd: Date)
    }

    private func record(_ action: BlockAction) {
        guard !isApplyingUndo else { return }
        undoStack.append(action)
        if undoStack.count > undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        canUndo = !undoStack.isEmpty
        canRedo = false
    }

    /// Reverses the most recent action.
    func undo() {
        guard let action = undoStack.popLast() else { return }
        isApplyingUndo = true
        let inverse = apply(inverseOf: action)
        isApplyingUndo = false
        if let inverse { redoStack.append(inverse) }
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    /// Re-applies the most recently undone action.
    func redo() {
        guard let action = redoStack.popLast() else { return }
        isApplyingUndo = true
        let inverse = apply(inverseOf: action)
        isApplyingUndo = false
        if let inverse { undoStack.append(inverse) }
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    /// Applies the inverse of an action and returns the counterpart action
    /// to push onto the opposite stack (so that undo/redo is symmetric).
    private func apply(inverseOf action: BlockAction) -> BlockAction? {
        switch action {
        case .created(let id):
            // Reverse = delete. Return counterpart = deleted(block).
            guard let block = nativeBlocks[id] else { return nil }
            delete(id)
            return .deleted(block: block)

        case .deleted(let block):
            // Reverse = recreate with the same UUID.
            guard case let .native(id) = block.source else { return nil }
            nativeBlocks[id] = block
            persist(block)
            persistAttachments(id: id, attachments: block.attachments)
            recompute()
            return .created(id: id)

        case .moved(let id, let oldStart, let oldEnd, let newStart, let newEnd):
            // Reverse = move back to old times.
            applyMove(id: id, start: oldStart, end: oldEnd)
            return .moved(id: id,
                          oldStart: newStart, oldEnd: newEnd,
                          newStart: oldStart, newEnd: oldEnd)
        }
    }

    /// Move without recording (used by undo/redo and by recorded moveBlock).
    private func applyMove(id: String, start: Date, end: Date) {
        if let nid = nativeID(for: id), var block = nativeBlocks[nid] {
            block.start = start
            block.end = end
            nativeBlocks[nid] = block
            persist(block)
            recompute()
        } else if id.hasPrefix("ek-") {
            let ek = String(id.dropFirst("ek-".count))
            calendar.moveSystemEvent(identifier: ek, newStart: start, newEnd: end)
        }
    }

    /// Records + applies a move. Called by drag-end in the week view.
    func moveBlock(id: String, newStart: Date, newEnd: Date) {
        guard let block = block(withID: id) else { return }
        let action = BlockAction.moved(id: id,
                                        oldStart: block.start, oldEnd: block.end,
                                        newStart: newStart, newEnd: newEnd)
        applyMove(id: id, start: newStart, end: newEnd)
        record(action)
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
