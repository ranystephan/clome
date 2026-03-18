import Foundation

/// Represents a parsed Jupyter notebook (.ipynb) file.
struct NotebookDocument: Codable {
    var cells: [NotebookCell]
    var metadata: NotebookMetadata
    var nbformat: Int
    var nbformat_minor: Int

    init(cells: [NotebookCell], metadata: NotebookMetadata, nbformat: Int, nbformat_minor: Int) {
        self.cells = cells
        self.metadata = metadata
        self.nbformat = nbformat
        self.nbformat_minor = nbformat_minor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlexKeys.self)
        cells = (try? container.decode([NotebookCell].self, forKey: FlexKeys(stringValue: "cells")!)) ?? []
        metadata = (try? container.decode(NotebookMetadata.self, forKey: FlexKeys(stringValue: "metadata")!)) ?? NotebookMetadata()
        nbformat = (try? container.decode(Int.self, forKey: FlexKeys(stringValue: "nbformat")!)) ?? 4
        nbformat_minor = (try? container.decode(Int.self, forKey: FlexKeys(stringValue: "nbformat_minor")!)) ?? 5
    }
}

struct NotebookMetadata: Codable {
    var kernelspec: KernelSpec?
    var language_info: LanguageInfo?

    struct KernelSpec: Codable {
        var display_name: String?
        var language: String?
        var name: String?

        init(display_name: String? = nil, language: String? = nil, name: String? = nil) {
            self.display_name = display_name
            self.language = language
            self.name = name
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: FlexKeys.self)
            display_name = try? container.decode(String.self, forKey: FlexKeys(stringValue: "display_name")!)
            language = try? container.decode(String.self, forKey: FlexKeys(stringValue: "language")!)
            name = try? container.decode(String.self, forKey: FlexKeys(stringValue: "name")!)
        }
    }

    struct LanguageInfo: Codable {
        var name: String?
        var version: String?
        var file_extension: String?

        init(name: String? = nil, version: String? = nil, file_extension: String? = nil) {
            self.name = name
            self.version = version
            self.file_extension = file_extension
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: FlexKeys.self)
            name = try? container.decode(String.self, forKey: FlexKeys(stringValue: "name")!)
            version = try? container.decode(String.self, forKey: FlexKeys(stringValue: "version")!)
            file_extension = try? container.decode(String.self, forKey: FlexKeys(stringValue: "file_extension")!)
        }
    }

    init(kernelspec: KernelSpec? = nil, language_info: LanguageInfo? = nil) {
        self.kernelspec = kernelspec
        self.language_info = language_info
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlexKeys.self)
        kernelspec = try? container.decode(KernelSpec.self, forKey: FlexKeys(stringValue: "kernelspec")!)
        language_info = try? container.decode(LanguageInfo.self, forKey: FlexKeys(stringValue: "language_info")!)
    }
}

/// Flexible coding key that accepts any string — prevents "unknown key" decode failures.
struct FlexKeys: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
}

struct NotebookCell: Codable, Identifiable {
    let id = UUID()
    var cell_type: CellType
    var source: CellSource
    var outputs: [CellOutput]?
    var execution_count: Int?

    enum CodingKeys: String, CodingKey {
        case cell_type, source, outputs, execution_count
    }

    enum CellType: String, Codable {
        case code
        case markdown
        case raw
    }

    init(cell_type: CellType, source: CellSource, outputs: [CellOutput]? = nil, execution_count: Int? = nil) {
        self.cell_type = cell_type
        self.source = source
        self.outputs = outputs
        self.execution_count = execution_count
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cell_type = (try? container.decode(CellType.self, forKey: .cell_type)) ?? .code
        source = (try? container.decode(CellSource.self, forKey: .source)) ?? .string("")
        outputs = try? container.decode([CellOutput].self, forKey: .outputs)
        execution_count = try? container.decode(Int.self, forKey: .execution_count)
    }

    /// The source text of a cell, joined from array or single string.
    var sourceText: String {
        switch source {
        case .array(let lines): return lines.joined()
        case .string(let s): return s
        }
    }
}

/// .ipynb source can be a string or array of strings.
enum CellSource: Codable {
    case string(String)
    case array([String])

