import SwiftUI
import ClomeModels

/// Right-side sidebar that lists the selected day's items broken into
/// three editorial sections: Schedule (timed events), Tasks (scheduled
/// todos and deadlines), and Reminders. Mirrors the iOS Today view's
/// agenda card vocabulary.
struct CalendarAgendaSidebar: View {
    @ObservedObject var dataManager: CalendarDataManager
    @ObservedObject private var syncService = FlowSyncService.shared
    @State private var currentTime = Date()
    @State private var newTodoTitle: String = ""
    @FocusState private var addTodoFocused: Bool
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FlowTokens.spacingXL) {
                heroSection
                scheduleSection
                tasksSection
                deadlinesSection
                Spacer(minLength: 0)
            }
            .padding(FlowTokens.spacingLG)
        }
        .background(FlowTokens.bg0)
        .onReceive(ticker) { currentTime = $0 }
    }

    // MARK: - Hero (current/next meeting)

    @ViewBuilder
    private var heroSection: some View {
        if let active = activeMeeting {
            heroCard(item: active, status: .now)
        } else if let next = nextMeeting {
            heroCard(item: next, status: .upcoming)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("NO MEETINGS")
                    .flowFont(.sectionLabel)
                    .foregroundColor(FlowTokens.textTertiary)
                Text(emptyStateGreeting)
                    .flowFont(.title3)
                    .foregroundColor(FlowTokens.textPrimary)
                Text("Tap the canvas to create something.")
                    .flowFont(.caption)
                    .foregroundColor(FlowTokens.textTertiary)
            }
            .padding(FlowTokens.spacingLG)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: FlowTokens.radiusXL, style: .continuous)
                    .fill(FlowTokens.bg2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FlowTokens.radiusXL, style: .continuous)
                    .strokeBorder(FlowTokens.border, lineWidth: FlowTokens.hairline)
            )
        }
    }

    private enum HeroStatus { case now, upcoming }

    private func heroCard(item: any CalendarItemProtocol, status: HeroStatus) -> some View {
        let countdown = countdownString(to: status == .now ? item.endDate : item.startDate)
        let yellow = FlowTokens.editorialYellow
        let dark = FlowTokens.editorialDark
        let progress = status == .now ? activeProgress(item: item) : 0

        return HStack(spacing: 0) {
            // Left yellow banner — the iOS "You Have a Meeting" hero
            VStack(alignment: .leading, spacing: 4) {
                Text(status == .now ? "HAPPENING" : "UP NEXT")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.2)
                    .foregroundColor(dark.opacity(0.7))
                Text(countdown)
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .tracking(-1)
                    .foregroundColor(dark)
                Spacer(minLength: 0)
                Text(item.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(dark)
                    .lineLimit(2)
            }
            .padding(FlowTokens.spacingMD)
            .frame(width: 132, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(yellow)

            // Right details
            VStack(alignment: .leading, spacing: FlowTokens.spacingSM) {
                Text(timeRange(item))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(FlowTokens.textSecondary)

                if let loc = location(of: item), !loc.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 9))
                        Text(loc).lineLimit(1)
                    }
                    .font(.system(size: 11))
                    .foregroundColor(FlowTokens.textTertiary)
                }

                Spacer(minLength: 0)

                if status == .now {
                    VStack(alignment: .leading, spacing: 4) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(FlowTokens.editorialRed.opacity(0.18))
                                Capsule().fill(FlowTokens.editorialRed)
                                    .frame(width: max(2, geo.size.width * progress))
                            }
                        }
                        .frame(height: 4)
                        Text("\(Int(progress * 100))%  ·  \(remainingString(item: item))")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(FlowTokens.editorialRed)
                    }
                } else {
                    Text("Starts " + relativeString(item.startDate))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(FlowTokens.textTertiary)
                }
            }
            .padding(FlowTokens.spacingMD)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FlowTokens.bg2)
        }
        .frame(height: 132)
        .clipShape(RoundedRectangle(cornerRadius: FlowTokens.radiusXL, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FlowTokens.radiusXL, style: .continuous)
                .strokeBorder(FlowTokens.border, lineWidth: FlowTokens.hairline)
        )
    }

    // MARK: - Schedule section

    private var scheduleSection: some View {
        section(title: "SCHEDULE", count: timedEvents.count) {
            if timedEvents.isEmpty {
                emptyRow("No events on this day")
            } else {
                ForEach(timedEvents, id: \.calendarItemID) { item in
                    agendaRow(
                        leading: timeStack(item),
                        accent: item.displayColor,
                        title: item.title,
                        subtitle: location(of: item),
                        isPast: item.endDate < currentTime
                    )
                }
            }
        }
    }

    private var tasksSection: some View {
        section(title: "TASKS", count: activeTodos.count) {
            addTodoRow
            if activeTodos.isEmpty {
                emptyRow("Nothing on your plate")
            } else {
                ForEach(activeTodos) { todo in
                    todoRow(todo)
                }
            }
        }
    }

    private var addTodoRow: some View {
        HStack(spacing: 0) {
            Image(systemName: "plus.circle")
                .font(.system(size: 14))
                .foregroundColor(FlowTokens.textHint)
                .frame(width: 44)

            Rectangle()
                .fill(FlowTokens.calendarTodo.opacity(0.5))
                .frame(width: 2, height: 28)
                .clipShape(Capsule())

            TextField("Add a todo…", text: $newTodoTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(FlowTokens.textPrimary)
                .focused($addTodoFocused)
                .padding(.leading, FlowTokens.spacingSM)
                .padding(.vertical, 8)
                .onSubmit(commitNewTodo)

            Spacer(minLength: 0)
        }
        .padding(.trailing, FlowTokens.spacingMD)
        .contentShape(Rectangle())
        .onTapGesture { addTodoFocused = true }
    }

    private func todoRow(_ todo: TodoItem) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Button {
                syncService.toggleTodoComplete(id: todo.id)
            } label: {
                Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(todo.isCompleted ? FlowTokens.success : FlowTokens.textTertiary)
                    .frame(width: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(FlowTokens.calendarTodo.opacity(todo.isCompleted ? 0.35 : 1.0))
                .frame(width: 2, height: 28)
                .clipShape(Capsule())

            VStack(alignment: .leading, spacing: 1) {
                Text(todo.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(todo.isCompleted ? FlowTokens.textTertiary : FlowTokens.textPrimary)
                    .strikethrough(todo.isCompleted, color: FlowTokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                if let sub = todoSubtitle(todo) {
                    Text(sub)
                        .font(.system(size: 10))
                        .foregroundColor(FlowTokens.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, FlowTokens.spacingSM)
            .padding(.vertical, 8)

            Spacer(minLength: 0)
        }
        .padding(.trailing, FlowTokens.spacingMD)
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
                switch (a.scheduledDate, b.scheduledDate) {
                case let (la?, lb?): return la < lb
                case (_?, nil):      return true
                case (nil, _?):      return false
                default:             return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
                }
            }
    }

    private func todoSubtitle(_ todo: TodoItem) -> String? {
        guard let date = todo.scheduledDate else { return nil }
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(date) {
            f.dateFormat = "'Today' h:mm a"
        } else if cal.isDateInTomorrow(date) {
            f.dateFormat = "'Tomorrow' h:mm a"
        } else {
            f.dateFormat = "MMM d · h:mm a"
        }
        return f.string(from: date)
    }

    private var deadlinesSection: some View {
        section(title: "DEADLINES", count: deadlineItems.count) {
            if deadlineItems.isEmpty {
                emptyRow("Nothing due")
            } else {
                ForEach(deadlineItems, id: \.calendarItemID) { item in
                    agendaRow(
                        leading: AnyView(
                            Image(systemName: "flag.fill")
                                .font(.system(size: 11))
                                .foregroundColor(item.displayColor)
                                .frame(width: 44)
                        ),
                        accent: item.displayColor,
                        title: item.title,
                        subtitle: dueLabel(item),
                        isPast: item.isCompleted
                    )
                }
            }
        }
    }

    // MARK: - Section frame

    private func section<Content: View>(
        title: String,
        count: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: FlowTokens.spacingSM) {
            HStack(spacing: 6) {
                Text(title)
                    .flowFont(.sectionLabel)
                    .foregroundColor(FlowTokens.textTertiary)
                Text("\(count)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(FlowTokens.textHint)
            }
            VStack(spacing: 1) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: FlowTokens.radiusMedium, style: .continuous)
                    .fill(FlowTokens.bg1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FlowTokens.radiusMedium, style: .continuous)
                    .strokeBorder(FlowTokens.border, lineWidth: FlowTokens.hairline)
            )
        }
    }

    // MARK: - Row

    private func agendaRow<Leading: View>(
        leading: Leading,
        accent: Color,
        title: String,
        subtitle: String?,
        isPast: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: 0) {
            leading

            Rectangle()
                .fill(accent.opacity(isPast ? 0.35 : 1.0))
                .frame(width: 2, height: 28)
                .clipShape(Capsule())

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isPast ? FlowTokens.textTertiary : FlowTokens.textPrimary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(FlowTokens.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, FlowTokens.spacingSM)
            .padding(.vertical, 8)

            Spacer(minLength: 0)
        }
        .padding(.trailing, FlowTokens.spacingMD)
    }

    private func timeStack(_ item: any CalendarItemProtocol) -> AnyView {
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return AnyView(
            VStack(alignment: .trailing, spacing: 0) {
                Text(f.string(from: item.startDate))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(FlowTokens.textSecondary)
                Text(f.string(from: item.endDate))
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundColor(FlowTokens.textHint)
            }
            .frame(width: 56, alignment: .trailing)
            .padding(.trailing, FlowTokens.spacingSM)
        )
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(FlowTokens.textHint)
            .padding(FlowTokens.spacingMD)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Filtering

    private var dayItems: [any CalendarItemProtocol] {
        let cal = Calendar.current
        return dataManager.items.filter { cal.isDate($0.startDate, inSameDayAs: dataManager.selectedDate) }
    }

    private var timedEvents: [any CalendarItemProtocol] {
        dayItems.filter { $0.kind == .systemEvent && !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
    }

    private var todoItems: [any CalendarItemProtocol] {
        dayItems.filter { $0.kind == .todo }
            .sorted { $0.startDate < $1.startDate }
    }

    private var deadlineItems: [any CalendarItemProtocol] {
        dayItems.filter { $0.kind == .deadline }
            .sorted { $0.startDate < $1.startDate }
    }

    private var activeMeeting: (any CalendarItemProtocol)? {
        timedEvents.first { $0.startDate <= currentTime && $0.endDate > currentTime }
    }

    private var nextMeeting: (any CalendarItemProtocol)? {
        timedEvents.first { $0.startDate > currentTime }
    }

    // MARK: - Helpers

    private var emptyStateGreeting: String {
        let h = Calendar.current.component(.hour, from: currentTime)
        switch h {
        case 5..<12: return "Good morning."
        case 12..<17: return "Good afternoon."
        case 17..<22: return "Good evening."
        default: return "Quiet hours."
        }
    }

    private func countdownString(to date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSince(currentTime)))
        let m = s / 60, sec = s % 60
        if m >= 60 { return String(format: "%d:%02d", m / 60, m % 60) }
        return String(format: "%02d:%02d", m, sec)
    }

    private func remainingString(item: any CalendarItemProtocol) -> String {
        let s = max(0, Int(item.endDate.timeIntervalSince(currentTime)))
        let m = s / 60
        if m >= 60 { return "\(m / 60)h \(m % 60)m left" }
        return "\(m)m left"
    }

    private func activeProgress(item: any CalendarItemProtocol) -> Double {
        let total = item.endDate.timeIntervalSince(item.startDate)
        guard total > 0 else { return 0 }
        let elapsed = currentTime.timeIntervalSince(item.startDate)
        return max(0, min(1, elapsed / total))
    }

    private func relativeString(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: currentTime)
    }

    private func timeRange(_ item: any CalendarItemProtocol) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return "\(f.string(from: item.startDate)) – \(f.string(from: item.endDate))"
    }

    private func location(of item: any CalendarItemProtocol) -> String? {
        (item as? SystemEventItem)?.location
    }

    private func dueLabel(_ item: any CalendarItemProtocol) -> String? {
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return "Due " + f.string(from: item.startDate)
    }
}
