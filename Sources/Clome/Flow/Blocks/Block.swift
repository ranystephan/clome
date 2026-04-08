import SwiftUI
import ClomeModels

// MARK: - Block
//
// Block is the first-class scheduling primitive in Flow. Everything on the
// Plan surface is a Block: events, tasks, deadlines, reminders, and native
// user-created items. Blocks can be timed or pinned (untimed for the day),
// and carry a list of attachments that bind them to Clome context.

/// Source of truth for a block. Each source has its own backing store.
enum BlockSource: Hashable {
    /// User-created block stored in blocks.db.
    case native(UUID)
    /// Imported EKEvent (EventKit). String is `EKEvent.eventIdentifier`.
    case eventKit(String)
    /// FlowSyncService todo wrapped as a timed block.
    case todo(UUID)
    /// FlowSyncService deadline wrapped as a zero-duration marker.
    case deadline(UUID)
    /// EKReminder wrapped as a marker.
    case reminder(String)

    /// Stable identifier for `Identifiable`.
    var key: String {
        switch self {
        case .native(let id):     return "native-\(id.uuidString)"
        case .eventKit(let id):   return "ek-\(id)"
        case .todo(let id):       return "todo-\(id.uuidString)"
        case .deadline(let id):   return "deadline-\(id.uuidString)"
        case .reminder(let id):   return "reminder-\(id)"
        }
    }

    var isEditable: Bool {
        switch self {
        case .native, .eventKit: return true
        default: return false
        }
    }
}

/// Lifecycle state for a block. Used for NOW / next-up queries on Dashboard.
enum BlockStatus: String, Codable {
    case planned
    case running
    case done
    case skipped
}

/// Semantic kind — drives default color and behavior when no explicit
/// color is set. Imported items get their kind from their source.
enum BlockKind: String, Codable {
    case focus      // deep work, default for new native blocks
    case meeting
    case task
    case deadline
    case reminder
    case habit
    case note       // read-this / reference card, usually pinned

    var defaultColor: Color {
        switch self {
        case .focus:    return FlowTokens.accent
        case .meeting:  return Color(red: 0.490, green: 0.678, blue: 0.882)  // info blue
        case .task:     return FlowTokens.calendarTodo
        case .deadline: return FlowTokens.urgencyCritical
        case .reminder: return FlowTokens.calendarReminder
        case .habit:    return Color(red: 0.820, green: 0.680, blue: 0.310)  // amber
        case .note:     return FlowTokens.textSecondary
        }
    }

    var systemIcon: String {
        switch self {
        case .focus:    return "scope"
        case .meeting:  return "person.2.fill"
        case .task:     return "checkmark.circle"
        case .deadline: return "flag.fill"
        case .reminder: return "bell.fill"
        case .habit:    return "repeat"
        case .note:     return "doc.text"
        }
    }
}

// MARK: - Attachment

/// Rich context attached to a block. M1 defines the enum; drag-drop wiring
/// lands in M2. Payload is stored as JSON in the attachments table.
enum BlockAttachment: Codable, Hashable {
    case file(path: String)
    case url(URL)
    case workspace(id: String, name: String)
    case claudeThread(id: String, title: String)
    case canvas(id: UUID, title: String)
    case note(markdown: String)
    case task(id: UUID, title: String)
    case gitBranch(name: String, workspaceId: String)
    case image(path: String)

    var systemIcon: String {
        switch self {
        case .file:          return "doc"
        case .url:           return "link"
        case .workspace:     return "square.stack.3d.up"
        case .claudeThread:  return "sparkles"
        case .canvas:        return "rectangle.dashed"
        case .note:          return "text.alignleft"
        case .task:          return "checkmark.square"
        case .gitBranch:     return "arrow.triangle.branch"
        case .image:         return "photo"
        }
    }

    var shortLabel: String {
        switch self {
        case .file(let path):          return (path as NSString).lastPathComponent
        case .url(let u):              return u.host ?? u.absoluteString
        case .workspace(_, let name):  return name
        case .claudeThread(_, let t):  return t
        case .canvas(_, let t):        return t
        case .note:                    return "note"
        case .task(_, let t):          return t
        case .gitBranch(let n, _):     return n
        case .image(let path):         return (path as NSString).lastPathComponent
        }
    }
}

// MARK: - Block

/// Concrete block struct. Not a protocol — all sources convert into this
/// so the UI has one shape to render.
struct Block: Identifiable, Hashable {
    var id: String { source.key }

    let source: BlockSource
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var isPinned: Bool          // true = day-pinned, untimed (goes in pinned strip)
    var kind: BlockKind
    var color: Color
    var status: BlockStatus
    var notes: String
    var attachments: [BlockAttachment]
    var isCompleted: Bool

    var duration: TimeInterval { end.timeIntervalSince(start) }
    var isEditable: Bool { source.isEditable }

    // Hashable by stable id.
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (a: Block, b: Block) -> Bool { a.id == b.id }
}
