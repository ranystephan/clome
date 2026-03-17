import Foundation

/// High-level text buffer backed by a Rope.
/// Manages undo/redo, dirty state, file association, and multi-cursor editing.
final class TextBuffer {
    private var rope: Rope
    private(set) var filePath: String?
    private(set) var isDirty: Bool = false {
        didSet {
            if isDirty != oldValue {
                NotificationCenter.default.post(name: .bufferDirtyStateChanged, object: self)
            }
        }
    }
    private(set) var language: String?

    private var undoStack: [Edit] = []
    private var redoStack: [Edit] = []
    private let maxUndoHistory = 500

    struct Edit {
        let range: Range<Int>
        let oldText: String
        let newText: String
    }

    /// Cursor/selection state
    struct CursorState {
        var offset: Int = 0
        var line: Int = 0
        var column: Int = 0
        var selectionStart: Int?

        var hasSelection: Bool { selectionStart != nil }
        var selectionRange: Range<Int>? {
            guard let start = selectionStart else { return nil }
            let lo = min(start, offset)
            let hi = max(start, offset)
            return lo..<hi
        }
    }

    /// Multi-cursor array. The primary cursor is always at index 0.
    var cursors: [CursorState] = [CursorState()]

    /// Primary cursor (convenience accessor).
    var cursor: CursorState {
        get { cursors[0] }
        set { cursors[0] = newValue }
    }

    init() {
        rope = Rope()
    }

    init(string: String) {
        rope = Rope(string)
    }

    init(contentsOfFile path: String) throws {
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        rope = Rope(contents)
        filePath = path
        language = TextBuffer.detectLanguage(from: path)
    }

    // MARK: - Properties

    var text: String { rope.toString() }
    var count: Int { rope.count }
    var lineCount: Int { rope.lineCount }
    var isEmpty: Bool { rope.isEmpty }

    // MARK: - Read

    func line(_ index: Int) -> String {
        rope.line(index)
    }

    func lineStartOffset(_ lineIndex: Int) -> Int {
        rope.lineStartOffset(lineIndex)
    }

    func lineIndex(at offset: Int) -> Int {
        rope.lineIndex(at: offset)
    }

    func substring(in range: Range<Int>) -> String {
        rope.substring(in: range)
    }

    func character(at index: Int) -> Character? {
        rope.character(at: index)
    }

    /// Convert an offset to (line, column).
    func position(at offset: Int) -> (line: Int, column: Int) {
        let line = lineIndex(at: offset)
        let lineStart = lineStartOffset(line)
        return (line, offset - lineStart)
    }

    /// Convert (line, column) to an offset.
    func offset(line: Int, column: Int) -> Int {
        let start = lineStartOffset(line)
        let lineText = self.line(line)
        let maxCol = lineText.count
        return start + min(column, maxCol)
    }

    // MARK: - Write

    func insert(_ string: String, at offset: Int) {
        let edit = Edit(range: offset..<offset, oldText: "", newText: string)
        applyEdit(edit)
    }

    func delete(in range: Range<Int>) {
        let oldText = substring(in: range)
        let edit = Edit(range: range, oldText: oldText, newText: "")
        applyEdit(edit)
    }

    func replace(in range: Range<Int>, with string: String) {
        let oldText = substring(in: range)
        let edit = Edit(range: range, oldText: oldText, newText: string)
        applyEdit(edit)
    }

    /// Insert text at the current cursor position.
    func insertAtCursor(_ string: String) {
        if let selection = cursor.selectionRange {
            replace(in: selection, with: string)
            cursor.offset = selection.lowerBound + string.count
            cursor.selectionStart = nil
        } else {
            insert(string, at: cursor.offset)
            cursor.offset += string.count
        }
        updateCursorPosition()
    }

    /// Delete the character before the cursor (backspace).
    func backspace() {
        if let selection = cursor.selectionRange {
            delete(in: selection)
            cursor.offset = selection.lowerBound
            cursor.selectionStart = nil
        } else if cursor.offset > 0 {
            delete(in: (cursor.offset - 1)..<cursor.offset)
            cursor.offset -= 1
        }
        updateCursorPosition()
    }

    /// Delete the character at the cursor (forward delete).
    func forwardDelete() {
        if let selection = cursor.selectionRange {
            delete(in: selection)
            cursor.offset = selection.lowerBound
            cursor.selectionStart = nil
        } else if cursor.offset < count {
            delete(in: cursor.offset..<(cursor.offset + 1))
        }
        updateCursorPosition()
    }

