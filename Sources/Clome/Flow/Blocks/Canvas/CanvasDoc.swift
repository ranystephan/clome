import SwiftUI

// MARK: - Canvas model
//
// Minimal card-and-arrow canvas. Persisted as JSON in
// ~/Library/Application Support/Clome/canvases/<uuid>.canvas.json

struct CanvasDoc: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var nodes: [CanvasNode]
    var edges: [CanvasEdge]

    static func new(title: String) -> CanvasDoc {
        let now = Date()
        return CanvasDoc(
            id: UUID(),
            title: title,
            createdAt: now,
            updatedAt: now,
            nodes: [],
            edges: []
        )
    }
}

struct CanvasNode: Codable, Identifiable, Equatable {
    let id: UUID
    var kind: CanvasNodeKind
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var title: String
    var body: String      // note markdown / URL string / file path
    var colorHex: String  // tint for the rail

    static func note(at point: CGPoint) -> CanvasNode {
        CanvasNode(
            id: UUID(),
            kind: .note,
            x: point.x, y: point.y,
            width: 180, height: 80,
            title: "Note",
            body: "",
            colorHex: "#3FAA9DFF"
        )
    }

    static func file(path: String, at point: CGPoint) -> CanvasNode {
        CanvasNode(
            id: UUID(),
            kind: .file,
            x: point.x, y: point.y,
            width: 180, height: 56,
            title: (path as NSString).lastPathComponent,
            body: path,
            colorHex: "#7DBCE7FF"
        )
    }

    static func url(_ url: URL, at point: CGPoint) -> CanvasNode {
        CanvasNode(
            id: UUID(),
            kind: .url,
            x: point.x, y: point.y,
            width: 200, height: 52,
            title: url.host ?? url.absoluteString,
            body: url.absoluteString,
            colorHex: "#B48AEA FF".replacingOccurrences(of: " ", with: "")
        )
    }
}

enum CanvasNodeKind: String, Codable {
    case note
    case file
    case url
    case image

    var systemIcon: String {
        switch self {
        case .note:  return "text.alignleft"
        case .file:  return "doc"
        case .url:   return "link"
        case .image: return "photo"
        }
    }
}

struct CanvasEdge: Codable, Identifiable, Equatable {
    let id: UUID
    var from: UUID
    var to: UUID
}
