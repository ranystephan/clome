import SwiftUI

// MARK: - Calendar Month View

struct CalendarMonthView: View {
    @ObservedObject var dataManager: CalendarDataManager

    private let weekdayLetters = ["S", "M", "T", "W", "T", "F", "S"]
    private let cellHeight: CGFloat = 44

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Weekday headers
            weekdayHeader

            // Week rows
            ForEach(Array(monthWeeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        monthDayCell(day)
                    }
                }
            }

            Spacer()
        }
        .background(FlowTokens.bg0)
    }

    // MARK: - Weekday Header

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(weekdayLetters.enumerated()), id: \.offset) { _, letter in
                Text(letter)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(FlowTokens.textHint)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, FlowTokens.spacingSM)
    }

    // MARK: - Day Cell

    private func monthDayCell(_ day: Date) -> some View {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(day)
        let isCurrentMonth = cal.component(.month, from: day) == cal.component(.month, from: currentMonthFirstDay)
        let dayNumber = cal.component(.day, from: day)
        let dayItems = itemsForDay(day)

        return Button {
            withAnimation(.flowQuick) {
                dataManager.selectedDate = day
                dataManager.viewMode = .day
            }
        } label: {
            VStack(spacing: FlowTokens.spacingXS) {
                // Day number
                ZStack {
                    if isToday {
                        Circle()
                            .fill(FlowTokens.accent)
                            .frame(width: 18, height: 18)
                    }
                    Text("\(dayNumber)")
                        .font(.system(size: 10, weight: isToday ? .bold : .regular, design: .monospaced))
                        .foregroundColor(dayNumberColor(isToday: isToday, isCurrentMonth: isCurrentMonth))
                }

                // Event dots or +N indicator
                if !dayItems.isEmpty {
                    eventDotsView(dayItems)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: cellHeight)
            .background(
                RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                    .fill(isToday ? FlowTokens.accentSubtle : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Event Dots

    @ViewBuilder
    private func eventDotsView(_ items: [any CalendarItemProtocol]) -> some View {
        let uniqueKinds = uniqueItemKinds(items)
        let dotCount = min(uniqueKinds.count, 3)
        let overflow = items.count > 3

        HStack(spacing: 2) {
            ForEach(0..<dotCount, id: \.self) { index in
                Circle()
                    .fill(dotColor(for: uniqueKinds[index]))
                    .frame(width: 4, height: 4)
            }
            if overflow {
                Text("+\(items.count - 3)")
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundColor(FlowTokens.textHint)
            }
        }
    }

    // MARK: - Month Grid Computation

    /// First day of the month derived from selectedDate.
    private var currentMonthFirstDay: Date {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: dataManager.selectedDate))!
    }

    /// All visible days in the month grid (42 days = 6 weeks), split into rows of 7.
    private var monthWeeks: [[Date]] {
        let cal = Calendar.current
        let firstOfMonth = currentMonthFirstDay

        // Which weekday does the 1st fall on? (1 = Sunday .. 7 = Saturday)
        let weekdayOfFirst = cal.component(.weekday, from: firstOfMonth)

        // Back up to the previous Sunday (or the 1st if it IS Sunday)
        let gridStart = cal.date(byAdding: .day, value: -(weekdayOfFirst - 1), to: firstOfMonth)!

        // Generate 42 days (6 weeks)
        let allDays = (0..<42).map { cal.date(byAdding: .day, value: $0, to: gridStart)! }

        // Split into rows of 7
        return stride(from: 0, to: 42, by: 7).map { start in
            Array(allDays[start..<min(start + 7, allDays.count)])
        }
    }

    // MARK: - Data Filtering

    private func itemsForDay(_ day: Date) -> [any CalendarItemProtocol] {
        dataManager.items.filter { Calendar.current.isDate($0.startDate, inSameDayAs: day) }
    }

    // MARK: - Helpers

    private func dayNumberColor(isToday: Bool, isCurrentMonth: Bool) -> Color {
        if isToday { return .white }
        if isCurrentMonth { return FlowTokens.textTertiary }
        return FlowTokens.textDisabled
    }

    /// Returns unique item kinds in stable order, up to the first 3.
    private func uniqueItemKinds(_ items: [any CalendarItemProtocol]) -> [CalendarItemKind] {
        var seen = Set<String>()
        var result: [CalendarItemKind] = []
        for item in items {
            let key = item.kind.rawValue
            if !seen.contains(key) {
                seen.insert(key)
                result.append(item.kind)
            }
            if result.count >= 3 { break }
        }
        return result
    }

    private func dotColor(for kind: CalendarItemKind) -> Color {
        switch kind {
        case .systemEvent:
            return FlowTokens.accent
        case .todo:
            return FlowTokens.calendarTodo
        case .deadline:
            return FlowTokens.calendarDeadline
        case .reminder:
            return FlowTokens.calendarReminder
        }
    }
}