    /// The resolved text content, joining array elements if needed.
    var text: String {
        switch self {
        case .string(let s): return s
        case .array(let a): return a.joined()
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let arr = try? container.decode([String].self) {
            self = .array(arr)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else {
            self = .string("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .array(let lines): try container.encode(lines)
        case .string(let s): try container.encode(s)
        }
    }
}

struct CellOutput: Codable {
    var output_type: OutputType
    var text: CellSource?
    var data: OutputData?
    var ename: String?
    var evalue: String?
    var traceback: [String]?
    var execution_count: Int?
    var name: String?  // stream name: stdout/stderr

    enum OutputType: String, Codable {
        case stream
        case execute_result
        case display_data
        case error
    }

    init(output_type: OutputType, text: CellSource? = nil, data: OutputData? = nil,
         ename: String? = nil, evalue: String? = nil, traceback: [String]? = nil,
         execution_count: Int? = nil, name: String? = nil) {
        self.output_type = output_type
        self.text = text
        self.data = data
        self.ename = ename
        self.evalue = evalue
        self.traceback = traceback
        self.execution_count = execution_count
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlexKeys.self)
        let typeStr = (try? container.decode(String.self, forKey: FlexKeys(stringValue: "output_type")!)) ?? "stream"
        output_type = OutputType(rawValue: typeStr) ?? .stream
        text = try? container.decode(CellSource.self, forKey: FlexKeys(stringValue: "text")!)
        data = try? container.decode(OutputData.self, forKey: FlexKeys(stringValue: "data")!)
        ename = try? container.decode(String.self, forKey: FlexKeys(stringValue: "ename")!)
        evalue = try? container.decode(String.self, forKey: FlexKeys(stringValue: "evalue")!)
        traceback = try? container.decode([String].self, forKey: FlexKeys(stringValue: "traceback")!)
        execution_count = try? container.decode(Int.self, forKey: FlexKeys(stringValue: "execution_count")!)
        name = try? container.decode(String.self, forKey: FlexKeys(stringValue: "name")!)
    }
}

struct OutputData: Codable {
    var text_plain: CellSource?
    var text_html: CellSource?
    var image_png: String?  // base64-encoded
    var image_jpeg: String?
    var image_svg: CellSource?

    init(text_plain: CellSource? = nil, text_html: CellSource? = nil,
         image_png: String? = nil, image_jpeg: String? = nil, image_svg: CellSource? = nil) {
        self.text_plain = text_plain
        self.text_html = text_html
        self.image_png = image_png
        self.image_jpeg = image_jpeg
        self.image_svg = image_svg
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlexKeys.self)
        text_plain = try? container.decode(CellSource.self, forKey: FlexKeys(stringValue: "text/plain")!)
        text_html = try? container.decode(CellSource.self, forKey: FlexKeys(stringValue: "text/html")!)
        image_png = try? container.decode(String.self, forKey: FlexKeys(stringValue: "image/png")!)
        image_jpeg = try? container.decode(String.self, forKey: FlexKeys(stringValue: "image/jpeg")!)
        image_svg = try? container.decode(CellSource.self, forKey: FlexKeys(stringValue: "image/svg+xml")!)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: FlexKeys.self)
        try container.encodeIfPresent(text_plain, forKey: FlexKeys(stringValue: "text/plain")!)
        try container.encodeIfPresent(text_html, forKey: FlexKeys(stringValue: "text/html")!)
        try container.encodeIfPresent(image_png, forKey: FlexKeys(stringValue: "image/png")!)
        try container.encodeIfPresent(image_jpeg, forKey: FlexKeys(stringValue: "image/jpeg")!)
        try container.encodeIfPresent(image_svg, forKey: FlexKeys(stringValue: "image/svg+xml")!)
    }
}

// MARK: - Notebook I/O

enum NotebookError: Error {
    case invalidFormat
}

@MainActor
final class NotebookStore {
    private(set) var document: NotebookDocument
    private(set) var filePath: String?
    private(set) var isDirty: Bool = false

    var language: String {
        document.metadata.language_info?.name ?? document.metadata.kernelspec?.language ?? "python"
    }

    var kernelDisplayName: String {
        document.metadata.kernelspec?.display_name ?? language.capitalized
    }

    init() {
        document = NotebookDocument(
            cells: [NotebookCell(cell_type: .code, source: .string(""), outputs: [])],
            metadata: NotebookMetadata(),
            nbformat: 4,
            nbformat_minor: 5
        )
    }

