import SwiftUI

/// Pure geometry helpers shared by week view, cards, and (future) drag logic.
/// No state, no views — just coordinate ↔ time conversions.
struct CalendarGridGeometry {

    // MARK: - Tunables

    /// Pixels per hour. Higher = taller cards, more breathing room.
    static let hourHeight: CGFloat = 52

    /// First hour visible in the grid (0–23). Earlier content is still
    /// reachable by scrolling above — this is just the default scroll anchor.
    static let firstHour: Int = 0
    static let lastHour: Int = 24

    /// Total vertical extent of the timeline (midnight to midnight).
    static var timelineHeight: CGFloat {
        CGFloat(lastHour - firstHour) * hourHeight
    }

    /// Snap granularity for drag/create in minutes.
    static let snapMinutes: Int = 15

    /// Left gutter width for hour labels.
    static let gutterWidth: CGFloat = 52

    /// All-day strip row height and max rows before collapsing.
    static let allDayRowHeight: CGFloat = 22
    static let allDayMaxRows: Int = 2

    /// Day header height (weekday + number).
    static let dayHeaderHeight: CGFloat = 60

    // MARK: - Time ↔ Y

    /// Y offset inside the timeline for a given date.
    /// Uses the date's hour+minute only (ignores the day).
    static func y(for date: Date) -> CGFloat {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: date)
        let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let hoursFromTop = CGFloat(minutes) / 60.0 - CGFloat(firstHour)
        return hoursFromTop * hourHeight
    }

    /// Height of a card given its start/end.
    static func height(from start: Date, to end: Date) -> CGFloat {
        let minutes = max(15, end.timeIntervalSince(start) / 60)
        return CGFloat(minutes) / 60.0 * hourHeight
    }

    /// Convert a Y offset back to a Date on a given day, snapped to 15-min.
    static func time(forY y: CGFloat, onDay day: Date) -> Date {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let totalMinutes = Int((y / hourHeight) * 60) + firstHour * 60
        let snapped = (totalMinutes / snapMinutes) * snapMinutes
        return cal.date(byAdding: .minute, value: snapped, to: dayStart) ?? dayStart
    }

    // MARK: - Day ↔ Column

    /// The 7 days of the Sunday-based week containing `reference`.
    static func weekDays(containing reference: Date) -> [Date] {
        let cal = Calendar.current
        var comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: reference)
        comps.weekday = 1
        guard let start = cal.date(from: comps) else { return [] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    /// Width of a single day column given total width and left gutter.
    static func columnWidth(totalWidth: CGFloat) -> CGFloat {
        max(0, (totalWidth - gutterWidth) / 7)
    }

    /// Column index (0–6) for a given X offset.
    static func columnIndex(forX x: CGFloat, totalWidth: CGFloat) -> Int {
        let w = columnWidth(totalWidth: totalWidth)
        guard w > 0 else { return 0 }
        return min(6, max(0, Int((x - gutterWidth) / w)))
    }
}
