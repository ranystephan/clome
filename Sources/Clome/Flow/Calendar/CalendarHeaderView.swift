import SwiftUI

/// Calendar toolbar. Preserved as `CalendarHeaderView` alias for compat.
typealias CalendarHeaderView = CalendarToolbar

struct CalendarToolbar: View {
    @ObservedObject var dataManager: CalendarDataManager
    @Binding var showSidebar: Bool

    @State private var showDatePicker = false

    private let controlHeight: CGFloat = 26

    var body: some View {
        HStack(spacing: FlowTokens.spacingMD) {
            // Left cluster: nav + today
            HStack(spacing: 4) {
                navButton("chevron.left") { step(by: -1) }
                navButton("chevron.right") { step(by: 1) }
                todayButton
                    .padding(.leading, 2)
            }

            Spacer()

            // Center: tappable range label (opens date picker)
            Button { showDatePicker.toggle() } label: {
                HStack(spacing: FlowTokens.spacingSM) {
                    Text(rangeLabel)
                        .flowFont(.title3)
                        .foregroundColor(FlowTokens.textPrimary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(FlowTokens.textTertiary)
                }
                .padding(.horizontal, FlowTokens.spacingMD)
                .frame(height: controlHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDatePicker, arrowEdge: .top) {
                DatePicker("", selection: $dataManager.selectedDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding(FlowTokens.spacingMD)
                    .frame(width: 280)
            }

            Spacer()

            // Right cluster: view switcher + sidebar
            viewModeSwitcher

            sidebarToggle
        }
        .padding(.horizontal, FlowTokens.spacingLG)
        .padding(.vertical, FlowTokens.spacingMD)
        .background(FlowTokens.bg0)
        .overlay(alignment: .bottom) {
            Rectangle().fill(FlowTokens.border).frame(height: FlowTokens.hairline)
        }
    }

    // MARK: - Pieces

    private func navButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(FlowTokens.textSecondary)
                .frame(width: controlHeight, height: controlHeight)
                .flowControl()
        }
        .buttonStyle(.plain)
    }

    private var todayButton: some View {
        Button {
            withAnimation(.flowQuick) { dataManager.selectedDate = Date() }
        } label: {
            Text("Today")
                .flowFont(.callout)
                .foregroundColor(FlowTokens.textPrimary)
                .padding(.horizontal, FlowTokens.spacingMD)
                .frame(height: controlHeight)
                .flowControl()
        }
        .buttonStyle(.plain)
        .help("Jump to today")
    }

    private var viewModeSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(CalendarViewMode.allCases, id: \.self) { mode in
                let isActive = dataManager.viewMode == mode
                Button {
                    withAnimation(.flowQuick) { dataManager.viewMode = mode }
                } label: {
                    Text(mode == .week ? "Week" : "Month")
                        .flowFont(.callout)
                        .foregroundColor(isActive ? FlowTokens.textPrimary : FlowTokens.textTertiary)
                        .padding(.horizontal, FlowTokens.spacingMD)
                        .frame(height: 22)
                        .background {
                            if isActive {
                                RoundedRectangle(cornerRadius: FlowTokens.radiusControl, style: .continuous)
                                    .fill(FlowTokens.bg3)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: FlowTokens.radiusButton, style: .continuous)
                .fill(FlowTokens.bg1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FlowTokens.radiusButton, style: .continuous)
                .strokeBorder(FlowTokens.border, lineWidth: FlowTokens.hairline)
        )
    }

    private var sidebarToggle: some View {
        Button {
            withAnimation(.flowSpring) { showSidebar.toggle() }
        } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(showSidebar ? FlowTokens.textPrimary : FlowTokens.textTertiary)
                .frame(width: controlHeight, height: controlHeight)
                .flowControl(isActive: showSidebar)
        }
        .buttonStyle(.plain)
        .help("Toggle agenda")
    }

    // MARK: - Range label

    private var rangeLabel: String {
        let f = DateFormatter()
        switch dataManager.viewMode {
        case .month:
            f.dateFormat = "MMMM yyyy"
            return f.string(from: dataManager.selectedDate)
        case .week:
            let cal = Calendar.current
            var comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: dataManager.selectedDate)
            comps.weekday = 1
            guard let start = cal.date(from: comps),
                  let end = cal.date(byAdding: .day, value: 6, to: start) else {
                f.dateFormat = "MMM d"
                return f.string(from: dataManager.selectedDate)
            }
            let sameMonth = cal.component(.month, from: start) == cal.component(.month, from: end)
            if sameMonth {
                f.dateFormat = "MMMM d"
                let sf = f.string(from: start)
                f.dateFormat = "d, yyyy"
                return "\(sf)–\(f.string(from: end))"
            } else {
                f.dateFormat = "MMM d"
                let sf = f.string(from: start)
                f.dateFormat = "MMM d, yyyy"
                return "\(sf) – \(f.string(from: end))"
            }
        }
    }

    private func step(by amount: Int) {
        let cal = Calendar.current
        let component: Calendar.Component = dataManager.viewMode == .week ? .weekOfYear : .month
        if let next = cal.date(byAdding: component, value: amount, to: dataManager.selectedDate) {
            withAnimation(.flowQuick) { dataManager.selectedDate = next }
        }
    }
}
