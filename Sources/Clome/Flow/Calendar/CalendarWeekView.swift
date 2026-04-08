import SwiftUI
import ClomeModels

/// Week view — Apple Calendar convention with Things 3 restraint.
///
/// Header:    3-letter weekday above big day number; today gets the accent.
/// All-day:   hair-thin strip with small tinted pills.
/// Grid:      hour rows with a whisper half-hour subdivision; selected-day
///            column gets a faint bg1 tint.
/// Events:    translucent fill + solid left bar, NO border; title + time.
/// Now line:  1pt red hairline spanning ALL columns + filled dot on today.
struct CalendarWeekView: View {
    @ObservedObject var dataManager: CalendarDataManager
    @Binding var showCreationPopover: Bool
    @Binding var creationTime: Date?

    @State private var currentTime = Date()
    @State private var selectedItemID: String?
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    // Layout
    private let startHour = 6
    private let endHour = 24
    private let hourHeight: CGFloat = 52
    private let gutterWidth: CGFloat = 56
    private let headerHeight: CGFloat = 60
    private let allDayLaneHeight: CGFloat = 24

    private var timelineHeight: CGFloat {
        CGFloat(endHour - startHour) * hourHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            dayHeader
            if !weekAllDayItems.isEmpty {
                allDayStrip
            }
            Rectangle().fill(FlowTokens.border).frame(height: FlowTokens.hairline)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    GeometryReader { geo in
                        let columnsWidth = geo.size.width - gutterWidth
                        let columnWidth = columnsWidth / 7
                        ZStack(alignment: .topLeading) {
                            selectedDayTint(columnWidth: columnWidth)
                            hourGrid(width: geo.size.width)
                            verticalDividers(columnWidth: columnWidth)
                            eventLayer(columnWidth: columnWidth)
                            nowLineIfVisible(columnWidth: columnWidth)
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

    // MARK: - Header

    private var dayHeader: some View {
        HStack(spacing: 0) {
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
        let isSelected = cal.isDate(day, inSameDayAs: dataManager.selectedDate)
        let weekday = formatted(day, "EEE").uppercased()
        let dayNumber = cal.component(.day, from: day)

        return Button {
            withAnimation(.flowQuick) { dataManager.selectedDate = day }
        } label: {
            VStack(spacing: 6) {
                Text(weekday)
                    .font(.system(size: 10, weight: .semibold, design: .default))
                    .tracking(1.0)
                    .foregroundColor(isToday ? FlowTokens.accent : FlowTokens.textTertiary)

                ZStack {
                    if isToday {
                        Circle()
                            .fill(FlowTokens.accent)
                            .frame(width: 30, height: 30)
                    } else if isSelected {
                        Circle()
                            .strokeBorder(FlowTokens.borderStrong, lineWidth: FlowTokens.hairlineStrong)
                            .frame(width: 30, height: 30)
                    }
                    Text("\(dayNumber)")
                        .font(.system(size: 18,
                                      weight: isToday ? .semibold : .regular))
                        .foregroundColor(isToday ? .white : FlowTokens.textPrimary)
                        .tracking(-0.4)
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
                .flowFont(.micro)
                .foregroundColor(FlowTokens.textMuted)
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, FlowTokens.spacingSM)

            HStack(spacing: 0) {
                ForEach(weekDays, id: \.self) { day in
                    let items = allDayItems(for: day)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(items.prefix(2), id: \.calendarItemID) { item in
                            allDayPill(item)
                        }
                        if items.count > 2 {
                            Text("+\(items.count - 2)")
                                .flowFont(.micro)
                                .foregroundColor(FlowTokens.textMuted)
                                .padding(.leading, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 3)
                }
            }
        }
        .padding(.vertical, FlowTokens.spacingSM)
        .frame(minHeight: allDayLaneHeight)
        .background(FlowTokens.bg0)
    }

    private func allDayPill(_ item: any CalendarItemProtocol) -> some View {
        HStack(spacing: 4) {
            Rectangle()
                .fill(item.displayColor)
                .frame(width: FlowTokens.accentBarWidth)
            Text(item.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(FlowTokens.textPrimary)
                .lineLimit(1)
                .padding(.trailing, 5)
                .padding(.vertical, 2)
            Spacer(minLength: 0)
        }
        .background(
            RoundedRectangle(cornerRadius: FlowTokens.radiusControl - 2, style: .continuous)
                .fill(item.displayColor.opacity(FlowTokens.eventFillActive))
        )
        .clipShape(RoundedRectangle(cornerRadius: FlowTokens.radiusControl - 2, style: .continuous))
    }

    // MARK: - Hour grid

    private func hourGrid(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // Hour labels
            VStack(spacing: 0) {
                ForEach(startHour..<endHour, id: \.self) { hour in
                    HStack {
                        Text(hourLabel(hour))
                            .font(.system(size: 10, weight: .regular, design: .default))
                            .monospacedDigit()
                            .foregroundColor(FlowTokens.textMuted)
                            .frame(width: gutterWidth - FlowTokens.spacingSM, alignment: .trailing)
                            .padding(.trailing, FlowTokens.spacingSM)
                            .offset(y: -6)
                        Spacer(minLength: 0)
                    }
                    .frame(height: hourHeight)
                }
            }

            // Hour hairlines (full width, starting from gutter)
            VStack(spacing: 0) {
                ForEach(startHour..<endHour, id: \.self) { _ in
                    ZStack(alignment: .top) {
                        Rectangle()
                            .fill(FlowTokens.border)
                            .frame(height: FlowTokens.hairline)
                        Rectangle()
                            .fill(FlowTokens.hourGridLine)
                            .frame(height: FlowTokens.hairline)
                            .offset(y: hourHeight / 2)
                        Spacer(minLength: 0)
                    }
                    .frame(height: hourHeight)
                    .padding(.leading, gutterWidth)
                }
            }
        }
    }

    private func verticalDividers(columnWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<8, id: \.self) { i in
                Rectangle()
                    .fill(FlowTokens.border)
                    .frame(width: FlowTokens.hairline, height: timelineHeight)
                    .offset(x: gutterWidth + CGFloat(i) * columnWidth)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Selected day tint

    private func selectedDayTint(columnWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if let col = selectedColumnIndex {
                Rectangle()
                    .fill(FlowTokens.bg1.opacity(0.55))
                    .frame(width: columnWidth, height: timelineHeight)
                    .offset(x: gutterWidth + CGFloat(col) * columnWidth)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Event layer

    private func eventLayer(columnWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(weekDays.enumerated()), id: \.offset) { index, day in
                let dayItems = timedItems(for: day)
                let tuples = dayItems.map { (id: $0.calendarItemID,
                                             start: $0.startDate,
                                             end: $0.endDate,
                                             isAllDay: $0.isAllDay) }
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
                        eventCard(item: item, isSelected: selectedItemID == item.calendarItemID)
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

    // MARK: - Event card (borderless, Things 3 / Apple Calendar style)

    private func eventCard(item: any CalendarItemProtocol, isSelected: Bool) -> some View {
        let status = blockStatus(for: item)
        let tint = item.displayColor
        let fillAlpha: Double = {
            switch status {
            case .past:     return FlowTokens.eventFillPast
            case .now:      return FlowTokens.eventFillActive
            case .upcoming: return FlowTokens.eventFillActive
            }
        }()
        let textColor: Color = status == .past
            ? FlowTokens.textTertiary
            : FlowTokens.textPrimary
        let barColor: Color = status == .past ? tint.opacity(0.55) : tint

        return GeometryReader { geo in
            let h = geo.size.height
            let veryCompact = h < 26
            let compact = h < 44

            HStack(spacing: 0) {
                Rectangle()
                    .fill(barColor)
                    .frame(width: FlowTokens.accentBarWidth + 1)

                VStack(alignment: .leading, spacing: veryCompact ? 0 : 2) {
                    Text(item.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(textColor)
                        .strikethrough(item.isCompleted)
                        .lineLimit(veryCompact ? 1 : 2)

                    if !compact {
                        Text(timeRangeString(item))
                            .font(.system(size: 10, weight: .regular))
                            .monospacedDigit()
                            .foregroundColor(FlowTokens.textTertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, veryCompact ? 1 : 4)

                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: FlowTokens.radiusControl, style: .continuous)
                    .fill(tint.opacity(fillAlpha))
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: FlowTokens.radiusControl, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.6), lineWidth: FlowTokens.hairlineStrong)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: FlowTokens.radiusControl, style: .continuous))
        }
    }

    // MARK: - Now line (full width)

    @ViewBuilder
    private func nowLineIfVisible(columnWidth: CGFloat) -> some View {
        if let _ = todayColumnIndex {
            nowLine(columnWidth: columnWidth)
                .allowsHitTesting(false)
        }
    }

    private func nowLine(columnWidth: CGFloat) -> some View {
        let yPos = CalendarOverlapLayout.yPosition(
            for: currentTime,
            hourHeight: hourHeight,
            startHour: startHour
        )
        let red = FlowTokens.editorialRed
        let todayCol = todayColumnIndex ?? 0

        return ZStack(alignment: .leading) {
            // Time chip in the gutter
            Text(formatted(currentTime, "h:mm"))
                .font(.system(size: 9, weight: .bold))
                .monospacedDigit()
                .foregroundColor(red)
                .padding(.horizontal, 4)
                .background(FlowTokens.bg0)
                .offset(x: FlowTokens.spacingSM, y: -8)

            // Full-width hairline across ALL columns
            Rectangle()
                .fill(red.opacity(0.7))
                .frame(height: FlowTokens.hairlineStrong)
                .padding(.leading, gutterWidth)

            // Solid dot on today's column
            Circle()
                .fill(red)
                .frame(width: 8, height: 8)
                .offset(x: gutterWidth + CGFloat(todayCol) * columnWidth - 4)
        }
        .offset(y: yPos)
    }

    // MARK: - Data

    private var weekDays: [Date] {
        let cal = Calendar.current
        var components = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: dataManager.selectedDate)
        components.weekday = 1 // Sunday
        let start = cal.date(from: components) ?? cal.startOfDay(for: dataManager.selectedDate)
        return (0..<7).map { cal.date(byAdding: .day, value: $0, to: start)! }
    }

    private var weekAllDayItems: [any CalendarItemProtocol] {
        let cal = Calendar.current
        return dataManager.items.filter { item in
            guard item.isAllDay else { return false }
            return weekDays.contains { cal.isDate(item.startDate, inSameDayAs: $0) }
        }
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

    private var selectedColumnIndex: Int? {
        let cal = Calendar.current
        return weekDays.firstIndex { cal.isDate($0, inSameDayAs: dataManager.selectedDate) }
    }

    // MARK: - Status

    private enum BlockStatus { case past, now, upcoming }

    private func blockStatus(for item: any CalendarItemProtocol) -> BlockStatus {
        if currentTime >= item.endDate { return .past }
        if currentTime >= item.startDate { return .now }
        return .upcoming
    }

    // MARK: - Tap-to-create

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

    // MARK: - Formatting

    private func hourLabel(_ hour: Int) -> String {
        if hour == 0 || hour == 24 { return "12 AM" }
        if hour < 12 { return "\(hour) AM" }
        if hour == 12 { return "12 PM" }
        return "\(hour - 12) PM"
    }

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
