import Foundation
import Combine
import ClomeModels

// MARK: - Sync Notifications
//
// Kept here so existing observers (CalendarDataManager, etc.) continue to
// receive the same notification names. WorkspaceStore is the actual poster.

extension Notification.Name {
    static let flowNotebookDidSync = Notification.Name("flowNotebookDidSync")
    static let flowSyncStatusChanged = Notification.Name("flowSyncStatusChanged")
    static let flowTodosDidSync = Notification.Name("flowTodosDidSync")
    static let flowDeadlinesDidSync = Notification.Name("flowDeadlinesDidSync")
}

// MARK: - Sync Status

enum FlowSyncStatus: Sendable {
    case disconnected
    case connecting
    case listening
    case error(String)

    var isConnected: Bool {
        if case .listening = self { return true }
        return false
    }
}

// MARK: - FlowSyncService (Phase 2 facade)
//
// Phase 2 of the Flow Workspaces rollout (see docs/flow-workspaces-spec.md).
//
// As of this phase, FlowSyncService is a **thin facade over WorkspaceStore**.
// It exists for one reason: keeping the 14 existing call sites in the Flow
// codebase compiling without a sweeping refactor. Every published property,
// every CRUD method just forwards to `WorkspaceStore.shared`.
//
// The public API is intentionally unchanged from the pre-workspaces version.
// What *has* changed is what the data means: the notes/todos/deadlines you
// see here are now scoped to the active workspace (Personal in Phase 2,
// user-selectable in Phase 3+).
//
// Phase 6 will retire this facade in favor of direct WorkspaceStore usage
// at every call site. Until then, treat this file as a compatibility shim
// and add new functionality on WorkspaceStore directly.

@MainActor
final class FlowSyncService: ObservableObject {

    // MARK: - Singleton

    static let shared = FlowSyncService()

    // MARK: - Published State (mirrors WorkspaceStore)

    @Published private(set) var notes: [NoteEntry] = []
    @Published private(set) var todos: [TodoItem] = []
    @Published private(set) var deadlines: [Deadline] = []
    @Published private(set) var syncStatus: FlowSyncStatus = .disconnected
    @Published private(set) var lastSyncDate: Date?

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private let store = WorkspaceStore.shared

    private init() {
        // Mirror WorkspaceStore's published state into our own published
        // properties so SwiftUI views observing FlowSyncService keep updating.
        store.$notes
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.notes = $0 }
            .store(in: &cancellables)

        store.$tasks
            .receive(on: RunLoop.main)
            .sink { [weak self] (_: [TaskItem]) in
                guard let self else { return }
                self.todos = self.store.tasksAsTodos
            }
            .store(in: &cancellables)

        store.$deadlines
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.deadlines = $0 }
            .store(in: &cancellables)

        store.$syncStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.syncStatus = $0 }
            .store(in: &cancellables)

        store.$lastSyncDate
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.lastSyncDate = $0 }
            .store(in: &cancellables)
    }

    // MARK: - Note CRUD

    func addNote(_ note: NoteEntry) { store.addNote(note) }

    func updateNote(id: UUID, summary: String? = nil, category: NoteCategory? = nil,
                    actionItems: [ActionItem]? = nil, formattedContent: String? = nil,
                    isDone: Bool? = nil) {
        store.updateNote(
            id: id,
            summary: summary,
            category: category,
            actionItems: actionItems,
            formattedContent: formattedContent,
            isDone: isDone
        )
    }

    func deleteNote(id: UUID) { store.deleteNote(id: id) }
    func toggleDone(id: UUID) { store.toggleNoteDone(id: id) }

    func updateActionItem(entryID: UUID, actionItemID: UUID,
                          isScheduled: Bool, eventTitle: String?) {
        store.updateActionItem(
            entryID: entryID,
            actionItemID: actionItemID,
            isScheduled: isScheduled,
            eventTitle: eventTitle
        )
    }

    // MARK: - Todo CRUD (legacy shape — converts to TaskItem internally)

    func addTodo(_ todo: TodoItem) { store.addTodoCompat(todo) }

    func updateTodo(id: UUID, title: String? = nil, notes: String? = nil,
                    category: HabitCategory? = nil, priority: TodoPriority? = nil,
                    tags: [String]? = nil) {
        let mappedPriority: TaskPriority?
        if let priority {
            mappedPriority = TaskPriority(rawValue: priority.rawValue) ?? .medium
        } else {
            mappedPriority = nil
        }
        store.updateTask(
            id: id,
            title: title,
            notes: notes,
            category: category,
            priority: mappedPriority,
            tags: tags
        )
    }

    func updateTodoSchedule(id: UUID, scheduledDate: Date?, scheduledEndDate: Date?) {
        store.updateTaskSchedule(id: id, scheduledDate: scheduledDate, scheduledEndDate: scheduledEndDate)
    }

    func deleteTodo(id: UUID) { store.deleteTask(id: id) }
    func toggleTodoComplete(id: UUID) { store.toggleTaskComplete(id: id) }

    // MARK: - Deadline CRUD

    func addDeadline(_ deadline: Deadline) { store.addDeadline(deadline) }

    func updateDeadline(id: UUID, title: String? = nil, dueDate: Date? = nil,
                        category: HabitCategory? = nil, estimatedPrepHours: Double? = nil,
                        projectTag: String? = nil) {
        store.updateDeadline(
            id: id,
            title: title,
            dueDate: dueDate,
            category: category,
            estimatedPrepHours: estimatedPrepHours,
            projectTag: projectTag
        )
    }

    func deleteDeadline(id: UUID) { store.deleteDeadline(id: id) }
    func toggleDeadlineComplete(id: UUID) { store.toggleDeadlineComplete(id: id) }

    // MARK: - Queries

    var recentNotes: [NoteEntry] {
        notes.sorted { $0.createdAt > $1.createdAt }
    }

    func notes(for category: NoteCategory) -> [NoteEntry] {
        notes.filter { $0.category == category }
    }

    var pendingActionItems: [(entry: NoteEntry, item: ActionItem)] {
        notes.flatMap { entry in
            entry.actionItems
                .filter { !$0.isScheduled }
                .map { (entry: entry, item: $0) }
        }
    }

    func search(query: String) -> [NoteEntry] {
        let lower = query.lowercased()
        return notes.filter {
            $0.rawContent.lowercased().contains(lower) ||
            $0.summary.lowercased().contains(lower) ||
            $0.actionItems.contains { $0.description.lowercased().contains(lower) }
        }
    }

    // MARK: - Manual Refresh

    func refreshNotebook() async {
        await store.refreshNotebook()
    }
}
