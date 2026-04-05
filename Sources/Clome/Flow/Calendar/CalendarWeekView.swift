import SwiftUI
import ClomeModels

// MARK: - Calendar Week View

struct CalendarWeekView: View {
    @ObservedObject var dataManager: CalendarDataManager
    @Binding var showCreationPopover: Bool
    @Binding var creationTime: Date?

    @State private var selectedItemID: String?
    @State private var selectedItemRect: CGRect = .zero
    @State private var selectedDayIndex: Int = -1

    private let startHour = 6
    private let endHour = 24
    private let hourHeight = FlowTokens.weekHourHeight   // 14pt
    private let gutterWidth = FlowTokens.weekGutterWidth  // 30pt
    private let dayHeaderHeight: CGFloat = 18

    // MARK: - Body

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            GeometryReader { outerGeo in
                let totalWidth = outerGeo.size.width

                ZStack(alignment: .topLeading) {
                    // Layer 1: The week grid
                    HStack(spacing: 0) {
                        // Shared hour gutter
                        hourGutter

                        // 7 day columns
                        ForEach(Array(weekDays.enumerated()), id: \.offset) { index, day in
                            dayColumn(day, dayIndex: index, totalWidth: totalWidth)
                            if index < weekDays.count - 1 {
                                Rectangle()
                                    .fill(FlowTokens.border)
                                    .frame(width: 0.5)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedItemID = nil
                    }

                    // Layer 2: Detail overlay positioned near selected event
                    if let selectedID = selectedItemID,
                       let item = findItem(selectedID) {
                        let popoverWidth: CGFloat = 260
                        let popoverEstHeight: CGFloat = 200
                        let timelineHeight = CGFloat(endHour - startHour) * hourHeight

                        // Compute anchor X: try right of event, fall back to left
                        let rightX = selectedItemRect.maxX + 6
                        let leftX = selectedItemRect.minX - popoverWidth - 6
                        let fitsRight = rightX + popoverWidth <= totalWidth
                        let anchorX = fitsRight ? rightX : max(0, leftX)

                        // Anchor Y: center on event, clamped to timeline bounds
                        let anchorY = min(
                            max(selectedItemRect.midY - popoverEstHeight / 2, dayHeaderHeight),
                            dayHeaderHeight + timelineHeight - popoverEstHeight
                        )

                        CalendarEventDetailPopover(item: item) {
                            selectedItemID = nil
                        }
                        .fixedSize()
                        .offset(x: anchorX, y: anchorY)
                        .shadow(color: Color.black.opacity(0.25), radius: 12, y: 4)
                        .transition(.opacity)
                        .zIndex(1000)
                    }
                }
            }
            .frame(height: dayHeaderHeight + CGFloat(endHour - startHour) * hourHeight)
        }
        .background(FlowTokens.bg0)
    }

    // MARK: - Hour Gutter

    private var hourGutter: some View {
        VStack(spacing: 0) {
            Spacer()
                .frame(height: dayHeaderHeight)

            ForEach(startHour..<endHour, id: \.self) { hour in
                Text(hourLabel(hour))
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundColor(FlowTokens.textMuted)
                    .frame(height: hourHeight)
                    .frame(width: gutterWidth, alignment: .trailing)
            }
        }
    }

    // MARK: - Day Column

