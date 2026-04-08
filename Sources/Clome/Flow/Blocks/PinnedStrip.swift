import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Untimed "day pinned" strip. Lives above the time grid.
/// One column per day. Each column is:
///   • A drop target for file URLs, web URLs, and plain text
///   • A vertical stack of small PinnedCard rows
///
/// Drop behavior:
///   • File URL  → creates a pinned Block with kind .note and a .file attachment
///   • Web URL   → creates a pinned Block with a .url attachment
///   • String    → creates a pinned Block with title = string
struct PinnedStrip: View {
    let days: [Date]
    let blocks: [Block]
    @ObservedObject private var store = BlockStore.shared

    @State private var dropTargetedDay: Date?
    @State private var selectedCardID: String?

    private let cal = Calendar.current
    private let rowHeight: CGFloat = 22
    private let strap: CGFloat = 6

    var body: some View {
        HStack(spacing: 0) {
            // Left gutter label
            Text("pinned")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.2)
                .foregroundColor(FlowTokens.textTertiary)
                .frame(width: CalendarGridGeometry.gutterWidth, alignment: .trailing)
                .padding(.trailing, 6)

            GeometryReader { geo in
                let colW = geo.size.width / CGFloat(max(1, days.count))
                HStack(spacing: 0) {
                    ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                        column(day: day)
                            .frame(width: colW)
                    }
                }
            }
        }
        .frame(height: columnHeight)
        .padding(.vertical, strap)
    }

    // MARK: - Column

    private var columnHeight: CGFloat {
        let maxCount = days.map { d in pinned(for: d).count }.max() ?? 0
        let visibleRows = min(max(1, maxCount), 4)
        return CGFloat(visibleRows) * (rowHeight + 2) + strap
    }

    private func column(day: Date) -> some View {
        let items = pinned(for: day)
        let targeted = dropTargetedDay.map { cal.isDate($0, inSameDayAs: day) } ?? false

        return VStack(alignment: .leading, spacing: 2) {
            ForEach(items) { block in
                PinnedCardRow(
                    block: block,
                    isSelected: selectedCardID == block.id,
                    onTap: { selectedCardID = block.id },
                    onOpen: { openAttachment(block) },
                    onDelete: { deleteBlock(block) }
                )
                .frame(height: rowHeight)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(targeted ? FlowTokens.accent.opacity(0.10) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    targeted ? FlowTokens.accent.opacity(0.55) : Color.clear,
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )
        )
        .contentShape(Rectangle())
        .onDrop(
            of: [.fileURL, .url, .text],
            isTargeted: Binding(
                get: { targeted },
                set: { isIn in dropTargetedDay = isIn ? day : nil }
            ),
            perform: { providers in handleDrop(providers: providers, on: day) }
        )
    }

    // MARK: - Data

    private func pinned(for day: Date) -> [Block] {
        blocks.filter { $0.isPinned && cal.isDate($0.start, inSameDayAs: day) }
    }

    // MARK: - Drop handling

    private func handleDrop(providers: [NSItemProvider], on day: Date) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data = data as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in self.createFilePinned(url: url, on: day) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.url.identifier) { data, _ in
                    var url: URL?
                    if let data = data as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let u = data as? URL {
                        url = u
                    }
                    guard let u = url else { return }
                    Task { @MainActor in self.createURLPinned(url: u, on: day) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.text.identifier) { data, _ in
                    var text: String?
                    if let s = data as? String { text = s }
                    else if let d = data as? Data { text = String(data: d, encoding: .utf8) }
                    guard let t = text, !t.isEmpty else { return }
                    Task { @MainActor in self.createNotePinned(text: t, on: day) }
                }
            }
        }
        return handled
    }

    private func createFilePinned(url: URL, on day: Date) {
        let title = url.lastPathComponent
        let start = cal.startOfDay(for: day)
        store.create(
            title: title,
            start: start,
            end: start.addingTimeInterval(60),
            kind: .note,
            isPinned: true,
            attachments: [.file(path: url.path)]
        )
    }

    private func createURLPinned(url: URL, on day: Date) {
        let title = url.host ?? url.absoluteString
        let start = cal.startOfDay(for: day)
        store.create(
            title: title,
            start: start,
            end: start.addingTimeInterval(60),
            kind: .note,
            isPinned: true,
            attachments: [.url(url)]
        )
    }

    private func createNotePinned(text: String, on day: Date) {
        let title = String(text.prefix(60))
        let start = cal.startOfDay(for: day)
        store.create(
            title: title,
            start: start,
            end: start.addingTimeInterval(60),
            kind: .note,
            isPinned: true,
            attachments: text.count > 60 ? [.note(markdown: text)] : []
        )
    }

    // MARK: - Actions

    private func openAttachment(_ block: Block) {
        guard let att = block.attachments.first else { return }
        switch att {
        case .file(let path):
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        case .url(let url):
            NSWorkspace.shared.open(url)
        case .image(let path):
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        default:
            break
        }
    }

    private func deleteBlock(_ block: Block) {
        store.deleteAny(id: block.id)
        selectedCardID = nil
    }
}

// MARK: - PinnedCardRow

/// Single horizontal pinned card row.
/// Icon + title. Tap to select, tap again to open, × to delete.
struct PinnedCardRow: View {
    let block: Block
    let isSelected: Bool
    let onTap: () -> Void
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var hovered = false

    private var tint: Color { block.color }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: iconName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(tint.opacity(0.85))
                .frame(width: 12)

            Text(block.title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(FlowTokens.textPrimary.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isSelected || hovered {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(FlowTokens.textTertiary)
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isSelected
                      ? tint.opacity(0.22)
                      : (hovered ? tint.opacity(0.14) : tint.opacity(0.08)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(
                    isSelected ? tint.opacity(0.50) : Color.clear,
                    lineWidth: 0.5
                )
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { onOpen() }
        .onTapGesture { onTap() }
    }

    private var iconName: String {
        if let first = block.attachments.first { return first.systemIcon }
        return block.kind.systemIcon
    }
}
