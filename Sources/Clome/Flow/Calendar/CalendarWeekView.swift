import SwiftUI
import ClomeModels

// MARK: - Calendar Week View
//
// Apple Calendar.app-style 7-day week timeline.
//
//   ┌──────────────────────────────────────────────────┐
//   │       │ SUN │ MON │ TUE │ WED │ THU │ FRI │ SAT │   ← day header
//   │       │  6  │  7  │  8  │  9  │ 10  │ 11  │ 12  │
//   ├───────┼─────┴─────┴─────┴─────┴─────┴─────┴─────┤
//   │ all-day strip (only if any all-day items)        │
//   ├───────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┤
//   │  6 AM │     │     │     │     │     │     │     │
//   │  ─────┤  …  │  …  │  …  │  …  │  …  │  …  │  …  │
//   │  7 AM │     │     │     │     │     │     │     │
//   │   …   │     │     │     │     │     │     │     │
//   └───────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┘

struct CalendarWeekView: View {
    @ObservedObject var dataManager: CalendarDataManager
    @Binding var showCreationPopover: Bool
    @Binding var creationTime: Date?

    @State private var currentTime = Date()
    @State private var selectedItemID: String?
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    // Layout constants
    private let startHour = 6
    private let endHour = 24
    private let hourHeight: CGFloat = 48
    private let gutterWidth: CGFloat = 52
    private let headerHeight: CGFloat = 56

