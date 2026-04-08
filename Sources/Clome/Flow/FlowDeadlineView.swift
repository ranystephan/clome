import SwiftUI
import ClomeModels

/// Redesigned deadline view with progress bars, timeframe grouping,
/// inline add form, and Firestore sync via FlowSyncService.
struct FlowDeadlineView: View {
    let projectContext: String?

    @ObservedObject private var syncService = FlowSyncService.shared
    @State private var showAddForm = false
    @State private var expandedDeadlineID: UUID?

    // Add form state
    @State private var newTitle = ""
    @State private var newDueDate = Date().addingTimeInterval(86400 * 3)
    @State private var newCategory: HabitCategory = .general
    @State private var newPrepHours: Double = 0
    @FocusState private var isAddFocused: Bool

    private var activeDeadlines: [Deadline] {
        syncService.deadlines.filter { !$0.isCompleted }.sorted { $0.dueDate < $1.dueDate }
    }

    // MARK: - Timeframe Groups

    private enum TimeGroup: String, CaseIterable {
        case overdue = "OVERDUE"
        case today = "TODAY"
        case thisWeek = "THIS WEEK"
        case later = "LATER"
    }

    private func deadlinesFor(_ group: TimeGroup) -> [Deadline] {
        let cal = Calendar.current
        let now = Date()
        let endOfToday = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: now)!)
        let endOfWeek = cal.startOfDay(for: cal.date(byAdding: .day, value: 7, to: now)!)

        return activeDeadlines.filter { d in
            switch group {
            case .overdue: return d.dueDate < now
            case .today: return d.dueDate >= now && d.dueDate < endOfToday
            case .thisWeek: return d.dueDate >= endOfToday && d.dueDate < endOfWeek
            case .later: return d.dueDate >= endOfWeek
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(FlowTokens.border).frame(height: FlowTokens.hairline)

            if showAddForm {
                addForm
                Rectangle().fill(FlowTokens.border).frame(height: FlowTokens.hairline)
            }

            if activeDeadlines.isEmpty && !showAddForm {
                emptyState
            } else {
                deadlinesList
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Deadlines")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(FlowTokens.textSecondary)
            Spacer()
            Text("\(activeDeadlines.count) active")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(FlowTokens.textHint)

            Button {
                withAnimation(.flowSpring) { showAddForm.toggle() }
            } label: {
                Image(systemName: showAddForm ? "xmark" : "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(FlowTokens.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .flowHeaderBar()
    }

    // MARK: - Add Form

    private var addForm: some View {
        VStack(spacing: FlowTokens.spacingMD) {
            TextField("Deadline title…", text: $newTitle)
                .textFieldStyle(.plain)
                .flowFont(.body)
                .foregroundColor(FlowTokens.textPrimary)
                .focused($isAddFocused)
                .onSubmit { saveDeadline() }
                .flowInput(isFocused: isAddFocused)

            HStack(spacing: FlowTokens.spacingMD) {
                // Date picker
                DatePicker("", selection: $newDueDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .scaleEffect(0.85, anchor: .leading)

                Spacer()

                // Prep hours
                if newPrepHours > 0 {
                    Text("~\(Int(newPrepHours))h")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(FlowTokens.textTertiary)
                }
                Stepper("", value: $newPrepHours, in: 0...100, step: 1)
                    .labelsHidden()
                    .scaleEffect(0.8)
            }

            // Category pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: FlowTokens.spacingSM) {
                    ForEach([HabitCategory.general, .work, .study, .research, .lecture, .creative], id: \.self) { cat in
                        let isActive = newCategory == cat
                        Button {
                            newCategory = cat
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: cat.icon)
                                    .font(.system(size: 9, weight: .semibold))
                                Text(cat.displayName)
                                    .flowFont(.micro)
                            }
                            .foregroundColor(isActive ? FlowTokens.textPrimary : FlowTokens.textTertiary)
                            .padding(.horizontal, FlowTokens.spacingMD - 2)
                            .padding(.vertical, 4)
                            .flowControl(isActive: isActive, radius: FlowTokens.radiusControl)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Save / Cancel
            HStack(spacing: FlowTokens.spacingMD) {
                Spacer()
                Button("Cancel") {
                    withAnimation(.flowSpring) { resetAddForm() }
                }
                .font(.system(size: 11))
                .foregroundColor(FlowTokens.textTertiary)
                .buttonStyle(.plain)

                Button("Save") { saveDeadline() }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(FlowTokens.accent)
                    .buttonStyle(.plain)
                    .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(FlowTokens.spacingLG)
        .background(FlowTokens.bg1)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .onAppear { isAddFocused = true }
    }

    // MARK: - Deadlines List

    private var deadlinesList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(TimeGroup.allCases, id: \.self) { group in
                    let items = deadlinesFor(group)
                    if !items.isEmpty {
                        timeGroupSection(group, items: items)
                    }
                }
            }
            .padding(.vertical, FlowTokens.spacingSM)
        }
    }

    private func timeGroupSection(_ group: TimeGroup, items: [Deadline]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(group.rawValue)
                    .flowSectionHeader()
                Spacer()
                Text("\(items.count)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(FlowTokens.textMuted)
            }
            .padding(.horizontal, 10)
            .padding(.top, FlowTokens.spacingLG)
            .padding(.bottom, FlowTokens.spacingMD)

            ForEach(items) { deadline in
                deadlineCard(deadline)
                    .padding(.horizontal, FlowTokens.spacingMD)
                    .padding(.bottom, FlowTokens.spacingMD)
            }
        }
    }

    // MARK: - Deadline Card

    private func deadlineCard(_ deadline: Deadline) -> some View {
        let isExpanded = expandedDeadlineID == deadline.id
        let progress = deadlineProgress(deadline)
        let color = urgencyColor(deadline)

        return VStack(alignment: .leading, spacing: FlowTokens.spacingMD) {
            // Title row
            HStack(spacing: FlowTokens.spacingMD) {
                Image(systemName: deadline.category.icon)
                    .font(.system(size: 10))
                    .foregroundColor(color.opacity(0.7))

                Text(deadline.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(FlowTokens.textPrimary)
                    .lineLimit(isExpanded ? 3 : 1)

                Spacer()

                if let hours = deadline.estimatedPrepHours, hours > 0 {
                    Text("~\(Int(hours))h")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(FlowTokens.textMuted)
                        .padding(.horizontal, FlowTokens.spacingSM)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(FlowTokens.bg3)
                        )
                }
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(FlowTokens.bg3)
                        .frame(height: 4)

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color)
                        .frame(width: geo.size.width * min(progress, 1.0), height: 4)
                        .opacity(deadline.isPastDue ? pulsingOpacity : 1.0)
                }
            }
            .frame(height: 4)

            // Countdown row
            HStack {
                Text(countdownLabel(deadline))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(color)

                Spacer()

                Text(deadline.category.displayName)
                    .font(.system(size: 9))
                    .foregroundColor(FlowTokens.textMuted)
            }

            // Expanded content
            if isExpanded {
                Rectangle().fill(FlowTokens.border).frame(height: FlowTokens.hairline)

                if !deadline.linkedEventTitles.isEmpty {
                    VStack(alignment: .leading, spacing: FlowTokens.spacingXS) {
                        Text("LINKED EVENTS")
                            .flowSectionHeader()
                        ForEach(deadline.linkedEventTitles, id: \.self) { title in
                            HStack(spacing: FlowTokens.spacingSM) {
                                Image(systemName: "calendar")
                                    .font(.system(size: 8))
                                    .foregroundColor(FlowTokens.textMuted)
                                Text(title)
                                    .font(.system(size: 10))
                                    .foregroundColor(FlowTokens.textTertiary)
                            }
                        }
                    }
                }

                HStack(spacing: FlowTokens.spacingLG) {
                    Spacer()

                    Button {
                        withAnimation(.flowSpring) {
                            syncService.toggleDeadlineComplete(id: deadline.id)
                        }
                    } label: {
                        HStack(spacing: FlowTokens.spacingSM) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 10))
                            Text("Complete")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(FlowTokens.success)
                    }
                    .buttonStyle(.plain)

                    Button {
                        withAnimation(.flowSpring) {
                            syncService.deleteDeadline(id: deadline.id)
                        }
                    } label: {
                        HStack(spacing: FlowTokens.spacingSM) {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                            Text("Delete")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(FlowTokens.error)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(FlowTokens.spacingMD)
        .flowCard(isSelected: isExpanded)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.flowSpring) {
                expandedDeadlineID = isExpanded ? nil : deadline.id
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: FlowTokens.spacingMD) {
            Spacer()
            Image(systemName: "flag")
                .font(.system(size: 28))
                .foregroundColor(FlowTokens.textDisabled)
            Text("No deadlines")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(FlowTokens.textTertiary)
            Text("Tap + to add a deadline")
                .font(.system(size: 11))
                .foregroundColor(FlowTokens.textMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    @State private var pulsingOpacity: Double = 1.0

    private func deadlineProgress(_ deadline: Deadline) -> Double {
        let total = deadline.dueDate.timeIntervalSince(deadline.createdDate)
        guard total > 0 else { return 1.0 }
        let elapsed = Date().timeIntervalSince(deadline.createdDate)
        return elapsed / total
    }

    private func urgencyColor(_ deadline: Deadline) -> Color {
        let hours = deadline.hoursUntilDue
        if hours < 0 { return FlowTokens.urgencyOverdue }
        if hours < 24 { return FlowTokens.urgencyCritical }
        if hours < 72 { return FlowTokens.urgencyWarning }
        return FlowTokens.urgencyNormal
    }

    private func countdownLabel(_ deadline: Deadline) -> String {
        let hours = deadline.hoursUntilDue
        if hours < 0 {
            let overdue = abs(hours)
            if overdue < 24 { return "\(Int(overdue))h overdue" }
            return "\(Int(overdue / 24))d \(Int(overdue.truncatingRemainder(dividingBy: 24)))h overdue"
        }
        if hours < 1 { return "\(Int(hours * 60))m left" }
        if hours < 24 { return "\(Int(hours))h \(Int((hours.truncatingRemainder(dividingBy: 1)) * 60))m left" }
        if hours < 168 { return "\(Int(hours / 24))d \(Int(hours.truncatingRemainder(dividingBy: 24)))h left" }
        return "\(Int(hours / 168))w \(Int((hours.truncatingRemainder(dividingBy: 168)) / 24))d left"
    }

    private func saveDeadline() {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let deadline = Deadline(
            title: trimmed,
            dueDate: newDueDate,
            category: newCategory,
            estimatedPrepHours: newPrepHours > 0 ? newPrepHours : nil,
            projectTag: projectContext
        )
        withAnimation(.flowSpring) {
            syncService.addDeadline(deadline)
            resetAddForm()
        }
    }

    private func resetAddForm() {
        showAddForm = false
        newTitle = ""
        newDueDate = Date().addingTimeInterval(86400 * 3)
        newCategory = .general
        newPrepHours = 0
    }
}
