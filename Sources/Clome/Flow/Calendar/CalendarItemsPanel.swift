import SwiftUI
import ClomeModels

// MARK: - Panel Segment

enum CalendarPanelSegment: String, CaseIterable {
    case todos = "Todos"
    case deadlines = "Deadlines"
    case notes = "Notes"
}

// MARK: - Calendar Items Panel

/// Collapsible panel that shows todos, deadlines, and notes for the selected calendar date.
/// Displayed below the calendar timeline and integrates with other Flow subtabs.
struct CalendarItemsPanel: View {

    @ObservedObject private var syncService = FlowSyncService.shared
    @ObservedObject private var dataManager = CalendarDataManager.shared
    @State private var activeSegment: CalendarPanelSegment = .todos
    @State private var quickAddText = ""
    @FocusState private var quickAddFocused: Bool

    // MARK: - Filtered Data

    private var selectedCalendar: Calendar { Calendar.current }

    private var scheduledTodos: [TodoItem] {
        syncService.todos.filter { todo in
            guard let scheduled = todo.scheduledDate else { return false }
            return selectedCalendar.isDate(scheduled, inSameDayAs: dataManager.selectedDate)
        }
    }

    private var backlogTodos: [TodoItem] {
        syncService.todos.filter { $0.scheduledDate == nil && !$0.isCompleted }
    }

    private var dueTodayDeadlines: [Deadline] {
        syncService.deadlines.filter { deadline in
            selectedCalendar.isDate(deadline.dueDate, inSameDayAs: dataManager.selectedDate)
        }
    }

    private var overdueDeadlines: [Deadline] {
        syncService.deadlines.filter { deadline in
            deadline.isPastDue
                && !deadline.isCompleted
                && !selectedCalendar.isDate(deadline.dueDate, inSameDayAs: dataManager.selectedDate)
        }
    }

    private var todayNotes: [NoteEntry] {
        syncService.notes.filter { note in
            selectedCalendar.isDate(note.updatedAt, inSameDayAs: dataManager.selectedDate)
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            segmentedHeader
            Divider().background(FlowTokens.border)
            contentArea
            Divider().background(FlowTokens.border)
            quickAddBar
        }
        .background(FlowTokens.bg0)
    }

    // MARK: - Segmented Header

