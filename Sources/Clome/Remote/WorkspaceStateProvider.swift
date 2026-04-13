// WorkspaceStateProvider.swift
// Serializes workspace/tab/pane state into WorkspaceSnapshot for streaming to remote iOS clients.

import AppKit

/// Produces `WorkspaceSnapshot` values from live `WorkspaceManager` state and emits
/// debounced change callbacks when the workspace tree mutates.
@MainActor
final class WorkspaceStateProvider {

    // MARK: - Version Counter

    /// Monotonic version that increments on every observed state change.
    private(set) var version: UInt64 = 0

    // MARK: - Change Callback

    /// Called (on the main actor) after state changes are detected and debounced.
    var onStateChanged: ((WorkspaceSnapshot) -> Void)?

    // MARK: - Debounce

    private static let debounceInterval: TimeInterval = 3.0 // 3 seconds — prevents flooding the remote connection
    private var debounceWorkItem: DispatchWorkItem?

    // MARK: - Observation State

    private weak var observedManager: WorkspaceManager?
    nonisolated(unsafe) private var notificationTokens: [NSObjectProtocol] = []

    // MARK: - Snapshot

    /// Build a complete snapshot of the current workspace state.
    static func snapshot(from manager: WorkspaceManager) -> WorkspaceSnapshot {
        // Use a shared instance version counter when called statically.
        // For one-off snapshots where version tracking is not needed, start at 0.
        return snapshot(from: manager, version: 0)
    }

    /// Build a snapshot tagged with the given version number.
    private static func snapshot(from manager: WorkspaceManager, version: UInt64) -> WorkspaceSnapshot {
        let workspaceStates = manager.workspaces.map { workspace in
            serializeWorkspace(workspace)
        }
        return WorkspaceSnapshot(
            version: version,
            workspaces: workspaceStates,
            activeWorkspaceIndex: manager.activeWorkspaceIndex
        )
    }

    /// Produce a versioned snapshot through this provider (increments the version counter).
    func versionedSnapshot(from manager: WorkspaceManager) -> WorkspaceSnapshot {
        version &+= 1
        return Self.snapshot(from: manager, version: version)
    }

    // MARK: - Workspace Serialization

    private static func serializeWorkspace(_ workspace: Workspace) -> WorkspaceState {
        let tabStates = workspace.tabs.map { tab in
            serializeTab(tab)
        }
        let unread = NotificationSystem.shared.unreadCount(for: workspace.id)

        return WorkspaceState(
            id: workspace.id.uuidString,
            name: workspace.name,
            icon: workspace.icon,
            color: workspace.color.rawValue,
            gitBranch: workspace.gitBranch,
            workingDirectory: workspace.workingDirectory,
            tabs: tabStates,
            activeTabIndex: workspace.activeTabIndex,
            unreadCount: unread
        )
    }

    // MARK: - Tab Serialization

    private static func serializeTab(_ tab: WorkspaceTab) -> TabState {
        let tabType = convertTabType(tab.type)
        let isDirty = extractDirtyState(from: tab)
        let activity = extractTerminalActivity(from: tab)

        return TabState(
            id: tab.id.uuidString,
            type: tabType,
            title: tab.title,
            isDirty: isDirty,
            activity: activity
        )
    }

    private static func convertTabType(_ type: WorkspaceTab.TabType) -> TabState.TabType {
        switch type {
        case .terminal: return .terminal
        case .browser:  return .browser
        case .editor:   return .editor
        case .pdf:      return .pdf
        case .notebook: return .notebook
        case .project:  return .project
        case .diff:     return .diff
        case .flow:     return .terminal // Flow maps to terminal for remote display
        }
    }

    // MARK: - Dirty State Extraction

    private static func extractDirtyState(from tab: WorkspaceTab) -> Bool {
        let view = tab.view

        if let editor = view as? EditorPanel {
            return editor.editorView.buffer.isDirty
        }
        if let notebook = view as? NotebookPanel {
            return notebook.store.isDirty
        }
        // For project panels, check if any sub-editor is dirty
        if let project = view as? ProjectPanel {
            return projectHasDirtyFiles(project)
        }
        return false
    }

    /// Walk a ProjectPanel's open files to detect any unsaved buffers.
    private static func projectHasDirtyFiles(_ project: ProjectPanel) -> Bool {
        for file in project.openFiles {
            if let editor = file.panel as? EditorPanel, editor.editorView.buffer.isDirty {
                return true
            }
            if let notebook = file.panel as? NotebookPanel, notebook.store.isDirty {
                return true
            }
        }
        return false
    }

    // MARK: - Terminal Activity Extraction

    /// Extract terminal activity from a tab. Handles both direct TerminalSurface views
    /// and TerminalSurfaces nested inside a PaneContainerView (split panes).
    private static func extractTerminalActivity(from tab: WorkspaceTab) -> TerminalActivity? {
        guard tab.type == .terminal else { return nil }

        // The focused pane takes priority for activity reporting
        if let focused = tab.focusedPane as? TerminalSurface {
            return activityFromSurface(focused)
        }

        // Direct terminal surface (no splits)
        if let surface = tab.view as? TerminalSurface {
            return activityFromSurface(surface)
        }

        // Split panes: find the first terminal surface via the split container
        let leaves = tab.splitContainer.allLeafViews
        for leaf in leaves {
            if let surface = leaf as? TerminalSurface {
                return activityFromSurface(surface)
            }
        }

        return nil
    }