    // MARK: - Multi-Cursor Operations

    /// Add a new cursor. Cursors are kept sorted by offset and deduplicated.
    func addCursor(_ newCursor: CursorState) {
        cursors.append(newCursor)
        cursors.sort { $0.offset < $1.offset }
        deduplicateCursors()
    }

    /// Add a cursor at a specific offset.
    func addCursor(at offset: Int) {
        var c = CursorState()
        c.offset = offset
        let pos = position(at: offset)
        c.line = pos.line
        c.column = pos.column
        addCursor(c)
    }

    /// Collapse to single primary cursor.
    func collapseCursors() {
        let primary = cursors[0]
        cursors = [primary]
    }

    /// Remove duplicate cursors at the same offset.
    private func deduplicateCursors() {
        var seen = Set<Int>()
        cursors = cursors.filter { seen.insert($0.offset).inserted }
    }

    /// Insert text at all cursor positions. Processes in reverse offset order
    /// and adjusts subsequent cursor offsets by the delta.
    func insertAtAllCursors(_ string: String) {
        // Sort indices by offset descending to preserve positions
        let sortedIndices = cursors.indices.sorted { cursors[$0].offset > cursors[$1].offset }

        for idx in sortedIndices {
            let c = cursors[idx]
            if let selection = c.selectionRange {
                replace(in: selection, with: string)
                let delta = string.count - selection.count
                cursors[idx].offset = selection.lowerBound + string.count
                cursors[idx].selectionStart = nil
                // Adjust earlier cursors' offsets
                adjustCursorsAfterEdit(at: selection.lowerBound, delta: delta, excludeIndex: idx)
            } else {
                insert(string, at: c.offset)
                cursors[idx].offset = c.offset + string.count
                // Adjust earlier cursors
                adjustCursorsAfterEdit(at: c.offset, delta: string.count, excludeIndex: idx)
            }
            let pos = position(at: cursors[idx].offset)
            cursors[idx].line = pos.line
            cursors[idx].column = pos.column
        }
        deduplicateCursors()
    }

    /// Backspace at all cursor positions.
    func backspaceAll() {
        let sortedIndices = cursors.indices.sorted { cursors[$0].offset > cursors[$1].offset }

        for idx in sortedIndices {
            let c = cursors[idx]
            if let selection = c.selectionRange {
                delete(in: selection)
                let delta = -selection.count
                cursors[idx].offset = selection.lowerBound
                cursors[idx].selectionStart = nil
                adjustCursorsAfterEdit(at: selection.lowerBound, delta: delta, excludeIndex: idx)
            } else if c.offset > 0 {
                delete(in: (c.offset - 1)..<c.offset)
                cursors[idx].offset = c.offset - 1
                adjustCursorsAfterEdit(at: c.offset - 1, delta: -1, excludeIndex: idx)
            }
            let pos = position(at: cursors[idx].offset)
            cursors[idx].line = pos.line
            cursors[idx].column = pos.column
        }
        deduplicateCursors()
    }

    /// Forward delete at all cursor positions.
    func forwardDeleteAll() {
        let sortedIndices = cursors.indices.sorted { cursors[$0].offset > cursors[$1].offset }

        for idx in sortedIndices {
            let c = cursors[idx]
            if let selection = c.selectionRange {
                delete(in: selection)
                let delta = -selection.count
                cursors[idx].offset = selection.lowerBound
                cursors[idx].selectionStart = nil
                adjustCursorsAfterEdit(at: selection.lowerBound, delta: delta, excludeIndex: idx)
            } else if c.offset < count {
                delete(in: c.offset..<(c.offset + 1))
                adjustCursorsAfterEdit(at: c.offset, delta: -1, excludeIndex: idx)
            }
            let pos = position(at: cursors[idx].offset)
            cursors[idx].line = pos.line
            cursors[idx].column = pos.column
        }
        deduplicateCursors()
    }

    /// Adjust cursor offsets after an edit at a given position.
    private func adjustCursorsAfterEdit(at editOffset: Int, delta: Int, excludeIndex: Int) {
        for i in cursors.indices where i != excludeIndex {
            if cursors[i].offset > editOffset {
                cursors[i].offset = max(0, cursors[i].offset + delta)
                let pos = position(at: cursors[i].offset)
                cursors[i].line = pos.line
                cursors[i].column = pos.column
            }
        }
    }

