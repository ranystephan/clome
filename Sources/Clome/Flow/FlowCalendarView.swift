import SwiftUI

/// Thin shell that composes CalendarHeaderView with the active view mode
/// (day/week/month), items panel, AI chat bar, and manages the creation popover.
struct FlowCalendarView: View {
    @ObservedObject private var dataManager = CalendarDataManager.shared
    @State private var showCreationPopover = false
    @State private var creationTime: Date?
    @State private var showItemsPanel = true

    var body: some View {
        VStack(spacing: 0) {
            CalendarHeaderView(dataManager: dataManager)
            Divider().background(FlowTokens.border)

            if !dataManager.hasCalendarAccess {
                accessRequired
            } else {
                calendarWithPanel
            }
        }
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

    // MARK: - Calendar + Items Panel + Chat

    private var calendarWithPanel: some View {
        VStack(spacing: 0) {
            // Calendar content (expandable)
            calendarContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Collapsible items panel
            if showItemsPanel {
                panelDivider
                CalendarItemsPanel()
                    .frame(maxHeight: 200)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                panelToggleBar
            }

            // AI Chat bar (always visible)
            CalendarChatBar()
        }
    }

    // MARK: - Calendar Content

    private var calendarContent: some View {
        Group {
            switch dataManager.viewMode {
            case .day:
                CalendarDayView(
                    dataManager: dataManager,
                    showCreationPopover: $showCreationPopover,
                    creationTime: $creationTime
                )
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
    }

    // MARK: - Panel Divider with Toggle

    private var panelDivider: some View {
        HStack {
            Rectangle()
                .fill(FlowTokens.border)
                .frame(height: 0.5)

            Button {
                withAnimation(.flowSpring) { showItemsPanel = false }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(FlowTokens.textMuted)
                    .frame(width: 20, height: 12)
                    .background(FlowTokens.bg2)
                    .cornerRadius(FlowTokens.radiusSmall)
            }
            .buttonStyle(.plain)
            .help("Collapse panel")

            Rectangle()
                .fill(FlowTokens.border)
                .frame(height: 0.5)
        }
    }

    private var panelToggleBar: some View {
        Button {
            withAnimation(.flowSpring) { showItemsPanel = true }
        } label: {
            HStack {
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(FlowTokens.textMuted)
                Text("Todos & Deadlines")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(FlowTokens.textMuted)
                Image(systemName: "chevron.up")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(FlowTokens.textMuted)
                Spacer()
            }
            .padding(.vertical, FlowTokens.spacingSM)
            .background(FlowTokens.bg1)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Access Required

    private var accessRequired: some View {
        VStack(spacing: FlowTokens.spacingMD) {
            Spacer()
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 28))
                .foregroundColor(FlowTokens.textDisabled)
            Text("Calendar access required")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(FlowTokens.textTertiary)
            Button("Grant Access") { dataManager.requestCalendarAccess() }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(FlowTokens.accent)
                .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
