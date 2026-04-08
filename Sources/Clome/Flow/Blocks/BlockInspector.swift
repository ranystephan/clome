import SwiftUI
import AppKit

/// Right-pane inspector for the currently selected Block.
///
/// Design notes:
///   • Chromeless — no boxes, no inner borders. Sections separated by
///     generous vertical space and a single hairline.
///   • Title is a plain TextField that looks like a big label until you
///     click into it. Monospace timestamps. SF icons only where they earn
///     their keep.
///   • Apple-feel transitions: spring on appear, fade on section reorder.
///
/// Works for native blocks (full edit) and imported blocks (title + view).
struct BlockInspector: View {
    @ObservedObject var store: BlockStore

    let block: Block

    @State private var title: String = ""
    @State private var notes: String = ""
    @FocusState private var titleFocused: Bool
    @FocusState private var notesFocused: Bool

    private var tint: Color { block.color }
    private var isNative: Bool {
        if case .native = block.source { return true }
        return false
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 28) {
                titleSection
                timeSection
                kindSection
                attachmentsSection
                notesSection
                Spacer(minLength: 40)
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .background(FlowTokens.bg0)
        .onAppear(perform: sync)
        .onChange(of: block.id) { _, _ in sync() }
    }

    private func sync() {
        title = block.title
        notes = block.notes
    }

    // MARK: - Title

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: block.kind.systemIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(tint.opacity(0.85))
                    .frame(width: 18, height: 18)
                    .background(
                        Circle().fill(tint.opacity(0.14))
                    )

                Text(kindLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.4)
                    .foregroundColor(FlowTokens.textTertiary)
                    .textCase(.uppercase)

                Spacer()

                sourceBadge
            }

            TextField("", text: $title, onCommit: commitTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(FlowTokens.textPrimary)
                .focused($titleFocused)
                .disabled(!block.isEditable)
        }
    }

    private var kindLabel: String { block.kind.rawValue.capitalized }

    private var sourceBadge: some View {
        let label: String = {
            switch block.source {
            case .native:    return "Clome"
            case .eventKit:  return "Calendar"
            case .todo:      return "Task"
            case .deadline:  return "Deadline"
            case .reminder:  return "Reminder"
            }
        }()
        return Text(label.uppercased())
            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
            .tracking(1.0)
            .foregroundColor(FlowTokens.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .stroke(FlowTokens.border, lineWidth: 0.5)
            )
    }

    // MARK: - Time

    private var timeSection: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("STARTS")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundColor(FlowTokens.textTertiary)
                Text(dayLabel(block.start))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(FlowTokens.textPrimary)
                Text(timeLabel(block.start))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(FlowTokens.textSecondary)
            }

            Rectangle()
                .fill(FlowTokens.border)
                .frame(width: 1, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("ENDS")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundColor(FlowTokens.textTertiary)
                Text(dayLabel(block.end))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(FlowTokens.textPrimary)
                Text(timeLabel(block.end))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(FlowTokens.textSecondary)
            }

            Spacer()

            Text(durationLabel)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(FlowTokens.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous).fill(FlowTokens.bg2.opacity(0.6))
                )
        }
    }

    private func dayLabel(_ d: Date) -> String {
        let f = DateFormatter()
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInTomorrow(d) { return "Tomorrow" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: d)
    }

    private func timeLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: d).lowercased()
    }

    private var durationLabel: String {
        let minutes = Int(block.duration / 60)
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    // MARK: - Kind picker (native only)

    private var kindSection: some View {
        Group {
            if isNative {
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("KIND")
                    HStack(spacing: 6) {
                        ForEach(BlockKind.allCases, id: \.self) { k in
                            kindChip(k)
                        }
                    }
                }
            }
        }
    }

    private func kindChip(_ k: BlockKind) -> some View {
        let active = k == block.kind
        return Button {
            if let nid = store.nativeID(for: block.id) {
                store.update(nid, kind: k)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: k.systemIcon)
                    .font(.system(size: 9, weight: .semibold))
                Text(k.rawValue.capitalized)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundColor(active ? k.defaultColor.opacity(0.95) : FlowTokens.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(active ? k.defaultColor.opacity(0.16) : FlowTokens.bg2.opacity(0.5))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(active ? k.defaultColor.opacity(0.40) : Color.clear, lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Attachments

    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("ATTACHMENTS")
                Spacer()
                Text("\(block.attachments.count)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(FlowTokens.textTertiary)
            }

            if block.attachments.isEmpty {
                Text("Drop files, links, or notes here")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(FlowTokens.textHint)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(FlowTokens.border, style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    )
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(block.attachments.enumerated()), id: \.offset) { idx, att in
                        attachmentRow(att, index: idx)
                    }
                }
            }
        }
    }

    private func attachmentRow(_ att: BlockAttachment, index: Int) -> some View {
        let canRemove = isNative
        return HStack(spacing: 10) {
            Image(systemName: att.systemIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(tint.opacity(0.85))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(att.shortLabel)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(FlowTokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let sub = attachmentSubtitle(att) {
                    Text(sub)
                        .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                        .foregroundColor(FlowTokens.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if canRemove {
                Button {
                    if let nid = store.nativeID(for: block.id) {
                        store.removeAttachment(at: index, fromNativeID: nid)
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(FlowTokens.textTertiary)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .opacity(0.6)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(FlowTokens.bg2.opacity(0.5))
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(att) }
    }

    private func attachmentSubtitle(_ att: BlockAttachment) -> String? {
        switch att {
        case .file(let path):        return path
        case .url(let url):          return url.absoluteString
        case .workspace:             return "Clome workspace"
        case .claudeThread:          return "Claude session"
        case .canvas:                return "canvas"
        case .note:                  return "note"
        case .task:                  return "task"
        case .gitBranch(_, let ws):  return "workspace: \(ws)"
        case .image(let path):       return path
        }
    }

    private func open(_ att: BlockAttachment) {
        switch att {
        case .file(let path), .image(let path):
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        case .url(let url):
            NSWorkspace.shared.open(url)
        default:
            break
        }
    }

    // MARK: - Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("NOTES")
            ZStack(alignment: .topLeading) {
                if notes.isEmpty && !notesFocused {
                    Text("Add a note…")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(FlowTokens.textHint)
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $notes)
                    .font(.system(size: 12, weight: .regular))
                    .scrollContentBackground(.hidden)
                    .focused($notesFocused)
                    .disabled(!isNative)
                    .frame(minHeight: 90)
                    .onChange(of: notesFocused) { _, focused in
                        if !focused { commitNotes() }
                    }
            }
        }
    }

    // MARK: - Section header

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(1.4)
            .foregroundColor(FlowTokens.textTertiary)
    }

    // MARK: - Commit helpers

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != block.title else { return }
        store.updateAny(id: block.id, title: trimmed)
    }

    private func commitNotes() {
        guard isNative, notes != block.notes else { return }
        if let nid = store.nativeID(for: block.id) {
            store.update(nid, notes: notes)
        }
    }
}

// MARK: - BlockKind CaseIterable

extension BlockKind: CaseIterable {
    static var allCases: [BlockKind] { [.focus, .meeting, .task, .deadline, .reminder, .habit, .note] }
}
