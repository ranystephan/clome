import SwiftUI
import ClomeModels

// MARK: - Creation Type

enum CalendarCreationType: String, CaseIterable {
    case event = "Event"
    case todo = "Todo"
    case deadline = "Deadline"
}

// MARK: - Calendar Creation Popover

/// Popover for quickly creating events, todos, or deadlines from the calendar timeline.
struct CalendarCreationPopover: View {
    let initialDate: Date
    let onDismiss: () -> Void

    @ObservedObject private var dataManager = CalendarDataManager.shared
    @ObservedObject private var syncService = FlowSyncService.shared

    @State private var creationType: CalendarCreationType = .event
    @State private var title = ""
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var priority: TodoPriority = .medium
    @State private var duration: TimeInterval = 1800 // 30 min
    @State private var category: HabitCategory = .general
    @State private var prepHours: Double = 0
    @FocusState private var titleFocused: Bool

    // MARK: - Init

    init(initialDate: Date, onDismiss: @escaping () -> Void) {
        self.initialDate = initialDate
        self.onDismiss = onDismiss
        _startTime = State(initialValue: initialDate)
        _endTime = State(initialValue: initialDate.addingTimeInterval(3600))
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: FlowTokens.spacingMD) {
            // Type picker
            Picker("", selection: $creationType) {
                ForEach(CalendarCreationType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)

            // Title field
            TextField("Title...", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(FlowTokens.spacingMD)
                .background(
                    RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                        .fill(FlowTokens.bg2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                        .stroke(titleFocused ? FlowTokens.borderFocused : FlowTokens.border, lineWidth: 0.5)
                )
                .focused($titleFocused)

            // Type-specific fields
            switch creationType {
            case .event:
                eventFields
            case .todo:
                todoFields
            case .deadline:
                deadlineFields
            }

            // Action buttons
            HStack {
                Button("Cancel") { onDismiss() }
                    .font(.system(size: 11))
                    .foregroundColor(FlowTokens.textTertiary)
                    .buttonStyle(.plain)

                Spacer()

                Button("Create") { createItem() }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(title.isEmpty ? FlowTokens.textDisabled : FlowTokens.accent)
                    .buttonStyle(.plain)
                    .disabled(title.isEmpty)
            }
        }
        .padding(FlowTokens.spacingXL)
        .frame(width: 260)
        .onAppear { titleFocused = true }
    }

    // MARK: - Event Fields

    private var eventFields: some View {
        VStack(spacing: FlowTokens.spacingSM) {
            HStack {
                Text("Start")
                    .font(.system(size: 10))
                    .foregroundColor(FlowTokens.textTertiary)
                    .frame(width: 36, alignment: .leading)
                DatePicker("", selection: $startTime, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .controlSize(.small)
            }
            HStack {
                Text("End")
                    .font(.system(size: 10))
                    .foregroundColor(FlowTokens.textTertiary)
                    .frame(width: 36, alignment: .leading)
                DatePicker("", selection: $endTime, in: startTime..., displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Todo Fields

    private var todoFields: some View {
        VStack(spacing: FlowTokens.spacingMD) {
            // Priority pills
            VStack(alignment: .leading, spacing: FlowTokens.spacingSM) {
                Text("PRIORITY")
                    .flowSectionHeader()
                HStack(spacing: FlowTokens.spacingSM) {
                    priorityPill("H", .high, FlowTokens.priorityHigh)
                    priorityPill("M", .medium, FlowTokens.priorityMedium)
                    priorityPill("L", .low, FlowTokens.priorityLow)
                }
            }

            // Duration pills
            VStack(alignment: .leading, spacing: FlowTokens.spacingSM) {
                Text("DURATION")
                    .flowSectionHeader()
                HStack(spacing: FlowTokens.spacingSM) {
                    durationPill("15m", 900)
                    durationPill("30m", 1800)
                    durationPill("1h", 3600)
                    durationPill("2h", 7200)
                }
            }

            // Start time
            HStack {
                Text("Start")
                    .font(.system(size: 10))
                    .foregroundColor(FlowTokens.textTertiary)
                    .frame(width: 36, alignment: .leading)
                DatePicker("", selection: $startTime, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Deadline Fields

    private var deadlineFields: some View {
        VStack(spacing: FlowTokens.spacingMD) {
            // Due date + time
            HStack {
                Text("Due")
                    .font(.system(size: 10))
                    .foregroundColor(FlowTokens.textTertiary)
                    .frame(width: 36, alignment: .leading)
                DatePicker("", selection: $startTime, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .controlSize(.small)
            }

            // Category pills
            VStack(alignment: .leading, spacing: FlowTokens.spacingSM) {
                Text("CATEGORY")
                    .flowSectionHeader()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: FlowTokens.spacingSM) {
                        ForEach(commonCategories, id: \.self) { cat in
                            categoryPill(cat)
                        }
                    }
                }
            }

            // Prep hours stepper
            HStack {
                Text("Prep hours")
                    .font(.system(size: 10))
                    .foregroundColor(FlowTokens.textTertiary)
                Spacer()
                HStack(spacing: FlowTokens.spacingSM) {
                    Button {
                        if prepHours > 0 { prepHours -= 1 }
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 12))
                            .foregroundColor(prepHours > 0 ? FlowTokens.textSecondary : FlowTokens.textDisabled)
                    }
                    .buttonStyle(.plain)
                    .disabled(prepHours <= 0)

                    Text("\(Int(prepHours))h")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(FlowTokens.textPrimary)
                        .frame(width: 28, alignment: .center)

                    Button {
                        if prepHours < 20 { prepHours += 1 }
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 12))
                            .foregroundColor(prepHours < 20 ? FlowTokens.textSecondary : FlowTokens.textDisabled)
                    }
                    .buttonStyle(.plain)
                    .disabled(prepHours >= 20)
                }
            }
        }
    }

    // MARK: - Pill Helpers

    private func priorityPill(_ label: String, _ value: TodoPriority, _ color: Color) -> some View {
        Button {
            withAnimation(.flowQuick) { priority = value }
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(priority == value ? color : FlowTokens.textTertiary)
                .frame(width: 28, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                        .fill(priority == value ? color.opacity(0.15) : FlowTokens.bg2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                        .stroke(priority == value ? color.opacity(0.4) : FlowTokens.border, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    private func durationPill(_ label: String, _ seconds: TimeInterval) -> some View {
        Button {
            withAnimation(.flowQuick) {
                duration = seconds
                endTime = startTime.addingTimeInterval(seconds)
            }
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(duration == seconds ? FlowTokens.accent : FlowTokens.textTertiary)
                .padding(.horizontal, FlowTokens.spacingMD)
                .padding(.vertical, FlowTokens.spacingSM)
                .background(
                    RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                        .fill(duration == seconds ? FlowTokens.accentSubtle : FlowTokens.bg2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                        .stroke(duration == seconds ? FlowTokens.accent.opacity(0.3) : FlowTokens.border, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    private func categoryPill(_ cat: HabitCategory) -> some View {
        Button {
            withAnimation(.flowQuick) { category = cat }
        } label: {
            Text(cat.displayName)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(category == cat ? FlowTokens.accent : FlowTokens.textTertiary)
                .padding(.horizontal, FlowTokens.spacingMD)
                .padding(.vertical, FlowTokens.spacingSM)
                .background(
                    RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                        .fill(category == cat ? FlowTokens.accentSubtle : FlowTokens.bg2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                        .stroke(category == cat ? FlowTokens.accent.opacity(0.3) : FlowTokens.border, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Common Categories

    private var commonCategories: [HabitCategory] {
        [.general, .work, .study, .research, .lecture, .creative]
    }

    // MARK: - Create Action

    private func createItem() {
        guard !title.isEmpty else { return }

        switch creationType {
        case .event:
            dataManager.createSystemEvent(title: title, start: startTime, end: endTime)

        case .todo:
            let todo = TodoItem(
                title: title,
                priority: priority,
                scheduledDate: startTime,
                scheduledEndDate: startTime.addingTimeInterval(duration)
            )
            syncService.addTodo(todo)

        case .deadline:
            let deadline = Deadline(
                title: title,
                dueDate: startTime,
                category: category,
                estimatedPrepHours: prepHours > 0 ? prepHours : nil
            )
            syncService.addDeadline(deadline)
        }

        dataManager.refresh()
        onDismiss()
    }
}
