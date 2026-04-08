import SwiftUI

/// Chromeless block card. Apple-style: quiet fill, tint title, SF-light time,
/// attachment chips rendered as small capsules when height allows.
struct BlockCard: View {
    let block: Block
    var isPast: Bool = false
    var isHovered: Bool = false
    var isSelected: Bool = false
    var isEditing: Bool = false
    var editingTitle: Binding<String>? = nil
    var onCommit: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @FocusState private var titleFocused: Bool

    private var tint: Color { block.color }

    private var fillAlpha: Double {
        if isEditing || isSelected { return 0.22 }
        if isPast { return 0.07 }
        if isHovered { return 0.18 }
        return 0.13
    }

    private var titleAlpha: Double { isPast ? 0.55 : 0.96 }
    private var subAlpha: Double { isPast ? 0.32 : 0.55 }

    private var height: CGFloat {
        CGFloat(max(15, block.end.timeIntervalSince(block.start) / 60)) / 60 * CalendarGridGeometry.hourHeight
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(tint.opacity(isPast ? 0.42 : 0.92))
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 1) {
                titleRow
                if showTime {
                    Text(timeLabel)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(tint.opacity(subAlpha))
                        .lineLimit(1)
                }
                if showChips && !block.attachments.isEmpty {
                    chipRow
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint.opacity(fillAlpha))
        )
        .overlay {
            if isSelected || isEditing {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
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
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
    }

    // MARK: - Title

    @ViewBuilder
    private var titleRow: some View {
        HStack(spacing: 4) {
            if !block.isPinned {
                Image(systemName: block.kind.systemIcon)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(tint.opacity(titleAlpha - 0.1))
            }
            if isEditing, let binding = editingTitle {
                TextField("", text: binding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(tint.opacity(0.96))
                    .focused($titleFocused)
                    .onAppear { titleFocused = true }
                    .onSubmit { onCommit?() }
            } else {
                Text(block.title.isEmpty ? "Untitled" : block.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(tint.opacity(titleAlpha))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .strikethrough(block.isCompleted, color: tint.opacity(0.7))
            }
        }
    }

    // MARK: - Attachment chip row

    private var chipRow: some View {
        HStack(spacing: 3) {
            ForEach(Array(block.attachments.prefix(4).enumerated()), id: \.offset) { _, att in
                chip(att)
            }
            if block.attachments.count > 4 {
                Text("+\(block.attachments.count - 4)")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(tint.opacity(subAlpha))
            }
        }
    }

    private func chip(_ att: BlockAttachment) -> some View {
        HStack(spacing: 2) {
            Image(systemName: att.systemIcon)
                .font(.system(size: 7, weight: .semibold))
            Text(att.shortLabel)
                .font(.system(size: 8.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundColor(tint.opacity(0.78))
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .frame(maxWidth: 70, alignment: .leading)
        .background(
            Capsule(style: .continuous).fill(tint.opacity(0.14))
        )
    }

    // MARK: - Layout thresholds

    private var showTime: Bool { block.duration >= 25 * 60 }
    private var showChips: Bool { height >= 52 }

    private var timeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return "\(f.string(from: block.start))–\(f.string(from: block.end))"
    }
}
