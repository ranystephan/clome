import SwiftUI

/// Chromeless calendar toolbar. Left: nav + today. Center: range label.
/// Right: day/week segmented + sidebar toggle.
struct CalendarToolbar: View {
    @ObservedObject var dataManager: CalendarDataManager
    @ObservedObject private var store = BlockStore.shared
    @Binding var showSidebar: Bool
    @State private var now = Date()
    @State private var showDatePicker = false
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: FlowTokens.spacingMD) {
            HStack(spacing: 2) {
                navButton("chevron.left") { step(-1) }
                navButton("chevron.right") { step(1) }
            }

            Button {
                withAnimation(.flowSpring) { dataManager.selectedDate = Date() }
            } label: {
                Text("Today")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(FlowTokens.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            if let runningID = store.runningBlockID,
               let running = store.block(withID: runningID) {
                runningPill(running)
            } else {
                Button { showDatePicker.toggle() } label: {
                    HStack(spacing: 6) {
                        Text(rangeLabel)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(FlowTokens.textPrimary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(FlowTokens.textTertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showDatePicker, arrowEdge: .top) {
                    DatePicker(
                        "",
                        selection: $dataManager.selectedDate,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding(14)
                    .frame(width: 280)
                    .background(FlowTokens.bg1)
                }
            }

            Spacer()

            segmented

            Button {
                withAnimation(.flowSpring) { showSidebar.toggle() }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(showSidebar ? FlowTokens.textPrimary : FlowTokens.textTertiary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, FlowTokens.spacingLG)
        .padding(.vertical, 10)
        .background(FlowTokens.bg0)
        .onReceive(ticker) { now = $0 }
    }

    // MARK: - Running pill

    private func runningPill(_ block: Block) -> some View {
        let tint = block.color
        return Button {
            store.selectedBlockID = block.id
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                    .opacity(0.9)
                Text(block.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(FlowTokens.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: 200)
                Text(elapsedLabel)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(FlowTokens.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous).fill(tint.opacity(0.12))
            )
            .overlay(
                Capsule(style: .continuous).strokeBorder(tint.opacity(0.38), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var elapsedLabel: String {
        guard let started = store.runningStartedAt else { return "" }
        let total = Int(now.timeIntervalSince(started))
        let m = total / 60, s = total % 60
        if m < 60 { return String(format: "%d:%02d", m, s) }
        let h = m / 60, mm = m % 60
        return String(format: "%d:%02d:%02d", h, mm, s)
    }

    private func navButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(FlowTokens.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var segmented: some View {
        HStack(spacing: 0) {
            ForEach(CalendarViewMode.allCases, id: \.self) { mode in
                let active = dataManager.viewMode == mode
                Button {
                    withAnimation(.flowSpring) { dataManager.viewMode = mode }
                } label: {
                    Text(mode == .week ? "Week" : "Day")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(active ? FlowTokens.textPrimary : FlowTokens.textTertiary)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background {
                            if active {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(FlowTokens.bg2)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(FlowTokens.bg1.opacity(0.6))
        )
    }

    private func step(_ amount: Int) {
        let cal = Calendar.current
        let comp: Calendar.Component = dataManager.viewMode == .week ? .weekOfYear : .day
        if let next = cal.date(byAdding: comp, value: amount, to: dataManager.selectedDate) {
            withAnimation(.flowSpring) { dataManager.selectedDate = next }
        }
    }

    private var rangeLabel: String {
        let f = DateFormatter()
        let cal = Calendar.current
        switch dataManager.viewMode {
        case .day:
            f.dateFormat = "EEEE, MMMM d"
            return f.string(from: dataManager.selectedDate)
        case .week:
            let days = CalendarGridGeometry.weekDays(containing: dataManager.selectedDate)
            guard let start = days.first, let end = days.last else { return "" }
            let sameMonth = cal.component(.month, from: start) == cal.component(.month, from: end)
            if sameMonth {
                f.dateFormat = "MMMM d"
                let s = f.string(from: start)
                f.dateFormat = "d, yyyy"
                return "\(s)–\(f.string(from: end))"
            } else {
                f.dateFormat = "MMM d"
                let s = f.string(from: start)
                f.dateFormat = "MMM d, yyyy"
                return "\(s) – \(f.string(from: end))"
            }
        }
    }
}
