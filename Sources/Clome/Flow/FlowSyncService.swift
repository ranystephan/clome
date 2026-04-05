import Foundation
import FirebaseAuth
import FirebaseFirestore
import Combine
import ClomeModels

// MARK: - Sync Notifications

extension Notification.Name {
    static let flowNotebookDidSync = Notification.Name("flowNotebookDidSync")
    static let flowSyncStatusChanged = Notification.Name("flowSyncStatusChanged")
    static let flowTodosDidSync = Notification.Name("flowTodosDidSync")
    static let flowDeadlinesDidSync = Notification.Name("flowDeadlinesDidSync")
}

// MARK: - Wrapper Types

/// Mirrors the iOS Notebook struct so we can decode the Firestore document directly.
struct FlowNotebook: Codable, Sendable {
    var entries: [NoteEntry]
    init(entries: [NoteEntry] = []) { self.entries = entries }
}

/// Wrapper for todo sync document.
struct FlowTodoStore: Codable, Sendable {
    var todos: [TodoItem]
    init(todos: [TodoItem] = []) { self.todos = todos }
}

/// Wrapper for deadline sync document.
struct FlowDeadlineStore: Codable, Sendable {
    var deadlines: [Deadline]
    init(deadlines: [Deadline] = []) { self.deadlines = deadlines }
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

// MARK: - FlowSyncService

/// Syncs notebook, todos, and deadlines between the macOS Clome app and Clome Flow via Firestore.
///
/// Firestore paths:
///   - `users/{uid}/sync/notebook`      — notes
///   - `users/{uid}/sync/todoStore`     — todos
///   - `users/{uid}/sync/deadlineStore` — deadlines
///
/// Encoding: JSONEncoder with default settings (Date as timeIntervalSinceReferenceDate).
@MainActor
final class FlowSyncService: ObservableObject {

    // MARK: - Singleton

    static let shared = FlowSyncService()

    // MARK: - Published State

    @Published private(set) var notes: [NoteEntry] = []
    @Published private(set) var todos: [TodoItem] = []
    @Published private(set) var deadlines: [Deadline] = []
    @Published private(set) var syncStatus: FlowSyncStatus = .disconnected
    @Published private(set) var lastSyncDate: Date?

    // MARK: - Private

    private let db = Firestore.firestore()
    private var notebookListener: ListenerRegistration?
    private var todoListener: ListenerRegistration?
    private var deadlineListener: ListenerRegistration?
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var currentUserId: String?

    private var isSyncingFromRemote = false
    private var notebookUploadTask: Task<Void, Never>?
    private var todoUploadTask: Task<Void, Never>?
    private var deadlineUploadTask: Task<Void, Never>?

    // MARK: - Storage Keys

    private static let cachedNotebookKey = "FlowSyncService.cachedNotebook"
    private static let cachedTodoStoreKey = "FlowSyncService.cachedTodoStore"
    private static let cachedDeadlineStoreKey = "FlowSyncService.cachedDeadlineStore"
    private static let lastSyncDateKey = "FlowSyncService.lastSyncDate"

    // MARK: - Lifecycle

    private init() {
        loadCachedData()
        startAuthObserver()
    }

    // MARK: - Auth Observation

    private func startAuthObserver() {
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                guard let self else { return }
                if let user {
                    self.startListening(userId: user.uid)
                } else {
                    self.stopListening()
                }
            }
        }