    // MARK: - Edits (internal)

    private func applyEdit(_ edit: Edit) {
        // Record for undo
        undoStack.append(edit)
        if undoStack.count > maxUndoHistory {
            undoStack.removeFirst()
        }
        redoStack.removeAll()

        // Apply
        if edit.newText.isEmpty {
            rope.delete(in: edit.range)
        } else if edit.range.isEmpty {
            rope.insert(edit.newText, at: edit.range.lowerBound)
        } else {
            rope.replace(in: edit.range, with: edit.newText)
        }

        isDirty = true
    }

    private func updateCursorPosition() {
        let pos = position(at: cursor.offset)
        cursor.line = pos.line
        cursor.column = pos.column
    }

    // MARK: - Undo/Redo

    func undo() {
        guard let edit = undoStack.popLast() else { return }
        let reverseRange: Range<Int>
        if edit.newText.isEmpty {
            rope.insert(edit.oldText, at: edit.range.lowerBound)
            reverseRange = edit.range
        } else if edit.oldText.isEmpty {
            let end = edit.range.lowerBound + edit.newText.count
            rope.delete(in: edit.range.lowerBound..<end)
            reverseRange = edit.range.lowerBound..<end
        } else {
            let insertedEnd = edit.range.lowerBound + edit.newText.count
            rope.replace(in: edit.range.lowerBound..<insertedEnd, with: edit.oldText)
            reverseRange = edit.range
        }
        redoStack.append(edit)
        cursor.offset = reverseRange.lowerBound
        updateCursorPosition()
    }

    func redo() {
        guard let edit = redoStack.popLast() else { return }
        if edit.newText.isEmpty {
            rope.delete(in: edit.range)
        } else if edit.oldText.isEmpty {
            rope.insert(edit.newText, at: edit.range.lowerBound)
        } else {
            rope.replace(in: edit.range, with: edit.newText)
        }
        undoStack.append(edit)
        cursor.offset = edit.range.lowerBound + edit.newText.count
        updateCursorPosition()
    }

    // MARK: - File I/O

    func save() throws {
        guard let path = filePath else { return }
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        isDirty = false
    }

    func saveAs(_ path: String) throws {
        filePath = path
        language = TextBuffer.detectLanguage(from: path)
        try save()
    }

    func reload() throws {
        guard let path = filePath else { return }
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        rope = Rope(contents)
        isDirty = false
        undoStack.removeAll()
        redoStack.removeAll()
        cursors = [CursorState()]
    }

    // MARK: - Efficient Character Access (avoids full text materialization)

    /// Check if character at offset matches a predicate. O(log n) via rope.
    func characterSatisfies(at offset: Int, _ predicate: (Character) -> Bool) -> Bool {
        guard let ch = character(at: offset) else { return false }
        return predicate(ch)
    }

    /// Get a small substring around a position without materializing the full text.
    /// Uses rope.substring which is O(log n + k) where k is the range size.
    func localSubstring(around offset: Int, radius: Int) -> (string: String, startOffset: Int) {
        let start = max(0, offset - radius)
        let end = min(count, offset + radius)
        return (substring(in: start..<end), start)
    }

    // MARK: - Language Detection

    static func detectLanguage(from path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        let map: [String: String] = [
            "swift": "swift", "rs": "rust", "py": "python", "js": "javascript",
            "ts": "typescript", "tsx": "tsx", "jsx": "javascript",
            "go": "go", "rb": "ruby", "c": "c", "h": "c",
            "cpp": "cpp", "hpp": "cpp", "cc": "cpp", "cxx": "cpp",
            "java": "java", "kt": "kotlin", "cs": "c_sharp",
            "html": "html", "css": "css", "scss": "scss",
            "json": "json", "yaml": "yaml", "yml": "yaml",
            "toml": "toml", "xml": "xml", "md": "markdown",
            "sh": "bash", "zsh": "bash", "bash": "bash",
            "sql": "sql", "zig": "zig", "lua": "lua",
            "vim": "vim", "el": "elisp", "ex": "elixir",
            "erl": "erlang", "hs": "haskell", "ml": "ocaml",
            "r": "r", "jl": "julia", "dart": "dart",
            "php": "php", "pl": "perl", "scala": "scala",
            "ipynb": "jupyter",
            "tex": "latex", "sty": "latex", "cls": "latex", "bib": "bibtex",
        ]
        return map[ext]
    }
}
