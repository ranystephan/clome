import SwiftUI
import ClomeModels

// MARK: - Calendar Item Kind

enum CalendarItemKind: String {
    case systemEvent
    case todo
    case deadline
    case reminder
}

// MARK: - Calendar Item Protocol

protocol CalendarItemProtocol: Identifiable {
    var calendarItemID: String { get }
    var title: String { get }
    var startDate: Date { get }
    var endDate: Date { get }
    var isAllDay: Bool { get }
    var kind: CalendarItemKind { get }
    var displayColor: Color { get }
    var isCompleted: Bool { get }
}

extension CalendarItemProtocol {
    var id: String { calendarItemID }
}

// MARK: - System Event Item

/// Wraps extracted EKEvent data. Does NOT retain the EKEvent reference.
struct SystemEventItem: CalendarItemProtocol {
    let calendarItemID: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let calendarColor: Color
    let eventIdentifier: String
    let isClomeCreated: Bool
    let location: String?
    let notes: String?
    let calendarName: String
    let hasRecurrence: Bool
    let hasAlarms: Bool

    var kind: CalendarItemKind { .systemEvent }
    var displayColor: Color { calendarColor }
    var isCompleted: Bool { false }
}

// MARK: - Scheduled Todo Item

/// Wraps a TodoItem that has a non-nil scheduledDate.
struct ScheduledTodoItem: CalendarItemProtocol {
    let todo: TodoItem

    var calendarItemID: String { "todo-\(todo.id.uuidString)" }
    var title: String { todo.title }

    var startDate: Date {
        todo.scheduledDate!
    }

    var endDate: Date {
        todo.scheduledEndDate ?? todo.scheduledDate!.addingTimeInterval(30 * 60)
    }

    var isAllDay: Bool { false }
    var kind: CalendarItemKind { .todo }
    var displayColor: Color { FlowTokens.calendarTodo }
    var isCompleted: Bool { todo.isCompleted }
}

// MARK: - Deadline Calendar Item

/// Wraps a Deadline as a zero-duration marker on the calendar.
struct DeadlineCalendarItem: CalendarItemProtocol {
    let deadline: Deadline

    var calendarItemID: String { "deadline-\(deadline.id.uuidString)" }
    var title: String { deadline.title }
    var startDate: Date { deadline.dueDate }
    var endDate: Date { deadline.dueDate }
    var isAllDay: Bool { false }
    var kind: CalendarItemKind { .deadline }
    var isCompleted: Bool { deadline.isCompleted }

    var displayColor: Color {
        let hours = deadline.hoursUntilDue
        if deadline.isPastDue {
            return FlowTokens.urgencyOverdue
        } else if hours < 24 {
            return FlowTokens.urgencyCritical
        } else if hours < 72 {
            return FlowTokens.urgencyWarning
        } else {
            return FlowTokens.urgencyNormal
        }
    }
}

// MARK: - Reminder Calendar Item

/// Wraps extracted EKReminder data. Does NOT retain the EKReminder reference.
struct ReminderCalendarItem: CalendarItemProtocol {
    let calendarItemID: String
    let title: String
    let dueDate: Date
    let isCompleted: Bool
    let reminderIdentifier: String

    var startDate: Date { dueDate }
    var endDate: Date { dueDate }
    var isAllDay: Bool { false }
    var kind: CalendarItemKind { .reminder }
    var displayColor: Color { FlowTokens.calendarReminder }
}
