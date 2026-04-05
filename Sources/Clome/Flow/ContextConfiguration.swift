import Foundation
import ClomeModels

// MARK: - Context Sections

enum ContextSection: String, Codable, CaseIterable {
    case time
    case todos
    case deadlines
    case calendar
    case notes
    case workspace
    case custom

    var displayName: String {
        switch self {
        case .time: return "Current Time"
        case .todos: return "Todos"
        case .deadlines: return "Deadlines"
        case .calendar: return "Calendar"
        case .notes: return "Notes"
        case .workspace: return "Workspace"
        case .custom: return "Custom Snippets"
        }
    }

    var icon: String {
        switch self {
        case .time: return "clock"
        case .todos: return "checklist"
        case .deadlines: return "flag"
        case .calendar: return "calendar"
        case .notes: return "note.text"
        case .workspace: return "folder"
        case .custom: return "doc.text"
        }
    }
}

// MARK: - Custom Snippet

struct CustomSnippet: Identifiable, Codable {
    let id: UUID
    var title: String
    var content: String
    let createdAt: Date

    init(title: String, content: String) {
        self.id = UUID()
        self.title = title
        self.content = content
        self.createdAt = Date()
    }
}

// MARK: - Context Configuration

struct ContextConfiguration: Codable {
    /// Which sections are enabled (default: all true).
    var sectionEnabled: [String: Bool]   // keyed by ContextSection.rawValue for Codable

    /// Selected item IDs per section. Empty set = include ALL items (opt-out model).
    /// Non-empty set = include ONLY these items.
    var selectedItemIDs: [String: Set<UUID>]  // keyed by ContextSection.rawValue

    /// Custom text snippets pasted by the user.
    var customSnippets: [CustomSnippet]

    /// Workspace project path (set from workspace context).
    var workspaceProjectPath: String?

    // MARK: - Defaults

    static var `default`: ContextConfiguration {
        var enabled: [String: Bool] = [:]
        for section in ContextSection.allCases {
            enabled[section.rawValue] = true
        }
        return ContextConfiguration(
            sectionEnabled: enabled,
            selectedItemIDs: [:],
            customSnippets: [],
            workspaceProjectPath: nil
        )
    }

    // MARK: - Section Control

    func isSectionEnabled(_ section: ContextSection) -> Bool {
        sectionEnabled[section.rawValue] ?? true
    }

    mutating func toggleSection(_ section: ContextSection) {
        let current = sectionEnabled[section.rawValue] ?? true
        sectionEnabled[section.rawValue] = !current
    }

    mutating func setSection(_ section: ContextSection, enabled: Bool) {
        sectionEnabled[section.rawValue] = enabled
    }

    // MARK: - Item Selection

    /// Returns true if a specific item should be included.
    /// If the selectedItemIDs set for a section is empty, ALL items are included.
    /// If non-empty, only items in the set are included.
    func isItemSelected(section: ContextSection, id: UUID) -> Bool {
        let selected = selectedItemIDs[section.rawValue] ?? []
        return selected.isEmpty || selected.contains(id)
    }

    /// Toggles an item's selection. When first item is deselected from a section,
    /// the set is populated with ALL other IDs (switching from "include all" to "include specific").
    mutating func toggleItem(section: ContextSection, id: UUID, allItemIDs: Set<UUID>) {
        var selected = selectedItemIDs[section.rawValue] ?? []

        if selected.isEmpty {
            // Currently "include all" — switch to explicit: all except this one
            selected = allItemIDs
            selected.remove(id)
        } else if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }

        // If all items are selected, revert to empty set (= include all)
        if selected == allItemIDs {
            selected = []
        }

