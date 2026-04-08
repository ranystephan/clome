import SwiftUI
import ClomeModels

/// Agenda sidebar — restrained list of the selected day's schedule
/// plus a live Tasks section with inline add-todo.
///
/// Sections:
///   - Schedule  (timed events)
///   - Tasks     (active todos; add-todo inline at top)
///   - Due       (deadlines for the day, if any)
struct CalendarAgendaSidebar: View {
    @ObservedObject var dataManager: CalendarDataManager
    @ObservedObject private var syncService = FlowSyncService.shared

    @State private var currentTime = Date()
    @State private var newTodoTitle: String = ""
    @State private var detailItem: AnyAgendaItem?
    @FocusState private var addTodoFocused: Bool
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: FlowTokens.spacingXL) {
                    scheduleSection
                    tasksSection
                    deadlinesSection
                    Spacer(minLength: FlowTokens.spacingXL)
                }
                .padding(.horizontal, FlowTokens.spacingLG)
                .padding(.top, FlowTokens.spacingLG)
                .padding(.bottom, FlowTokens.spacingXXL)
            }
        }
        .background(FlowTokens.bg0)
        .onReceive(ticker) { currentTime = $0 }
        // Detail popover temporarily removed — will be replaced by inline expand in Wave 2.
        .onChange(of: detailItem?.id) { _, _ in detailItem = nil }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(relativeDayLabel.uppercased())
                .flowFont(.sectionLabel)
                .foregroundColor(FlowTokens.textTertiary)
            Text(fullDateLabel)
                .flowFont(.title2)
                .foregroundColor(FlowTokens.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, FlowTokens.spacingLG)
        .padding(.top, FlowTokens.spacingLG)
        .padding(.bottom, FlowTokens.spacingMD)
        .overlay(alignment: .bottom) {
            Rectangle().fill(FlowTokens.border).frame(height: FlowTokens.hairline)
        }
    }

    private var relativeDayLabel: String {
        let cal = Calendar.current
        let d = dataManager.selectedDate
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        let f = DateFormatter(); f.dateFormat = "EEEE"
        return f.string(from: d)
    }

    private var fullDateLabel: String {
        let f = DateFormatter(); f.dateFormat = "MMMM d"
        return f.string(from: dataManager.selectedDate)
    }

    // MARK: - Schedule

    private var scheduleSection: some View {
        let items = scheduleItems
        return VStack(alignment: .leading, spacing: FlowTokens.spacingSM) {
            sectionHeader("Schedule", count: items.count)

            if items.isEmpty {
                emptyHint("Nothing scheduled")
            } else {
                VStack(spacing: 2) {
                    ForEach(items, id: \.calendarItemID) { item in
                        agendaRow(item)
                            .onTapGesture { detailItem = AnyAgendaItem(item) }
                    }
                }
            }
        }
    }

    private var scheduleItems: [any CalendarItemProtocol] {
        let cal = Calendar.current
        return dataManager.items
            .filter { $0.kind == .systemEvent && cal.isDate($0.startDate, inSameDayAs: dataManager.selectedDate) }
            .sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Tasks

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: FlowTokens.spacingSM) {
            sectionHeader("Tasks", count: activeTodos.count)
            addTodoRow
            if activeTodos.isEmpty {
                emptyHint("Nothing on your plate")
            } else {
                VStack(spacing: 2) {
                    ForEach(activeTodos) { todo in
                        todoRow(todo)
                    }
                }
            }
        }
    }

    private var addTodoRow: some View {
        HStack(spacing: FlowTokens.spacingSM) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(FlowTokens.textHint)
                .frame(width: 14)
            TextField("Add a task…", text: $newTodoTitle)
                .textFieldStyle(.plain)
                .flowFont(.body)
                .foregroundColor(FlowTokens.textPrimary)
                .focused($addTodoFocused)
                .onSubmit(commitNewTodo)
        }
        .flowInput(isFocused: addTodoFocused)
    }

    private func commitNewTodo() {
        let trimmed = newTodoTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        syncService.addTodo(TodoItem(title: trimmed))
        newTodoTitle = ""
        addTodoFocused = true
    }

    private var activeTodos: [TodoItem] {
        syncService.todos
            .filter { !$0.isCompleted }
            .sorted { a, b in
                // Scheduled first (by time), then unscheduled
                switch (a.scheduledDate, b.scheduledDate) {
                case let (la?, lb?): return la < lb
                case (_?, nil):      return true
                case (nil, _?):      return false
                default:             return a.priority.sortOrder < b.priority.sortOrder
                }
            }
    }

    private func todoRow(_ todo: TodoItem) -> some View {
        HStack(alignment: .center, spacing: FlowTokens.spacingMD) {
            Button {
                syncService.toggleTodoComplete(id: todo.id)
            } label: {
                Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(todo.isCompleted ? FlowTokens.success.opacity(0.75) : FlowTokens.textTertiary)
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(todoAccentColor(todo))
                .frame(width: FlowTokens.accentBarWidth)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 1) {
                Text(todo.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(todo.isCompleted ? FlowTokens.textTertiary : FlowTokens.textPrimary)
                    .strikethrough(todo.isCompleted, color: FlowTokens.textTertiary)
                    .lineLimit(2)
                if let sub = todoSubtitle(todo) {
                    Text(sub)
                        .flowFont(.timestamp)
                        .foregroundColor(FlowTokens.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, FlowTokens.spacingSM - 2)
        .padding(.horizontal, FlowTokens.spacingSM)
    }

    private func todoAccentColor(_ todo: TodoItem) -> Color {
        if todo.isCompleted { return FlowTokens.textMuted }
        switch todo.priority {
        case .high:   return FlowTokens.priorityHigh
        case .medium: return FlowTokens.priorityMedium
        case .low:    return FlowTokens.priorityLow
        }
    }

    private func todoSubtitle(_ todo: TodoItem) -> String? {
        if let date = todo.scheduledDate {
            let f = DateFormatter(); f.dateFormat = "h:mm a"
            return f.string(from: date).lowercased()
        }
        return nil
    }

    // MARK: - Deadlines

    @ViewBuilder
    private var deadlinesSection: some View {
        let items = deadlineItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: FlowTokens.spacingSM) {
                sectionHeader("Due", count: items.count)
                VStack(spacing: 2) {
                    ForEach(items, id: \.calendarItemID) { item in
                        agendaRow(item)
                            .onTapGesture { detailItem = AnyAgendaItem(item) }
                    }
                }
            }
        }
    }

    private var deadlineItems: [any CalendarItemProtocol] {
        let cal = Calendar.current
        return dataManager.items
            .filter { $0.kind == .deadline && cal.isDate($0.startDate, inSameDayAs: dataManager.selectedDate) }
            .sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Section header

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: FlowTokens.spacingSM) {
            Text(title.uppercased())
                .flowFont(.sectionLabel)
                .foregroundColor(FlowTokens.textTertiary)
            if count > 0 {
                Text("\(count)")
                    .flowFont(.timestamp)
                    .foregroundColor(FlowTokens.textMuted)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Agenda row

    private func agendaRow(_ item: any CalendarItemProtocol) -> some View {
        let status = rowStatus(for: item)
        let isNow = status == .now
        let isPast = status == .past
        let tint = item.displayColor

        return HStack(alignment: .top, spacing: FlowTokens.spacingMD) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(formatted(item.startDate, "h:mm"))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(isPast ? FlowTokens.textMuted : FlowTokens.textSecondary)
                Text(formatted(item.startDate, "a").lowercased())
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(FlowTokens.textMuted)
            }
            .frame(width: 38, alignment: .trailing)

            Rectangle()
                .fill(isPast ? tint.opacity(0.45) : tint)
                .frame(width: FlowTokens.accentBarWidth)
                .padding(.vertical, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12, weight: isNow ? .semibold : .medium))
                    .foregroundColor(isPast ? FlowTokens.textTertiary : FlowTokens.textPrimary)
                    .strikethrough(item.isCompleted)
                    .lineLimit(2)
                Text(metaLabel(for: item))
                    .flowFont(.timestamp)
                    .foregroundColor(FlowTokens.textMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isNow {
                Circle()
                    .fill(FlowTokens.editorialRed)
                    .frame(width: 6, height: 6)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, FlowTokens.spacingSM - 2)
        .padding(.horizontal, FlowTokens.spacingSM)
        .background(
            RoundedRectangle(cornerRadius: FlowTokens.radiusControl, style: .continuous)
                .fill(isNow ? FlowTokens.bg2.opacity(0.5) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func metaLabel(for item: any CalendarItemProtocol) -> String {
        switch item.kind {
        case .systemEvent:
            let duration = item.endDate.timeIntervalSince(item.startDate)
            let mins = Int(duration / 60)
            if mins <= 0 { return "—" }
            if mins < 60 { return "\(mins) min" }
            let h = mins / 60
            let m = mins % 60
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        case .todo:     return "Task"
        case .deadline: return "Due"
        case .reminder: return "Reminder"
        }
    }

    // MARK: - Empty hint

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .flowFont(.caption)
            .foregroundColor(FlowTokens.textMuted)
            .padding(.horizontal, FlowTokens.spacingSM)
            .padding(.vertical, FlowTokens.spacingXS)
    }

    // MARK: - Status

    private enum RowStatus { case past, now, upcoming }

    private func rowStatus(for item: any CalendarItemProtocol) -> RowStatus {
        if currentTime >= item.endDate { return .past }
        if currentTime >= item.startDate { return .now }
        return .upcoming
    }

    private func formatted(_ date: Date, _ format: String) -> String {
        let f = DateFormatter(); f.dateFormat = format
        return f.string(from: date)
    }
}

// MARK: - Identifiable wrapper for popover(item:)
private struct AnyAgendaItem: Identifiable {
    let item: any CalendarItemProtocol
    var id: String { item.calendarItemID }
    init(_ item: any CalendarItemProtocol) { self.item = item }
}
