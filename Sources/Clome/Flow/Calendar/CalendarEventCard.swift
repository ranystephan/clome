import SwiftUI

/// Chromeless event card.
/// - No outline, no shadow.
/// - 2pt left rail in full tint.
/// - Translucent tint fill, tint-colored title.
/// - Optional inline edit mode for in-place title editing.
struct CalendarEventCard: View {
    let item: any CalendarItemProtocol
    var isPast: Bool = false
    var isHovered: Bool = false
    var isSelected: Bool = false
    var isEditing: Bool = false
    var editingTitle: Binding<String>? = nil
    var onCommit: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @FocusState private var titleFocused: Bool

    private var tint: Color { item.displayColor }

    private var fillAlpha: Double {
        if isEditing || isSelected { return 0.24 }
        if isPast { return 0.08 }
        if isHovered { return 0.20 }
        return 0.14
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(tint.opacity(isPast ? 0.45 : 0.95))
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 1) {
                titleRow
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
        .overlay {
            if isSelected || isEditing {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(tint.opacity(0.55), lineWidth: 1)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isSelected && !isEditing, let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(tint.opacity(0.9))
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(FlowTokens.bg1))
                }
                .buttonStyle(.plain)
                .padding(3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var titleRow: some View {
        if isEditing, let binding = editingTitle {
            TextField("", text: binding)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(tint.opacity(0.95))
                .focused($titleFocused)
                .onAppear { titleFocused = true }
                .onSubmit { onCommit?() }
        } else {
            Text(item.title.isEmpty ? "Untitled" : item.title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(tint.opacity(isPast ? 0.55 : 0.95))
                .lineLimit(2)
                .truncationMode(.tail)
                .strikethrough(item.isCompleted, color: tint.opacity(0.7))
        }
    }

    private var heightAllowsTime: Bool {
        item.endDate.timeIntervalSince(item.startDate) >= 25 * 60
    }

    private var timeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return "\(f.string(from: item.startDate))–\(f.string(from: item.endDate))"
    }
}
