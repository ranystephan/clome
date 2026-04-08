import SwiftUI

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
    @State private var selectedID: String?
    @State private var editingID: String?
    @State private var editingTitle: String = ""
    @State private var hoveredID: String?
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

        return ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    handleBackgroundTap(day: day, y: location.y)
                }

            if !isDay && index < 6 {
                Rectangle()
                    .fill(FlowTokens.border.opacity(0.5))
                    .frame(width: FlowTokens.hairline)
                    .frame(maxHeight: .infinity, alignment: .topTrailing)
                    .offset(x: width - FlowTokens.hairline)
            }

            ForEach(timed) { block in
                let slot = slots[block.id] ?? CalendarOverlapLayout.Slot(column: 0, columnCount: 1)
                let slotW = max(20, (width - 4) / CGFloat(slot.columnCount))
                let x = 2 + slotW * CGFloat(slot.column)
                let y = CalendarGridGeometry.y(for: block.start)
                let h = CalendarGridGeometry.height(from: block.start, to: block.end)
                let past = block.end < now
                let id = block.id

                BlockCard(
                    block: block,
                    isPast: past,
                    isHovered: hoveredID == id,
                    isSelected: selectedID == id && editingID != id,
                    isEditing: editingID == id,
                    editingTitle: editingID == id ? $editingTitle : nil,
                    onCommit: { commitEdit(block) },
                    onDelete: { deleteBlock(block) }
                )
                .frame(width: slotW - 2, height: max(18, h - 1))
                .offset(x: x, y: y)
                .onHover { hoveredID = $0 ? id : (hoveredID == id ? nil : hoveredID) }
                .onTapGesture(count: 2) { beginEdit(block) }
                .onTapGesture { selectedID = id }
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

    // MARK: - Interactions

    private func handleBackgroundTap(day: Date, y: CGFloat) {
        if createDraft != nil { commitCreate(); return }
        if editingID != nil { commitEditCurrent(); return }
        if selectedID != nil { selectedID = nil; return }

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
        selectedID = block.id
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
        selectedID = nil
        editingID = nil
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
