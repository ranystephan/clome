import SwiftUI
import ClomeModels

/// Week view — Notion Calendar / Cron sensibility.
///
/// Design rules:
///   - Flat. No drop shadows, no inner gradients, no decorative chrome.
///   - One color decoration per element (no left bar AND tint fill AND border).
///   - Day header: weekday + number, no circles. Today wears accent color.
///   - Event card: solid tint fill, tint-colored title, no border, no shadow.
///   - Hover brightens; drag scales and dims background.
///   - Grid is whisper-quiet hairlines, no half-hour subdivisions.
struct CalendarWeekView: View {
    @ObservedObject var dataManager: CalendarDataManager
    @Binding var showCreationPopover: Bool
    @Binding var creationTime: Date?

    @State private var currentTime = Date()
    @State private var hoveredItemID: String?
    @State private var detailItem: AnyCalendarItem?
    @State private var draggingItemID: String?
    @State private var dragOffset: CGSize = .zero
    @State private var dragColumnDelta: Int = 0
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    // Layout
    private let startHour = 6
    private let endHour = 24
    private let hourHeight: CGFloat = 44
    private let gutterWidth: CGFloat = 56
    private let headerHeight: CGFloat = 56
    private let allDayPillHeight: CGFloat = 18
    private let allDayMaxRows: Int = 2

