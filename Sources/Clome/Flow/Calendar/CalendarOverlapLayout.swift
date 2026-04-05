import SwiftUI

/// Result of overlap layout computation for a single calendar item.
struct LayoutSlot {
    let itemID: String       // matches CalendarItemProtocol.calendarItemID
    let column: Int          // 0-based column index within overlap group
    let totalColumns: Int    // total columns in this overlap group
    let startDate: Date
    let endDate: Date
}

/// Pure-function overlap layout engine for calendar items.
/// Caseless enum used as a namespace — no instances.
enum CalendarOverlapLayout {

    // MARK: - Overlap Layout Computation

    /// Computes overlap-aware column assignments for calendar items.
    ///
    /// Algorithm (sweep-line):
    /// 1. Filter out all-day items (they render in a separate section)
    /// 2. Sort by startDate, then by duration descending (longer events get priority)
    /// 3. Build overlap groups using sweep-line
    /// 4. Within each group, assign columns greedily
    /// 5. Return LayoutSlot for each item
    static func computeOverlapLayout(
        items: [(id: String, start: Date, end: Date, isAllDay: Bool)]
    ) -> [LayoutSlot] {
        // 1. Filter out all-day items
        let timedItems = items.filter { !$0.isAllDay }

        guard !timedItems.isEmpty else { return [] }

        // 2. Sort by startDate, then by duration descending
        let sorted = timedItems.sorted { a, b in
            if a.start == b.start {
                let durA = a.end.timeIntervalSince(a.start)
                let durB = b.end.timeIntervalSince(b.start)
                return durA > durB // longer events first
            }
            return a.start < b.start
        }

        // 3. Build overlap groups using sweep-line
        var groups: [[(id: String, start: Date, end: Date, isAllDay: Bool)]] = []
        var currentGroup: [(id: String, start: Date, end: Date, isAllDay: Bool)] = []
        var groupLatestEnd: Date = .distantPast

        for item in sorted {
            if currentGroup.isEmpty || item.start < groupLatestEnd {
                // Item overlaps with the current group
                currentGroup.append(item)
                let itemEnd = max(item.start, item.end) // handle zero-duration
                if itemEnd > groupLatestEnd {
                    groupLatestEnd = itemEnd
                }
            } else {
                // Finalize current group, start new one
                groups.append(currentGroup)
                currentGroup = [item]
                groupLatestEnd = max(item.start, item.end)
            }
        }
        if !currentGroup.isEmpty {
            groups.append(currentGroup)
        }

        // 4. Assign columns within each group
        var results: [LayoutSlot] = []

        for group in groups {
            // Track column assignments: column index -> list of (start, end) intervals
            var columnIntervals: [[(start: Date, end: Date)]] = []
            var assignments: [(item: (id: String, start: Date, end: Date, isAllDay: Bool), column: Int)] = []

            for item in group {
                let itemEnd = item.start == item.end ? item.end : item.end // keep original for slot

                // Find lowest column where no existing item overlaps
                var assignedColumn = -1
                for col in 0..<columnIntervals.count {
                    let overlaps = columnIntervals[col].contains { interval in
                        item.start < interval.end && item.end > interval.start
                    }
                    if !overlaps {
                        assignedColumn = col
                        break
                    }
                }

                if assignedColumn == -1 {
                    // Need a new column
                    assignedColumn = columnIntervals.count
                    columnIntervals.append([])
                }

                let effectiveEnd = item.end > item.start ? item.end : item.start.addingTimeInterval(1)
                columnIntervals[assignedColumn].append((start: item.start, end: effectiveEnd))
                assignments.append((item: item, column: assignedColumn))
            }

            let totalColumns = columnIntervals.count

            for assignment in assignments {
                results.append(LayoutSlot(
                    itemID: assignment.item.id,
                    column: assignment.column,
                    totalColumns: totalColumns,
                    startDate: assignment.item.start,
                    endDate: assignment.item.end
                ))
            }
        }

        return results
    }

    // MARK: - Geometry Helpers

    /// Computes the y-position for a given date within the day timeline.
    /// Returns the offset from the top of the timeline.
    ///
    /// - Parameters:
    ///   - date: The date/time to compute position for.
    ///   - hourHeight: The height in points of one hour in the timeline.
    ///   - startHour: The first visible hour in the timeline (e.g. 6 for 6 AM).
    /// - Returns: The y offset from the top of the timeline.
    static func yPosition(for date: Date, hourHeight: CGFloat, startHour: Int) -> CGFloat {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0

        let y = CGFloat(hour - startHour) * hourHeight + CGFloat(minute) / 60.0 * hourHeight

        // Clamp: items starting before startHour get y = 0
        return max(y, 0)
    }

    /// Computes the frame rect for a layout slot within available geometry.
    ///
    /// - Parameters:
    ///   - slot: The computed layout slot for the calendar item.
    ///   - hourHeight: The height in points of one hour in the timeline.
    ///   - startHour: The first visible hour in the timeline.
    ///   - availableWidth: Total width available for event columns (excluding gutter).
    ///   - gutterWidth: Width of the time-label gutter on the leading edge.
    /// - Returns: The frame rectangle for this slot.
    static func frame(
        for slot: LayoutSlot,
        hourHeight: CGFloat,
        startHour: Int,
        availableWidth: CGFloat,
        gutterWidth: CGFloat
    ) -> CGRect {
        let top = yPosition(for: slot.startDate, hourHeight: hourHeight, startHour: startHour)
        var bottom = yPosition(for: slot.endDate, hourHeight: hourHeight, startHour: startHour)

        // Clamp end to max visible area (24 hours from startHour)
        let maxY = CGFloat(24 - startHour) * hourHeight
        bottom = min(bottom, maxY)

        // Minimum height for zero-duration or very short items
        let height = max(bottom - top, hourHeight * 0.5)

        let slotWidth = availableWidth / CGFloat(slot.totalColumns)
        let x = gutterWidth + CGFloat(slot.column) * slotWidth

        return CGRect(x: x, y: top, width: slotWidth - 1, height: height)
    }
}
