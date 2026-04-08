import SwiftUI
import FirebaseAuth

/// Root SwiftUI view for the Flow panel, embedded in FlowPanel via NSHostingView.
/// Shows auth screen if not signed in, otherwise shows mode selector + content.
struct FlowPanelHostView: View {
    let projectContext: String?
    let workspaceID: UUID?

    init(projectContext: String?, workspaceID: UUID? = nil) {
        self.projectContext = projectContext
        self.workspaceID = workspaceID
    }

    @State private var isAuthenticated = false
    @State private var activeMode: FlowMode = .calendar
    @State private var authHandle: AuthStateDidChangeListenerHandle?
    @State private var showSettings = false
    @State private var showInspector = false
    @ObservedObject private var syncService = FlowSyncService.shared
    @ObservedObject private var workspaceStore = WorkspaceStore.shared
    @Namespace private var modeAnimation

    enum FlowMode: String, CaseIterable, Identifiable {
        case calendar = "Calendar"
        case todos = "Todos"
        case deadlines = "Deadlines"
        case notes = "Notes"
        case chat = "Chat"

        var id: String { rawValue }

        /// Tabs that appear in the top segmented picker.
        static var dockCases: [FlowMode] {
            [.calendar, .deadlines, .notes, .chat]
        }

        var icon: String {
            switch self {
            case .calendar:  return "calendar"
            case .todos:     return "checklist"
            case .notes:     return "note.text"
            case .chat:      return "bubble.left"
            case .deadlines: return "flag"
            }
        }
    }

    var body: some View {
        Group {
            if isAuthenticated {
                mainContent
            } else {
                FlowAuthView {
                    isAuthenticated = true
                }
            }
        }
        .background(FlowTokens.bg0)
        .preferredColorScheme(.dark)
        .onAppear {
            let user = Auth.auth().currentUser
            isAuthenticated = user != nil

            authHandle = Auth.auth().addStateDidChangeListener { _, user in
                Task { @MainActor in
                    isAuthenticated = user != nil
                }
            }
        }
        .onDisappear {
            if let handle = authHandle {
                Auth.auth().removeStateDidChangeListener(handle)
            }
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(spacing: 0) {
            topHeader
            content
        }
        .background(FlowTokens.bg0.ignoresSafeArea())
        .background(WorkspaceShortcutHost(store: workspaceStore))
    }

    // MARK: - Top Header
    //
    // Rhythm (left → right):
    //   workspace chip · divider · title block · ⟨spacer⟩ · segmented picker · ⟨spacer⟩ · project · inspector · settings
    // Uniform 14pt vertical padding, single hairline at bottom, 2pt workspace
    // accent strip on top (replaces the bottom one — feels more native).

    private var topHeader: some View {
        VStack(spacing: 0) {
            // Workspace accent strip — thin color cue at very top of the panel.
            Rectangle()
                .fill((workspaceStore.activeWorkspace?.colorKey ?? .graphite).tint)
                .frame(height: FlowTokens.accentBarWidth)

            HStack(alignment: .center, spacing: FlowTokens.spacingLG) {
                WorkspaceSwitcherChip(store: workspaceStore)

                Rectangle()
                    .fill(FlowTokens.border)
                    .frame(width: FlowTokens.hairline, height: 24)

                titleBlock

                Spacer(minLength: FlowTokens.spacingMD)

                modeSegmentedControl

                Spacer(minLength: FlowTokens.spacingMD)

                if let project = projectContext {
                    projectChip(project)
                }

                controlButton(systemImage: "slider.horizontal.3", help: "AI Inspector") {
                    showInspector.toggle()
                }
                .sheet(isPresented: $showInspector) {
                    FlowHarnessInspectorView()
                }

                controlButton(systemImage: "gearshape", help: "Settings") {
                    showSettings.toggle()
                }
                .popover(isPresented: $showSettings, arrowEdge: .top) {
                    settingsPopover
                }
            }
            .padding(.horizontal, FlowTokens.spacingXL)
            .padding(.vertical, FlowTokens.spacingMD + 2)
            .background(FlowTokens.bg0)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(FlowTokens.border)
                    .frame(height: FlowTokens.hairline)
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(headerMonth)
                    .flowFont(.title2)
                    .foregroundColor(FlowTokens.textPrimary)
                Text(headerYear)
                    .flowFont(.title2)
                    .foregroundColor(FlowTokens.textTertiary)
            }
            Text(activeMode.rawValue.uppercased())
                .flowFont(.sectionLabel)
                .foregroundColor(FlowTokens.textTertiary)
        }
    }

    private var headerMonth: String {
        let f = DateFormatter(); f.dateFormat = "MMMM"
        return f.string(from: Date())
    }

    private var headerYear: String {
        let f = DateFormatter(); f.dateFormat = "yyyy"
        return f.string(from: Date())
    }

    // MARK: - Content

