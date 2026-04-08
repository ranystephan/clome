import SwiftUI

/// Root of the Flow calendar surface.
struct FlowCalendarView: View {
    @ObservedObject private var dataManager = CalendarDataManager.shared
    @State private var showSidebar = true

    var body: some View {
        VStack(spacing: 0) {
            CalendarToolbar(
                dataManager: dataManager,
                showSidebar: $showSidebar
            )

            Rectangle()
                .fill(FlowTokens.border)
                .frame(height: FlowTokens.hairline)

            if !dataManager.hasCalendarAccess {
                accessRequired
            } else {
                HStack(spacing: 0) {
                    CalendarWeekView(dataManager: dataManager)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if showSidebar {
                        Rectangle()
                            .fill(FlowTokens.border)
                            .frame(width: FlowTokens.hairline)
                        CalendarAgendaSidebar(dataManager: dataManager)
                            .frame(width: FlowTokens.sidebarWidth)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
        }
        .background(FlowTokens.bg0)
        .task { dataManager.refresh() }
        .onChange(of: dataManager.selectedDate) { _, _ in dataManager.refresh() }
        .onChange(of: dataManager.viewMode) { _, _ in dataManager.refresh() }
    }

    private var accessRequired: some View {
        VStack(spacing: FlowTokens.spacingLG) {
            Spacer()
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 36, weight: .light))
                .foregroundColor(FlowTokens.textTertiary)
            Text("Calendar access required")
                .flowFont(.title3)
                .foregroundColor(FlowTokens.textPrimary)
            Text("Flow needs access to your calendar to display events.")
                .flowFont(.caption)
                .foregroundColor(FlowTokens.textTertiary)
            Button("Grant Access") { dataManager.requestCalendarAccess() }
                .buttonStyle(.borderedProminent)
                .tint(FlowTokens.accent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlowTokens.bg0)
    }
}