    @ViewBuilder
    private func dayColumn(_ day: Date, dayIndex: Int, totalWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            dayHeader(day)
            dayTimeline(day, dayIndex: dayIndex, totalWidth: totalWidth)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Day Header

    private func dayHeader(_ day: Date) -> some View {
        let isToday = Calendar.current.isDateInToday(day)
        let weekdayLetter = dayLetterFormatter.string(from: day)
        let dayNumber = Calendar.current.component(.day, from: day)

        return Button {
            withAnimation(.flowQuick) {
                dataManager.selectedDate = day
                dataManager.viewMode = .day
            }
        } label: {
            HStack(spacing: FlowTokens.spacingXS) {
                Text(weekdayLetter)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(isToday ? FlowTokens.accent : FlowTokens.textTertiary)

                ZStack {
                    if isToday {
                        Circle()
                            .fill(FlowTokens.accentSubtle)
                            .frame(width: 14, height: 14)
                    }
                    Text("\(dayNumber)")
                        .font(.system(size: 8, weight: isToday ? .bold : .medium, design: .monospaced))
                        .foregroundColor(isToday ? FlowTokens.accent : FlowTokens.textSecondary)
                }
            }
            .frame(height: dayHeaderHeight)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Day Timeline

    private func dayTimeline(_ day: Date, dayIndex: Int, totalWidth: CGFloat) -> some View {
        let dayItems = itemsForDay(day)
        let overlapInput = dayItems.map { item in
            (id: item.calendarItemID, start: item.startDate, end: item.endDate, isAllDay: item.isAllDay)
        }
        let slots = CalendarOverlapLayout.computeOverlapLayout(items: overlapInput)
        let totalHeight = CGFloat(endHour - startHour) * hourHeight

        return GeometryReader { geo in
            let columnWidth = geo.size.width

            ZStack(alignment: .topLeading) {
                // Hour grid lines
                ForEach(startHour..<endHour, id: \.self) { hour in
                    let y = CGFloat(hour - startHour) * hourHeight
                    Rectangle()
                        .fill(hour % 6 == 0 ? FlowTokens.hourGridLineAccent : FlowTokens.hourGridLine)
                        .frame(height: 0.5)
                        .offset(y: y)
                }

                // Event blocks
                ForEach(slots, id: \.itemID) { slot in
                    let item = dayItems.first { $0.calendarItemID == slot.itemID }
                    if let item = item {
                        eventBlock(item: item, slot: slot, columnWidth: columnWidth, dayIndex: dayIndex, totalWidth: totalWidth)
                    }
                }
            }
        }
        .frame(height: totalHeight)
    }

    // MARK: - Event Block

    private func eventBlock(
        item: any CalendarItemProtocol,
        slot: LayoutSlot,
        columnWidth: CGFloat,
        dayIndex: Int,
        totalWidth: CGFloat
    ) -> some View {
        let y = CalendarOverlapLayout.yPosition(for: slot.startDate, hourHeight: hourHeight, startHour: startHour)
        let yEnd = CalendarOverlapLayout.yPosition(for: slot.endDate, hourHeight: hourHeight, startHour: startHour)
        let height = max(yEnd - y, hourHeight * 0.5)

        let slotWidth = columnWidth / CGFloat(slot.totalColumns)
        let x = CGFloat(slot.column) * slotWidth

        // Compute the day column's X origin in the outer coordinate space
        // Each day column has equal width = (totalWidth - gutterWidth - separators) / 7
        let separatorTotal: CGFloat = 6 * 0.5  // 6 separators at 0.5pt each
        let dayColumnWidth = (totalWidth - gutterWidth - separatorTotal) / 7
        let dayOriginX = gutterWidth + CGFloat(dayIndex) * (dayColumnWidth + 0.5)

        return RoundedRectangle(cornerRadius: FlowTokens.radiusSmall - 1, style: .continuous)
            .fill(item.displayColor.opacity(item.isCompleted ? 0.25 : 0.6))
            .overlay(alignment: .topLeading) {
                if slotWidth > 45 {
                    Text(item.title)
                        .font(.system(size: 8))
                        .foregroundColor(FlowTokens.textPrimary)
                        .lineLimit(1)
                        .padding(.horizontal, 2)
                        .padding(.top, 1)
                }
            }
            .frame(width: max(slotWidth - 1, 0), height: height)
            .offset(x: x, y: y)
            .contentShape(Rectangle())
            .onTapGesture {
                if selectedItemID == item.calendarItemID {
                    selectedItemID = nil
                } else {
                    selectedItemID = item.calendarItemID
                    selectedDayIndex = dayIndex
                    // Store rect in outer (whole-timeline) coordinate space
                    selectedItemRect = CGRect(
                        x: dayOriginX + x,
                        y: dayHeaderHeight + y,
                        width: max(slotWidth - 1, 0),
                        height: height
                    )
                }
            }
            .help("\(item.title)\n\(timeRangeLabel(item.startDate, item.endDate))")
    }

    // MARK: - Week Day Computation

    private var weekDays: [Date] {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: dataManager.selectedDate))!
        return (0..<7).map { cal.date(byAdding: .day, value: $0, to: start)! }
    }

    // MARK: - Data Filtering

    private func itemsForDay(_ day: Date) -> [any CalendarItemProtocol] {
        dataManager.items.filter { Calendar.current.isDate($0.startDate, inSameDayAs: day) }
    }

    // MARK: - Item Lookup

    private func findItem(_ id: String) -> (any CalendarItemProtocol)? {
        dataManager.items.first { $0.calendarItemID == id }
    }

    // MARK: - Formatters

    private var dayLetterFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "EEEEE"  // Single letter weekday
        return f
    }

    private func hourLabel(_ hour: Int) -> String {
        if hour == 0 || hour == 24 { return "12a" }
        if hour == 12 { return "12p" }
        if hour < 12 { return "\(hour)a" }
        return "\(hour - 12)p"
    }

    private func timeRangeLabel(_ start: Date, _ end: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return "\(f.string(from: start)) - \(f.string(from: end))"
    }
}
