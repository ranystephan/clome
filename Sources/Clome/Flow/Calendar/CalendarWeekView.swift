import SwiftUI
import UniformTypeIdentifiers

/// Week view — M1 rewrite. Renders Blocks from `BlockStore` (which merges
/// native blocks with EventKit events, todos, deadlines, and reminders).
///
/// Interactions so far:
///   • Tap empty timeline → inline create (native block)
///   • Tap card → select (hairline ring + × delete)
///   • Double-tap card → inline title edit
///   • Background tap commits/dismisses create or edit
///
/// Drag, resize, pinned-card strip, and drop targets land in M2.
struct CalendarWeekView: View {
    @ObservedObject var dataManager: CalendarDataManager
    @ObservedObject private var store = BlockStore.shared

    @State private var now = Date()
    @State private var createDraft: CreateDraft?
    @State private var createTitle: String = ""
    @State private var editingID: String?
    @State private var editingTitle: String = ""
    @State private var hoveredID: String?
    @State private var dropTargetedDay: Date?
    @State private var pendingDropY: CGFloat = 0

    // Drag / resize state
    @State private var dragID: String?
    @State private var dragTranslation: CGSize = .zero
    @State private var dragMode: DragMode = .move
    @State private var dragColumnWidth: CGFloat = 0

    enum DragMode { case move, resizeTop, resizeBottom }

    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    struct CreateDraft: Equatable {
        let day: Date
        let start: Date
        let end: Date
    }

    private var days: [Date] {
        if dataManager.viewMode == .day {
            return [Calendar.current.startOfDay(for: dataManager.selectedDate)]
        }
        return CalendarGridGeometry.weekDays(containing: dataManager.selectedDate)
    }

    private var isDay: Bool { dataManager.viewMode == .day }

