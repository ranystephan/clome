import SwiftUI
import AppKit
import ClomeModels

/// The "what now?" dashboard. Live, ambient, read-mostly.
///
/// Sections (top to bottom):
///   • Greeting + date
///   • NOW strip (running block, elapsed, end button)
///   • NEXT UP (next block on today's schedule)
///   • TODAY (compact timeline)
///   • DEADLINES radar (next 7 days, urgency-colored)
///   • INBOX (leftovers, agent changes — counts only, non-AI)
///   • QUICK CAPTURE (creates a pinned note for today)
///
/// Design: chromeless, section dividers are vertical whitespace not lines,
/// monospace small caps for section labels, SF-rounded body copy, spring
/// transitions. No inner boxes unless interactive.
struct FlowDashboardView: View {
    @ObservedObject private var store = BlockStore.shared
    @ObservedObject private var syncService = FlowSyncService.shared

    @State private var now = Date()
    @State private var captureText: String = ""
    @FocusState private var captureFocused: Bool

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let cal = Calendar.current

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 42) {
                greeting
                nowStrip
                nextUpSection
                todayTimelineSection
                deadlinesSection
                inboxSection
                quickCaptureSection
                Spacer(minLength: 60)
            }
            .padding(.horizontal, 48)
            .padding(.top, 40)
            .padding(.bottom, 60)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(FlowTokens.bg0)
        .onReceive(ticker) { now = $0 }
    }

    // MARK: - Greeting

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greetingLine)
                .font(.system(size: 32, weight: .semibold))
                .foregroundColor(FlowTokens.textPrimary)
            Text(dateLine.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.6)
                .foregroundColor(FlowTokens.textTertiary)
        }
    }

    private var greetingLine: String {
        let hour = cal.component(.hour, from: now)
        switch hour {
        case 5..<12:  return "Good morning."
        case 12..<17: return "Good afternoon."
        case 17..<22: return "Good evening."
        default:      return "Working late."
        }
    }

    private var dateLine: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE · MMMM d"
        return f.string(from: now)
    }

    // MARK: - NOW strip

    @ViewBuilder
    private var nowStrip: some View {
        if let runningID = store.runningBlockID, let block = store.block(withID: runningID) {
            runningStrip(block)
        } else {
            idleStrip
        }
    }

    private func runningStrip(_ block: Block) -> some View {
        let tint = block.color
        return HStack(alignment: .center, spacing: 18) {
            // Animated pulse dot
            ZStack {
                Circle()
                    .fill(tint.opacity(0.20))
                    .frame(width: 28, height: 28)
                Circle()
                    .fill(tint)
                    .frame(width: 10, height: 10)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("NOW")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundColor(tint.opacity(0.85))
                Text(block.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(FlowTokens.textPrimary)
                    .lineLimit(1)
                if !block.attachments.isEmpty {
                    Text(attachmentLine(block))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(FlowTokens.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(elapsedLabel)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundColor(FlowTokens.textPrimary)
                Text("elapsed")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundColor(FlowTokens.textTertiary)
            }

            Button {
                store.endBlock(id: block.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                    Text("End").font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(FlowTokens.editorialRed)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(FlowTokens.editorialRed.opacity(0.12))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(FlowTokens.editorialRed.opacity(0.40), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(0.30), lineWidth: 0.5)
        )
    }

    private var idleStrip: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(FlowTokens.textTertiary.opacity(0.3))
                .frame(width: 8, height: 8)
            Text("Nothing running.")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(FlowTokens.textSecondary)
            Spacer()
            if let next = nextUpBlock {
                Button {
                    store.startBlock(id: next.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                        Text("Start next").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(next.color)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(next.color.opacity(0.14)))
                    .overlay(Capsule().strokeBorder(next.color.opacity(0.36), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(FlowTokens.bg1.opacity(0.4))
        )
    }

    private func attachmentLine(_ block: Block) -> String {
        let counts = Dictionary(grouping: block.attachments, by: { $0.systemIcon })
        return block.attachments.prefix(3).map { $0.shortLabel }.joined(separator: " · ")
            + (block.attachments.count > 3 ? " · +\(block.attachments.count - 3)" : "")
            + (counts.isEmpty ? "" : "")
    }

    private var elapsedLabel: String {
        guard let started = store.runningStartedAt else { return "0:00" }
        let total = Int(now.timeIntervalSince(started))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Next up

    private var nextUpBlock: Block? {
        store.blocks
            .filter { !$0.isAllDay && !$0.isPinned && $0.start > now && cal.isDateInToday($0.start) }
            .sorted { $0.start < $1.start }
            .first
    }

    @ViewBuilder
    private var nextUpSection: some View {
        if let next = nextUpBlock {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("NEXT UP")
                HStack(spacing: 12) {
                    Rectangle()
                        .fill(next.color)
                        .frame(width: 2, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(next.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(FlowTokens.textPrimary)
                        Text("in \(relativeTime(to: next.start)) · \(timeLabel(next.start))")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(FlowTokens.textTertiary)
                    }
                    Spacer()
                    Button {
                        store.selectedBlockID = next.id
                    } label: {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(FlowTokens.textTertiary)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(FlowTokens.bg2.opacity(0.6)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Today timeline

    private var todayBlocks: [Block] {
        store.blocks
            .filter { !$0.isAllDay && !$0.isPinned && cal.isDateInToday($0.start) }
            .sorted { $0.start < $1.start }
    }

    @ViewBuilder
    private var todayTimelineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader("TODAY")
                Spacer()
                Text("\(todayBlocks.count) blocks")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(FlowTokens.textTertiary)
            }
            if todayBlocks.isEmpty {
                Text("Nothing scheduled. Switch to Plan to add a block.")
                    .font(.system(size: 11))
                    .foregroundColor(FlowTokens.textHint)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 2) {
                    ForEach(todayBlocks) { block in
                        todayRow(block)
                    }
                }
            }
        }
    }

    private func todayRow(_ block: Block) -> some View {
        let past = block.end < now
        let running = store.runningBlockID == block.id
        return Button {
            store.selectedBlockID = block.id
        } label: {
            HStack(spacing: 12) {
                Text(timeLabel(block.start))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(past ? FlowTokens.textHint : FlowTokens.textTertiary)
                    .frame(width: 58, alignment: .trailing)
                Rectangle()
                    .fill(block.color.opacity(past ? 0.35 : 0.85))
                    .frame(width: 2, height: 16)
                Text(block.title)
                    .font(.system(size: 12, weight: running ? .semibold : .regular))
                    .foregroundColor(past ? FlowTokens.textTertiary : FlowTokens.textPrimary)
                    .strikethrough(block.isCompleted, color: FlowTokens.textTertiary)
                    .lineLimit(1)
                if running {
                    Text("NOW")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundColor(block.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(block.color.opacity(0.18)))
                }
                Spacer()
                Text(durationShort(block))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(FlowTokens.textHint)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func durationShort(_ b: Block) -> String {
        let m = Int(b.duration / 60)
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h\(m % 60)"
    }

    // MARK: - Deadlines

    private var upcomingDeadlines: [Deadline] {
        syncService.deadlines
            .filter { !$0.isCompleted && $0.dueDate > now.addingTimeInterval(-60 * 60) }
            .sorted { $0.dueDate < $1.dueDate }
            .prefix(5)
            .map { $0 }
    }

    @ViewBuilder
    private var deadlinesSection: some View {
        if !upcomingDeadlines.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("DEADLINES")
                VStack(spacing: 2) {
                    ForEach(upcomingDeadlines, id: \.id) { d in
                        deadlineRow(d)
                    }
                }
            }
        }
    }

    private func deadlineRow(_ d: Deadline) -> some View {
        let hoursUntil = d.hoursUntilDue
        let urgency: Color = d.isPastDue
            ? FlowTokens.urgencyOverdue
            : (hoursUntil < 24 ? FlowTokens.urgencyCritical
               : (hoursUntil < 72 ? FlowTokens.urgencyWarning : FlowTokens.urgencyNormal))
        return HStack(spacing: 12) {
            Circle().fill(urgency).frame(width: 6, height: 6)
            Text(d.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(FlowTokens.textPrimary)
                .lineLimit(1)
            Spacer()
            Text(relativeDeadline(d.dueDate))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(urgency.opacity(0.85))
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
    }

    private func relativeDeadline(_ date: Date) -> String {
        let delta = date.timeIntervalSince(now)
        let h = Int(delta / 3600)
        if h < 0 { return "overdue" }
        if h < 24 { return "in \(h)h" }
        let d = h / 24
        return "in \(d)d"
    }

    // MARK: - Inbox

    private var leftoverCount: Int {
        syncService.todos.filter { !$0.isCompleted && $0.scheduledDate == nil }.count
    }

    private var inboxSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("INBOX")
            HStack(spacing: 10) {
                inboxTile(count: leftoverCount, label: "unscheduled tasks", icon: "tray")
                inboxTile(count: syncService.deadlines.filter { $0.isPastDue && !$0.isCompleted }.count,
                          label: "overdue", icon: "exclamationmark.triangle")
                Spacer()
            }
        }
    }

    private func inboxTile(count: Int, label: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(count > 0 ? FlowTokens.textSecondary : FlowTokens.textHint)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(count)")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(count > 0 ? FlowTokens.textPrimary : FlowTokens.textHint)
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(FlowTokens.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(FlowTokens.bg1.opacity(0.5))
        )
    }

    // MARK: - Quick capture

    private var quickCaptureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("QUICK CAPTURE")
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(FlowTokens.textTertiary)
                TextField("i need to…", text: $captureText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(FlowTokens.textPrimary)
                    .focused($captureFocused)
                    .onSubmit(commitCapture)
                if !captureText.isEmpty {
                    Button(action: commitCapture) {
                        Image(systemName: "return")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(FlowTokens.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().strokeBorder(FlowTokens.border, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(FlowTokens.bg1.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        captureFocused ? FlowTokens.accent.opacity(0.45) : FlowTokens.border,
                        lineWidth: 0.5
                    )
            )
            Text("Creates a pinned card on today. AI routing lands in a later release.")
                .font(.system(size: 9))
                .foregroundColor(FlowTokens.textHint)
        }
    }

    private func commitCapture() {
        let trimmed = captureText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let start = cal.startOfDay(for: now)
        store.create(
            title: String(trimmed.prefix(80)),
            start: start,
            end: start.addingTimeInterval(60),
            kind: .note,
            isPinned: true,
            attachments: trimmed.count > 80 ? [.note(markdown: trimmed)] : []
        )
        captureText = ""
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(1.6)
            .foregroundColor(FlowTokens.textTertiary)
    }

    private func timeLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: d).lowercased()
    }

    private func relativeTime(to date: Date) -> String {
        let delta = Int(date.timeIntervalSince(now))
        if delta < 60 { return "now" }
        let m = delta / 60
        if m < 60 { return "\(m) min" }
        let h = m / 60, mm = m % 60
        return mm == 0 ? "\(h)h" : "\(h)h \(mm)m"
    }
}
