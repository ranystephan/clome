import SwiftUI

/// Week view day headers: weekday label (tracked small caps) + day number.
/// Selected day scales up + brightens. Today uses accent tint on the number.
struct CalendarWeekHeader: View {
    let days: [Date]
    let selectedDate: Date
    let onSelect: (Date) -> Void

    private let cal = Calendar.current

    var body: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: CalendarGridGeometry.gutterWidth)
            ForEach(days, id: \.self) { day in
                dayCell(day)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: CalendarGridGeometry.dayHeaderHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FlowTokens.border)
                .frame(height: FlowTokens.hairline)
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = cal.isDate(day, inSameDayAs: selectedDate)
        let isToday = cal.isDateInToday(day)

        let weekday = weekdayLabel(day)
        let number = cal.component(.day, from: day)

        let numberColor: Color = isToday ? FlowTokens.accent
            : (isSelected ? FlowTokens.textPrimary : FlowTokens.textSecondary)
        let weekdayColor: Color = isSelected ? FlowTokens.textSecondary : FlowTokens.textTertiary

        return Button {
            withAnimation(.flowSpring) { onSelect(day) }
        } label: {
            VStack(spacing: 4) {
                Text(weekday)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.4)
                    .foregroundColor(weekdayColor)
                Text("\(number)")
                    .font(.system(size: isSelected ? 26 : 20, weight: .light))
                    .foregroundColor(numberColor)
                    .animation(.flowSpring, value: isSelected)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func weekdayLabel(_ day: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: day).uppercased()
    }
}