    var body: some View {
        VStack(spacing: 0) {
            CalendarWeekHeader(
                days: days,
                selectedDate: dataManager.selectedDate,
                onSelect: { dataManager.selectedDate = $0 }
            )

            CalendarAllDayStrip(days: days, blocks: store.blocks.filter { $0.isAllDay })
                .overlay(alignment: .bottom) {
                    Rectangle().fill(FlowTokens.border).frame(height: FlowTokens.hairline)
                }

            PinnedStrip(days: days, blocks: store.blocks)
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
                    DispatchQueue.main.async {
                        proxy.scrollTo("timeline", anchor: .top)
                    }
                }
            }
        }
        .background(FlowTokens.bg0)
        .onReceive(ticker) { now = $0 }
        .background {
            // Hidden keyboard shortcut buttons (Apple-quiet way to wire
            // global shortcuts without fighting first responder).
            Group {
                Button("") { store.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                Button("") { store.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                Button("") { deleteSelected() }
                    .keyboardShortcut(.delete, modifiers: [])
                Button("") { store.selectedBlockID = nil }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .opacity(0)
            .allowsHitTesting(false)
            .frame(width: 0, height: 0)
        }
    }

    private func deleteSelected() {
        guard editingID == nil, createDraft == nil,
              let id = store.selectedBlockID,
              let block = store.block(withID: id) else { return }
        deleteBlock(block)
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
        let timed = store.blocks.filter { b in
            !b.isAllDay && !b.isPinned && cal.isDate(b.start, inSameDayAs: day)
        }
        let slots = CalendarOverlapLayout.layout(timed.map(BlockLayoutItem.init))

        let isTargeted = dropTargetedDay.map { cal.isDate($0, inSameDayAs: day) } ?? false

        return ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    handleBackgroundTap(day: day, y: location.y)
                }
                .onDrop(
                    of: [.fileURL, .url, .text],
                    delegate: TimeGridDropDelegate(
                        day: day,
                        onTargeted: { isIn, y in
                            dropTargetedDay = isIn ? day : nil
                            pendingDropY = y
                        },
                        onDrop: { providers, y in
                            handleTimeGridDrop(providers: providers, day: day, y: y)
                        }
                    )
                )

            if isTargeted {
                // Subtle accent wash + horizontal line showing the snap point.
                Rectangle()
                    .fill(FlowTokens.accent.opacity(0.06))
                    .frame(maxHeight: .infinity)
                Rectangle()
                    .fill(FlowTokens.accent.opacity(0.55))
                    .frame(height: 1)
                    .offset(y: snappedDropY(pendingDropY))
            }

            if !isDay && index < 6 {
                Rectangle()
                    .fill(FlowTokens.border.opacity(0.5))
                    .frame(width: FlowTokens.hairline)
                    .frame(maxHeight: .infinity, alignment: .topTrailing)
                    .offset(x: width - FlowTokens.hairline)
            }

            ForEach(timed) { block in
                draggableCard(block: block, slots: slots, columnWidth: width)
            }

            // Inline create ghost card
            if let draft = createDraft, cal.isDate(draft.day, inSameDayAs: day) {
                CalendarInlineCreate(
                    start: draft.start,
                    end: draft.end,
                    title: $createTitle,
                    onCommit: commitCreate,
                    onCancel: cancelCreate
                )
                .frame(
                    width: width - 4,
                    height: max(24, CalendarGridGeometry.height(from: draft.start, to: draft.end) - 1)
                )
                .offset(x: 2, y: CalendarGridGeometry.y(for: draft.start))
            }
        }
    }

    // MARK: - Draggable card

    private func draggableCard(block: Block,
                                slots: [String: CalendarOverlapLayout.Slot],
                                columnWidth: CGFloat) -> some View {
        let slot = slots[block.id] ?? CalendarOverlapLayout.Slot(column: 0, columnCount: 1)
        let slotW = max(20, (columnWidth - 4) / CGFloat(slot.columnCount))
        let baseX = 2 + slotW * CGFloat(slot.column)
        let baseY = CalendarGridGeometry.y(for: block.start)
        let baseH = CalendarGridGeometry.height(from: block.start, to: block.end)
        let past = block.end < now
        let id = block.id
        let isDragging = dragID == id
        let frame = liveFrame(baseX: baseX, baseY: baseY, baseH: baseH, isDragging: isDragging)
        let x = frame.0, y = frame.1, h = frame.2

        return BlockCard(
            block: block,
            isPast: past,
            isHovered: hoveredID == id,
            isSelected: store.selectedBlockID == id && editingID != id,
            isRunning: store.runningBlockID == id,
            isEditing: editingID == id,
            editingTitle: editingID == id ? $editingTitle : nil,
            onCommit: { commitEdit(block) },
            onDelete: { deleteBlock(block) }
        )
        .frame(width: slotW - 2, height: h)
        .scaleEffect(isDragging && dragMode == .move ? 1.02 : 1.0)
        .opacity(isDragging ? 0.92 : 1.0)
        .offset(x: x, y: y)
        .zIndex(isDragging ? 10 : 0)
        .overlay(alignment: .top) {
            resizeHandle(edge: .resizeTop, block: block, width: slotW - 2)
                .offset(x: x, y: y)
        }
        .overlay(alignment: .top) {
            resizeHandle(edge: .resizeBottom, block: block, width: slotW - 2)
                .offset(x: x, y: y + h - 6)
        }
        .onHover { hoveredID = $0 ? id : (hoveredID == id ? nil : hoveredID) }
        .onTapGesture(count: 2) { beginEdit(block) }
        .onTapGesture { store.selectedBlockID = id }
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .local)
                .onChanged { v in
                    if dragID != id {
                        dragID = id
                        dragMode = .move
                        dragColumnWidth = columnWidth
                        store.selectedBlockID = id
                    }
                    if dragMode == .move {
                        dragTranslation = v.translation
                    }
                }
                .onEnded { v in
                    guard dragID == id else { return }
                    if dragMode == .move {
                        commitMoveDrag(block: block, translation: v.translation, columnWidth: dragColumnWidth)
                    }
                    clearDrag()
                }
        )
    }

    private func liveFrame(baseX: CGFloat, baseY: CGFloat, baseH: CGFloat, isDragging: Bool)
        -> (CGFloat, CGFloat, CGFloat) {
        guard isDragging else { return (baseX, baseY, baseH) }
        var x = baseX, y = baseY, h = baseH
        switch dragMode {
        case .move:
            x += dragTranslation.width
            y += dragTranslation.height
        case .resizeTop:
            let dy = dragTranslation.height
            y += dy
            h -= dy
        case .resizeBottom:
            h += dragTranslation.height
        }
        return (x, y, max(18, h))
    }

    private func resizeHandle(edge: DragMode, block: Block, width: CGFloat) -> some View {
        let id = block.id
        // Only show resize handles on the currently selected/hovered card.
        let visible = store.selectedBlockID == id || hoveredID == id
        let isNS = edge == .resizeTop || edge == .resizeBottom
        return Color.clear
            .frame(width: width, height: 6)
            .contentShape(Rectangle())
            .opacity(visible ? 1 : 0)
            .onHover { if $0 && isNS { NSCursor.resizeUpDown.push() } else if isNS { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .local)
                    .onChanged { v in
                        if dragID != id {
                            dragID = id
                            dragMode = edge
                            store.selectedBlockID = id
                        }
                        dragTranslation = v.translation
                    }
                    .onEnded { v in
                        guard dragID == id else { return }
                        commitResizeDrag(block: block, translation: v.translation, edge: edge)
                        clearDrag()
                    }
            )
    }

    private func clearDrag() {
        dragID = nil
        dragTranslation = .zero
        dragMode = .move
    }

    private func snapMinutes(_ pixels: CGFloat) -> Int {
        let totalMin = Int((pixels / CalendarGridGeometry.hourHeight) * 60)
        let snap = CalendarGridGeometry.snapMinutes
        return (totalMin / snap) * snap
    }

    private func commitMoveDrag(block: Block, translation: CGSize, columnWidth: CGFloat) {
        let colDelta = columnWidth > 0 && !isDay
            ? Int((translation.width / columnWidth).rounded())
            : 0
        let minDelta = snapMinutes(translation.height)
        let cal = Calendar.current
        var newStart = block.start
        if colDelta != 0 {
            newStart = cal.date(byAdding: .day, value: colDelta, to: newStart) ?? newStart
        }
        newStart = cal.date(byAdding: .minute, value: minDelta, to: newStart) ?? newStart
        let newEnd = newStart.addingTimeInterval(block.end.timeIntervalSince(block.start))
        guard newStart != block.start || newEnd != block.end else { return }
        store.moveBlock(id: block.id, newStart: newStart, newEnd: newEnd)
    }

    private func commitResizeDrag(block: Block, translation: CGSize, edge: DragMode) {
        let minDelta = snapMinutes(translation.height)
        guard minDelta != 0 else { return }
        let cal = Calendar.current
        var newStart = block.start
        var newEnd = block.end
        switch edge {
        case .resizeTop:
            newStart = cal.date(byAdding: .minute, value: minDelta, to: newStart) ?? newStart
            if newEnd.timeIntervalSince(newStart) < 15 * 60 {
                newStart = newEnd.addingTimeInterval(-15 * 60)
            }
        case .resizeBottom:
            newEnd = cal.date(byAdding: .minute, value: minDelta, to: newEnd) ?? newEnd
            if newEnd.timeIntervalSince(newStart) < 15 * 60 {
                newEnd = newStart.addingTimeInterval(15 * 60)
            }
        case .move:
            return
        }
        store.moveBlock(id: block.id, newStart: newStart, newEnd: newEnd)
    }

    // MARK: - Interactions

    private func handleBackgroundTap(day: Date, y: CGFloat) {
        if createDraft != nil { commitCreate(); return }
        if editingID != nil { commitEditCurrent(); return }
        if store.selectedBlockID != nil { store.selectedBlockID = nil; return }

        let start = CalendarGridGeometry.time(forY: y, onDay: day)
        let end = start.addingTimeInterval(60 * 60)
        createTitle = ""
        withAnimation(.flowSpring) {
            createDraft = CreateDraft(day: Calendar.current.startOfDay(for: day), start: start, end: end)
        }
    }

    private func commitCreate() {
        guard let draft = createDraft else { return }
        let title = createTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            store.create(title: title, start: draft.start, end: draft.end)
        }
        createDraft = nil
        createTitle = ""
    }

    private func cancelCreate() {
        withAnimation(.flowQuick) {
            createDraft = nil
            createTitle = ""
        }
    }

    private func beginEdit(_ block: Block) {
        guard block.isEditable else { return }
        store.selectedBlockID = block.id
        editingID = block.id
        editingTitle = block.title
    }

    private func commitEdit(_ block: Block) {
        let trimmed = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != block.title {
            store.updateAny(id: block.id, title: trimmed)
        }
        editingID = nil
    }

    private func commitEditCurrent() {
        guard let id = editingID,
              let block = store.block(withID: id) else {
            editingID = nil
            return
        }
        commitEdit(block)
    }

    private func deleteBlock(_ block: Block) {
        store.deleteAny(id: block.id)
        store.selectedBlockID = nil
        editingID = nil
    }

    // MARK: - Time-grid drop

    private func snappedDropY(_ y: CGFloat) -> CGFloat {
        let slot = CalendarGridGeometry.hourHeight / 4  // 15-min slots
        return (y / slot).rounded() * slot
    }

    private func handleTimeGridDrop(providers: [NSItemProvider], day: Date, y: CGFloat) -> Bool {
        let start = CalendarGridGeometry.time(forY: y, onDay: day)
        let end = start.addingTimeInterval(60 * 60)
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data = data as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        store.create(
                            title: url.lastPathComponent,
                            start: start, end: end,
                            kind: .focus,
                            attachments: [.file(path: url.path)]
                        )
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.url.identifier) { data, _ in
                    var url: URL?
                    if let d = data as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                    else if let u = data as? URL { url = u }
                    guard let u = url else { return }
                    Task { @MainActor in
                        store.create(
                            title: u.host ?? u.absoluteString,
                            start: start, end: end,
                            kind: .focus,
                            attachments: [.url(u)]
                        )
                    }
                }
            }
        }
        dropTargetedDay = nil
        return handled
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