    private var timelineHeight: CGFloat {
        CGFloat(endHour - startHour) * hourHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            dayHeader
            if !allDayItems.isEmpty { allDayStrip }
            Divider().background(FlowTokens.border)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    GeometryReader { geo in
                        let columnsWidth = geo.size.width - gutterWidth
                        let columnWidth = columnsWidth / 7
                        ZStack(alignment: .topLeading) {
                            hourGrid(width: geo.size.width)
                            verticalDayDividers(columnWidth: columnWidth)
                            eventLayer(columnWidth: columnWidth)
                            if let todayCol = todayColumnIndex {
                                nowLine(columnWidth: columnWidth, columnIndex: todayCol)
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(width: geo.size.width, height: timelineHeight)
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            if selectedItemID != nil {
                                selectedItemID = nil
                            } else {
                                handleTimelineTap(at: location, columnWidth: columnWidth)
                            }
                        }
                    }
                    .frame(height: timelineHeight)
                    .id("timeline")
                }
                .onAppear { scrollToCurrentHour(proxy: proxy) }
            }
        }
        .background(FlowTokens.bg0)
        .onReceive(ticker) { currentTime = $0 }
    }

    // MARK: - Day Header

    private var dayHeader: some View {
        HStack(spacing: 0) {
            // Gutter spacer aligned with hour column
            Color.clear.frame(width: gutterWidth)

            ForEach(weekDays, id: \.self) { day in
                dayHeaderCell(day)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: headerHeight)
        .background(FlowTokens.bg0)
    }

    private func dayHeaderCell(_ day: Date) -> some View {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: dataManager.selectedDate) && !isToday
        let weekday = formatted(day, "EEE").uppercased()
        let dayNumber = cal.component(.day, from: day)

        return Button {
            withAnimation(.flowQuick) { dataManager.selectedDate = day }
        } label: {
            VStack(spacing: FlowTokens.spacingXS) {
                Text(weekday)
                    .flowFont(.sectionLabel)
                    .foregroundColor(isToday ? FlowTokens.editorialRed : FlowTokens.textTertiary)
                ZStack {
                    if isToday {
                        Circle()
                            .fill(FlowTokens.editorialRed)
                            .frame(width: 26, height: 26)
                    } else if isSelected {
                        Circle()
                            .strokeBorder(FlowTokens.borderStrong, lineWidth: FlowTokens.hairlineStrong)
                            .frame(width: 26, height: 26)
                    }
                    Text("\(dayNumber)")
                        .font(.system(size: 15, weight: isToday ? .semibold : .regular))
                        .foregroundColor(isToday ? .white : FlowTokens.textPrimary)
                        .tracking(-0.2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - All-day strip

    private var allDayStrip: some View {
        HStack(spacing: 0) {
            Text("all-day")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(FlowTokens.textHint)
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, FlowTokens.spacingMD)

            HStack(spacing: 0) {
                ForEach(weekDays, id: \.self) { day in
                    let items = allDayItems(for: day)
                    VStack(spacing: 2) {
                        ForEach(items.prefix(2), id: \.calendarItemID) { item in
                            allDayPill(item)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 2)
                }
            }
        }
        .padding(.vertical, 6)
        .background(FlowTokens.bg0)
    }

    private func allDayPill(_ item: any CalendarItemProtocol) -> some View {
        Text(item.title)
            .flowFont(.caption)
            .foregroundColor(FlowTokens.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, FlowTokens.spacingSM - 1)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .flowEventCard(tint: item.displayColor, state: .upcoming)
    }

    // MARK: - Hour Grid

    private func hourGrid(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(startHour..<endHour, id: \.self) { hour in
                HStack(alignment: .top, spacing: 0) {
                    Text(hourLabel(hour))
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(FlowTokens.textHint)
                        .frame(width: gutterWidth, alignment: .trailing)
                        .padding(.trailing, FlowTokens.spacingSM)
                        .offset(y: -6)
                    ZStack(alignment: .top) {
                        Rectangle()
                            .fill(FlowTokens.hourGridLineAccent)
                            .frame(height: FlowTokens.hairline)
                        Rectangle()
                            .fill(FlowTokens.hourGridLine)
                            .frame(height: FlowTokens.hairline)
                            .offset(y: hourHeight / 2)
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(height: hourHeight)
            }
        }
    }

    private func verticalDayDividers(columnWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<8, id: \.self) { i in
                Rectangle()
                    .fill(FlowTokens.border)
                    .frame(width: FlowTokens.hairline, height: timelineHeight)
                    .offset(x: gutterWidth + CGFloat(i) * columnWidth - 0.25)
            }
        }
        .allowsHitTesting(false)
    }

    private func hourLabel(_ hour: Int) -> String {
        if hour == 0 || hour == 24 { return "12 AM" }
        if hour < 12 { return "\(hour) AM" }
        if hour == 12 { return "12 PM" }
        return "\(hour - 12) PM"
    }

    // MARK: - Event Layer

    private func eventLayer(columnWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(weekDays.enumerated()), id: \.offset) { index, day in
                let dayItems = timedItems(for: day)
                let tuples = dayItems.map { (id: $0.calendarItemID, start: $0.startDate, end: $0.endDate, isAllDay: $0.isAllDay) }
                let slots = CalendarOverlapLayout.computeOverlapLayout(items: tuples)
                let dict = Dictionary(uniqueKeysWithValues: dayItems.map { ($0.calendarItemID, $0) })
                let columnX = gutterWidth + CGFloat(index) * columnWidth

                ForEach(slots, id: \.itemID) { slot in
                    if let item = dict[slot.itemID] {
                        let rect = CalendarOverlapLayout.frame(
                            for: slot,
                            hourHeight: hourHeight,
                            startHour: startHour,
                            availableWidth: columnWidth - 4,
                            gutterWidth: 0
                        )
                        eventCard(item: item)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: columnX + 2 + rect.origin.x, y: rect.origin.y)
                            .onTapGesture {
                                selectedItemID = (selectedItemID == item.calendarItemID) ? nil : item.calendarItemID
                            }
                    }
                }
            }
        }
    }

    // MARK: - Event Card (Apple Calendar style)

    /// Native-feel event card. Uses `.flowEventCard` for consistent chrome;
    /// left accent bar, stacked title + time, no shadow.
    private func eventCard(item: any CalendarItemProtocol) -> some View {
        let rawStatus = blockStatus(for: item)
        let state: FlowEventState = {
            switch rawStatus {
            case .past:     return .past
            case .now:      return .now
            case .upcoming: return .upcoming
            }
        }()
        let accent = item.displayColor
        let textColor: Color = rawStatus == .past ? FlowTokens.textTertiary : FlowTokens.textPrimary

        return GeometryReader { geo in
            let h = geo.size.height
            let veryCompact = h < 28
            let compact = h < 44

            HStack(spacing: 0) {
                Rectangle()
                    .fill(rawStatus == .past ? accent.opacity(0.55) : accent)
                    .frame(width: FlowTokens.accentBarWidth)

                VStack(alignment: .leading, spacing: veryCompact ? 0 : 1) {
                    HStack(spacing: 4) {
                        Text(item.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(textColor)
                            .strikethrough(item.isCompleted)
                            .lineLimit(veryCompact ? 1 : 2)
                        if rawStatus == .now {
                            Spacer(minLength: 0)
                            Circle()
                                .fill(FlowTokens.editorialRed)
                                .frame(width: 5, height: 5)
                        }
                    }
                    if !compact {
                        Text(timeRangeString(item))
                            .flowFont(.timestamp)
                            .foregroundColor(FlowTokens.textTertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, veryCompact ? 1 : 3)

                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .flowEventCard(tint: accent, state: state)
            .clipShape(RoundedRectangle(cornerRadius: FlowTokens.radiusControl, style: .continuous))
        }
    }

    // MARK: - NOW line

    private func nowLine(columnWidth: CGFloat, columnIndex: Int) -> some View {
        let yPos = CalendarOverlapLayout.yPosition(
            for: currentTime,
            hourHeight: hourHeight,
            startHour: startHour
        )
        let red = FlowTokens.editorialRed
        let xStart = gutterWidth + CGFloat(columnIndex) * columnWidth

        return ZStack(alignment: .leading) {
            // Time chip in the gutter on the very left edge
            Text(formatted(currentTime, "h:mm"))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(red))
                .offset(x: gutterWidth - 42, y: -8)

            Rectangle()
                .fill(red)
                .frame(width: columnWidth, height: 1.5)
                .offset(x: xStart)

            Circle()
                .fill(red)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(FlowTokens.bg0, lineWidth: 1.5))
                .offset(x: xStart - 4.5)
        }
        .offset(y: yPos)
    }

    // MARK: - Filtering

    private var weekDays: [Date] {
        let cal = Calendar.current
        var components = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: dataManager.selectedDate)
        components.weekday = 1 // Sunday
        let start = cal.date(from: components) ?? cal.startOfDay(for: dataManager.selectedDate)
        return (0..<7).map { cal.date(byAdding: .day, value: $0, to: start)! }
    }

    private var allDayItems: [any CalendarItemProtocol] {
        dataManager.items.filter { $0.isAllDay }
    }

    private func allDayItems(for day: Date) -> [any CalendarItemProtocol] {
        let cal = Calendar.current
        return dataManager.items.filter {
            $0.isAllDay && cal.isDate($0.startDate, inSameDayAs: day)
        }
    }

    private func timedItems(for day: Date) -> [any CalendarItemProtocol] {
        let cal = Calendar.current
        return dataManager.items.filter {
            !$0.isAllDay && cal.isDate($0.startDate, inSameDayAs: day)
        }
    }

    private var todayColumnIndex: Int? {
        let cal = Calendar.current
        return weekDays.firstIndex { cal.isDateInToday($0) }
    }

    // MARK: - Status

    private enum BlockStatus { case past, now, upcoming }

    private func blockStatus(for item: any CalendarItemProtocol) -> BlockStatus {
        if currentTime >= item.endDate { return .past }
        if currentTime >= item.startDate { return .now }
        return .upcoming
    }

    // MARK: - Tap to Create

    private func handleTimelineTap(at location: CGPoint, columnWidth: CGFloat) {
        guard location.x > gutterWidth else { return }
        let col = min(6, max(0, Int((location.x - gutterWidth) / columnWidth)))
        let day = weekDays[col]

        let tapY = location.y
        let rawHour = startHour + Int(tapY / hourHeight)
        let fractional = (tapY.truncatingRemainder(dividingBy: hourHeight) / hourHeight) * 60
        let roundedMinute = (Int(fractional) / 15) * 15
        let hour = min(max(rawHour, startHour), endHour - 1)

        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: day)
        comps.hour = hour
        comps.minute = min(roundedMinute, 45)
        comps.second = 0
        if let date = cal.date(from: comps) {
            creationTime = date
            showCreationPopover = true
        }
    }

    // MARK: - Scroll

    private func scrollToCurrentHour(proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.flowQuick) {
                proxy.scrollTo("timeline", anchor: .top)
            }
        }
    }

    // MARK: - Helpers

    private func formatted(_ date: Date, _ format: String) -> String {
        let f = DateFormatter(); f.dateFormat = format
        return f.string(from: date)
    }

    private func timeRangeString(_ item: any CalendarItemProtocol) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return "\(f.string(from: item.startDate))–\(f.string(from: item.endDate))"
    }
}
