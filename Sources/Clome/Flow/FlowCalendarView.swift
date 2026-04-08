import SwiftUI

/// Root of the Flow calendar surface.
///
/// Layout:
///   ┌──────────────────────────────────────────┐
///   │  Toolbar  (nav · today · day/week/month) │
///   ├──────────────────────┬───────────────────┤
///   │                      │  Agenda Sidebar   │
///   │   Calendar Canvas    │  ─ today's items  │
///   │   (day/week/month)   │  ─ tasks          │
///   │                      │  ─ deadlines      │
///   └──────────────────────┴───────────────────┘
struct FlowCalendarView: View {
    @ObservedObject private var dataManager = CalendarDataManager.shared
    @State private var showCreationPopover = false
    @State private var creationTime: Date?
    @State private var showSidebar = true

    private let sidebarWidth: CGFloat = FlowTokens.sidebarWidth

    var body: some View {
        VStack(spacing: 0) {
            CalendarToolbar(
                dataManager: dataManager,
                showSidebar: $showSidebar
            )

            if !dataManager.hasCalendarAccess {
                accessRequired
            } else {
                HStack(spacing: 0) {
                    canvas
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if showSidebar {
                        Rectangle()
                            .fill(FlowTokens.border)
                            .frame(width: FlowTokens.hairline)
                        CalendarAgendaSidebar(dataManager: dataManager)
                            .frame(width: sidebarWidth)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
        }
        .background(FlowTokens.bg0)
        .task { dataManager.refresh() }
        .onChange(of: dataManager.selectedDate) { _, _ in dataManager.refresh() }
        .onChange(of: dataManager.viewMode) { _, _ in dataManager.refresh() }
        .popover(isPresented: $showCreationPopover) {
            if let time = creationTime {
                CalendarCreationPopover(initialDate: time) {
                    showCreationPopover = false
                    creationTime = nil
                }
            }
        }
    }

    // MARK: - Canvas

    @ViewBuilder
    private var canvas: some View {
        switch dataManager.viewMode {
        case .week:
            CalendarWeekView(
                dataManager: dataManager,
                showCreationPopover: $showCreationPopover,
                creationTime: $creationTime
            )
        case .month:
            CalendarMonthView(dataManager: dataManager)
        }
    }

    // MARK: - Access Required

    private var accessRequired: some View {
        VStack(spacing: FlowTokens.spacingLG) {
            Spacer()
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 36, weight: .light))
                .foregroundColor(FlowTokens.textTertiary)
            VStack(spacing: 4) {
                Text("Calendar access required")
                    .flowFont(.title3)
                    .foregroundColor(FlowTokens.textPrimary)
                Text("Flow needs access to your calendar to display events.")
                    .flowFont(.caption)
                    .foregroundColor(FlowTokens.textTertiary)
            }
            Button("Grant Access") { dataManager.requestCalendarAccess() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(FlowTokens.accent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlowTokens.bg0)
    }
}
