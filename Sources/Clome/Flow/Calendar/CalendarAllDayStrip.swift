import SwiftUI

/// Fixed-height all-day strip. Caps at `allDayMaxRows` rows and collapses
/// overflow into a `+N` chip that expands inline when tapped.
struct CalendarAllDayStrip: View {
    let days: [Date]
    let items: [any CalendarItemProtocol]
    @State private var expanded = false

    private let cal = Calendar.current

    var body: some View {
        let maxRows = CalendarGridGeometry.allDayMaxRows
        let rows = layoutRows()
        let visibleRows = expanded ? rows.count : min(rows.count, maxRows)
        let height = CGFloat(max(1, visibleRows)) * CalendarGridGeometry.allDayRowHeight + 8

        return HStack(spacing: 0) {
            Text("all-day")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.2)
                .foregroundColor(FlowTokens.textTertiary)
                .frame(width: CalendarGridGeometry.gutterWidth, alignment: .trailing)
                .padding(.trailing, 6)

            GeometryReader { geo in
                let colW = geo.size.width / 7
                ZStack(alignment: .topLeading) {
                    ForEach(Array(rows.prefix(visibleRows).enumerated()), id: \.offset) { rowIndex, row in
                        ForEach(row, id: \.id) { entry in
                            chip(for: entry.item)
                                .frame(
                                    width: colW * CGFloat(entry.span) - 4,
                                    height: CalendarGridGeometry.allDayRowHeight - 4
                                )
                                .offset(
                                    x: colW * CGFloat(entry.startCol) + 2,
                                    y: CGFloat(rowIndex) * CalendarGridGeometry.allDayRowHeight + 2
                                )
                        }
                    }
                    if rows.count > maxRows && !expanded {
                        Button {
                            withAnimation(.flowSpring) { expanded = true }
                        } label: {
                            Text("+\(rows.count - maxRows) more")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(FlowTokens.textTertiary)
                                .padding(.horizontal, 4)
                        }
                        .buttonStyle(.plain)
                        .offset(y: CGFloat(maxRows - 1) * CalendarGridGeometry.allDayRowHeight + 4)
                    }
                }
            }
        }
        .frame(height: height)
        .animation(.flowSpring, value: expanded)
    }

    // MARK: - Chip

    private func chip(for item: any CalendarItemProtocol) -> some View {
        let tint = item.displayColor
        return HStack(spacing: 0) {
            Rectangle().fill(tint.opacity(0.9)).frame(width: 2)
            Text(item.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(tint.opacity(0.95))
                .lineLimit(1)
                .padding(.horizontal, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(tint.opacity(0.14))
        )
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    // MARK: - Row layout

    private struct Entry {
        let id: String
        let item: any CalendarItemProtocol
        let startCol: Int
        let span: Int
    }

    private func layoutRows() -> [[Entry]] {
        let allDay = items.filter { $0.isAllDay }
        guard !allDay.isEmpty, !days.isEmpty else { return [] }

        let weekStart = cal.startOfDay(for: days.first!)
        let entries: [Entry] = allDay.compactMap { item in
            let startDay = cal.startOfDay(for: item.startDate)
            let endDay = cal.startOfDay(for: item.endDate)
            let startCol = cal.dateComponents([.day], from: weekStart, to: startDay).day ?? 0
            let endCol = cal.dateComponents([.day], from: weekStart, to: endDay).day ?? startCol
            let clampedStart = max(0, startCol)
            let clampedEnd = min(6, endCol)
            guard clampedEnd >= clampedStart else { return nil }
            return Entry(
                id: item.calendarItemID,
                item: item,
                startCol: clampedStart,
                span: clampedEnd - clampedStart + 1
            )
        }.sorted { a, b in
            if a.startCol != b.startCol { return a.startCol < b.startCol }
            return a.span > b.span
        }

        // Greedy row packing: place each entry in the first row where its
        // column range is free.
        var rows: [[Entry]] = []
        for entry in entries {
            var placed = false
            for r in 0..<rows.count {
                let conflict = rows[r].contains { existing in
                    !(entry.startCol + entry.span <= existing.startCol ||
                      existing.startCol + existing.span <= entry.startCol)
                }
                if !conflict {
                    rows[r].append(entry)
                    placed = true
                    break
                }
            }
            if !placed { rows.append([entry]) }
        }
        return rows
    }
}
