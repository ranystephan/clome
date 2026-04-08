import SwiftUI

/// Chromeless calendar toolbar. Left: nav + today. Center: range label.
/// Right: day/week segmented + sidebar toggle.
struct CalendarToolbar: View {
    @ObservedObject var dataManager: CalendarDataManager
    @Binding var showSidebar: Bool

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

            Text(rangeLabel)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(FlowTokens.textPrimary)

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
