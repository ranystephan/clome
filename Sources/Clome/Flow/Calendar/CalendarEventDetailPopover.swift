import SwiftUI
import ClomeModels

// MARK: - Calendar Event Detail Popover

/// Popover for viewing and editing calendar items.
/// Shows different fields depending on item kind (event, todo, deadline, reminder).
struct CalendarEventDetailPopover: View {
    let item: any CalendarItemProtocol
    let onDismiss: () -> Void

    @ObservedObject private var syncService = FlowSyncService.shared
    @ObservedObject private var dataManager = CalendarDataManager.shared

    // Editable state
    @State private var editTitle: String = ""
    @State private var editStartTime: Date = Date()
    @State private var editEndTime: Date = Date()
    @State private var editPriority: TodoPriority = .medium
    @State private var editCategory: HabitCategory = .general
    @State private var editPrepHours: Double = 0
    @State private var isEditing = false

    // MARK: - Init

    init(item: any CalendarItemProtocol, onDismiss: @escaping () -> Void) {
        self.item = item
        self.onDismiss = onDismiss
        _editTitle = State(initialValue: item.title)
        _editStartTime = State(initialValue: item.startDate)
        _editEndTime = State(initialValue: item.endDate)

        // Extract priority from todo if applicable
        if let todoItem = item as? ScheduledTodoItem {
            _editPriority = State(initialValue: todoItem.todo.priority)
        }

        // Extract category and prep hours from deadline if applicable
        if let deadlineItem = item as? DeadlineCalendarItem {
            _editCategory = State(initialValue: deadlineItem.deadline.category)
            _editPrepHours = State(initialValue: deadlineItem.deadline.estimatedPrepHours ?? 0)
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: FlowTokens.spacingMD) {
            // Kind badge with colored dot
            HStack {
                Circle()
                    .fill(item.displayColor)
                    .frame(width: 6, height: 6)
                Text(kindLabel)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(FlowTokens.textSecondary)
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .foregroundColor(FlowTokens.textTertiary)
                }
                .buttonStyle(.plain)
            }

            // Title
            if isEditing && (item.kind == .todo || item.kind == .deadline) {
                TextField("Title", text: $editTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(FlowTokens.textPrimary)
            } else {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(FlowTokens.textPrimary)
                    .lineLimit(2)
            }

            // Time range
            if isEditing {
                DatePicker("Start", selection: $editStartTime, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .scaleEffect(0.85, anchor: .leading)
                DatePicker("End", selection: $editEndTime, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .scaleEffect(0.85, anchor: .leading)
            } else {
                Text(timeRangeString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(FlowTokens.textTertiary)
            }

            // Kind-specific fields
            kindSpecificFields

            Divider()
                .background(FlowTokens.border)

            // Action buttons
            HStack {
                if item.kind == .todo || item.kind == .deadline {
                    Button("Complete") { markComplete() }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(FlowTokens.success)
                        .buttonStyle(.plain)

                    Button("Delete") { deleteItem() }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(FlowTokens.error)
                        .buttonStyle(.plain)
                }

                Spacer()

                if isEditing {
                    Button("Cancel") { isEditing = false }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(FlowTokens.textSecondary)
                        .buttonStyle(.plain)
                    Button("Save") { saveChanges(); onDismiss() }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(FlowTokens.accent)
                        .buttonStyle(.plain)
                } else if item.kind == .todo || item.kind == .deadline {
                    Button("Edit") { isEditing = true }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(FlowTokens.accent)
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(FlowTokens.spacingLG)
        .frame(width: 260)
        .background(FlowTokens.bg2)
        .overlay(
            RoundedRectangle(cornerRadius: FlowTokens.radiusMedium, style: .continuous)
                .stroke(FlowTokens.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: FlowTokens.radiusMedium, style: .continuous))
    }

    // MARK: - Kind-Specific Fields

    @ViewBuilder
    private var kindSpecificFields: some View {
        switch item.kind {
        case .todo:
            // Priority pills
            if isEditing {
                HStack(spacing: FlowTokens.spacingSM) {
                    Text("Priority")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(FlowTokens.textTertiary)
                    ForEach(TodoPriority.allCases, id: \.self) { priority in
                        Button {
                            editPriority = priority
                        } label: {
                            Text(priorityAbbrev(priority))
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(editPriority == priority ? .white : FlowTokens.textTertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: FlowTokens.radiusSmall)
                                        .fill(editPriority == priority ? priorityColor(priority) : FlowTokens.bg3)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if let todoItem = item as? ScheduledTodoItem {
                HStack(spacing: FlowTokens.spacingSM) {
                    Text("Priority:")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(FlowTokens.textTertiary)
                    Text(todoItem.todo.priority.displayName)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(priorityColor(todoItem.todo.priority))
                }
                if item.isCompleted {
                    completionBadge
                }
            }

        case .deadline:
            if let deadlineItem = item as? DeadlineCalendarItem {
                HStack(spacing: FlowTokens.spacingSM) {
                    Text("Category:")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(FlowTokens.textTertiary)
                    Text(deadlineItem.deadline.category.rawValue.capitalized)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(FlowTokens.textSecondary)
                }
                if let prepHours = deadlineItem.deadline.estimatedPrepHours, prepHours > 0 {
                    HStack(spacing: FlowTokens.spacingSM) {
                        Text("Prep:")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(FlowTokens.textTertiary)
                        Text("\(prepHours, specifier: "%.1f")h")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(FlowTokens.textSecondary)
                    }
                }
                if item.isCompleted {
                    completionBadge
                }
            }

        case .systemEvent:
            if let eventItem = item as? SystemEventItem {
                HStack(spacing: FlowTokens.spacingSM) {
                    Text("Calendar")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(FlowTokens.textTertiary)
                    Circle()
                        .fill(eventItem.calendarColor)
                        .frame(width: 6, height: 6)
                    if eventItem.isClomeCreated {
                        Text("Clome")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(FlowTokens.accent)
                    }
                }
            }

        case .reminder:
            HStack(spacing: FlowTokens.spacingSM) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10))
                    .foregroundColor(item.isCompleted ? FlowTokens.success : FlowTokens.textTertiary)
                Text(item.isCompleted ? "Completed" : "Pending")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(FlowTokens.textTertiary)
            }
        }
    }

    // MARK: - Helpers

    private var completionBadge: some View {
        HStack(spacing: FlowTokens.spacingXS) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(FlowTokens.success)
            Text("Completed")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(FlowTokens.success)
        }
    }

    private var kindLabel: String {
        switch item.kind {
        case .systemEvent: return "EVENT"
        case .todo:        return "TODO"
        case .deadline:    return "DEADLINE"
        case .reminder:    return "REMINDER"
        }
    }

    private var timeRangeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let start = formatter.string(from: item.startDate)
        let end = formatter.string(from: item.endDate)
        if item.isAllDay { return "All Day" }
        if item.startDate == item.endDate { return start }
        return "\(start) \u{2013} \(end)"
    }

    private func priorityAbbrev(_ priority: TodoPriority) -> String {
        switch priority {
        case .high:   return "H"
        case .medium: return "M"
        case .low:    return "L"
        }
    }

    private func priorityColor(_ priority: TodoPriority) -> Color {
        switch priority {
        case .high:   return FlowTokens.priorityHigh
        case .medium: return FlowTokens.priorityMedium
        case .low:    return FlowTokens.priorityLow
        }
    }

    // MARK: - ID Extraction

    private func extractTodoID() -> UUID? {
        let raw = item.calendarItemID
        guard raw.hasPrefix("todo-") else { return nil }
        return UUID(uuidString: String(raw.dropFirst(5)))
    }

    private func extractDeadlineID() -> UUID? {
        let raw = item.calendarItemID
        guard raw.hasPrefix("deadline-") else { return nil }
        return UUID(uuidString: String(raw.dropFirst(9)))
    }

    // MARK: - Actions

    private func markComplete() {
        switch item.kind {
        case .todo:
            if let id = extractTodoID() {
                syncService.toggleTodoComplete(id: id)
            }
        case .deadline:
            if let id = extractDeadlineID() {
                syncService.toggleDeadlineComplete(id: id)
            }
        default:
            break
        }
        dataManager.refresh()
        onDismiss()
    }

    private func deleteItem() {
        switch item.kind {
        case .todo:
            if let id = extractTodoID() {
                syncService.deleteTodo(id: id)
            }
        case .deadline:
            if let id = extractDeadlineID() {
                syncService.deleteDeadline(id: id)
            }
        default:
            break
        }
        dataManager.refresh()
        onDismiss()
    }

    private func saveChanges() {
        switch item.kind {
        case .todo:
            if let id = extractTodoID() {
                syncService.updateTodo(id: id, title: editTitle)
                syncService.updateTodoSchedule(id: id, scheduledDate: editStartTime, scheduledEndDate: editEndTime)
            }
        case .deadline:
            if let id = extractDeadlineID() {
                syncService.updateDeadline(id: id, title: editTitle, dueDate: editStartTime)
            }
        default:
            break
        }
        dataManager.refresh()
    }
}
