import SwiftUI

/// Month view — Apple Calendar convention with Things 3 restraint.
///
/// Each cell shows:
///   - Day number (top-left), accent color on today, dim on out-of-month days
///   - Up to 3 event lines: 4pt colored dot + title
///   - "+N more" footer if truncated
///
/// Grid is a subtle hairline with generous cell padding, weekend columns
/// get a whisper of tint to add rhythm without noise.
struct CalendarMonthView: View {
    @ObservedObject var dataManager: CalendarDataManager

    private let weekdayLetters = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private let maxEventLines = 3

    var body: some View {
        VStack(spacing: 0) {
            weekdayHeader
            Rectangle().fill(FlowTokens.border).frame(height: FlowTokens.hairline)

            GeometryReader { geo in
                let rows = monthWeeks.count
                let rowHeight = geo.size.height / CGFloat(rows)
                VStack(spacing: 0) {
                    ForEach(Array(monthWeeks.enumerated()), id: \.offset) { weekIdx, week in
                        HStack(spacing: 0) {
                            ForEach(Array(week.enumerated()), id: \.offset) { dayIdx, day in
                                dayCell(day, height: rowHeight)
                                    .overlay(alignment: .trailing) {
                                        if dayIdx < 6 {
                                            Rectangle()
                                                .fill(FlowTokens.border)
                                                .frame(width: FlowTokens.hairline)
                                        }
                                    }
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if weekIdx < rows - 1 {
                                Rectangle()
                                    .fill(FlowTokens.border)
                                    .frame(height: FlowTokens.hairline)
                            }
                        }
                    }
                }
            }
        }
        .background(FlowTokens.bg0)
    }

    // MARK: - Weekday header

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(weekdayLetters.enumerated()), id: \.offset) { idx, label in
                Text(label.uppercased())
                    .flowFont(.sectionLabel)
                    .foregroundColor(isWeekend(idx) ? FlowTokens.textMuted : FlowTokens.textTertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, FlowTokens.spacingMD)
        .background(FlowTokens.bg0)
    }

    private func isWeekend(_ weekdayIndex: Int) -> Bool {
        weekdayIndex == 0 || weekdayIndex == 6
    }

    // MARK: - Day cell

    private func dayCell(_ day: Date, height: CGFloat) -> some View {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: dataManager.selectedDate) && !isToday
        let isCurrentMonth = cal.component(.month, from: day) == cal.component(.month, from: currentMonthFirstDay)
        let weekday = cal.component(.weekday, from: day) // 1=Sun … 7=Sat
        let isWknd = weekday == 1 || weekday == 7
        let dayNumber = cal.component(.day, from: day)
        let dayItems = sortedItemsForDay(day)
        let maxVisible = linesFit(for: height)

        return Button {
            withAnimation(.flowQuick) {
                dataManager.selectedDate = day
                dataManager.viewMode = .week
            }
        } label: {
            ZStack(alignment: .topLeading) {
                // Cell fill: weekend whisper / selected tint
                Rectangle()
                    .fill(cellFill(isCurrentMonth: isCurrentMonth,
                                   isWeekend: isWknd,
                                   isSelected: isSelected))

                VStack(alignment: .leading, spacing: FlowTokens.spacingXS) {
                    // Day number row
                    HStack(alignment: .center, spacing: 0) {
                        dayNumberLabel(dayNumber,
                                       isToday: isToday,
                                       isCurrentMonth: isCurrentMonth)
                        Spacer(minLength: 0)
                    }

                    // Event lines
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(dayItems.prefix(maxVisible).enumerated()), id: \.offset) { _, item in
                            eventLine(item, isCurrentMonth: isCurrentMonth)
                        }
                        if dayItems.count > maxVisible {
                            Text("+\(dayItems.count - maxVisible) more")
                                .flowFont(.micro)
                                .foregroundColor(FlowTokens.textMuted)
                                .padding(.leading, 8)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, FlowTokens.spacingSM)
                .padding(.top, FlowTokens.spacingSM)
                .padding(.bottom, FlowTokens.spacingXS)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func cellFill(isCurrentMonth: Bool, isWeekend: Bool, isSelected: Bool) -> Color {
        if isSelected { return FlowTokens.bg2.opacity(0.7) }
        if !isCurrentMonth { return FlowTokens.bg0.opacity(0.4) }
        if isWeekend { return Color.white.opacity(0.015) }
        return FlowTokens.bg0
    }

    // MARK: - Day number

    private func dayNumberLabel(_ number: Int, isToday: Bool, isCurrentMonth: Bool) -> some View {
        let color: Color = {
            if isToday { return FlowTokens.accent }
            if !isCurrentMonth { return FlowTokens.textDisabled }
            return FlowTokens.textPrimary
        }()
        let weight: Font.Weight = isToday ? .bold : .medium
        return Text("\(number)")
            .font(.system(size: 13, weight: weight, design: .default))
            .tracking(-0.1)
            .foregroundColor(color)
    }

    // MARK: - Event line

    private func eventLine(_ item: any CalendarItemProtocol, isCurrentMonth: Bool) -> some View {
        let tint = item.displayColor
        let textColor: Color = isCurrentMonth
            ? FlowTokens.textSecondary
            : FlowTokens.textDisabled
        return HStack(spacing: 5) {
            Circle()
                .fill(tint.opacity(isCurrentMonth ? 1.0 : 0.5))
                .frame(width: 5, height: 5)
            Text(item.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Layout helpers

    /// Roughly how many event lines fit in the cell after the day number.
    private func linesFit(for height: CGFloat) -> Int {
        // Day number + padding ≈ 30, each line ≈ 14
        let available = max(0, height - 34)
        return max(0, min(maxEventLines, Int(available / 14)))
    }

    // MARK: - Grid

    private var currentMonthFirstDay: Date {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: dataManager.selectedDate))!
    }

    private var monthWeeks: [[Date]] {
        let cal = Calendar.current
        let firstOfMonth = currentMonthFirstDay
        let weekdayOfFirst = cal.component(.weekday, from: firstOfMonth)
        let gridStart = cal.date(byAdding: .day, value: -(weekdayOfFirst - 1), to: firstOfMonth)!
        // Use 6 rows only if needed (42 cells max).
        let firstOfNextMonth = cal.date(byAdding: .month, value: 1, to: firstOfMonth)!
        let daysInMonth = cal.dateComponents([.day], from: firstOfMonth, to: firstOfNextMonth).day ?? 30
        let needed = weekdayOfFirst - 1 + daysInMonth
        let rowCount = needed > 35 ? 6 : 5
        let allDays = (0..<rowCount * 7).map { cal.date(byAdding: .day, value: $0, to: gridStart)! }
        return stride(from: 0, to: rowCount * 7, by: 7).map { start in
            Array(allDays[start..<start + 7])
        }
    }

    // MARK: - Data

    private func sortedItemsForDay(_ day: Date) -> [any CalendarItemProtocol] {
        let cal = Calendar.current
        return dataManager.items
            .filter { cal.isDate($0.startDate, inSameDayAs: day) }
            .sorted { lhs, rhs in
                // All-day first, then by start time
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                return lhs.startDate < rhs.startDate
            }
    }
}