        selectedItemIDs[section.rawValue] = selected
    }

    // MARK: - Custom Snippets

    mutating func addSnippet(title: String, content: String) {
        customSnippets.append(CustomSnippet(title: title, content: content))
    }

    mutating func removeSnippet(id: UUID) {
        customSnippets.removeAll { $0.id == id }
    }

    mutating func updateSnippet(id: UUID, title: String? = nil, content: String? = nil) {
        guard let idx = customSnippets.firstIndex(where: { $0.id == id }) else { return }
        if let t = title { customSnippets[idx].title = t }
        if let c = content { customSnippets[idx].content = c }
    }

    // MARK: - Context Assembly

    /// Assembles the full context string, respecting enabled sections and item selections.
    /// This replaces FlowChatView.buildContext().
    @MainActor
    func assembleContext(
        sync: FlowSyncService,
        calendarManager: CalendarDataManager,
        projectPath: String?
    ) -> String {
        let now = Date()
        var ctx = ""

        // Time section
        if isSectionEnabled(.time) {
            let fullFmt = DateFormatter()
            fullFmt.dateFormat = "EEEE, MMM d, yyyy 'at' h:mm a"
            let isoFmt = DateFormatter()
            isoFmt.dateFormat = "yyyy-MM-dd"
            ctx += "RIGHT NOW: \(fullFmt.string(from: now))\n"
            ctx += "TODAY: \(isoFmt.string(from: now))\n\n"
        }

        // Todos section
        if isSectionEnabled(.todos) {
            let activeTodos = sync.todos.filter { !$0.isCompleted }
            let filtered = activeTodos.filter { isItemSelected(section: .todos, id: $0.id) }
            if !filtered.isEmpty {
                ctx += "TODOS (\(filtered.count) active):\n"
                for todo in filtered.sorted(by: { $0.priority.sortOrder < $1.priority.sortOrder }) {
                    var line = "- \(todo.title)"
                    if todo.priority == .high { line += " [HIGH]" }
                    if todo.category != HabitCategory.general { line += " (\(todo.category.rawValue))" }
                    if let notes = todo.notes, !notes.isEmpty { line += " — \(notes)" }
                    ctx += "\(line)\n"
                }
                ctx += "\n"
            } else {
                ctx += "TODOS: None active.\n\n"
            }
        }

        // Deadlines section
        if isSectionEnabled(.deadlines) {
            let activeDeadlines = sync.deadlines.filter { !$0.isCompleted }
            let filtered = activeDeadlines.filter { isItemSelected(section: .deadlines, id: $0.id) }
            if !filtered.isEmpty {
                let dlFmt = DateFormatter()
                dlFmt.dateFormat = "EEEE, MMM d 'at' h:mm a"
                ctx += "ACTIVE DEADLINES:\n"
                for deadline in filtered.sorted(by: { $0.dueDate < $1.dueDate }) {
                    let hoursUntil = deadline.dueDate.timeIntervalSince(now) / 3600
                    var line = "- \(deadline.title): due \(dlFmt.string(from: deadline.dueDate))"
                    if hoursUntil > 0 && hoursUntil < 48 {
                        line += " (\(Int(hoursUntil))h remaining)"
                    }
                    if let prep = deadline.estimatedPrepHours {
                        line += " [est. \(prep)h prep needed]"
                    }
                    ctx += "\(line)\n"
                }
                ctx += "\n"
            }
        }

        // Calendar section
        if isSectionEnabled(.calendar) {
            // NOTE: Do NOT call calendarManager.refresh() here — assembleContext is called
            // during SwiftUI view body evaluation, and refresh() mutates @Published state,
            // which triggers "Publishing changes from within view updates" and freezes.
            let weekEnd = Calendar.current.date(byAdding: .day, value: 7, to: now)!
            let calendarEvents = calendarManager.items.filter { item in
                item.kind == .systemEvent && item.startDate >= now && item.startDate <= weekEnd
            }.sorted { $0.startDate < $1.startDate }

            if calendarManager.hasCalendarAccess {
                if !calendarEvents.isEmpty {
                    let dayFmt = DateFormatter()
                    dayFmt.dateFormat = "EEE, MMM d"
                    let timeFmt = DateFormatter()
                    timeFmt.dateFormat = "h:mm a"
                    ctx += "CALENDAR (next 7 days):\n"
                    var currentDay = ""
                    for event in calendarEvents {
                        let dayStr = dayFmt.string(from: event.startDate)
                        if dayStr != currentDay {
                            currentDay = dayStr
                            ctx += "\n\(dayStr):\n"
                        }
                        if event.isAllDay {
                            ctx += "  [All day] \(event.title)\n"
                        } else {
                            ctx += "  \(timeFmt.string(from: event.startDate))-\(timeFmt.string(from: event.endDate)): \(event.title)\n"
                        }
                    }
                    ctx += "\nOutside these events, the user is FREE.\n\n"
                } else {
                    ctx += "CALENDAR: No events this week — wide open.\n\n"
                }
            } else {
                ctx += "CALENDAR: Access not granted.\n\n"
            }
        }

        // Notes section
        if isSectionEnabled(.notes) {
            let recentNotes = sync.notes.sorted(by: { $0.updatedAt > $1.updatedAt }).prefix(10)
            let filtered = recentNotes.filter { isItemSelected(section: .notes, id: $0.id) }
            if !filtered.isEmpty {
                ctx += "RECENT NOTES:\n"
                for note in filtered {
                    let doneTag = note.isDone ? " [done]" : ""
                    ctx += "- [\(note.category.displayName)] \(note.summary)\(doneTag)\n"
                }
                ctx += "\n"
            }
        }

        // Workspace section
        if isSectionEnabled(.workspace), let path = projectPath ?? workspaceProjectPath {
            let tree = WorkspaceContextProvider.directoryTree(at: path)
            if !tree.isEmpty {
                ctx += "WORKSPACE PROJECT: \((path as NSString).lastPathComponent)\n"
                ctx += tree
                ctx += "\n\n"
            }
        }

        // Custom snippets
        if isSectionEnabled(.custom) && !customSnippets.isEmpty {
            ctx += "CUSTOM CONTEXT:\n"
            for snippet in customSnippets {
                ctx += "--- \(snippet.title) ---\n"
                ctx += snippet.content
                ctx += "\n---\n\n"
            }
        }

        return ctx
    }

    // MARK: - Token Estimation

    /// Estimates token count for the assembled context (word-based approximation).
    @MainActor
    func estimateTokens(
        sync: FlowSyncService,
        calendarManager: CalendarDataManager,
        projectPath: String?
    ) -> Int {
        let text = assembleContext(sync: sync, calendarManager: calendarManager, projectPath: projectPath)
        let wordCount = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        return max(1, Int(Double(wordCount) * 1.3))
    }
}