    init(contentsOfFile path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if data.isEmpty {
            // Empty file — create a blank notebook
            document = NotebookDocument(
                cells: [NotebookCell(cell_type: .code, source: .string(""), outputs: [])],
                metadata: NotebookMetadata(),
                nbformat: 4,
                nbformat_minor: 5
            )
        } else {
            let decoder = JSONDecoder()
            do {
                document = try decoder.decode(NotebookDocument.self, from: data)
            } catch {
                throw NotebookError.invalidFormat
            }
        }
        filePath = path
    }

    func save() throws {
        guard let path = filePath else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: URL(fileURLWithPath: path))
        isDirty = false
    }

    func saveAs(_ path: String) throws {
        filePath = path
        try save()
    }

    // MARK: - Cell Operations

    func insertCell(at index: Int, type: NotebookCell.CellType) {
        let cell = NotebookCell(cell_type: type, source: .string(""), outputs: type == .code ? [] : nil)
        document.cells.insert(cell, at: index)
        isDirty = true
    }

    func appendCell(type: NotebookCell.CellType) {
        insertCell(at: document.cells.count, type: type)
    }

    func deleteCell(at index: Int) {
        guard document.cells.count > 1 else { return } // keep at least one cell
        document.cells.remove(at: index)
        isDirty = true
    }

    func moveCell(from: Int, to: Int) {
        guard from != to, from >= 0, from < document.cells.count,
              to >= 0, to < document.cells.count else { return }
        let cell = document.cells.remove(at: from)
        document.cells.insert(cell, at: to)
        isDirty = true
    }

    func updateCellSource(at index: Int, text: String) {
        guard index >= 0, index < document.cells.count else { return }
        // Split into lines preserving newlines for .ipynb format
        var lines: [String] = []
        var remaining = text[text.startIndex...]
        while let nl = remaining.firstIndex(of: "\n") {
            let lineEnd = remaining.index(after: nl)
            lines.append(String(remaining[remaining.startIndex..<lineEnd]))
            remaining = remaining[lineEnd...]
        }
        if !remaining.isEmpty {
            lines.append(String(remaining))
        }
        document.cells[index].source = lines.isEmpty ? .string("") : .array(lines)
        isDirty = true
    }

    func changeCellType(at index: Int, to type: NotebookCell.CellType) {
        guard index >= 0, index < document.cells.count else { return }
        document.cells[index].cell_type = type
        if type != .code {
            document.cells[index].outputs = nil
            document.cells[index].execution_count = nil
        } else if document.cells[index].outputs == nil {
            document.cells[index].outputs = []
        }
        isDirty = true
    }

    func clearOutputs(at index: Int) {
        guard index >= 0, index < document.cells.count else { return }
        document.cells[index].outputs = []
        document.cells[index].execution_count = nil
        isDirty = true
    }

    func clearAllOutputs() {
        for i in document.cells.indices {
            if document.cells[i].cell_type == .code {
                document.cells[i].outputs = []
                document.cells[i].execution_count = nil
            }
        }
        isDirty = true
    }

    // MARK: - Execution State

    enum CellExecutionState {
        case idle
        case queued
        case running
    }

    private(set) var cellExecutionStates: [UUID: CellExecutionState] = [:]

    func setCellExecutionState(_ cellId: UUID, state: CellExecutionState) {
        if state == .idle {
            cellExecutionStates.removeValue(forKey: cellId)
        } else {
            cellExecutionStates[cellId] = state
        }
    }

    /// Append a single output incrementally (used during streaming execution).
    func appendCellOutput(cellId: UUID, output: CellOutput) {
        guard let index = document.cells.firstIndex(where: { $0.id == cellId }) else { return }
        if document.cells[index].outputs == nil {
            document.cells[index].outputs = []
        }
        document.cells[index].outputs?.append(output)
        isDirty = true
    }

    /// Bulk set outputs and execution count after completion.
    func setCellExecutionCount(cellId: UUID, executionCount: Int?) {
        guard let index = document.cells.firstIndex(where: { $0.id == cellId }) else { return }
        document.cells[index].execution_count = executionCount
        isDirty = true
    }

    /// Clear outputs for a cell by UUID (before re-execution).
    func clearCellOutputs(cellId: UUID) {
        guard let index = document.cells.firstIndex(where: { $0.id == cellId }) else { return }
        document.cells[index].outputs = []
        document.cells[index].execution_count = nil
        isDirty = true
    }
}
