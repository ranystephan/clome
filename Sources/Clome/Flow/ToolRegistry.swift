import SwiftUI

// MARK: - Tool Category

enum ToolCategory: String, CaseIterable, Codable {
    case todos = "Todos"
    case calendar = "Calendar"
    case notes = "Notes"
    case deadlines = "Deadlines"
}

// MARK: - Tool Definition

struct ToolDefinition {
    let name: String
    let displayName: String
    let description: String
    let icon: String
    let color: Color
    let colorHex: String
    let category: ToolCategory
    let parameters: [(name: String, type: String, description: String, required: Bool, enumValues: [String]?)]

    /// Generates the Gemini API function declaration dictionary.
    func declaration() -> [String: Any] {
        var properties: [String: Any] = [:]
        for param in parameters {
            var p: [String: Any] = ["type": param.type, "description": param.description]
            if !param.required { p["nullable"] = true }
            if let ev = param.enumValues { p["enum"] = ev }
            properties[param.name] = p
        }
        var schema: [String: Any] = ["type": "OBJECT", "properties": properties]
        let required = parameters.filter(\.required).map(\.name)
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "parameters": schema]
    }
}

// MARK: - Tool Registry

enum ToolRegistry {

    static let all: [ToolDefinition] = [

        // MARK: Todos

        ToolDefinition(
            name: "create_todo",
            displayName: "Create Todo",
            description: "Create a new todo item for the user.",
            icon: "plus.circle.fill",
            color: FlowTokens.success,
            colorHex: "#4DBF66",
            category: .todos,
            parameters: [
                (name: "title", type: "STRING", description: "The title of the todo item.", required: true, enumValues: nil),
                (name: "notes", type: "STRING", description: "Optional notes or details for the todo.", required: false, enumValues: nil),
                (name: "category", type: "STRING", description: "Optional category to organize the todo.", required: false, enumValues: nil),
                (name: "priority", type: "STRING", description: "Priority level of the todo.", required: false, enumValues: ["high", "medium", "low"]),
            ]
        ),

        ToolDefinition(
            name: "complete_todo",
            displayName: "Complete Todo",
            description: "Mark an existing todo item as completed.",
            icon: "checkmark.circle.fill",
            color: FlowTokens.success,
            colorHex: "#4DBF66",
            category: .todos,
            parameters: [
                (name: "todo_title", type: "STRING", description: "The title of the todo to mark as completed.", required: true, enumValues: nil),
            ]
        ),

        ToolDefinition(
            name: "delete_todo",
            displayName: "Delete Todo",
            description: "Delete an existing todo item.",
            icon: "trash.fill",
            color: FlowTokens.error,
            colorHex: "#E66666",
            category: .todos,
            parameters: [
                (name: "todo_title", type: "STRING", description: "The title of the todo to delete.", required: true, enumValues: nil),
            ]
        ),

        // MARK: Deadlines

        ToolDefinition(
            name: "create_deadline",
            displayName: "Create Deadline",
            description: "Create a new deadline with a due date.",
            icon: "flag.fill",
            color: FlowTokens.warning,
            colorHex: "#E6BF4D",
            category: .deadlines,
            parameters: [
                (name: "title", type: "STRING", description: "The title of the deadline.", required: true, enumValues: nil),
                (name: "due_date", type: "STRING", description: "The due date in YYYY-MM-DD format.", required: true, enumValues: nil),
                (name: "due_time", type: "STRING", description: "Optional due time in HH:mm format.", required: false, enumValues: nil),
                (name: "category", type: "STRING", description: "Category for the deadline.", required: false, enumValues: ["study", "work", "research", "personalStudy", "creative", "general"]),
                (name: "estimated_prep_hours", type: "NUMBER", description: "Estimated preparation hours needed.", required: false, enumValues: nil),
            ]
        ),

        // MARK: Notes

        ToolDefinition(
            name: "create_note",
            displayName: "Create Note",
            description: "Create a new note with content and summary.",
            icon: "note.text",
            color: FlowTokens.accent,
            colorHex: "#618FFF",
            category: .notes,
            parameters: [
                (name: "content", type: "STRING", description: "The full content of the note.", required: true, enumValues: nil),
                (name: "summary", type: "STRING", description: "A brief summary of the note.", required: true, enumValues: nil),
                (name: "category", type: "STRING", description: "Category for the note.", required: false, enumValues: ["idea", "task", "reminder", "goal", "journal", "reference"]),
            ]
        ),

        // MARK: Calendar

        ToolDefinition(
            name: "schedule_event",
            displayName: "Schedule Event",
            description: "Schedule a new calendar event.",
            icon: "calendar.badge.plus",
            color: FlowTokens.accent,
            colorHex: "#618FFF",
            category: .calendar,
            parameters: [
                (name: "title", type: "STRING", description: "The title of the event.", required: true, enumValues: nil),
                (name: "date", type: "STRING", description: "The event date in YYYY-MM-DD format.", required: true, enumValues: nil),
                (name: "start_time", type: "STRING", description: "Start time in HH:mm format.", required: true, enumValues: nil),
                (name: "end_time", type: "STRING", description: "Optional end time in HH:mm format.", required: false, enumValues: nil),
                (name: "duration", type: "INTEGER", description: "Optional duration in minutes.", required: false, enumValues: nil),
            ]
        ),

        ToolDefinition(
            name: "reschedule_event",
            displayName: "Reschedule Event",
            description: "Reschedule an existing calendar event to a new date or time.",
            icon: "calendar.badge.clock",
            color: FlowTokens.warning,
            colorHex: "#E6BF4D",
            category: .calendar,
            parameters: [
                (name: "event_title", type: "STRING", description: "The title of the event to reschedule.", required: true, enumValues: nil),
                (name: "new_date", type: "STRING", description: "The new date in YYYY-MM-DD format.", required: false, enumValues: nil),
                (name: "new_start_time", type: "STRING", description: "The new start time in HH:mm format.", required: false, enumValues: nil),
                (name: "new_end_time", type: "STRING", description: "The new end time in HH:mm format.", required: false, enumValues: nil),
            ]
        ),

        ToolDefinition(
            name: "delete_event",
            displayName: "Delete Event",
            description: "Delete an existing calendar event.",
            icon: "calendar.badge.minus",
            color: FlowTokens.error,
            colorHex: "#E66666",
            category: .calendar,
            parameters: [
                (name: "event_title", type: "STRING", description: "The title of the event to delete.", required: true, enumValues: nil),
            ]
        ),

        ToolDefinition(
            name: "edit_event",
            displayName: "Edit Event",
            description: "Edit properties of an existing calendar event (title, location, notes).",
            icon: "calendar.badge.exclamationmark",
            color: FlowTokens.warning,
            colorHex: "#E6BF4D",
            category: .calendar,
            parameters: [
                (name: "event_title", type: "STRING", description: "The title of the event to edit.", required: true, enumValues: nil),
                (name: "new_title", type: "STRING", description: "New title for the event.", required: false, enumValues: nil),
                (name: "new_location", type: "STRING", description: "New location for the event.", required: false, enumValues: nil),
                (name: "new_notes", type: "STRING", description: "New notes/description for the event.", required: false, enumValues: nil),
            ]
        ),

        ToolDefinition(
            name: "list_calendars",
            displayName: "List Calendars",
            description: "List all available calendars the user has.",
            icon: "calendar",
            color: FlowTokens.accent,
            colorHex: "#618FFF",
            category: .calendar,
            parameters: []
        ),

        ToolDefinition(
            name: "query_events",
            displayName: "Query Events",
            description: "Query calendar events in a specific date range.",
            icon: "calendar.badge.magnifyingglass",
            color: FlowTokens.accent,
            colorHex: "#618FFF",
            category: .calendar,
            parameters: [
                (name: "date", type: "STRING", description: "Single date to query in YYYY-MM-DD format.", required: false, enumValues: nil),
                (name: "date_range_start", type: "STRING", description: "Start of date range in YYYY-MM-DD format.", required: false, enumValues: nil),
                (name: "date_range_end", type: "STRING", description: "End of date range in YYYY-MM-DD format.", required: false, enumValues: nil),
            ]
        ),

        ToolDefinition(
            name: "check_availability",
            displayName: "Check Availability",
            description: "Check if a time slot is free on the user's calendar.",
            icon: "calendar.badge.checkmark",
            color: FlowTokens.success,
            colorHex: "#4DBF66",
            category: .calendar,
            parameters: [
                (name: "date", type: "STRING", description: "The date to check in YYYY-MM-DD format.", required: true, enumValues: nil),
                (name: "start_time", type: "STRING", description: "Start time in HH:mm format.", required: true, enumValues: nil),
                (name: "end_time", type: "STRING", description: "End time in HH:mm format.", required: true, enumValues: nil),
            ]
        ),

        // MARK: Extended Todos

        ToolDefinition(
            name: "edit_todo",
            displayName: "Edit Todo",
            description: "Edit an existing todo item's title, notes, priority, or category.",
            icon: "pencil.circle.fill",
            color: FlowTokens.warning,
            colorHex: "#E6BF4D",
            category: .todos,
            parameters: [
                (name: "todo_title", type: "STRING", description: "The title of the todo to edit.", required: true, enumValues: nil),
                (name: "new_title", type: "STRING", description: "New title for the todo.", required: false, enumValues: nil),
                (name: "new_notes", type: "STRING", description: "New notes for the todo.", required: false, enumValues: nil),
                (name: "new_priority", type: "STRING", description: "New priority level.", required: false, enumValues: ["high", "medium", "low"]),
                (name: "new_category", type: "STRING", description: "New category.", required: false, enumValues: nil),
            ]
        ),

        ToolDefinition(
            name: "schedule_todo",
            displayName: "Schedule Todo",
            description: "Schedule an existing todo to a specific date and time on the calendar.",
            icon: "calendar.badge.plus",
            color: FlowTokens.accent,
            colorHex: "#618FFF",
            category: .todos,
            parameters: [
                (name: "todo_title", type: "STRING", description: "The title of the todo to schedule.", required: true, enumValues: nil),
                (name: "date", type: "STRING", description: "The date in YYYY-MM-DD format.", required: true, enumValues: nil),
                (name: "start_time", type: "STRING", description: "Start time in HH:mm format.", required: true, enumValues: nil),
                (name: "end_time", type: "STRING", description: "End time in HH:mm format.", required: false, enumValues: nil),
            ]
        ),

        ToolDefinition(
            name: "list_todos",
            displayName: "List Todos",
            description: "List todos, optionally filtered by status, priority, or category.",
            icon: "list.bullet",
            color: FlowTokens.success,
            colorHex: "#4DBF66",
            category: .todos,
            parameters: [
                (name: "filter", type: "STRING", description: "Filter by status.", required: false, enumValues: ["active", "completed", "all"]),
                (name: "priority", type: "STRING", description: "Filter by priority.", required: false, enumValues: ["high", "medium", "low"]),
                (name: "category", type: "STRING", description: "Filter by category.", required: false, enumValues: nil),
            ]
        ),

        // MARK: Extended Deadlines

        ToolDefinition(
            name: "complete_deadline",
            displayName: "Complete Deadline",
            description: "Mark a deadline as completed.",
            icon: "checkmark.circle.fill",
            color: FlowTokens.success,
            colorHex: "#4DBF66",
            category: .deadlines,
            parameters: [
                (name: "deadline_title", type: "STRING", description: "The title of the deadline to complete.", required: true, enumValues: nil),
            ]
        ),

        ToolDefinition(
            name: "delete_deadline",
            displayName: "Delete Deadline",
            description: "Delete an existing deadline.",
            icon: "trash.fill",
            color: FlowTokens.error,
            colorHex: "#E66666",
            category: .deadlines,
            parameters: [
                (name: "deadline_title", type: "STRING", description: "The title of the deadline to delete.", required: true, enumValues: nil),
            ]
        ),

        ToolDefinition(
            name: "edit_deadline",
            displayName: "Edit Deadline",
            description: "Edit an existing deadline's title, due date, category, or prep hours.",
            icon: "pencil.circle.fill",
            color: FlowTokens.warning,
            colorHex: "#E6BF4D",
            category: .deadlines,
            parameters: [
                (name: "deadline_title", type: "STRING", description: "The title of the deadline to edit.", required: true, enumValues: nil),
                (name: "new_title", type: "STRING", description: "New title.", required: false, enumValues: nil),
                (name: "new_due_date", type: "STRING", description: "New due date in YYYY-MM-DD format.", required: false, enumValues: nil),
                (name: "new_category", type: "STRING", description: "New category.", required: false, enumValues: ["study", "work", "research", "personalStudy", "creative", "general"]),
                (name: "new_prep_hours", type: "NUMBER", description: "New estimated prep hours.", required: false, enumValues: nil),
            ]
        ),

        // MARK: Extended Notes

        ToolDefinition(
            name: "edit_note",
            displayName: "Edit Note",
            description: "Edit an existing note's content, summary, or category.",
            icon: "pencil.circle.fill",
            color: FlowTokens.warning,
            colorHex: "#E6BF4D",
            category: .notes,
            parameters: [
                (name: "note_summary", type: "STRING", description: "The summary of the note to edit.", required: true, enumValues: nil),
                (name: "new_content", type: "STRING", description: "New content.", required: false, enumValues: nil),
                (name: "new_summary", type: "STRING", description: "New summary.", required: false, enumValues: nil),
                (name: "new_category", type: "STRING", description: "New category.", required: false, enumValues: ["idea", "task", "reminder", "goal", "journal", "reference"]),
            ]
        ),

        ToolDefinition(
            name: "delete_note",
            displayName: "Delete Note",
            description: "Delete an existing note.",
            icon: "trash.fill",
            color: FlowTokens.error,
            colorHex: "#E66666",
            category: .notes,
            parameters: [
                (name: "note_summary", type: "STRING", description: "The summary of the note to delete.", required: true, enumValues: nil),
            ]
        ),

        ToolDefinition(
            name: "search_notes",
            displayName: "Search Notes",
            description: "Search through notes by keyword.",
            icon: "magnifyingglass",
            color: FlowTokens.accent,
            colorHex: "#618FFF",
            category: .notes,
            parameters: [
                (name: "query", type: "STRING", description: "The search query.", required: true, enumValues: nil),
            ]
        ),
    ]

    // MARK: - Queries

    /// Returns Gemini API function declarations for all tools.
    static func allDeclarations() -> [[String: Any]] {
        all.map { $0.declaration() }
    }

    /// Returns display metadata for a tool by name; falls back to a generic entry.
    static func displayInfo(for name: String) -> (displayName: String, icon: String, color: Color, hex: String) {
        if let tool = all.first(where: { $0.name == name }) {
            return (tool.displayName, tool.icon, tool.color, tool.colorHex)
        }
        return (name, "gear", FlowTokens.textTertiary, "#666666")
    }

    /// Returns the full definition for a tool by name, if it exists.
    static func tool(named name: String) -> ToolDefinition? {
        all.first { $0.name == name }
    }

    /// All registered tool names.
    static var allToolNames: [String] { all.map(\.name) }
}