    private var segmentedHeader: some View {
        HStack(spacing: FlowTokens.spacingXS) {
            ForEach(CalendarPanelSegment.allCases, id: \.self) { segment in
                Button {
                    withAnimation(.flowQuick) { activeSegment = segment }
                } label: {
                    HStack(spacing: 3) {
                        Text(segment.rawValue)
                            .font(.system(size: 10, weight: activeSegment == segment ? .medium : .regular))
                        Text("\(countFor(segment))")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(FlowTokens.textMuted)
                    }
                    .foregroundColor(activeSegment == segment ? FlowTokens.textPrimary : FlowTokens.textTertiary)
                    .padding(.horizontal, FlowTokens.spacingMD)
                    .padding(.vertical, FlowTokens.spacingSM)
                    .background(
                        RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                            .fill(activeSegment == segment ? FlowTokens.accentSubtle : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, FlowTokens.spacingSM)
    }

    // MARK: - Content Area

    private var contentArea: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                switch activeSegment {
                case .todos:
                    todosContent
                case .deadlines:
                    deadlinesContent
                case .notes:
                    notesContent
                }
            }
            .padding(.vertical, FlowTokens.spacingSM)
        }
    }

    // MARK: - Todos Content

    @ViewBuilder
    private var todosContent: some View {
        if !scheduledTodos.isEmpty {
            sectionHeader("SCHEDULED")
            ForEach(scheduledTodos) { todo in
                todoRow(todo)
            }
        }

        if !backlogTodos.isEmpty {
            sectionHeader("BACKLOG")
            ForEach(backlogTodos) { todo in
                todoRow(todo)
            }
        }

        if scheduledTodos.isEmpty && backlogTodos.isEmpty {
            emptyState("No todos for this date")
        }
    }

    private func todoRow(_ todo: TodoItem) -> some View {
        HStack(spacing: FlowTokens.spacingSM) {
            Circle()
                .fill(priorityColor(todo.priority))
                .frame(width: 5, height: 5)

            Button {
                syncService.toggleTodoComplete(id: todo.id)
            } label: {
                Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10))
                    .foregroundColor(todo.isCompleted ? FlowTokens.success.opacity(0.6) : FlowTokens.textTertiary)
            }
            .buttonStyle(.plain)

            Text(todo.title)
                .font(.system(size: 11))
                .foregroundColor(todo.isCompleted ? FlowTokens.textDisabled : FlowTokens.textPrimary)
                .strikethrough(todo.isCompleted, color: FlowTokens.textDisabled)
                .lineLimit(1)

            Spacer()

            if let scheduled = todo.scheduledDate {
                Text(timeString(scheduled))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(FlowTokens.textHint)
            }
        }
        .frame(height: 22)
        .padding(.horizontal, 10)
    }

    // MARK: - Deadlines Content

    @ViewBuilder
    private var deadlinesContent: some View {
        if !overdueDeadlines.isEmpty {
            sectionHeader("OVERDUE")
            ForEach(overdueDeadlines) { deadline in
                deadlineRow(deadline)
            }
        }

        if !dueTodayDeadlines.isEmpty {
            sectionHeader("DUE TODAY")
            ForEach(dueTodayDeadlines) { deadline in
                deadlineRow(deadline)
            }
        }

        if overdueDeadlines.isEmpty && dueTodayDeadlines.isEmpty {
            emptyState("No deadlines for this date")
        }
    }

    private func deadlineRow(_ deadline: Deadline) -> some View {
        HStack(spacing: FlowTokens.spacingSM) {
            Image(systemName: "flag.fill")
                .font(.system(size: 8))
                .foregroundColor(urgencyColor(deadline))

            Text(deadline.title)
                .font(.system(size: 11))
                .foregroundColor(deadline.isCompleted ? FlowTokens.textDisabled : FlowTokens.textPrimary)
                .strikethrough(deadline.isCompleted, color: FlowTokens.textDisabled)
                .lineLimit(1)

            Spacer()

            Text(countdownString(deadline))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(urgencyColor(deadline))
        }
        .frame(height: 22)
        .padding(.horizontal, 10)
    }

    // MARK: - Notes Content

    @ViewBuilder
    private var notesContent: some View {
        if todayNotes.isEmpty {
            emptyState("No notes for this date")
        } else {
            ForEach(todayNotes) { note in
                noteRow(note)
            }
        }
    }

    private func noteRow(_ note: NoteEntry) -> some View {
        HStack(spacing: FlowTokens.spacingSM) {
            Image(systemName: note.category.icon)
                .font(.system(size: 8))
                .foregroundColor(noteCategoryColor(note.category))

            Text(note.summary.isEmpty ? String(note.rawContent.prefix(60)) : note.summary)
                .font(.system(size: 11))
                .foregroundColor(FlowTokens.textPrimary)
                .lineLimit(1)

            Spacer()

            Text(relativeTimeString(note.updatedAt))
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(FlowTokens.textHint)
        }
        .frame(height: 22)
        .padding(.horizontal, 10)
    }

    // MARK: - Quick-Add Bar

    private var quickAddBar: some View {
        HStack(spacing: FlowTokens.spacingSM) {
            Image(systemName: "plus.circle")
                .font(.system(size: 11))
                .foregroundColor(FlowTokens.textHint)

            TextField(quickAddPlaceholder, text: $quickAddText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($quickAddFocused)
                .onSubmit { quickAdd() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, FlowTokens.spacingMD)
        .background(FlowTokens.bg1)
    }

    private var quickAddPlaceholder: String {
        let dateStr = shortDateString(dataManager.selectedDate)
        switch activeSegment {
        case .todos:     return "Add todo to backlog..."
        case .deadlines: return "Add deadline..."
        case .notes:     return "Add note..."
        }
    }

    // MARK: - Shared Components

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .flowSectionHeader()
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, FlowTokens.spacingMD)
        .padding(.bottom, FlowTokens.spacingSM)
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 10))
            .foregroundColor(FlowTokens.textHint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, FlowTokens.spacingXL)
    }

    // MARK: - Actions

    private func quickAdd() {
        let text = quickAddText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        switch activeSegment {
        case .todos:
            // Create unscheduled todo (backlog). User can drag onto calendar to schedule.
            let todo = TodoItem(title: text)
            syncService.addTodo(todo)

        case .deadlines:
            let endOfDay = selectedCalendar.date(bySettingHour: 23, minute: 59, second: 59, of: dataManager.selectedDate) ?? dataManager.selectedDate
            let deadline = Deadline(
                title: text,
                dueDate: endOfDay
            )
            syncService.addDeadline(deadline)

        case .notes:
            // Notes are synced from iOS, not created here
            break
        }

        withAnimation(.flowQuick) {
            quickAddText = ""
        }
    }

    // MARK: - Helpers

    private func countFor(_ segment: CalendarPanelSegment) -> Int {
        switch segment {
        case .todos:     return scheduledTodos.count + backlogTodos.count
        case .deadlines: return dueTodayDeadlines.count + overdueDeadlines.count
        case .notes:     return todayNotes.count
        }
    }

    private func priorityColor(_ priority: TodoPriority) -> Color {
        switch priority {
        case .high:   return FlowTokens.priorityHigh
        case .medium: return FlowTokens.priorityMedium
        case .low:    return FlowTokens.priorityLow
        }
    }

    private func urgencyColor(_ deadline: Deadline) -> Color {
        let hours = deadline.hoursUntilDue
        if hours < 0  { return FlowTokens.urgencyOverdue }
        if hours < 24  { return FlowTokens.urgencyCritical }
        if hours < 72  { return FlowTokens.urgencyWarning }
        return FlowTokens.urgencyNormal
    }

    private func noteCategoryColor(_ category: NoteCategory) -> Color {
        FlowTokens.categoryColor(category.rawValue)
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func shortDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private func countdownString(_ deadline: Deadline) -> String {
        let hours = deadline.hoursUntilDue
        if hours < 0 {
            let overdue = abs(hours)
            if overdue < 24 {
                return "-\(Int(overdue))h"
            } else {
                return "-\(Int(overdue / 24))d"
            }
        } else if hours < 1 {
            return "\(Int(hours * 60))m"
        } else if hours < 24 {
            return "\(Int(hours))h"
        } else {
            return "\(Int(hours / 24))d"
        }
    }

    private func relativeTimeString(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86400))d ago"
    }
}
