import SwiftUI

/// Chromeless event card.
/// - No outline, no shadow.
/// - 2pt left rail in full tint.
/// - Translucent tint fill (14%).
/// - Title in tint @ 95%, time in tint @ 55%.
struct CalendarEventCard: View {
    let item: any CalendarItemProtocol
    var isPast: Bool = false
    var isHovered: Bool = false

    private var tint: Color { item.displayColor }

    private var fillAlpha: Double {
        if isPast { return 0.08 }
        if isHovered { return 0.20 }
        return 0.14
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left rail
            Rectangle()
                .fill(tint.opacity(isPast ? 0.45 : 0.95))
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(tint.opacity(isPast ? 0.55 : 0.95))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .strikethrough(item.isCompleted, color: tint.opacity(0.7))

                if heightAllowsTime {
                    Text(timeLabel)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(tint.opacity(isPast ? 0.35 : 0.55))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(tint.opacity(fillAlpha))
        )
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .contentShape(Rectangle())
    }

    private var heightAllowsTime: Bool {
        // Cards shorter than ~30 min hide the time line to stay legible.
        item.endDate.timeIntervalSince(item.startDate) >= 25 * 60
    }

    private var timeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        let start = f.string(from: item.startDate)
        let end = f.string(from: item.endDate)
        return "\(start)–\(end)"
    }
}
