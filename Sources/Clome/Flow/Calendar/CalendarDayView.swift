import SwiftUI
import ClomeModels

// MARK: - Calendar Day View

/// Main day timeline view with overlap-aware event rendering,
/// item type distinction (events, todos, deadlines, reminders),
/// tap-to-create, drag-to-move, drag-to-resize, and tap-to-edit support.
struct CalendarDayView: View {
    @ObservedObject var dataManager: CalendarDataManager
    @Binding var showCreationPopover: Bool
    @Binding var creationTime: Date?

    @State private var selectedItemID: String?
    @State private var selectedItemRect: CGRect = .zero
    @State private var draggedItemID: String?
    @State private var dragOffset: CGFloat = 0
    @State private var resizingItemID: String?
    @State private var resizeOffset: CGFloat = 0
    @State private var currentTime = Date()
    @ObservedObject private var syncService = FlowSyncService.shared

    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private let startHour = 6
    private let endHour = 24
    private let hourHeight = FlowTokens.dayHourHeight   // 28pt
    private let gutterWidth = FlowTokens.gutterWidth     // 36pt

    private var timelineHeight: CGFloat {
        CGFloat(endHour - startHour) * hourHeight
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(dataManager.selectedDate)
    }

    private var allDayItems: [any CalendarItemProtocol] {
        let cal = Calendar.current
        return dataManager.items.filter { item in
            item.isAllDay && cal.isDate(item.startDate, inSameDayAs: dataManager.selectedDate)
        }
    }

