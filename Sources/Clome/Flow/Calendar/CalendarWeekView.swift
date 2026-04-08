import SwiftUI

/// Week view — Wave 1: pure layout and rendering. No interactions yet
/// (create / edit / drag land in Waves 2–4).
struct CalendarWeekView: View {
    @ObservedObject var dataManager: CalendarDataManager
    @State private var now = Date()
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var days: [Date] {
        let ref = dataManager.viewMode == .day ? dataManager.selectedDate : dataManager.selectedDate
        if dataManager.viewMode == .day {
            return [Calendar.current.startOfDay(for: ref)]
        }
        return CalendarGridGeometry.weekDays(containing: ref)
    }

    private var isDay: Bool { dataManager.viewMode == .day }

    var body: some View {
        VStack(spacing: 0) {
            CalendarWeekHeader(
                days: days,
                selectedDate: dataManager.selectedDate,
                onSelect: { dataManager.selectedDate = $0 }
            )

            CalendarAllDayStrip(days: days, items: dataManager.items)
                .padding(.horizontal, 0)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(FlowTokens.border).frame(height: FlowTokens.hairline)
                }

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    GeometryReader { geo in
                        timeline(width: geo.size.width)
                    }
                    .frame(height: CalendarGridGeometry.timelineHeight)
                    .id("timeline")
                }
                .onAppear {
                    // Anchor scroll near the current time.
                    DispatchQueue.main.async {
                        proxy.scrollTo("timeline", anchor: .top)
                    }
                }
            }
        }
        .background(FlowTokens.bg0)
        .onReceive(ticker) { now = $0 }
    }

    // MARK: - Timeline

    private func timeline(width: CGFloat) -> some View {
        let colW = isDay
            ? max(0, width - CalendarGridGeometry.gutterWidth)
            : CalendarGridGeometry.columnWidth(totalWidth: width)

        return ZStack(alignment: .topLeading) {
            hourLines(width: width)
            hourLabels

            ForEach(Array(days.enumerated()), id: \.offset) { idx, day in
                dayColumn(day: day, index: idx, width: colW)
                    .frame(width: colW)
                    .offset(x: CalendarGridGeometry.gutterWidth + colW * CGFloat(idx))
            }

            nowLine(width: width, colW: colW)
        }
    }

    private func hourLines(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(CalendarGridGeometry.firstHour...CalendarGridGeometry.lastHour, id: \.self) { hour in
                Rectangle()
                    .fill(FlowTokens.hourGridLine)
                    .frame(height: FlowTokens.hairline)
                    .offset(y: CGFloat(hour - CalendarGridGeometry.firstHour) * CalendarGridGeometry.hourHeight)
            }
        }
        .frame(width: width, height: CalendarGridGeometry.timelineHeight, alignment: .topLeading)
    }

    private var hourLabels: some View {
        ZStack(alignment: .topLeading) {
            ForEach(CalendarGridGeometry.firstHour..<CalendarGridGeometry.lastHour, id: \.self) { hour in
                Text(hourLabel(hour))
                    .font(.system(size: 9, weight: .regular))
                    .foregroundColor(FlowTokens.textTertiary.opacity(0.6))
                    .frame(width: CalendarGridGeometry.gutterWidth - 8, alignment: .trailing)
                    .offset(
                        x: 0,
                        y: CGFloat(hour - CalendarGridGeometry.firstHour) * CalendarGridGeometry.hourHeight - 5
                    )
            }
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        if hour == 0 { return "" }
        if hour == 12 { return "12 PM" }
        if hour < 12 { return "\(hour) AM" }
        return "\(hour - 12) PM"
    }

    // MARK: - Day column

    private func dayColumn(day: Date, index: Int, width: CGFloat) -> some View {
        let cal = Calendar.current
        let timed = dataManager.items.filter { item in
            !item.isAllDay && cal.isDate(item.startDate, inSameDayAs: day)
        }
        let slots = CalendarOverlapLayout.layout(timedArray(timed))

        return ZStack(alignment: .topLeading) {
            // Vertical divider on the right edge (skip last column).
            if !isDay && index < 6 {
                Rectangle()
                    .fill(FlowTokens.border.opacity(0.5))
                    .frame(width: FlowTokens.hairline)
                    .frame(maxHeight: .infinity, alignment: .topTrailing)
                    .offset(x: width - FlowTokens.hairline)
            }

            ForEach(timed, id: \.calendarItemID) { item in
                let slot = slots[item.calendarItemID] ?? CalendarOverlapLayout.Slot(column: 0, columnCount: 1)
                let slotW = max(20, (width - 4) / CGFloat(slot.columnCount))
                let x = 2 + slotW * CGFloat(slot.column)
                let y = CalendarGridGeometry.y(for: item.startDate)
                let h = CalendarGridGeometry.height(from: item.startDate, to: item.endDate)
                let past = item.endDate < now

                CalendarEventCard(item: item, isPast: past)
                    .frame(width: slotW - 2, height: max(18, h - 1))
                    .offset(x: x, y: y)
            }
        }
    }

    /// Type-erase to a concrete array so `CalendarOverlapLayout.layout` (generic)
    /// can infer its element type.
    private func timedArray(_ items: [any CalendarItemProtocol]) -> [AnyCalendarItem] {
        items.map(AnyCalendarItem.init)
    }

    // MARK: - Now line

    private func nowLine(width: CGFloat, colW: CGFloat) -> some View {
        let cal = Calendar.current
        let y = CalendarGridGeometry.y(for: now)
        let todayIndex = days.firstIndex(where: { cal.isDate($0, inSameDayAs: now) })

        return Group {
            if todayIndex != nil {
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(FlowTokens.editorialRed.opacity(0.6))
                        .frame(
                            width: width - CalendarGridGeometry.gutterWidth,
                            height: 1
                        )
                        .offset(x: CalendarGridGeometry.gutterWidth)

                    if let idx = todayIndex {
                        Circle()
                            .fill(FlowTokens.editorialRed)
                            .frame(width: 6, height: 6)
                            .offset(
                                x: CalendarGridGeometry.gutterWidth + colW * CGFloat(idx) - 3,
                                y: -2.5
                            )
                    }
                }
                .offset(y: y)
            }
        }
    }
}

// MARK: - Type erasure for overlap layout

/// A concrete type-erased wrapper so `CalendarOverlapLayout.layout` can
/// infer a single `Item` generic across heterogeneous items.
struct AnyCalendarItem: CalendarItemProtocol {
    let calendarItemID: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let kind: CalendarItemKind
    let displayColor: Color
    let isCompleted: Bool

    init(_ base: any CalendarItemProtocol) {
        self.calendarItemID = base.calendarItemID
        self.title = base.title
        self.startDate = base.startDate
        self.endDate = base.endDate
        self.isAllDay = base.isAllDay
        self.kind = base.kind
        self.displayColor = base.displayColor
        self.isCompleted = base.isCompleted
    }
}
