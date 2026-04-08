import Foundation

/// On-disk canvas store. One JSON file per canvas under
/// ~/Library/Application Support/Clome/canvases/<id>.canvas.json
@MainActor
final class CanvasStore {
    static let shared = CanvasStore()

    private let dir: URL

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        dir = appSupport
            .appendingPathComponent("Clome")
            .appendingPathComponent("canvases")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func path(for id: UUID) -> URL {
        dir.appendingPathComponent("\(id.uuidString).canvas.json")
    }

    func load(_ id: UUID) -> CanvasDoc? {
        let url = path(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CanvasDoc.self, from: data)
    }

    func save(_ doc: CanvasDoc) {
        var copy = doc
        copy.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(copy) else { return }
        try? data.write(to: path(for: copy.id))
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: path(for: id))
    }

    /// Create and immediately persist a blank canvas.
    @discardableResult
    func createBlank(title: String = "Untitled canvas") -> CanvasDoc {
        let doc = CanvasDoc.new(title: title)
        save(doc)
        return doc
    }
}