    private var timedItems: [any CalendarItemProtocol] {
        let cal = Calendar.current
        return dataManager.items.filter { item in
            !item.isAllDay && cal.isDate(item.startDate, inSameDayAs: dataManager.selectedDate)
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if !allDayItems.isEmpty {
                allDaySection
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    GeometryReader { geo in
                        let eventAreaWidth = geo.size.width - gutterWidth

                        ZStack(alignment: .topLeading) {
                            // Layer 1: Hour grid
                            hourGrid

                            // Layer 2: Event blocks (ON TOP of grid, receives taps first)
                            eventBlocks(availableWidth: eventAreaWidth)

                            // Layer 3: Now indicator
                            if isToday {
                                nowIndicator(totalWidth: geo.size.width)
                                    .allowsHitTesting(false)
                            }

                            // Layer 4: Detail overlay positioned at the selected event
                            if let selectedID = selectedItemID,
                               let item = findItem(selectedID) {
                                let popoverWidth: CGFloat = 260
                                let popoverEstHeight: CGFloat = 200
                                // Position to the right of the event, or left if not enough space
                                let rightX = selectedItemRect.maxX + 8
                                let leftX = selectedItemRect.minX - popoverWidth - 8
                                let fitsRight = rightX + popoverWidth <= geo.size.width
                                let anchorX = fitsRight ? rightX : max(0, leftX)
                                // Center vertically on the event, clamped to timeline bounds
                                let anchorY = min(
                                    max(selectedItemRect.midY - popoverEstHeight / 2, 0),
                                    timelineHeight - popoverEstHeight
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
                        .frame(width: geo.size.width, height: timelineHeight)
                        .contentShape(Rectangle())
                        // Background tap: only fires when no event block intercepts
                        .onTapGesture { location in
                            if selectedItemID != nil {
                                selectedItemID = nil
                            } else {
                                handleTimelineTap(at: location)
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
        .onReceive(timer) { currentTime = $0 }
    }

    // MARK: - All-Day Section

    private var allDaySection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: FlowTokens.spacingSM) {
                ForEach(allDayItems, id: \.calendarItemID) { item in
                    allDayPill(for: item)
                        .onTapGesture {
                            selectedItemID = (selectedItemID == item.calendarItemID) ? nil : item.calendarItemID
                        }
                        .popover(
                            isPresented: Binding(
                                get: { selectedItemID == item.calendarItemID },
                                set: { if !$0 { selectedItemID = nil } }
                            ),
                            arrowEdge: .bottom
                        ) {
                            CalendarEventDetailPopover(item: item) {
                                selectedItemID = nil
                            }
                        }
                }
            }
            .padding(.horizontal, FlowTokens.spacingMD)
            .padding(.vertical, FlowTokens.spacingSM)
        }
        .frame(maxHeight: 24)
        .background(FlowTokens.bg1)
        .overlay(
            Rectangle().fill(FlowTokens.border).frame(height: 0.5),
            alignment: .bottom
        )
    }

    private func allDayPill(for item: any CalendarItemProtocol) -> some View {
        Text(item.title)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(FlowTokens.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, FlowTokens.spacingMD)
            .padding(.vertical, FlowTokens.spacingXS)
            .background(
                RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                    .fill(item.displayColor.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                    .stroke(item.displayColor.opacity(0.3), lineWidth: 0.5)
            )
    }

    // MARK: - Hour Grid

    private var hourGrid: some View {
        VStack(spacing: 0) {
            ForEach(startHour..<endHour, id: \.self) { hour in
                hourRow(hour: hour)
            }
        }
    }

    private func hourRow(hour: Int) -> some View {
        let currentHour = Calendar.current.component(.hour, from: currentTime)
        let isPast = isToday && hour < currentHour
        let labelColor = isPast ? FlowTokens.textDisabled : FlowTokens.textHint

        return HStack(alignment: .top, spacing: 0) {
            Text(hourLabel(for: hour))
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundColor(labelColor)
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, FlowTokens.spacingSM)
                .offset(y: -5)

            VStack(spacing: 0) {
                Rectangle()
                    .fill(FlowTokens.hourGridLine)
                    .frame(height: 0.5)
                Spacer()
            }
        }
        .frame(height: hourHeight)
    }

    private func hourLabel(for hour: Int) -> String {
        if hour == 0 || hour == 24 { return "12a" }
        if hour < 12 { return "\(hour)a" }
        if hour == 12 { return "12p" }
        return "\(hour - 12)p"
    }

    // MARK: - Event Blocks (offset-based layout)

    private func eventBlocks(availableWidth: CGFloat) -> some View {
        let items = timedItems
        let tuples = items.map { (id: $0.calendarItemID, start: $0.startDate, end: $0.endDate, isAllDay: $0.isAllDay) }
        let slots = CalendarOverlapLayout.computeOverlapLayout(items: tuples)
        let itemDict = Dictionary(uniqueKeysWithValues: items.map { ($0.calendarItemID, $0) })

        return ZStack(alignment: .topLeading) {
            ForEach(slots, id: \.itemID) { slot in
                if let item = itemDict[slot.itemID] {
                    let rect = CalendarOverlapLayout.frame(
                        for: slot,
                        hourHeight: hourHeight,
                        startHour: startHour,
                        availableWidth: availableWidth,
                        gutterWidth: gutterWidth
                    )
                    eventBlockWithInteractions(item: item, rect: rect)
                }
            }
        }
    }

    /// Single event block with all interactions: tap, drag-to-move, resize handle.
    /// Uses `.offset()` for correct positioning (origin-based, not center-based).
    private func eventBlockWithInteractions(item: any CalendarItemProtocol, rect: CGRect) -> some View {
        let isDragging = draggedItemID == item.calendarItemID
        let isResizing = resizingItemID == item.calendarItemID
        let yOffset = isDragging ? dragOffset : 0.0
        let heightDelta = isResizing ? resizeOffset : 0.0
        let effectiveHeight = max(rect.height + heightDelta, hourHeight * 0.4)
        let canDrag = item.kind == .systemEvent || item.kind == .todo

        return ZStack(alignment: .topLeading) {
            // The event block itself
            eventBlock(for: item, frame: CGRect(x: 0, y: 0, width: rect.width, height: effectiveHeight))
                .frame(width: rect.width, height: effectiveHeight)
                .contentShape(Rectangle())
                .opacity(isDragging ? 0.75 : 1.0)
                .shadow(color: isDragging ? Color.black.opacity(0.3) : .clear, radius: 4, y: 2)
                // Resize handle at bottom edge
                .overlay(alignment: .bottom) {
                    if canDrag && rect.height > 18 {
                        resizeHandle(item: item, rect: rect)
                    }
                }

            // Live time label during drag
            if isDragging {
                dragTimeLabel(item: item)
            }

            // Live time label during resize
            if isResizing {
                resizeTimeLabel(item: item, effectiveHeight: effectiveHeight)
            }
        }
        // Position using offset (origin-based — top-left corner)
        .offset(x: rect.origin.x, y: rect.origin.y + yOffset)
        // Tap to select for detail overlay
        .onTapGesture {
            if selectedItemID == item.calendarItemID {
                selectedItemID = nil
            } else {
                selectedItemID = item.calendarItemID
                selectedItemRect = CGRect(
                    x: rect.origin.x,
                    y: rect.origin.y + yOffset,
                    width: rect.width,
                    height: effectiveHeight
                )
            }
        }
        // Drag to move (separate gesture with higher minimum distance)
        .gesture(
            canDrag ?
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    draggedItemID = item.calendarItemID
                    dragOffset = value.translation.height
                }
                .onEnded { value in
                    handleDragEnd(item: item, offset: value.translation.height, rect: rect)
                    draggedItemID = nil
                    dragOffset = 0
                }
            : nil
        )
    }

    // MARK: - Resize Handle

    private func resizeHandle(item: any CalendarItemProtocol, rect: CGRect) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 8)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        resizingItemID = item.calendarItemID
                        resizeOffset = value.translation.height
                    }
                    .onEnded { value in
                        handleResizeEnd(item: item, offset: value.translation.height, rect: rect)
                        resizingItemID = nil
                        resizeOffset = 0
                    }
            )
    }