    private var content: some View {
        Group {
            switch activeMode {
            case .calendar:
                FlowCalendarView()
            case .todos:
                FlowTodoListView(projectContext: projectContext)
            case .notes:
                FlowNotesView()
            case .chat:
                FlowChatView(projectContext: projectContext, workspaceID: workspaceID)
            case .deadlines:
                FlowDeadlineView(projectContext: projectContext)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlowTokens.bg0)
        .transition(.opacity)
    }

    // MARK: - Segmented Mode Picker

    private var modeSegmentedControl: some View {
        HStack(spacing: 2) {
            ForEach(FlowMode.dockCases) { mode in
                segmentButton(mode)
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

    private func segmentButton(_ mode: FlowMode) -> some View {
        let isActive = activeMode == mode
        return Button {
            withAnimation(.flowQuick) { activeMode = mode }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(mode.rawValue)
                    .flowFont(.callout)
            }
            .foregroundColor(isActive ? FlowTokens.textPrimary : FlowTokens.textTertiary)
            .padding(.horizontal, FlowTokens.spacingMD)
            .frame(height: 24)
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: FlowTokens.radiusControl, style: .continuous)
                        .fill(FlowTokens.bg3)
                        .overlay(
                            RoundedRectangle(cornerRadius: FlowTokens.radiusControl, style: .continuous)
                                .strokeBorder(FlowTokens.borderStrong, lineWidth: FlowTokens.hairline)
                        )
                        .matchedGeometryEffect(id: "activeSeg", in: modeAnimation)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mode.rawValue)
    }

    // MARK: - Project Chip

    private func projectChip(_ project: String) -> some View {
        let name = (project as NSString).lastPathComponent
        return HStack(spacing: FlowTokens.spacingSM - 2) {
            syncStatusDot
            Text(name)
                .flowFont(.caption)
                .foregroundColor(FlowTokens.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, FlowTokens.spacingMD - 2)
        .frame(height: 26)
        .flowControl()
        .help(syncStatusLabel)
    }

    private var syncStatusDot: some View {
        Circle()
            .fill(syncStatusColor)
            .frame(width: 5, height: 5)
            .help(syncStatusLabel)
    }

    private var syncStatusColor: Color {
        switch syncService.syncStatus {
        case .listening: return FlowTokens.success
        case .connecting: return FlowTokens.warning
        case .error: return FlowTokens.error
        case .disconnected: return FlowTokens.textDisabled
        }
    }

    private var syncStatusLabel: String {
        switch syncService.syncStatus {
        case .listening: return "Synced"
        case .connecting: return "Connecting..."
        case .error(let msg): return "Error: \(msg)"
        case .disconnected: return "Disconnected"
        }
    }

    // MARK: - Settings Popover

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: FlowTokens.spacingLG) {
            if let user = Auth.auth().currentUser {
                HStack(spacing: FlowTokens.spacingMD) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundColor(FlowTokens.textTertiary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(user.displayName ?? "User")
                            .flowFont(.bodyMedium)
                            .foregroundColor(FlowTokens.textPrimary)
                        Text(user.email ?? user.uid.prefix(12).description)
                            .flowFont(.caption)
                            .foregroundColor(FlowTokens.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }

            Rectangle().fill(FlowTokens.border).frame(height: FlowTokens.hairline)

            // Sync row
            HStack(spacing: FlowTokens.spacingSM) {
                syncStatusDot
                Text(syncStatusLabel)
                    .flowFont(.caption)
                    .foregroundColor(FlowTokens.textSecondary)
                Spacer(minLength: 0)
                Button {
                    Task { await syncService.refreshNotebook() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(FlowTokens.textTertiary)
                        .frame(width: 22, height: 22)
                        .flowControl()
                }
                .buttonStyle(.plain)
                .help("Refresh sync")
            }

            if let lastSync = syncService.lastSyncDate {
                Text("Last synced \(lastSync.formatted(.relative(presentation: .named)))")
                    .flowFont(.micro)
                    .foregroundColor(FlowTokens.textMuted)
            }

            Rectangle().fill(FlowTokens.border).frame(height: FlowTokens.hairline)

            Button {
                try? Auth.auth().signOut()
                showSettings = false
            } label: {
                HStack(spacing: FlowTokens.spacingSM) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Sign Out")
                        .flowFont(.bodyMedium)
                    Spacer(minLength: 0)
                }
                .foregroundColor(FlowTokens.error)
                .padding(.horizontal, FlowTokens.spacingMD)
                .frame(height: 30)
                .flowControl()
            }
            .buttonStyle(.plain)
        }
        .padding(FlowTokens.spacingLG)
        .frame(width: FlowTokens.popoverWidth)
        .background(FlowTokens.bg1)
    }

    private func controlButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(FlowTokens.textSecondary)
                .frame(width: 26, height: 26)
                .flowControl()
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
