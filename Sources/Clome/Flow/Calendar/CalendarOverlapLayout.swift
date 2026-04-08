import Foundation

/// Resolves horizontal positioning for overlapping timed items using a
/// simple sweep-line column-assignment algorithm.
///
/// Output: for each item, a `(column, columnCount)` pair inside its
/// overlap group. Callers compute pixel frames from this.
enum CalendarOverlapLayout {

    struct Slot {
        let column: Int
        let columnCount: Int
    }

    /// Compute slot assignments for `items`. Items are assumed to be on the
    /// same day; all-day items should be filtered out by the caller.
    ///
    /// Stable: items sort by (startDate, endDate, id) so re-renders don't
    /// re-shuffle columns.
    static func layout<Item: CalendarItemProtocol>(_ items: [Item]) -> [String: Slot] {
        guard !items.isEmpty else { return [:] }

        let sorted = items.sorted { a, b in
            if a.startDate != b.startDate { return a.startDate < b.startDate }
            if a.endDate != b.endDate { return a.endDate > b.endDate }
            return a.calendarItemID < b.calendarItemID
        }

        var result: [String: Slot] = [:]

        // Build overlap groups via sweep-line: a group grows as long as
        // the next item starts before the group's current latest end.
        var groupStart = 0
        var groupLatestEnd: Date = sorted[0].endDate

        func flushGroup(_ range: Range<Int>) {
            let group = Array(sorted[range])
            // Greedy column assignment: each item goes in the lowest
            // column that doesn't conflict with any previously assigned
            // item sharing time.
            var columnEnds: [Date] = []
            var cols: [Int] = Array(repeating: 0, count: group.count)
            for (i, item) in group.enumerated() {
                var placed = false
                for c in 0..<columnEnds.count {
                    if columnEnds[c] <= item.startDate {
                        columnEnds[c] = item.endDate
                        cols[i] = c
                        placed = true
                        break
                    }
                }
                if !placed {
                    cols[i] = columnEnds.count
                    columnEnds.append(item.endDate)
                }
            }
            let count = max(1, columnEnds.count)
            for (i, item) in group.enumerated() {
                result[item.calendarItemID] = Slot(column: cols[i], columnCount: count)
            }
        }

        for i in 1..<sorted.count {
            if sorted[i].startDate < groupLatestEnd {
                groupLatestEnd = max(groupLatestEnd, sorted[i].endDate)
            } else {
                flushGroup(groupStart..<i)
                groupStart = i
                groupLatestEnd = sorted[i].endDate
            }
        }
        flushGroup(groupStart..<sorted.count)

        return result
    }
}