    // MARK: - Drag/Resize Time Labels

    private func dragTimeLabel(item: any CalendarItemProtocol) -> some View {
        let minuteOffset = Double(dragOffset / hourHeight) * 60
        let roundedMinutes = (Int(minuteOffset) / 15) * 15
        let newStart = Calendar.current.date(byAdding: .minute, value: roundedMinutes, to: item.startDate) ?? item.startDate

        return Text(timeString(newStart))
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundColor(FlowTokens.accent)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(FlowTokens.bg3.cornerRadius(3))
            .offset(y: -14)
    }

    private func resizeTimeLabel(item: any CalendarItemProtocol, effectiveHeight: CGFloat) -> some View {
        let newEnd = computeNewEndDate(from: item, offset: resizeOffset, rect: .zero)

        return Text(timeString(newEnd))
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundColor(FlowTokens.accent)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(FlowTokens.bg3.cornerRadius(3))
            .offset(y: effectiveHeight + 2)
    }

    // MARK: - Event Block Rendering

    @ViewBuilder
    private func eventBlock(for item: any CalendarItemProtocol, frame rect: CGRect) -> some View {
        switch item.kind {
        case .systemEvent:
            systemEventBlock(item: item, frame: rect)
        case .todo:
            todoBlock(item: item, frame: rect)
        case .deadline:
            deadlineMarker(item: item, frame: rect)
        case .reminder:
            reminderMarker(item: item, frame: rect)
        }
    }

    private func systemEventBlock(item: any CalendarItemProtocol, frame rect: CGRect) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(item.displayColor)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(FlowTokens.textPrimary)
                    .lineLimit(2)

