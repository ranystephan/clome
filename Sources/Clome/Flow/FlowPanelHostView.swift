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
    @State private var activeMode: FlowMode = .todos
    @State private var authHandle: AuthStateDidChangeListenerHandle?
    @State private var showSettings = false
    @State private var showInspector = false
    @ObservedObject private var syncService = FlowSyncService.shared
    @Namespace private var modeAnimation

    enum FlowMode: String, CaseIterable {
        case calendar = "Calendar"
        case todos = "Todos"
        case notes = "Notes"
        case chat = "Chat"
        case deadlines = "Deadlines"

        var icon: String {
            switch self {
            case .calendar: return "calendar"
            case .todos: return "checklist"
            case .notes: return "note.text"
            case .chat: return "bubble.left.fill"
            case .deadlines: return "flag.fill"
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
            modeBar
            Divider().background(FlowTokens.border)

            if let project = projectContext {
                contextBar(project)
                Divider().background(FlowTokens.border)
            }

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
            .transition(.opacity.combined(with: .offset(y: 2)))
        }
    }

    // MARK: - Mode Bar

    private var modeBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: FlowTokens.spacingXS) {
                ForEach(FlowMode.allCases, id: \.self) { mode in
                    modeButton(mode)
                }
            }

            Spacer()

            // AI Inspector
            Button {
                showInspector.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(FlowTokens.textHint)
            }
            .buttonStyle(.plain)
            .help("AI Inspector")
            .sheet(isPresented: $showInspector) {
                FlowHarnessInspectorView()
            }

            Spacer().frame(width: FlowTokens.spacingSM)

            // Settings gear
            Button {
                showSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(FlowTokens.textHint)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                settingsPopover
            }
        }
        .padding(.horizontal, FlowTokens.spacingMD)
        .frame(height: FlowTokens.modeBarHeight)
        .background(FlowTokens.bg0)
    }

    private func modeButton(_ mode: FlowMode) -> some View {
        Button {
            withAnimation(.flowSpring) {
                activeMode = mode
            }
        } label: {
            Image(systemName: mode.icon)
                .font(.system(size: FlowTokens.iconSize, weight: .medium))
                .foregroundColor(activeMode == mode ? FlowTokens.textPrimary : FlowTokens.textHint)
                .frame(width: 32, height: 26)
                .background {
                    if activeMode == mode {
                        RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                            .fill(FlowTokens.accentSubtle)
                            .matchedGeometryEffect(id: "activeTab", in: modeAnimation)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(mode.rawValue)
    }

    // MARK: - Context Bar

    private func contextBar(_ project: String) -> some View {
        let name = (project as NSString).lastPathComponent
        return HStack(spacing: FlowTokens.spacingSM) {
            Image(systemName: "folder.fill")
                .font(.system(size: 8))
                .foregroundColor(FlowTokens.textDisabled)
            Text(name)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(FlowTokens.textHint)
            Spacer()
            syncStatusDot
        }
        .padding(.horizontal, 10)
        .frame(height: FlowTokens.contextBarHeight)
        .background(FlowTokens.bg0)
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
        VStack(alignment: .leading, spacing: FlowTokens.spacingMD) {
            // User info
            if let user = Auth.auth().currentUser {
                HStack(spacing: FlowTokens.spacingMD) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(FlowTokens.textTertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.displayName ?? "User")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(FlowTokens.textPrimary)
                        Text(user.email ?? user.uid.prefix(12).description)
                            .font(.system(size: 10))
                            .foregroundColor(FlowTokens.textTertiary)
                    }
                }
            }

            Divider()

            // Sync status
            HStack(spacing: FlowTokens.spacingSM) {
                syncStatusDot
                Text(syncStatusLabel)
                    .font(.system(size: 11))
                    .foregroundColor(FlowTokens.textSecondary)
                Spacer()
                Button {
                    Task { await syncService.refreshNotebook() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundColor(FlowTokens.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Refresh sync")
            }

            if let lastSync = syncService.lastSyncDate {
                Text("Last synced: \(lastSync.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(FlowTokens.textMuted)
            }

            Divider()

            // Sign out
            Button {
                try? Auth.auth().signOut()
                showSettings = false
            } label: {
                HStack(spacing: FlowTokens.spacingSM) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 10))
                    Text("Sign Out")
                        .font(.system(size: 11))
                }
                .foregroundColor(FlowTokens.error)
            }
            .buttonStyle(.plain)
        }
        .padding(FlowTokens.spacingLG)
        .frame(width: 220)
    }
}
