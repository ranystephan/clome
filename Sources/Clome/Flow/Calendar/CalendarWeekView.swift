import SwiftUI
import ClomeModels

/// Week view — Apple Calendar convention with Things 3 restraint.
///
/// Interactions:
///   - Tap empty grid  → create event popover (parent binding)
///   - Tap event card  → open detail/edit popover
///   - Drag event card → reschedule (snaps to 15 min, column-aware)
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

    // Layout — tightened for information density.
    private let startHour = 6
    private let endHour = 24
    private let hourHeight: CGFloat = 42
    private let gutterWidth: CGFloat = 52
    private let headerHeight: CGFloat = 58
    private let allDayPillHeight: CGFloat = 18
    private let allDayMaxRows: Int = 2

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
            CalendarEventDetailPopover(item: wrapper.item) {
                detailItem = nil
            }
        }
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
            VStack(spacing: 4) {
                Text(weekday)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.0)
                    .foregroundColor(isToday ? FlowTokens.accent : FlowTokens.textTertiary)

                ZStack {
                    if isToday {
                        Circle()
                            .fill(FlowTokens.accent)
                            .frame(width: 28, height: 28)
                    } else if isSelected {
                        Circle()
                            .strokeBorder(FlowTokens.borderStrong, lineWidth: FlowTokens.hairlineStrong)
                            .frame(width: 28, height: 28)
                    }
                    Text("\(dayNumber)")
                        .font(.system(size: 16, weight: isToday ? .semibold : .regular))
                        .foregroundColor(isToday ? .white : FlowTokens.textPrimary)
                        .tracking(-0.3)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - All-day strip

    private var allDayStrip: some View {
        // Compute strip height from the busiest column so the lane fits
        // exactly N rows + padding — never expands to fill the parent.
        let busiest = min(allDayMaxRows + 1, // +1 for the "+N" overflow row
                          weekDays.map { allDayItems(for: $0).count }.max() ?? 0)
        let visibleRows = min(busiest, allDayMaxRows + 1)
        let stripHeight = CGFloat(max(1, visibleRows)) * (allDayPillHeight + 2)
            + FlowTokens.spacingSM * 2

        return HStack(alignment: .top, spacing: 0) {
            Text("all-day")
                .flowFont(.micro)
                .foregroundColor(FlowTokens.textMuted)
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, FlowTokens.spacingSM)
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
                            Text("+\(items.count - allDayMaxRows)")
                                .flowFont(.micro)
                                .foregroundColor(FlowTokens.textMuted)
                                .frame(height: allDayPillHeight)
                                .padding(.leading, 4)
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
        HStack(spacing: 4) {
            Rectangle()
                .fill(item.displayColor)
                .frame(width: FlowTokens.accentBarWidth)
            Text(item.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(FlowTokens.textPrimary)
                .lineLimit(1)
                .padding(.trailing, 5)
            Spacer(minLength: 0)
        }
        .frame(height: allDayPillHeight)
        .background(
            RoundedRectangle(cornerRadius: FlowTokens.radiusControl - 2, style: .continuous)
                .fill(item.displayColor.opacity(FlowTokens.eventFillActive))
        )
        .overlay(
            RoundedRectangle(cornerRadius: FlowTokens.radiusControl - 2, style: .continuous)
                .strokeBorder(item.displayColor.opacity(0.38), lineWidth: FlowTokens.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: FlowTokens.radiusControl - 2, style: .continuous))
    }

    // MARK: - Hour grid

    private func hourGrid(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(startHour..<endHour, id: \.self) { hour in
                    HStack {
                        Text(hourLabel(hour))
                            .font(.system(size: 10, weight: .regular))
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
                    .fill(FlowTokens.bg1.opacity(0.5))
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

                        eventCard(item: item, columnWidth: columnWidth)
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

    // MARK: - Event card (polished)
    //
    // Apple Calendar / Things 3 hybrid:
    //   - Translucent tint fill + inner hairline (tint @ 0.38)
    //   - Solid left accent bar (3pt, rounded)
    //   - Subtle top-to-bottom highlight gradient adds depth
    //   - Tiny drop shadow for elevation
    //   - Hover: slight brightening
    //   - Drag: scaled up + shadow intensifies

    private func eventCard(item: any CalendarItemProtocol, columnWidth: CGFloat) -> some View {
        let status = blockStatus(for: item)
        let tint = item.displayColor
        let isHovered = hoveredItemID == item.calendarItemID
        let isDragging = draggingItemID == item.calendarItemID
        let fillAlpha: Double = {
            switch status {
            case .past:     return FlowTokens.eventFillPast
            case .now:      return FlowTokens.eventFillActive + (isHovered ? 0.04 : 0)
            case .upcoming: return FlowTokens.eventFillActive + (isHovered ? 0.04 : 0)
            }
        }()
        let strokeAlpha: Double = status == .past ? 0.28 : 0.42
        let textColor: Color = status == .past ? FlowTokens.textTertiary : FlowTokens.textPrimary
        let secondaryColor: Color = status == .past ? FlowTokens.textDisabled : FlowTokens.textTertiary
        let barColor: Color = status == .past ? tint.opacity(0.55) : tint

        return GeometryReader { geo in
            let h = geo.size.height
            let veryCompact = h < 24
            let compact = h < 40

            ZStack(alignment: .topLeading) {
                // Base translucent fill
                RoundedRectangle(cornerRadius: FlowTokens.radiusControl, style: .continuous)
                    .fill(tint.opacity(fillAlpha))

                // Inner highlight gradient for subtle depth
                RoundedRectangle(cornerRadius: FlowTokens.radiusControl, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.06), Color.white.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )

                // Inner tint hairline
                RoundedRectangle(cornerRadius: FlowTokens.radiusControl, style: .continuous)
                    .strokeBorder(tint.opacity(strokeAlpha), lineWidth: FlowTokens.hairline)

                // Content
                HStack(alignment: .top, spacing: 0) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(barColor)
                        .frame(width: 3)
                        .padding(.vertical, 3)

                    VStack(alignment: .leading, spacing: veryCompact ? 0 : 1) {
                        Text(item.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(textColor)
                            .strikethrough(item.isCompleted)
                            .lineLimit(veryCompact ? 1 : 2)
                            .tracking(-0.1)

                        if !compact {
                            Text(timeRangeString(item))
                                .font(.system(size: 9, weight: .medium))
                                .monospacedDigit()
                                .foregroundColor(secondaryColor)
                                .lineLimit(1)
                        }
                    }
                    .padding(.leading, 5)
                    .padding(.trailing, 6)
                    .padding(.vertical, veryCompact ? 1 : 4)

                    Spacer(minLength: 0)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: FlowTokens.radiusControl, style: .continuous))
            .shadow(
                color: Color.black.opacity(isDragging ? 0.35 : (status == .past ? 0 : 0.18)),
                radius: isDragging ? 6 : 0.8,
                x: 0,
                y: isDragging ? 4 : 0.5
            )
            .scaleEffect(isDragging ? 1.02 : 1.0)
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

                // Snap Y translation to 15-min increments
                let minutesPerPixel = 60.0 / Double(hourHeight)
                let rawMinutes = Double(value.translation.height) * minutesPerPixel
                let snappedMinutes = (rawMinutes / 15.0).rounded() * 15.0

                // Column shift → day delta
                let columnDelta = Int((value.translation.width / columnWidth).rounded())

                // No-op if nothing changed
                if abs(snappedMinutes) < 1 && columnDelta == 0 { return }

                let cal = Calendar.current
                var newStart = item.startDate.addingTimeInterval(snappedMinutes * 60)
                if columnDelta != 0 {
                    newStart = cal.date(byAdding: .day, value: columnDelta, to: newStart) ?? newStart
                }
                let duration = item.endDate.timeIntervalSince(item.startDate)
                let newEnd = newStart.addingTimeInterval(duration)

                // Route to the correct data store
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

    // MARK: - Detail popover

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
                .font(.system(size: 9, weight: .bold))
                .monospacedDigit()
                .foregroundColor(red)
                .padding(.horizontal, 4)
                .background(FlowTokens.bg0)
                .offset(x: FlowTokens.spacingSM, y: -8)

            Rectangle()
                .fill(red.opacity(0.75))
                .frame(height: FlowTokens.hairlineStrong)
                .padding(.leading, gutterWidth)

            Circle()
                .fill(red)
                .frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(FlowTokens.bg0, lineWidth: 1))
                .offset(x: gutterWidth + CGFloat(todayCol) * columnWidth - 4)
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
//
// SwiftUI's `popover(item:)` needs an Identifiable value. The calendar items
// are existential (`any CalendarItemProtocol`) which can't conform directly,
// so we wrap.
private struct AnyCalendarItem: Identifiable {
    let item: any CalendarItemProtocol
    var id: String { item.calendarItemID }
    init(_ item: any CalendarItemProtocol) { self.item = item }
}