    private static func activityFromSurface(_ surface: TerminalSurface) -> TerminalActivity {
        let state = convertActivityState(surface.activityState)
        let isClaudeCode = surface.detectedProgram == "Claude Code"

        // Read context percentage from the Claude context bridge file if Claude is running
        let contextPercentage: Int? = isClaudeCode
            ? readClaudeContextPercentage(for: surface)
            : nil

        return TerminalActivity(
            state: state,
            runningProgram: surface.detectedProgram,
            programIcon: surface.programIcon,
            isClaudeCode: isClaudeCode,
            claudeContextPercentage: contextPercentage,
            outputPreview: surface.outputPreview,
            needsAttention: surface.needsAttention
        )
    }

    private static func convertActivityState(_ state: TerminalSurface.ActivityState) -> TerminalActivity.ActivityState {
        switch state {
        case .idle:         return .idle
        case .running:      return .running
        case .waitingInput: return .waitingInput
        case .completed:    return .completed
        }
    }

    /// Read Claude Code context window usage from the shared temp file.
    /// The ClaudeContextBridge writes context percentage to /tmp/clome-claude-context.
    private static func readClaudeContextPercentage(for surface: TerminalSurface) -> Int? {
        let path = "/tmp/clome-claude-context"
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        // File format: single integer 0-100
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(trimmed)
    }

    // MARK: - Change Observation

    /// Start observing workspace-level changes on the given manager.
    /// Calls `onStateChanged` (debounced) whenever the workspace tree mutates.
    func observeChanges(manager: WorkspaceManager) {
        // Tear down any previous observation
        stopObserving()
        observedManager = manager

        let center = NotificationCenter.default

        // Terminal activity changes (output, program detection, command state)
        addObserver(center, name: .terminalActivityChanged) { [weak self] _ in
            Task { @MainActor in self?.scheduleEmit() }
        }

        // Workspace structure notifications (posted by ClomeWindow / WorkspaceManager)
        let structuralNames: [Notification.Name] = [
            .workspaceDidSwitchTab,
            .workspaceDidAddTab,
            .workspaceDidCloseTab,
            .workspaceDidSwitchWorkspace,
            .workspaceDidAddWorkspace,
            .workspaceDidRemoveWorkspace,
            .workspaceDidRename,
        ]
        for name in structuralNames {
            addObserver(center, name: name) { [weak self] _ in
                Task { @MainActor in self?.scheduleEmit() }
            }
        }

        // Terminal title changes (working directory, program detection)
        addObserver(center, name: .terminalSurfaceTitleChanged) { [weak self] _ in
            Task { @MainActor in self?.scheduleEmit() }
        }

        // Notification badge updates
        addObserver(center, name: .clomeNotificationCountChanged) { [weak self] _ in
            Task { @MainActor in self?.scheduleEmit() }
        }

        // Tab structure / selection changes (posted by Workspace)
        addObserver(center, name: .workspaceTabsChanged) { [weak self] _ in
            Task { @MainActor in self?.scheduleEmit() }
        }
        addObserver(center, name: .workspaceActiveTabChanged) { [weak self] _ in
            Task { @MainActor in self?.scheduleEmit() }
        }
    }

    /// Stop all observations and cancel pending debounce.
    func stopObserving() {
        let center = NotificationCenter.default
        for token in notificationTokens {
            center.removeObserver(token)
        }
        notificationTokens.removeAll()
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        observedManager = nil
    }

    // MARK: - Debounce & Emit

    private func scheduleEmit() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let manager = self.observedManager else { return }
            let snapshot = self.versionedSnapshot(from: manager)
            self.onStateChanged?(snapshot)
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    // MARK: - Helpers

    private func addObserver(
        _ center: NotificationCenter,
        name: Notification.Name,
        handler: @escaping @Sendable (Notification) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main, using: handler)
        notificationTokens.append(token)
    }

    deinit {
        // Capture the tokens before deinit completes to satisfy Sendable requirements.
        let tokens = notificationTokens
        let center = NotificationCenter.default
        for token in tokens {
            center.removeObserver(token)
        }
    }
}

// MARK: - Weak Reference Wrapper

/// Non-capturing weak wrapper to avoid retain cycles in closure callbacks.
private struct Weak<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

// MARK: - Notification Names

extension Notification.Name {
    // Workspace structural events (post these from WorkspaceManager / ClomeWindow as needed)
    static let workspaceDidSwitchTab = Notification.Name("workspaceDidSwitchTab")
    static let workspaceDidAddTab = Notification.Name("workspaceDidAddTab")
    static let workspaceDidCloseTab = Notification.Name("workspaceDidCloseTab")
    static let workspaceDidSwitchWorkspace = Notification.Name("workspaceDidSwitchWorkspace")
    static let workspaceDidAddWorkspace = Notification.Name("workspaceDidAddWorkspace")
    static let workspaceDidRemoveWorkspace = Notification.Name("workspaceDidRemoveWorkspace")
    static let workspaceDidRename = Notification.Name("workspaceDidRename")

    /// Posted by Workspace when tabs are added, removed, or reordered.
    static let workspaceTabsChanged = Notification.Name("workspaceTabsChanged")
    /// Posted by Workspace when the active tab selection changes.
    static let workspaceActiveTabChanged = Notification.Name("workspaceActiveTabChanged")
}
