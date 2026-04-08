import SwiftUI

// MARK: - Calendar Month View
//
// Editorial month grid inspired by the iOS EnhancedMonthDayCell:
//   - 6×7 grid filling the canvas
//   - Each cell shows a day number with a circle for today / selected
//   - A 2pt left fill bar visualises busyness (proportional to scheduled hours)
//   - Up to four category dots sit under the day number
//   - Tapping a cell jumps to the day view

struct CalendarMonthView: View {
    @ObservedObject var dataManager: CalendarDataManager

    private let weekdayLetters = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
    private let maxDots = 4

    var body: some View {
        VStack(spacing: 0) {
            weekdayHeader
            Rectangle().fill(FlowTokens.border).frame(height: FlowTokens.hairline)

            GeometryReader { geo in
                let rowHeight = geo.size.height / CGFloat(monthWeeks.count)
                VStack(spacing: 0) {
                    ForEach(Array(monthWeeks.enumerated()), id: \.offset) { weekIdx, week in
                        HStack(spacing: 0) {
                            ForEach(Array(week.enumerated()), id: \.offset) { dayIdx, day in
                                monthDayCell(day, height: rowHeight)
                                    .overlay(alignment: .trailing) {
                                        if dayIdx < 6 {
                                            Rectangle().fill(FlowTokens.border).frame(width: FlowTokens.hairline)
                                        }
                                    }
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if weekIdx < monthWeeks.count - 1 {
                                Rectangle().fill(FlowTokens.border).frame(height: FlowTokens.hairline)
                            }
                        }
                    }
                }
            }
        }
        .background(FlowTokens.bg0)
    }

    // MARK: - Weekday Header

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(weekdayLetters.enumerated()), id: \.offset) { _, letter in
                Text(letter)
                    .flowFont(.sectionLabel)
                    .foregroundColor(FlowTokens.textTertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, FlowTokens.spacingMD)
    }

    // MARK: - Day Cell

    private func monthDayCell(_ day: Date, height: CGFloat) -> some View {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: dataManager.selectedDate) && !isToday
        let isCurrentMonth = cal.component(.month, from: day) == cal.component(.month, from: currentMonthFirstDay)
        let dayNumber = cal.component(.day, from: day)
        let dayItems = itemsForDay(day)
        let busyness = busynessFraction(dayItems)
        let kinds = uniqueItemKinds(dayItems)

        return Button {
            withAnimation(.flowQuick) {
                dataManager.selectedDate = day
                dataManager.viewMode = .week
            }
        } label: {
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(isCurrentMonth ? FlowTokens.bg0 : FlowTokens.bg0.opacity(0.5))

                // Busyness accent bar (left edge) — tokenized width
                if busyness > 0 {
                    Rectangle()
                        .fill(busynessColor(dayItems).opacity(0.6))
                        .frame(width: FlowTokens.accentBarWidth,
                               height: max(10, height * busyness))
                        .padding(.top, FlowTokens.spacingSM)
                }

                VStack(alignment: .leading, spacing: FlowTokens.spacingXS) {
                    HStack(spacing: 0) {
                        ZStack {
                            if isToday {
                                Circle()
                                    .fill(FlowTokens.editorialRed)
                                    .frame(width: 22, height: 22)
                            } else if isSelected {
                                Circle()
                                    .strokeBorder(FlowTokens.borderStrong, lineWidth: FlowTokens.hairlineStrong)
                                    .frame(width: 22, height: 22)
                            }
                            Text("\(dayNumber)")
                                .font(.system(size: 13,
                                              weight: isToday ? .semibold : .regular,
                                              design: .default))
                                .foregroundColor(numberColor(isToday: isToday,
                                                             isSelected: isSelected,
                                                             isCurrentMonth: isCurrentMonth))
                        }
                        Spacer(minLength: 0)
                        if dayItems.count > maxDots {
                            Text("+\(dayItems.count - maxDots)")
                                .flowFont(.micro)
                                .foregroundColor(FlowTokens.textHint)
                                .padding(.top, 3)
                        }
                    }

                    if !kinds.isEmpty {
                        HStack(spacing: 3) {
                            ForEach(0..<min(kinds.count, maxDots), id: \.self) { index in
                                Circle()
                                    .fill(dotColor(for: kinds[index]))
                                    .frame(width: 4, height: 4)
                            }
                        }
                        .padding(.leading, 1)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, FlowTokens.spacingSM + 2)
                .padding(.top, FlowTokens.spacingSM - 2)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Month Grid

    private var currentMonthFirstDay: Date {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: dataManager.selectedDate))!
    }

    private var monthWeeks: [[Date]] {
        let cal = Calendar.current
        let firstOfMonth = currentMonthFirstDay
        let weekdayOfFirst = cal.component(.weekday, from: firstOfMonth)
        let gridStart = cal.date(byAdding: .day, value: -(weekdayOfFirst - 1), to: firstOfMonth)!
        let allDays = (0..<42).map { cal.date(byAdding: .day, value: $0, to: gridStart)! }
        return stride(from: 0, to: 42, by: 7).map { start in
            Array(allDays[start..<min(start + 7, allDays.count)])
        }
    }

    // MARK: - Data

    private func itemsForDay(_ day: Date) -> [any CalendarItemProtocol] {
        dataManager.items.filter { Calendar.current.isDate($0.startDate, inSameDayAs: day) }
    }

    /// 0…1 — proportion of an 8-hour workday filled by scheduled events.
    private func busynessFraction(_ items: [any CalendarItemProtocol]) -> Double {
        let scheduled = items.filter { !$0.isAllDay && $0.kind == .systemEvent }
        let totalSeconds = scheduled.reduce(0.0) { acc, item in
            acc + max(0, item.endDate.timeIntervalSince(item.startDate))
        }
        let workday: Double = 8 * 3600
        return min(1.0, totalSeconds / workday)
    }

    private func busynessColor(_ items: [any CalendarItemProtocol]) -> Color {
        if items.contains(where: { $0.kind == .deadline }) {
            return FlowTokens.editorialRed
        }
        return FlowTokens.accent
    }

    private func uniqueItemKinds(_ items: [any CalendarItemProtocol]) -> [CalendarItemKind] {
        var seen = Set<String>()
        var result: [CalendarItemKind] = []
        for item in items {
            let key = item.kind.rawValue
            if !seen.contains(key) {
                seen.insert(key)
                result.append(item.kind)
            }
            if result.count >= maxDots { break }
        }
        return result
    }

    private func dotColor(for kind: CalendarItemKind) -> Color {
        switch kind {
        case .systemEvent: return FlowTokens.accent
        case .todo:        return FlowTokens.calendarTodo
        case .deadline:    return FlowTokens.editorialRed
        case .reminder:    return FlowTokens.calendarReminder
        }
    }

    private func numberColor(isToday: Bool, isSelected: Bool, isCurrentMonth: Bool) -> Color {
        if isToday { return .white }
        if isSelected { return FlowTokens.textPrimary }
        if isCurrentMonth { return FlowTokens.textPrimary }
        return FlowTokens.textHint
    }
}