    private var timelineHeight: CGFloat {
        CGFloat(endHour - startHour) * hourHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            dayHeader
            Rectangle().fill(FlowTokens.border).frame(height: FlowTokens.hairline)
            if !weekAllDayItems.isEmpty {
                allDayStrip
                Rectangle().fill(FlowTokens.border).frame(height: FlowTokens.hairline)
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
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
                            handleTimelineTap(at: location, columnWidth: columnWidth)
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
        .popover(item: $detailItem, arrowEdge: .leading) { wrapper in
            CalendarEventDetailPopover(item: wrapper.item) { detailItem = nil }
        }
    }

    // MARK: - Day header (no circles, no chrome)

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
        let isSelected = cal.isDate(day, inSameDayAs: dataManager.selectedDate) && !isToday
        let weekday = formatted(day, "EEE").uppercased()
        let dayNumber = cal.component(.day, from: day)

        let weekdayColor: Color = {
            if isToday { return FlowTokens.accent }
            if isSelected { return FlowTokens.textPrimary }
            return FlowTokens.textTertiary
        }()
        let numberColor: Color = {
            if isToday { return FlowTokens.accent }
            if isSelected { return FlowTokens.textPrimary }
            return FlowTokens.textSecondary
        }()

        return Button {
            withAnimation(.flowQuick) { dataManager.selectedDate = day }
        } label: {
            VStack(spacing: 4) {
                Text(weekday)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.4)
                    .foregroundColor(weekdayColor)
                Text("\(dayNumber)")
                    .font(.system(size: 22, weight: isToday ? .semibold : .regular))
                    .tracking(-0.6)
                    .foregroundColor(numberColor)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - All-day strip

    private var allDayStrip: some View {
        let busiest = weekDays.map { allDayItems(for: $0).count }.max() ?? 0
        let visibleRows = min(busiest, allDayMaxRows + 1)
        let stripHeight = CGFloat(max(1, visibleRows)) * (allDayPillHeight + 2)
            + FlowTokens.spacingSM * 2

        return HStack(alignment: .top, spacing: 0) {
            Text("all-day")
                .font(.system(size: 9, weight: .medium))
                .tracking(0.4)
                .foregroundColor(FlowTokens.textHint)
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, FlowTokens.spacingSM + 2)
                .padding(.top, FlowTokens.spacingSM + 2)

            HStack(alignment: .top, spacing: 0) {
                ForEach(weekDays, id: \.self) { day in
                    let items = allDayItems(for: day)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(items.prefix(allDayMaxRows), id: \.calendarItemID) { item in
                            allDayPill(item)
                                .onTapGesture { openDetail(item) }
                        }
                        if items.count > allDayMaxRows {
                            Text("+\(items.count - allDayMaxRows) more")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(FlowTokens.textMuted)
                                .padding(.leading, 6)
                                .frame(height: allDayPillHeight)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 3)
                }
            }
        }
        .frame(height: stripHeight)
        .padding(.vertical, FlowTokens.spacingSM)
        .background(FlowTokens.bg0)
    }

    private func allDayPill(_ item: any CalendarItemProtocol) -> some View {
        let tint = item.displayColor
        return HStack(spacing: 0) {
            Text(item.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(tint)
                .lineLimit(1)
                .padding(.horizontal, 6)
            Spacer(minLength: 0)
        }
        .frame(height: allDayPillHeight)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(tint.opacity(0.16))
        )
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    // MARK: - Hour grid (whisper-quiet hairlines, no half-hour)

    private func hourGrid(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // Hour labels — top-aligned in each row, right-aligned in gutter.
            VStack(spacing: 0) {
                ForEach(startHour..<endHour, id: \.self) { hour in
                    HStack(spacing: 0) {
                        Text(hourLabel(hour))
                            .font(.system(size: 10, weight: .regular))
                            .monospacedDigit()
                            .foregroundColor(FlowTokens.textHint)
                            .frame(width: gutterWidth - 8, alignment: .trailing)
                            .padding(.trailing, 8)
                            .offset(y: -5)
                        Spacer(minLength: 0)
                    }
                    .frame(height: hourHeight)
                }
            }

            // Hour hairlines — only on the canvas (right of gutter).
            VStack(spacing: 0) {
                ForEach(startHour..<endHour, id: \.self) { _ in
                    Rectangle()
                        .fill(FlowTokens.border.opacity(0.7))
                        .frame(height: FlowTokens.hairline)
                        .padding(.leading, gutterWidth)
                    Spacer(minLength: 0)
                        .frame(height: hourHeight - FlowTokens.hairline)
                }
            }
        }
    }

    private func verticalDividers(columnWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<8, id: \.self) { i in
                Rectangle()
                    .fill(FlowTokens.border.opacity(0.7))
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
                    .fill(FlowTokens.bg1.opacity(0.4))
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
                            availableWidth: columnWidth - 6,
                            gutterWidth: 0
                        )
                        let isDragging = draggingItemID == item.calendarItemID
                        let dragX = isDragging ? CGFloat(dragColumnDelta) * columnWidth : 0
                        let dragY = isDragging ? dragOffset.height : 0

                        eventCard(item: item)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: columnX + 3 + rect.origin.x + dragX,
                                    y: rect.origin.y + dragY)
                            .zIndex(isDragging ? 10 : 0)
                            .onTapGesture { openDetail(item) }
                            .gesture(dragGesture(for: item, columnWidth: columnWidth))
                    }
                }
            }
        }
    }

    // MARK: - Event card (Notion Calendar style)
    //
    // Solid translucent tint fill. Tint-colored title text. No border, no
    // shadow, no gradient, no left bar. Hover brightens. Drag scales and
    // raises opacity.

    private func eventCard(item: any CalendarItemProtocol) -> some View {
        let status = blockStatus(for: item)
        let tint = item.displayColor
        let isHovered = hoveredItemID == item.calendarItemID
        let isDragging = draggingItemID == item.calendarItemID

        let baseFill: Double = {
            switch status {
            case .past:     return 0.10
            case .now:      return 0.22
            case .upcoming: return 0.18
            }
        }()
        let fillAlpha = isHovered ? baseFill + 0.08 : baseFill
        let titleColor: Color = status == .past
            ? tint.opacity(0.55)
            : tint.opacity(0.92)
        let timeColor: Color = status == .past
            ? FlowTokens.textDisabled
            : FlowTokens.textTertiary

        return GeometryReader { geo in
            let h = geo.size.height
            let veryCompact = h < 24
            let compact = h < 38

            VStack(alignment: .leading, spacing: veryCompact ? 0 : 1) {
                Text(item.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(titleColor)
                    .strikethrough(item.isCompleted)
                    .lineLimit(veryCompact ? 1 : 2)
                    .tracking(-0.1)

                if !compact {
                    Text(timeRangeString(item))
                        .font(.system(size: 10, weight: .regular))
                        .monospacedDigit()
                        .foregroundColor(timeColor)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, veryCompact ? 1 : 5)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(fillAlpha))
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .scaleEffect(isDragging ? 1.025 : 1.0)
            .opacity(isDragging ? 0.92 : 1.0)
            .animation(.flowQuick, value: isHovered)
            .animation(.flowQuick, value: isDragging)
            .onHover { hoveredItemID = $0 ? item.calendarItemID : nil }
        }
    }

    // MARK: - Drag gesture

    private func dragGesture(for item: any CalendarItemProtocol,
                             columnWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                draggingItemID = item.calendarItemID
                dragOffset = value.translation
                dragColumnDelta = Int((value.translation.width / columnWidth).rounded())
            }
            .onEnded { value in
                defer {
                    draggingItemID = nil
                    dragOffset = .zero
                    dragColumnDelta = 0
                }

                let minutesPerPixel = 60.0 / Double(hourHeight)
                let rawMinutes = Double(value.translation.height) * minutesPerPixel
                let snappedMinutes = (rawMinutes / 15.0).rounded() * 15.0
                let columnDelta = Int((value.translation.width / columnWidth).rounded())

                if abs(snappedMinutes) < 1 && columnDelta == 0 { return }

                let cal = Calendar.current
                var newStart = item.startDate.addingTimeInterval(snappedMinutes * 60)
                if columnDelta != 0 {
                    newStart = cal.date(byAdding: .day, value: columnDelta, to: newStart) ?? newStart
                }
                let duration = item.endDate.timeIntervalSince(item.startDate)
                let newEnd = newStart.addingTimeInterval(duration)

                if let sysEvent = item as? SystemEventItem {
                    dataManager.moveSystemEvent(
                        identifier: sysEvent.eventIdentifier,
                        newStart: newStart,
                        newEnd: newEnd
                    )
                } else if let todoItem = item as? ScheduledTodoItem {
                    FlowSyncService.shared.updateTodoSchedule(
                        id: todoItem.todo.id,
                        scheduledDate: newStart,
                        scheduledEndDate: newEnd
                    )
                }
            }
    }

    private func openDetail(_ item: any CalendarItemProtocol) {
        detailItem = AnyCalendarItem(item)
    }

    // MARK: - Now line

    @ViewBuilder
    private func nowLineIfVisible(columnWidth: CGFloat) -> some View {
        if todayColumnIndex != nil {
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
            Text(formatted(currentTime, "h:mm"))
                .font(.system(size: 9, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(red)
                .frame(width: gutterWidth - 6, alignment: .trailing)
                .padding(.trailing, 6)
                .offset(y: -6)

            Rectangle()
                .fill(red.opacity(0.7))
                .frame(height: FlowTokens.hairline)
                .padding(.leading, gutterWidth)

            Circle()
                .fill(red)
                .frame(width: 7, height: 7)
                .offset(x: gutterWidth + CGFloat(todayCol) * columnWidth - 3.5)
        }
        .offset(y: yPos)
    }

    // MARK: - Data

    private var weekDays: [Date] {
        let cal = Calendar.current
        var components = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: dataManager.selectedDate)
        components.weekday = 1
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

// MARK: - Identifiable wrapper for popover(item:)
private struct AnyCalendarItem: Identifiable {
    let item: any CalendarItemProtocol
    var id: String { item.calendarItemID }
    init(_ item: any CalendarItemProtocol) { self.item = item }
}