                if rect.height > 20 {
                    Text(timeRangeString(start: item.startDate, end: item.endDate))
                        .font(.system(size: 8, weight: .regular, design: .monospaced))
                        .foregroundColor(FlowTokens.textMuted)
                        .lineLimit(1)
                }
            }
            .padding(.leading, FlowTokens.spacingSM)
            .padding(.vertical, FlowTokens.spacingXS)

            Spacer(minLength: 0)
        }
        .frame(width: rect.width, height: rect.height)
        .background(
            RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                .fill(item.displayColor.opacity(0.10))
        )
        .clipShape(RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous))
    }

    private func todoBlock(item: any CalendarItemProtocol, frame rect: CGRect) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(FlowTokens.calendarTodo)
                .frame(width: 4)

            HStack(spacing: FlowTokens.spacingSM) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 9))
                    .foregroundColor(item.isCompleted ? FlowTokens.calendarTodo : FlowTokens.textTertiary)

                Text(item.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(item.isCompleted ? FlowTokens.textTertiary : FlowTokens.textPrimary)
                    .strikethrough(item.isCompleted)
                    .lineLimit(2)
            }
            .padding(.leading, FlowTokens.spacingSM)
            .padding(.vertical, FlowTokens.spacingXS)

            Spacer(minLength: 0)
        }
        .frame(width: rect.width, height: rect.height)
        .background(
            RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                .fill(FlowTokens.calendarTodo.opacity(0.10))
        )
        .clipShape(RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous))
    }

    private func deadlineMarker(item: any CalendarItemProtocol, frame rect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(item.displayColor)
                .frame(width: rect.width, height: 1.5)

            HStack(spacing: FlowTokens.spacingXS) {
                Image(systemName: "flag.fill")
                    .font(.system(size: 9))
                    .foregroundColor(item.displayColor)
                Text(item.title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(item.displayColor)
                    .lineLimit(1)
            }
            .offset(y: 2)
        }
        .frame(width: rect.width, height: max(rect.height, 16))
    }

    private func reminderMarker(item: any CalendarItemProtocol, frame rect: CGRect) -> some View {
        HStack(spacing: FlowTokens.spacingSM) {
            Rectangle()
                .fill(FlowTokens.calendarReminder)
                .frame(width: 6, height: 6)
                .rotationEffect(.degrees(45))

            Text(item.title)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(FlowTokens.calendarReminder)
                .lineLimit(1)
        }
        .frame(width: rect.width, height: max(rect.height, 14), alignment: .leading)
        .padding(.leading, FlowTokens.spacingSM)
    }

    // MARK: - Now Indicator

    private func nowIndicator(totalWidth: CGFloat) -> some View {
        let yPos = CalendarOverlapLayout.yPosition(
            for: currentTime, hourHeight: hourHeight, startHour: startHour
        )

        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(FlowTokens.accent)
                .frame(width: totalWidth - gutterWidth, height: 1.5)
                .offset(x: gutterWidth)

            Circle()
                .fill(FlowTokens.accent)
                .frame(width: 8, height: 8)
                .offset(x: gutterWidth - 4)

            Text("NOW")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(FlowTokens.accent)
                .offset(x: totalWidth - 28)
        }
        .offset(y: yPos)
    }

    // MARK: - Tap-to-Create (on empty space)

    private func handleTimelineTap(at location: CGPoint) {
        // Ignore taps on the gutter
        guard location.x > gutterWidth else { return }

        let tapY = location.y
        let rawHour = startHour + Int(tapY / hourHeight)
        let fractionalMinute = (tapY.truncatingRemainder(dividingBy: hourHeight) / hourHeight) * 60
        let roundedMinute = (Int(fractionalMinute) / 15) * 15
        let hour = min(max(rawHour, startHour), endHour - 1)
        let minute = min(roundedMinute, 45)

        let cal = Calendar.current
        var components = cal.dateComponents([.year, .month, .day], from: dataManager.selectedDate)
        components.hour = hour
        components.minute = minute
        components.second = 0

        if let date = cal.date(from: components) {
            creationTime = date
            showCreationPopover = true
        }
    }

    // MARK: - Scroll to Current Hour

    private func scrollToCurrentHour(proxy: ScrollViewProxy) {
        guard isToday else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.flowQuick) {
                proxy.scrollTo("timeline", anchor: .top)
            }
        }
    }

    // MARK: - Drag & Resize Handlers

    private func handleDragEnd(item: any CalendarItemProtocol, offset: CGFloat, rect: CGRect) {
        let minuteOffset = Double(offset / hourHeight) * 60
        let roundedMinutes = (Int(minuteOffset) / 15) * 15

        guard let newStart = Calendar.current.date(byAdding: .minute, value: roundedMinutes, to: item.startDate),
              let newEnd = Calendar.current.date(byAdding: .minute, value: roundedMinutes, to: item.endDate)
        else { return }

        switch item.kind {
        case .systemEvent:
            if let sysItem = item as? SystemEventItem {
                dataManager.moveSystemEvent(identifier: sysItem.eventIdentifier, newStart: newStart, newEnd: newEnd)
            }
        case .todo:
            if let todoItem = item as? ScheduledTodoItem {
                syncService.updateTodoSchedule(id: todoItem.todo.id, scheduledDate: newStart, scheduledEndDate: newEnd)
            }
        default: break
        }
    }

    private func handleResizeEnd(item: any CalendarItemProtocol, offset: CGFloat, rect: CGRect) {
        let minuteOffset = Double(offset / hourHeight) * 60
        let roundedMinutes = (Int(minuteOffset) / 15) * 15

        guard let newEnd = Calendar.current.date(byAdding: .minute, value: roundedMinutes, to: item.endDate)
        else { return }

        let minEnd = item.startDate.addingTimeInterval(900)
        let finalEnd = max(newEnd, minEnd)

        switch item.kind {
        case .systemEvent:
            if let sysItem = item as? SystemEventItem {
                dataManager.resizeSystemEvent(identifier: sysItem.eventIdentifier, newEnd: finalEnd)
            }
        case .todo:
            if let todoItem = item as? ScheduledTodoItem {
                syncService.updateTodoSchedule(id: todoItem.todo.id, scheduledDate: item.startDate, scheduledEndDate: finalEnd)
            }
        default: break
        }
    }

    private func computeNewEndDate(from item: any CalendarItemProtocol, offset: CGFloat, rect: CGRect) -> Date {
        let minuteOffset = Double(offset / hourHeight) * 60
        let roundedMinutes = (Int(minuteOffset) / 15) * 15
        return Calendar.current.date(byAdding: .minute, value: roundedMinutes, to: item.endDate) ?? item.endDate
    }

    // MARK: - Helpers

    private func findItem(_ id: String) -> (any CalendarItemProtocol)? {
        dataManager.items.first { $0.calendarItemID == id }
    }

    private func timeRangeString(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mma"
        formatter.amSymbol = "a"
        formatter.pmSymbol = "p"
        return "\(formatter.string(from: start).lowercased())–\(formatter.string(from: end).lowercased())"
    }

    private func timeString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        return fmt.string(from: date)
    }
}
