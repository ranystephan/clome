import SwiftUI

/// Top toolbar for the Flow calendar.
///
/// `CalendarHeaderView` is kept as a thin alias so that any older callers
/// (like a CLI scripted launch) compile, but the canonical name is
/// `CalendarToolbar`.
typealias CalendarHeaderView = CalendarToolbar

struct CalendarToolbar: View {
    @ObservedObject var dataManager: CalendarDataManager
    @Binding var showSidebar: Bool

    @State private var showDatePicker = false

    private let controlHeight: CGFloat = 26

    var body: some View {
        HStack(spacing: FlowTokens.spacingMD) {
            // Nav cluster
            HStack(spacing: 4) {
                navButton(systemImage: "chevron.left", help: "Previous") { step(by: -1) }
                navButton(systemImage: "chevron.right", help: "Next") { step(by: 1) }
            }

            Button {
                withAnimation(.flowQuick) { dataManager.selectedDate = Date() }
            } label: {
                Text("Today")
                    .flowFont(.callout)
                    .foregroundColor(FlowTokens.textSecondary)
                    .padding(.horizontal, FlowTokens.spacingMD)
                    .frame(height: controlHeight)
                    .flowControl()
            }
            .buttonStyle(.plain)
            .help("Jump to today")

            // Editorial date marker
            Button { showDatePicker.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: FlowTokens.spacingSM - 2) {
                    Text(weekdayLabel)
                        .flowFont(.caption)
                        .foregroundColor(FlowTokens.textTertiary)
                    Text(dayNumberLabel)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(FlowTokens.textPrimary)
                        .tracking(-0.3)
                    Text(monthYearLabel)
                        .flowFont(.caption)
                        .foregroundColor(FlowTokens.textTertiary)
                }
                .padding(.horizontal, FlowTokens.spacingSM)
                .frame(height: controlHeight)
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
                .padding(FlowTokens.spacingMD)
                .frame(width: FlowTokens.popoverWidth + 20)
            }

            Spacer()

            viewModeSegments

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
            .help("Toggle agenda sidebar")
        }
        .padding(.horizontal, FlowTokens.spacingLG)
        .padding(.vertical, FlowTokens.spacingMD)
        .background(FlowTokens.bg0)
        .overlay(alignment: .bottom) {
            Rectangle().fill(FlowTokens.border).frame(height: FlowTokens.hairline)
        }
    }

    // MARK: - Bits

    private func navButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(FlowTokens.textSecondary)
                .frame(width: controlHeight, height: controlHeight)
                .flowControl()
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var viewModeSegments: some View {
        HStack(spacing: 2) {
            ForEach(CalendarViewMode.allCases, id: \.self) { mode in
                Button {
                    withAnimation(.flowQuick) { dataManager.viewMode = mode }
                } label: {
                    Text(label(for: mode))
                        .flowFont(.callout)
                        .foregroundColor(dataManager.viewMode == mode ? FlowTokens.textPrimary : FlowTokens.textTertiary)
                        .padding(.horizontal, FlowTokens.spacingMD)
                        .frame(height: 22)
                        .background {
                            if dataManager.viewMode == mode {
                                RoundedRectangle(cornerRadius: FlowTokens.radiusControl, style: .continuous)
                                    .fill(FlowTokens.bg3)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: FlowTokens.radiusControl, style: .continuous)
                                            .strokeBorder(FlowTokens.borderStrong, lineWidth: FlowTokens.hairline)
                                    )
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(label(for: mode))
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

    private func label(for mode: CalendarViewMode) -> String {
        switch mode {
        case .week:  return "Week"
        case .month: return "Month"
        }
    }

    // MARK: - Date Labels

    private var weekdayLabel: String {
        let f = DateFormatter(); f.dateFormat = "EEE"
        return f.string(from: dataManager.selectedDate).uppercased()
    }

    private var dayNumberLabel: String {
        let f = DateFormatter(); f.dateFormat = "d"
        return f.string(from: dataManager.selectedDate)
    }

    private var monthYearLabel: String {
        let f = DateFormatter(); f.dateFormat = "MMM yyyy"
        return f.string(from: dataManager.selectedDate)
    }

    // MARK: - Step

    private func step(by amount: Int) {
        let cal = Calendar.current
        let component: Calendar.Component = {
            switch dataManager.viewMode {
            case .week:  return .weekOfYear
            case .month: return .month
            }
        }()
        if let next = cal.date(byAdding: component, value: amount, to: dataManager.selectedDate) {
            withAnimation(.flowQuick) { dataManager.selectedDate = next }
        }
    }
}
