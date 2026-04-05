import SwiftUI

// MARK: - Calendar Header View

/// Unified header for all calendar view modes with navigation,
/// view mode picker, and item count display.
struct CalendarHeaderView: View {
    @ObservedObject var dataManager: CalendarDataManager
    @State private var showDatePicker = false

    // MARK: - Body

    var body: some View {
        HStack(spacing: FlowTokens.spacingSM) {
            // Left: View mode segmented control
            Picker("", selection: $dataManager.viewMode) {
                Image(systemName: "calendar.day.timeline.left")
                    .tag(CalendarViewMode.day)
                Image(systemName: "calendar.day.timeline.right")
                    .tag(CalendarViewMode.week)
                Image(systemName: "calendar")
                    .tag(CalendarViewMode.month)
            }
            .pickerStyle(.segmented)
            .frame(width: 100)

            Spacer()

            // Center: Date navigation
            Button {
                withAnimation(.flowQuick) { navigateBack() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(FlowTokens.textHint)
            }
            .buttonStyle(.plain)

            Button {
                showDatePicker.toggle()
            } label: {
                Text(dateLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(FlowTokens.textSecondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDatePicker, arrowEdge: .bottom) {
                VStack {
                    DatePicker("", selection: $dataManager.selectedDate, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .onChange(of: dataManager.selectedDate) { _, _ in
                            showDatePicker = false
                        }
                }
                .padding(FlowTokens.spacingMD)
                .frame(width: 260)
            }

            Button {
                withAnimation(.flowQuick) { navigateForward() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(FlowTokens.textHint)
            }
            .buttonStyle(.plain)

            // "Today" pill (only when not viewing current period)
            if !isViewingCurrentPeriod {
                Button {
                    withAnimation(.flowQuick) {
                        dataManager.selectedDate = Date()
                    }
                } label: {
                    Text("Today")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(FlowTokens.accent)
                        .padding(.horizontal, FlowTokens.spacingSM)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(FlowTokens.accentSubtle)
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Right: item count
            Text("\(dataManager.items.count) items")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(FlowTokens.textHint)
        }
        .flowHeaderBar()
    }

    // MARK: - Date Label

    private var dateLabel: String {
        let cal = Calendar.current
        switch dataManager.viewMode {
        case .day:
            return dayLabel

        case .week:
            // Compute the week start (Sunday) and end (Saturday)
            var components = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: dataManager.selectedDate)
            components.weekday = 1
            let weekStart = cal.date(from: components) ?? dataManager.selectedDate
            let weekEnd = cal.date(byAdding: .day, value: 6, to: weekStart) ?? dataManager.selectedDate

            let startFmt = DateFormatter()
            let endFmt = DateFormatter()

            // If they share the same month, abbreviate
            if cal.component(.month, from: weekStart) == cal.component(.month, from: weekEnd) {
                startFmt.dateFormat = "MMM d"
                endFmt.dateFormat = "d, yyyy"
            } else if cal.component(.year, from: weekStart) == cal.component(.year, from: weekEnd) {
                startFmt.dateFormat = "MMM d"
                endFmt.dateFormat = "MMM d, yyyy"
            } else {
                startFmt.dateFormat = "MMM d, yyyy"
                endFmt.dateFormat = "MMM d, yyyy"
            }
            return "\(startFmt.string(from: weekStart)) \u{2013} \(endFmt.string(from: weekEnd))"

        case .month:
            let fmt = DateFormatter()
            fmt.dateFormat = "MMMM yyyy"
            return fmt.string(from: dataManager.selectedDate)
        }
    }

    private var dayLabel: String {
        let cal = Calendar.current
        let date = dataManager.selectedDate
        let datePart = formatShortDate(date)

        if cal.isDateInToday(date) {
            return "Today, \(datePart)"
        }
        if cal.isDateInYesterday(date) {
            return "Yesterday, \(datePart)"
        }
        if cal.isDateInTomorrow(date) {
            return "Tomorrow, \(datePart)"
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMM d"
        return fmt.string(from: date)
    }

    private func formatShortDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return fmt.string(from: date)
    }

    // MARK: - Navigation

    private func navigateBack() {
        let cal = Calendar.current
        switch dataManager.viewMode {
        case .day:
            dataManager.selectedDate = cal.date(byAdding: .day, value: -1, to: dataManager.selectedDate)
                ?? dataManager.selectedDate
        case .week:
            dataManager.selectedDate = cal.date(byAdding: .day, value: -7, to: dataManager.selectedDate)
                ?? dataManager.selectedDate
        case .month:
            dataManager.selectedDate = cal.date(byAdding: .month, value: -1, to: dataManager.selectedDate)
                ?? dataManager.selectedDate
        }
    }

    private func navigateForward() {
        let cal = Calendar.current
        switch dataManager.viewMode {
        case .day:
            dataManager.selectedDate = cal.date(byAdding: .day, value: 1, to: dataManager.selectedDate)
                ?? dataManager.selectedDate
        case .week:
            dataManager.selectedDate = cal.date(byAdding: .day, value: 7, to: dataManager.selectedDate)
                ?? dataManager.selectedDate
        case .month:
            dataManager.selectedDate = cal.date(byAdding: .month, value: 1, to: dataManager.selectedDate)
                ?? dataManager.selectedDate
        }
    }

    // MARK: - Current Period Check

    private var isViewingCurrentPeriod: Bool {
        let cal = Calendar.current
        let now = Date()

        switch dataManager.viewMode {
        case .day:
            return cal.isDateInToday(dataManager.selectedDate)

        case .week:
            // Check if today falls within the same week as selectedDate
            let selectedWeek = cal.component(.weekOfYear, from: dataManager.selectedDate)
            let selectedYear = cal.component(.yearForWeekOfYear, from: dataManager.selectedDate)
            let currentWeek = cal.component(.weekOfYear, from: now)
            let currentYear = cal.component(.yearForWeekOfYear, from: now)
            return selectedWeek == currentWeek && selectedYear == currentYear

        case .month:
            // Check if today falls within the same month as selectedDate
            return cal.isDate(dataManager.selectedDate, equalTo: now, toGranularity: .month)
        }
    }
}