        if let user = Auth.auth().currentUser {
            startListening(userId: user.uid)
        }
    }

    // MARK: - Firestore Listeners

    private func startListening(userId: String) {
        guard currentUserId != userId else { return }
        stopListening()
        currentUserId = userId
        syncStatus = .connecting

        NSLog("[FlowSync] Starting listeners for user: \(userId)")

        let syncCollection = db.collection("users").document(userId).collection("sync")

        // Notebook listener
        notebookListener = syncCollection.document("notebook")
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        NSLog("[FlowSync] Notebook listener error: \(error.localizedDescription)")
                        self.syncStatus = .error(error.localizedDescription)
                        return
                    }
                    self.syncStatus = .listening
                    guard let snapshot, snapshot.exists, let data = snapshot.data() else {
                        NSLog("[FlowSync] Notebook document does not exist yet")
                        return
                    }
                    self.handleRemoteNotebook(data: data)
                }
            }

        // Todo listener
        todoListener = syncCollection.document("todoStore")
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        NSLog("[FlowSync] Todo listener error: \(error.localizedDescription)")
                        return
                    }
                    guard let snapshot, snapshot.exists, let data = snapshot.data() else {
                        NSLog("[FlowSync] TodoStore document does not exist yet")
                        return
                    }
                    self.handleRemoteTodos(data: data)
                }
            }

        // Deadline listener
        deadlineListener = syncCollection.document("deadlineStore")
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        NSLog("[FlowSync] Deadline listener error: \(error.localizedDescription)")
                        return
                    }
                    guard let snapshot, snapshot.exists, let data = snapshot.data() else {
                        NSLog("[FlowSync] DeadlineStore document does not exist yet")
                        return
                    }
                    self.handleRemoteDeadlines(data: data)
                }
            }
    }

    private func stopListening() {
        notebookListener?.remove()
        notebookListener = nil
        todoListener?.remove()
        todoListener = nil
        deadlineListener?.remove()
        deadlineListener = nil
        currentUserId = nil
        syncStatus = .disconnected
        NSLog("[FlowSync] Stopped listening")
    }

    // MARK: - Decoding

    private func handleRemoteNotebook(data: [String: Any]) {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: data, options: [])
            let notebook = try JSONDecoder().decode(FlowNotebook.self, from: jsonData)
            isSyncingFromRemote = true
            notes = notebook.entries
            lastSyncDate = Date()
            isSyncingFromRemote = false
            cacheNotebook(notebook)
            NotificationCenter.default.post(name: .flowNotebookDidSync, object: nil)
            NSLog("[FlowSync] Received \(notebook.entries.count) notes from Firestore")
        } catch {
            NSLog("[FlowSync] Failed to decode remote notebook: \(error)")
            syncStatus = .error("Decode error: \(error.localizedDescription)")
        }
    }

    private func handleRemoteTodos(data: [String: Any]) {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: data, options: [])
            let store = try JSONDecoder().decode(FlowTodoStore.self, from: jsonData)
            isSyncingFromRemote = true
            todos = store.todos
            isSyncingFromRemote = false
            cacheTodoStore(store)
            NotificationCenter.default.post(name: .flowTodosDidSync, object: nil)
            NSLog("[FlowSync] Received \(store.todos.count) todos from Firestore")
        } catch {
            NSLog("[FlowSync] Failed to decode remote todos: \(error)")
        }
    }

    private func handleRemoteDeadlines(data: [String: Any]) {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: data, options: [])
            let store = try JSONDecoder().decode(FlowDeadlineStore.self, from: jsonData)
            isSyncingFromRemote = true
            deadlines = store.deadlines
            isSyncingFromRemote = false
            cacheDeadlineStore(store)
            NotificationCenter.default.post(name: .flowDeadlinesDidSync, object: nil)
            NSLog("[FlowSync] Received \(store.deadlines.count) deadlines from Firestore")
        } catch {
            NSLog("[FlowSync] Failed to decode remote deadlines: \(error)")
        }
    }

    // MARK: - Upload (Notebooks)

    func uploadNotes() {
        guard !isSyncingFromRemote else { return }
        notebookUploadTask?.cancel()
        notebookUploadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.performNotebookUpload()
        }
    }

    func uploadNotesImmediately() {
        guard !isSyncingFromRemote else { return }
        notebookUploadTask?.cancel()
        Task { await performNotebookUpload() }
    }

    private func performNotebookUpload() async {
        guard let userId = currentUserId else { return }
        let notebook = FlowNotebook(entries: notes)
        do {
            let data = try JSONEncoder().encode(notebook)
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let docRef = db.collection("users").document(userId).collection("sync").document("notebook")
            try await docRef.setData(dict)
            NSLog("[FlowSync] Uploaded \(notebook.entries.count) notes")
        } catch {
            NSLog("[FlowSync] Note upload failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Upload (Todos)

    private func uploadTodos() {
        guard !isSyncingFromRemote else { return }
        todoUploadTask?.cancel()
        todoUploadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.performTodoUpload()
        }
    }

    private func performTodoUpload() async {
        guard let userId = currentUserId else { return }
        let store = FlowTodoStore(todos: todos)
        do {
            let data = try JSONEncoder().encode(store)
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let docRef = db.collection("users").document(userId).collection("sync").document("todoStore")
            try await docRef.setData(dict)
            NSLog("[FlowSync] Uploaded \(store.todos.count) todos")
        } catch {
            NSLog("[FlowSync] Todo upload failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Upload (Deadlines)

    private func uploadDeadlines() {
        guard !isSyncingFromRemote else { return }
        deadlineUploadTask?.cancel()
        deadlineUploadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.performDeadlineUpload()
        }
    }

    private func performDeadlineUpload() async {
        guard let userId = currentUserId else { return }
        let store = FlowDeadlineStore(deadlines: deadlines)
        do {
            let data = try JSONEncoder().encode(store)
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let docRef = db.collection("users").document(userId).collection("sync").document("deadlineStore")
            try await docRef.setData(dict)
            NSLog("[FlowSync] Uploaded \(store.deadlines.count) deadlines")
        } catch {
            NSLog("[FlowSync] Deadline upload failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Note CRUD

    func addNote(_ note: NoteEntry) {
        notes.append(note)
        cacheNotebook(FlowNotebook(entries: notes))
        uploadNotes()
    }

    func updateNote(id: UUID, summary: String? = nil, category: NoteCategory? = nil,
                    actionItems: [ActionItem]? = nil, formattedContent: String? = nil,
                    isDone: Bool? = nil) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        var entry = notes[index]
        if let summary { entry.summary = summary }
        if let category { entry.category = category }
        if let actionItems { entry.actionItems = actionItems }
        if let formattedContent { entry.formattedContent = formattedContent }
        if let isDone { entry.isDone = isDone }
        entry.updatedAt = Date()
        notes[index] = entry
        cacheNotebook(FlowNotebook(entries: notes))
        uploadNotes()
    }

    func deleteNote(id: UUID) {
        notes.removeAll { $0.id == id }
        cacheNotebook(FlowNotebook(entries: notes))
        uploadNotes()
    }

    func toggleDone(id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].isDone.toggle()
        notes[index].updatedAt = Date()
        cacheNotebook(FlowNotebook(entries: notes))
        uploadNotes()
    }

    func updateActionItem(entryID: UUID, actionItemID: UUID,
                          isScheduled: Bool, eventTitle: String?) {
        guard let entryIndex = notes.firstIndex(where: { $0.id == entryID }),
              let itemIndex = notes[entryIndex].actionItems.firstIndex(where: { $0.id == actionItemID })
        else { return }
        notes[entryIndex].actionItems[itemIndex].isScheduled = isScheduled
        notes[entryIndex].actionItems[itemIndex].scheduledEventTitle = eventTitle
        notes[entryIndex].updatedAt = Date()
        cacheNotebook(FlowNotebook(entries: notes))
        uploadNotes()
    }

    // MARK: - Todo CRUD

    func addTodo(_ todo: TodoItem) {
        todos.append(todo)
        cacheTodoStore(FlowTodoStore(todos: todos))
        uploadTodos()
    }

    func updateTodo(id: UUID, title: String? = nil, notes: String? = nil,
                    category: HabitCategory? = nil, priority: TodoPriority? = nil,
                    tags: [String]? = nil) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        if let title { todos[index].title = title }
        if let notes { todos[index].notes = notes }
        if let category { todos[index].category = category }
        if let priority { todos[index].priority = priority }
        if let tags { todos[index].tags = tags }
        cacheTodoStore(FlowTodoStore(todos: todos))
        uploadTodos()
    }

    func updateTodoSchedule(id: UUID, scheduledDate: Date?, scheduledEndDate: Date?) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[index].scheduledDate = scheduledDate
        todos[index].scheduledEndDate = scheduledEndDate
        cacheTodoStore(FlowTodoStore(todos: todos))
        uploadTodos()
    }

    func deleteTodo(id: UUID) {
        todos.removeAll { $0.id == id }
        cacheTodoStore(FlowTodoStore(todos: todos))
        uploadTodos()
    }

    func toggleTodoComplete(id: UUID) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[index].isCompleted.toggle()
        todos[index].completedDate = todos[index].isCompleted ? Date() : nil
        cacheTodoStore(FlowTodoStore(todos: todos))
        uploadTodos()
    }

    // MARK: - Deadline CRUD

    func addDeadline(_ deadline: Deadline) {
        deadlines.append(deadline)
        cacheDeadlineStore(FlowDeadlineStore(deadlines: deadlines))
        uploadDeadlines()
    }

    func updateDeadline(id: UUID, title: String? = nil, dueDate: Date? = nil,
                        category: HabitCategory? = nil, estimatedPrepHours: Double? = nil,
                        projectTag: String? = nil) {
        guard let index = deadlines.firstIndex(where: { $0.id == id }) else { return }
        if let title { deadlines[index].title = title }
        if let dueDate { deadlines[index].dueDate = dueDate }
        if let category { deadlines[index].category = category }
        if let estimatedPrepHours { deadlines[index].estimatedPrepHours = estimatedPrepHours }
        if let projectTag { deadlines[index].projectTag = projectTag }
        cacheDeadlineStore(FlowDeadlineStore(deadlines: deadlines))
        uploadDeadlines()
    }

    func deleteDeadline(id: UUID) {
        deadlines.removeAll { $0.id == id }
        cacheDeadlineStore(FlowDeadlineStore(deadlines: deadlines))
        uploadDeadlines()
    }

    func toggleDeadlineComplete(id: UUID) {
        guard let index = deadlines.firstIndex(where: { $0.id == id }) else { return }
        deadlines[index].isCompleted.toggle()
        cacheDeadlineStore(FlowDeadlineStore(deadlines: deadlines))
        uploadDeadlines()
    }

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

    // MARK: - Local Cache

    private func cacheNotebook(_ notebook: FlowNotebook) {
        guard let data = try? JSONEncoder().encode(notebook) else { return }
        UserDefaults.standard.set(data, forKey: Self.cachedNotebookKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastSyncDateKey)
    }

    private func cacheTodoStore(_ store: FlowTodoStore) {
        guard let data = try? JSONEncoder().encode(store) else { return }
        UserDefaults.standard.set(data, forKey: Self.cachedTodoStoreKey)
    }

    private func cacheDeadlineStore(_ store: FlowDeadlineStore) {
        guard let data = try? JSONEncoder().encode(store) else { return }
        UserDefaults.standard.set(data, forKey: Self.cachedDeadlineStoreKey)
    }

    private func loadCachedData() {
        // Decode all cached data first
        var loadedNotes: [NoteEntry] = []
        var loadedTodos: [TodoItem] = []
        var loadedDeadlines: [Deadline] = []
        var loadedSyncDate: Date?

        if let data = UserDefaults.standard.data(forKey: Self.cachedNotebookKey),
           let notebook = try? JSONDecoder().decode(FlowNotebook.self, from: data) {
            loadedNotes = notebook.entries
            NSLog("[FlowSync] Loaded \(loadedNotes.count) cached notes")
        }

        if let data = UserDefaults.standard.data(forKey: Self.cachedTodoStoreKey),
           let store = try? JSONDecoder().decode(FlowTodoStore.self, from: data) {
            loadedTodos = store.todos
            NSLog("[FlowSync] Loaded \(loadedTodos.count) cached todos")
        }

        if let data = UserDefaults.standard.data(forKey: Self.cachedDeadlineStoreKey),
           let store = try? JSONDecoder().decode(FlowDeadlineStore.self, from: data) {
            loadedDeadlines = store.deadlines
            NSLog("[FlowSync] Loaded \(loadedDeadlines.count) cached deadlines")
        }

        let timestamp = UserDefaults.standard.double(forKey: Self.lastSyncDateKey)
        if timestamp > 0 {
            loadedSyncDate = Date(timeIntervalSince1970: timestamp)
        }

        // Assign via backing storage to avoid publishing during init
        _notes = Published(initialValue: loadedNotes)
        _todos = Published(initialValue: loadedTodos)
        _deadlines = Published(initialValue: loadedDeadlines)
        _lastSyncDate = Published(initialValue: loadedSyncDate)
    }

    // MARK: - Manual Refresh

    func refreshNotebook() async {
        guard let userId = currentUserId else { return }
        let docRef = db.collection("users").document(userId).collection("sync").document("notebook")
        do {
            let snapshot = try await docRef.getDocument()
            guard snapshot.exists, let data = snapshot.data() else { return }
            handleRemoteNotebook(data: data)
        } catch {
            NSLog("[FlowSync] Refresh failed: \(error.localizedDescription)")
        }
    }
}