// MARK: - Drop delegate with location

/// DropDelegate that tracks the drop point's Y coordinate so the week view
/// can create the dropped block at the exact snapped time.
private struct TimeGridDropDelegate: DropDelegate {
    let day: Date
    let onTargeted: (Bool, CGFloat) -> Void
    let onDrop: ([NSItemProvider], CGFloat) -> Bool

    func dropEntered(info: DropInfo) {
        onTargeted(true, info.location.y)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        onTargeted(true, info.location.y)
        return DropProposal(operation: .copy)
    }
    func dropExited(info: DropInfo) {
        onTargeted(false, info.location.y)
    }
    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL, .url, .text])
    }
    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL, .url, .text])
        return onDrop(providers, info.location.y)
    }
}

// MARK: - Overlap layout adapter

/// Thin wrapper so the existing CalendarOverlapLayout (which takes a
/// `CalendarItemProtocol`) can sort Blocks without knowing the type.
private struct BlockLayoutItem: CalendarItemProtocol {
    let block: Block
    init(_ b: Block) { self.block = b }
    var calendarItemID: String { block.id }
    var title: String { block.title }
    var startDate: Date { block.start }
    var endDate: Date { block.end }
    var isAllDay: Bool { block.isAllDay }
    var kind: CalendarItemKind { .systemEvent }  // irrelevant for layout
    var displayColor: Color { block.color }
    var isCompleted: Bool { block.isCompleted }
}
