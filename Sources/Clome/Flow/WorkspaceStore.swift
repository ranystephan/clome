import Foundation
@preconcurrency import FirebaseAuth
@preconcurrency import FirebaseFirestore
import Combine
import ClomeModels

// MARK: - WorkspaceStore
//
// Phase 2 of the Flow Workspaces rollout (see docs/flow-workspaces-spec.md).
//
// Owns:
//   - The list of workspaces the user has access to.
//   - The active workspace (per-device, persisted in UserDefaults).
//   - Listeners on the active workspace's content documents (notebook, tasks,
//     deadlines, calendar binding).
//
// Path resolution rules during the Mac/iOS transition window:
//   - Notebook for the Personal workspace lives at the legacy
//     `users/{uid}/sync/notebook` path so the iOS app's notebook continues to
//     round-trip with Mac. iOS only writes notes today; preserving this is
//     non-negotiable per user requirement ("the iOS ones are the only ones I
//     like").
//   - Tasks and deadlines for the Personal workspace live at the new
//     `workspaces/{id}/content/tasks|deadlines` paths because iOS doesn't
//     write either of those documents today, so there's nothing to preserve.
//   - All content for non-Personal workspaces lives at the new
//     `workspaces/{id}/content/...` paths.
//   - When iOS gains workspace awareness in Phase 4, the notebook special-
//     case is removed and a one-shot move runs.
//
// Active workspace switching is exposed via `setActiveWorkspace(_:)`. In
// Phase 2 the active workspace is forced to Personal at startup; the
// switcher UI lands in Phase 3.

@MainActor
final class WorkspaceStore: ObservableObject {

    // MARK: - Singleton

    static let shared = WorkspaceStore()

    // MARK: - Published State

    /// All workspaces the current user owns. Sorted by membership.pinnedOrder
    /// with Personal forced to index 0.
    @Published private(set) var workspaces: [FlowWorkspace] = []

    /// The active workspace's id. Drives all content listeners.
    @Published private(set) var activeWorkspaceID: String?

    /// Membership index document. Tracks pinned order, last opened, didMigrate.
    @Published private(set) var membership: WorkspaceMembership = WorkspaceMembership()

    /// Notes for the active workspace.
    @Published private(set) var notes: [NoteEntry] = []

    /// Tasks for the active workspace. Stored as TaskItem (the new canonical
    /// type) but exposed as TodoItem to the rest of the Mac UI for the Phase
    /// 2 transition; see `tasksAsTodos` and the FlowSyncService facade.
    @Published private(set) var tasks: [TaskItem] = []

    /// Deadlines for the active workspace.
    @Published private(set) var deadlines: [Deadline] = []

    /// Calendar binding for the active workspace.
    @Published private(set) var activeCalendarBinding: CalendarBinding = .personalDefault

    /// Sync status surface for the existing FlowSyncService facade.
    @Published private(set) var syncStatus: FlowSyncStatus = .disconnected
    @Published private(set) var lastSyncDate: Date?

    // MARK: - Computed

    /// Convenience for callers that haven't been migrated to TaskItem yet.
    /// Returns tasks projected back into TodoItem (drops workspaceId and
    /// parentNoteId). Will be removed when Phase 6 ships.
    var tasksAsTodos: [TodoItem] {
        tasks.map { task in
            TodoItem(
                id: task.id,
                title: task.title,
                notes: task.notes,
                category: task.category,
                priority: TodoPriority(rawValue: task.priority.rawValue) ?? .medium,
                tags: task.tags,
                isCompleted: task.isCompleted,
                completedDate: task.completedDate,
                createdDate: task.createdDate,
                scheduledDate: task.scheduledDate,
                scheduledEndDate: task.scheduledEndDate
            )
        }
    }

    var activeWorkspace: FlowWorkspace? {
        guard let activeWorkspaceID else { return nil }
        return workspaces.first { $0.id == activeWorkspaceID }
    }

    // MARK: - Private

    private let db = Firestore.firestore()
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var currentUserId: String?

    private var workspacesListener: ListenerRegistration?
    private var membershipListener: ListenerRegistration?
    private var notebookListener: ListenerRegistration?
    private var tasksListener: ListenerRegistration?
    private var deadlinesListener: ListenerRegistration?
    private var bindingListener: ListenerRegistration?

    private var isSyncingFromRemote = false
    private var notebookUploadTask: Task<Void, Never>?
    private var tasksUploadTask: Task<Void, Never>?
    private var deadlinesUploadTask: Task<Void, Never>?

    private static let activeWorkspaceKey = "WorkspaceStore.activeWorkspaceID"
    private static let cachedNotesKey = "WorkspaceStore.cachedNotes"
    private static let cachedTasksKey = "WorkspaceStore.cachedTasks"
    private static let cachedDeadlinesKey = "WorkspaceStore.cachedDeadlines"
    private static let lastSyncDateKey = "WorkspaceStore.lastSyncDate"

    // MARK: - Lifecycle

    private init() {
        loadCachedData()
        startAuthObserver()
    }

    private func startAuthObserver() {
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                guard let self else { return }
                if let user {
                    await self.bootstrap(uid: user.uid)
                } else {
                    self.teardown()
                }
            }
        }
        if let user = Auth.auth().currentUser {
            Task { @MainActor in await bootstrap(uid: user.uid) }
        }
    }

    /// Stand up listeners and run migration for the given user.
    private func bootstrap(uid: String) async {
        guard currentUserId != uid else { return }
        teardown()
        currentUserId = uid
        syncStatus = .connecting

        // 1. Run migration before attaching content listeners. Migration is
        //    idempotent and only writes if `membership.didMigrate == false`.
        await runMigrationIfNeeded(uid: uid)

        // 2. Attach the workspace and membership listeners (always on).
        attachWorkspacesListener(uid: uid)
        attachMembershipListener(uid: uid)

        // 3. Resolve which workspace to make active.
        let resolved = resolveInitialActiveWorkspace(uid: uid)
        await setActiveWorkspace(id: resolved)
    }

    private func teardown() {
        workspacesListener?.remove(); workspacesListener = nil
        membershipListener?.remove(); membershipListener = nil
        detachContentListeners()
        currentUserId = nil
        syncStatus = .disconnected
    }

    private func detachContentListeners() {
        notebookListener?.remove(); notebookListener = nil
        tasksListener?.remove(); tasksListener = nil
        deadlinesListener?.remove(); deadlinesListener = nil
        bindingListener?.remove(); bindingListener = nil
    }

    // MARK: - Migration

    /// Phase 2 migration: ensure Personal exists and a membership doc is
    /// written. Idempotent — safe to re-run, safe to interrupt.
    private func runMigrationIfNeeded(uid: String) async {
        let membershipRef = db.collection("users").document(uid).collection("membership").document("index")

        do {
            let snapshot = try await membershipRef.getDocument()
            if snapshot.exists,
               let data = snapshot.data(),
               let didMigrate = data["didMigrate"] as? Bool,
               didMigrate {
                NSLog("[WorkspaceStore] Migration already complete for uid \(uid)")
                return
            }

            NSLog("[WorkspaceStore] Running first-launch migration for uid \(uid)")

            // Step 1: ensure Personal workspace exists.
            //
            // We deliberately skip Firestore transactions here because the
            // SDK's runTransaction closure isn't Sendable under Swift 6.
            // Two devices racing the migration both compute identical
            // payloads from a deterministic ID, so a last-write-wins
            // setData() is safe.
            let personal = FlowWorkspace.makePersonal(uid: uid)
            let personalRef = db.collection("workspaces").document(personal.id)
            let existingPersonal = try await personalRef.getDocument()
            if !existingPersonal.exists {
                nonisolated(unsafe) let payload = try Self.encodeWorkspace(personal)
                try await personalRef.setData(payload)
            }

            // Step 2: ensure the calendar binding for Personal exists with
            // includeAllCalendars = true (the default per spec D3).
            let bindingRef = db.collection("workspaces").document(personal.id).collection("calendarBinding").document("default")
            let existingBinding = try await bindingRef.getDocument()
            if !existingBinding.exists {
                nonisolated(unsafe) let bindingDict = try Self.encodeBinding(.personalDefault)
                try await bindingRef.setData(bindingDict)
            }

            // Step 3: write membership doc with didMigrate=true.
            let newMembership = WorkspaceMembership(
                workspaceIds: [personal.id],
                lastOpenedWorkspaceId: personal.id,
                pinnedOrder: [personal.id],
                didMigrate: true
            )
            nonisolated(unsafe) let membershipDict = try Self.encodeMembership(newMembership)
            try await membershipRef.setData(membershipDict)

            NSLog("[WorkspaceStore] Migration complete: Personal workspace \(personal.id)")
        } catch {
            NSLog("[WorkspaceStore] Migration failed: \(error.localizedDescription)")
            // Don't set didMigrate; will retry on next launch.
        }
    }

    // MARK: - Workspace List Listener

    private func attachWorkspacesListener(uid: String) {
        let q = db.collection("workspaces").whereField("ownerUid", isEqualTo: uid)
        workspacesListener = q.addSnapshotListener { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    NSLog("[WorkspaceStore] Workspaces listener error: \(error.localizedDescription)")
                    return
                }
                guard let snapshot else { return }
                let decoded: [FlowWorkspace] = snapshot.documents.compactMap { doc in
                    Self.decodeWorkspace(from: doc.data())
                }
                self.workspaces = self.sortWorkspaces(decoded)
                self.syncStatus = .listening
                NSLog("[WorkspaceStore] Workspaces synced: \(decoded.count)")
            }
        }
    }

    private func attachMembershipListener(uid: String) {
        let ref = db.collection("users").document(uid).collection("membership").document("index")
        membershipListener = ref.addSnapshotListener { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    NSLog("[WorkspaceStore] Membership listener error: \(error.localizedDescription)")
                    return
                }
                guard let snapshot, snapshot.exists, let data = snapshot.data() else { return }
                if let m = Self.decodeMembership(from: data) {
                    self.membership = m
                    self.workspaces = self.sortWorkspaces(self.workspaces)
                }
            }
        }
    }

    private func sortWorkspaces(_ list: [FlowWorkspace]) -> [FlowWorkspace] {
        guard let uid = currentUserId else { return list }
        let personalID = FlowWorkspace.personalID(for: uid)
        let order = membership.orderedWorkspaceIDs(personalID: personalID)
        let dict = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        var ordered: [FlowWorkspace] = []
        var seen = Set<String>()
        for id in order {
            if let ws = dict[id], !ws.isArchived {
                ordered.append(ws)
                seen.insert(id)
            }
        }
        for ws in list where !seen.contains(ws.id) && !ws.isArchived {
            ordered.append(ws)
        }
        return ordered
    }

    // MARK: - Active Workspace

    private func resolveInitialActiveWorkspace(uid: String) -> String {
        if let stored = UserDefaults.standard.string(forKey: Self.activeWorkspaceKey),
           !stored.isEmpty {
            return stored
        }
        if let last = membership.lastOpenedWorkspaceId, !last.isEmpty {
            return last
        }
        return FlowWorkspace.personalID(for: uid)
    }

    /// Switch the active workspace. Detaches old content listeners and
    /// reattaches at the new workspace's paths. Persists the choice locally.
    func setActiveWorkspace(id: String) async {
        guard let uid = currentUserId else { return }
        guard activeWorkspaceID != id else { return }

        detachContentListeners()
        activeWorkspaceID = id
        notes = []
        tasks = []
        deadlines = []
        activeCalendarBinding = .personalDefault

        UserDefaults.standard.set(id, forKey: Self.activeWorkspaceKey)

        attachContentListeners(uid: uid, workspaceId: id)
    }

    // MARK: - Workspace CRUD

    /// Create a new workspace, write it to Firestore, and add it to the
    /// membership index. Switches the active workspace to the new one on
    /// success.
    @discardableResult
    func createWorkspace(name: String, colorKey: WorkspaceColorKey, icon: String) async -> FlowWorkspace? {
        guard let uid = currentUserId else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let id = UUID().uuidString
        let workspace = FlowWorkspace(
            id: id,
            name: trimmed,
            slug: FlowWorkspace.slugify(trimmed),
            icon: icon,
            colorKey: colorKey,
            ownerUid: uid,
            createdAt: Date(),
            updatedAt: Date(),
            isPersonal: false,
            isArchived: false,
            sortOrder: workspaces.count
        )

        do {
            // 1. Write the workspace doc.
            nonisolated(unsafe) let payload = try Self.encodeWorkspace(workspace)
            try await db.collection("workspaces").document(id).setData(payload)

            // 2. Seed an empty calendar binding (defaults to all calendars).
            nonisolated(unsafe) let bindingPayload = try Self.encodeBinding(.personalDefault)
            try await Self.bindingDocument(db: db, workspaceId: id).setData(bindingPayload)

            // 3. Update the membership index — add to workspaceIds and append
            //    to pinnedOrder so keyboard shortcuts pick it up.
            var updated = membership
            if !updated.workspaceIds.contains(id) {
                updated.workspaceIds.append(id)
            }
            if !updated.pinnedOrder.contains(id) {
                updated.pinnedOrder.append(id)
            }
            updated.lastOpenedWorkspaceId = id
            try await persistMembership(updated)

            // 4. Switch to the newly created workspace.
            await setActiveWorkspace(id: id)
            return workspace
        } catch {
            NSLog("[WorkspaceStore] createWorkspace failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Persists the membership doc and updates the local published copy.
    private func persistMembership(_ m: WorkspaceMembership) async throws {
        guard let uid = currentUserId else { return }
        nonisolated(unsafe) let dict = try Self.encodeMembership(m)
        try await db.collection("users").document(uid)
            .collection("membership").document("index").setData(dict)
        // The listener will update self.membership; mirror locally too so
        // the switcher reflects the change immediately.
        self.membership = m
    }

    // MARK: - Content Listeners

    private func attachContentListeners(uid: String, workspaceId: String) {
        // Notebook (legacy path special-case for Personal)
        let notebookRef = Self.notebookDocument(db: db, uid: uid, workspaceId: workspaceId)
        notebookListener = notebookRef.addSnapshotListener { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    NSLog("[WorkspaceStore] Notebook listener error: \(error.localizedDescription)")
                    self.syncStatus = .error(error.localizedDescription)
                    return
                }
                self.syncStatus = .listening
                guard let snapshot, snapshot.exists, let data = snapshot.data() else { return }
                self.handleRemoteNotebook(data: data)
            }
        }

        // Tasks
        let tasksRef = Self.tasksDocument(db: db, workspaceId: workspaceId)
        tasksListener = tasksRef.addSnapshotListener { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    NSLog("[WorkspaceStore] Tasks listener error: \(error.localizedDescription)")
                    return
                }
                guard let snapshot, snapshot.exists, let data = snapshot.data() else { return }
                self.handleRemoteTasks(data: data)
            }
        }

        // Deadlines
        let deadlinesRef = Self.deadlinesDocument(db: db, workspaceId: workspaceId)
        deadlinesListener = deadlinesRef.addSnapshotListener { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    NSLog("[WorkspaceStore] Deadlines listener error: \(error.localizedDescription)")
                    return
                }
                guard let snapshot, snapshot.exists, let data = snapshot.data() else { return }
                self.handleRemoteDeadlines(data: data)
            }
        }

        // Calendar binding
        let bindingRef = Self.bindingDocument(db: db, workspaceId: workspaceId)
        bindingListener = bindingRef.addSnapshotListener { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self else { return }
                if error != nil { return }
                guard let snapshot, snapshot.exists, let data = snapshot.data() else {
                    self.activeCalendarBinding = .personalDefault
                    return
                }
                if let b = Self.decodeBinding(from: data) {
                    self.activeCalendarBinding = b
                }
            }
        }
    }

    // MARK: - Remote Decode Handlers

    private func handleRemoteNotebook(data: [String: Any]) {
        do {
            let json = try JSONSerialization.data(withJSONObject: data)
            let wrapper = try JSONDecoder().decode(NotebookWrapper.self, from: json)
            isSyncingFromRemote = true
            notes = wrapper.entries
            isSyncingFromRemote = false
            cacheNotes()
            lastSyncDate = Date()
            NotificationCenter.default.post(name: .flowNotebookDidSync, object: nil)
        } catch {
            NSLog("[WorkspaceStore] Notebook decode failed: \(error)")
        }
    }

    private func handleRemoteTasks(data: [String: Any]) {
        do {
            let json = try JSONSerialization.data(withJSONObject: data)
            let wrapper = try JSONDecoder().decode(TaskStoreWrapper.self, from: json)
            isSyncingFromRemote = true
            tasks = wrapper.items
            isSyncingFromRemote = false
            cacheTasks()
            NotificationCenter.default.post(name: .flowTodosDidSync, object: nil)
        } catch {
            NSLog("[WorkspaceStore] Tasks decode failed: \(error)")
        }
    }

    private func handleRemoteDeadlines(data: [String: Any]) {
        do {
            let json = try JSONSerialization.data(withJSONObject: data)
            let wrapper = try JSONDecoder().decode(DeadlineStoreWrapper.self, from: json)
            isSyncingFromRemote = true
            deadlines = wrapper.items
            isSyncingFromRemote = false
            cacheDeadlines()
            NotificationCenter.default.post(name: .flowDeadlinesDidSync, object: nil)
        } catch {
            NSLog("[WorkspaceStore] Deadlines decode failed: \(error)")
        }
    }

    // MARK: - Note CRUD

    func addNote(_ note: NoteEntry) {
        var stamped = note
        stamped.workspaceId = activeWorkspaceID
        notes.append(stamped)
        cacheNotes()
        scheduleNotebookUpload()
    }

    func updateNote(id: UUID, summary: String? = nil, category: NoteCategory? = nil,
                    actionItems: [ActionItem]? = nil, formattedContent: String? = nil,
                    isDone: Bool? = nil) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        var entry = notes[idx]
        if let summary { entry.summary = summary }
        if let category { entry.category = category }
        if let actionItems { entry.actionItems = actionItems }
        if let formattedContent { entry.formattedContent = formattedContent }
        if let isDone { entry.isDone = isDone }
        entry.updatedAt = Date()
        notes[idx] = entry
        cacheNotes()
        scheduleNotebookUpload()
    }

    func deleteNote(id: UUID) {
        notes.removeAll { $0.id == id }
        cacheNotes()
        scheduleNotebookUpload()
    }

    func toggleNoteDone(id: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[idx].isDone.toggle()
        notes[idx].updatedAt = Date()
        cacheNotes()
        scheduleNotebookUpload()
    }

    func updateActionItem(entryID: UUID, actionItemID: UUID,
                          isScheduled: Bool, eventTitle: String?) {
        guard let entryIdx = notes.firstIndex(where: { $0.id == entryID }),
              let itemIdx = notes[entryIdx].actionItems.firstIndex(where: { $0.id == actionItemID })
        else { return }
        notes[entryIdx].actionItems[itemIdx].isScheduled = isScheduled
        notes[entryIdx].actionItems[itemIdx].scheduledEventTitle = eventTitle
        notes[entryIdx].updatedAt = Date()
        cacheNotes()
        scheduleNotebookUpload()
    }

    // MARK: - Task CRUD

    func addTask(_ task: TaskItem) {
        var stamped = task
        stamped.workspaceId = activeWorkspaceID
        tasks.append(stamped)
        cacheTasks()
        scheduleTasksUpload()
    }

    /// Adds a task constructed from the legacy TodoItem shape.
    func addTodoCompat(_ todo: TodoItem) {
        let task = TaskItem(
            id: todo.id,
            workspaceId: activeWorkspaceID,
            title: todo.title,
            notes: todo.notes,
            category: todo.category,
            priority: TaskPriority(rawValue: todo.priority.rawValue) ?? .medium,
            tags: todo.tags,
            isCompleted: todo.isCompleted,
            completedDate: todo.completedDate,
            createdDate: todo.createdDate,
            scheduledDate: todo.scheduledDate,
            scheduledEndDate: todo.scheduledEndDate
        )
        addTask(task)
    }

    func updateTask(id: UUID, title: String? = nil, notes: String? = nil,
                    category: HabitCategory? = nil, priority: TaskPriority? = nil,
                    tags: [String]? = nil) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        if let title { tasks[idx].title = title }
        if let notes { tasks[idx].notes = notes }
        if let category { tasks[idx].category = category }
        if let priority { tasks[idx].priority = priority }
        if let tags { tasks[idx].tags = tags }
        cacheTasks()
        scheduleTasksUpload()
    }

    func updateTaskSchedule(id: UUID, scheduledDate: Date?, scheduledEndDate: Date?) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].scheduledDate = scheduledDate
        tasks[idx].scheduledEndDate = scheduledEndDate
        cacheTasks()
        scheduleTasksUpload()
    }

    func deleteTask(id: UUID) {
        tasks.removeAll { $0.id == id }
        cacheTasks()
        scheduleTasksUpload()
    }

    func toggleTaskComplete(id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].isCompleted.toggle()
        tasks[idx].completedDate = tasks[idx].isCompleted ? Date() : nil
        cacheTasks()
        scheduleTasksUpload()
    }

    // MARK: - Deadline CRUD

    func addDeadline(_ deadline: Deadline) {
        var stamped = deadline
        stamped.workspaceId = activeWorkspaceID
        deadlines.append(stamped)
        cacheDeadlines()
        scheduleDeadlinesUpload()
    }

    func updateDeadline(id: UUID, title: String? = nil, dueDate: Date? = nil,
                        category: HabitCategory? = nil, estimatedPrepHours: Double? = nil,
                        projectTag: String? = nil) {
        guard let idx = deadlines.firstIndex(where: { $0.id == id }) else { return }
        if let title { deadlines[idx].title = title }
        if let dueDate { deadlines[idx].dueDate = dueDate }
        if let category { deadlines[idx].category = category }
        if let estimatedPrepHours { deadlines[idx].estimatedPrepHours = estimatedPrepHours }
        if let projectTag { deadlines[idx].projectTag = projectTag }
        cacheDeadlines()
        scheduleDeadlinesUpload()
    }

    func deleteDeadline(id: UUID) {
        deadlines.removeAll { $0.id == id }
        cacheDeadlines()
        scheduleDeadlinesUpload()
    }

    func toggleDeadlineComplete(id: UUID) {
        guard let idx = deadlines.firstIndex(where: { $0.id == id }) else { return }
        deadlines[idx].isCompleted.toggle()
        cacheDeadlines()
        scheduleDeadlinesUpload()
    }

    // MARK: - Manual refresh (notebook)

    func refreshNotebook() async {
        guard let uid = currentUserId, let wsId = activeWorkspaceID else { return }
        let ref = Self.notebookDocument(db: db, uid: uid, workspaceId: wsId)
        do {
            let snap = try await ref.getDocument()
            guard snap.exists, let data = snap.data() else { return }
            handleRemoteNotebook(data: data)
        } catch {
            NSLog("[WorkspaceStore] Refresh failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Upload Scheduling

    private func scheduleNotebookUpload() {
        guard !isSyncingFromRemote else { return }
        notebookUploadTask?.cancel()
        notebookUploadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.performNotebookUpload()
        }
    }

    private func scheduleTasksUpload() {
        guard !isSyncingFromRemote else { return }
        tasksUploadTask?.cancel()
        tasksUploadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.performTasksUpload()
        }
    }

    private func scheduleDeadlinesUpload() {
        guard !isSyncingFromRemote else { return }
        deadlinesUploadTask?.cancel()
        deadlinesUploadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.performDeadlinesUpload()
        }
    }

    private func performNotebookUpload() async {
        guard let uid = currentUserId, let wsId = activeWorkspaceID else { return }
        let wrapper = NotebookWrapper(entries: notes)
        do {
            let json = try JSONEncoder().encode(wrapper)
            guard let parsed = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { return }
            nonisolated(unsafe) let dict = parsed
            try await Self.notebookDocument(db: db, uid: uid, workspaceId: wsId).setData(dict)
        } catch {
            NSLog("[WorkspaceStore] Notebook upload failed: \(error.localizedDescription)")
        }
    }

    private func performTasksUpload() async {
        guard let wsId = activeWorkspaceID else { return }
        let wrapper = TaskStoreWrapper(items: tasks)
        do {
            let json = try JSONEncoder().encode(wrapper)
            guard let parsed = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { return }
            nonisolated(unsafe) let dict = parsed
            try await Self.tasksDocument(db: db, workspaceId: wsId).setData(dict)
        } catch {
            NSLog("[WorkspaceStore] Tasks upload failed: \(error.localizedDescription)")
        }
    }

    private func performDeadlinesUpload() async {
        guard let wsId = activeWorkspaceID else { return }
        let wrapper = DeadlineStoreWrapper(items: deadlines)
        do {
            let json = try JSONEncoder().encode(wrapper)
            guard let parsed = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { return }
            nonisolated(unsafe) let dict = parsed
            try await Self.deadlinesDocument(db: db, workspaceId: wsId).setData(dict)
        } catch {
            NSLog("[WorkspaceStore] Deadlines upload failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Local cache

    private func cacheNotes() {
        guard let data = try? JSONEncoder().encode(NotebookWrapper(entries: notes)) else { return }
        UserDefaults.standard.set(data, forKey: Self.cachedNotesKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastSyncDateKey)
    }

    private func cacheTasks() {
        guard let data = try? JSONEncoder().encode(TaskStoreWrapper(items: tasks)) else { return }
        UserDefaults.standard.set(data, forKey: Self.cachedTasksKey)
    }

    private func cacheDeadlines() {
        guard let data = try? JSONEncoder().encode(DeadlineStoreWrapper(items: deadlines)) else { return }
        UserDefaults.standard.set(data, forKey: Self.cachedDeadlinesKey)
    }

    private func loadCachedData() {
        var loadedNotes: [NoteEntry] = []
        var loadedTasks: [TaskItem] = []
        var loadedDeadlines: [Deadline] = []
        var loadedDate: Date?

        if let data = UserDefaults.standard.data(forKey: Self.cachedNotesKey),
           let wrapper = try? JSONDecoder().decode(NotebookWrapper.self, from: data) {
            loadedNotes = wrapper.entries
        }
        if let data = UserDefaults.standard.data(forKey: Self.cachedTasksKey),
           let wrapper = try? JSONDecoder().decode(TaskStoreWrapper.self, from: data) {
            loadedTasks = wrapper.items
        }
        if let data = UserDefaults.standard.data(forKey: Self.cachedDeadlinesKey),
           let wrapper = try? JSONDecoder().decode(DeadlineStoreWrapper.self, from: data) {
            loadedDeadlines = wrapper.items
        }
        let ts = UserDefaults.standard.double(forKey: Self.lastSyncDateKey)
        if ts > 0 { loadedDate = Date(timeIntervalSince1970: ts) }

        _notes = Published(initialValue: loadedNotes)
        _tasks = Published(initialValue: loadedTasks)
        _deadlines = Published(initialValue: loadedDeadlines)
        _lastSyncDate = Published(initialValue: loadedDate)
    }

    // MARK: - Path Resolution

    /// Returns the document reference for the active workspace's notebook.
    /// Personal workspace gets the legacy `users/{uid}/sync/notebook` path so
    /// the iOS app's notebook continues to round-trip until iOS gains
    /// workspace awareness in Phase 4.
    static func notebookDocument(db: Firestore, uid: String, workspaceId: String) -> DocumentReference {
        if workspaceId == FlowWorkspace.personalID(for: uid) {
            return db.collection("users").document(uid).collection("sync").document("notebook")
        }
        return db.collection("workspaces").document(workspaceId)
            .collection("content").document("notebook")
    }

    static func tasksDocument(db: Firestore, workspaceId: String) -> DocumentReference {
        db.collection("workspaces").document(workspaceId)
            .collection("content").document("tasks")
    }

    static func deadlinesDocument(db: Firestore, workspaceId: String) -> DocumentReference {
        db.collection("workspaces").document(workspaceId)
            .collection("content").document("deadlines")
    }

    static func bindingDocument(db: Firestore, workspaceId: String) -> DocumentReference {
        db.collection("workspaces").document(workspaceId)
            .collection("calendarBinding").document("default")
    }

    // MARK: - Codec helpers

    private static func encodeWorkspace(_ ws: FlowWorkspace) throws -> [String: Any] {
        let data = try JSONEncoder().encode(ws)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func decodeWorkspace(from dict: [String: Any]) -> FlowWorkspace? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(FlowWorkspace.self, from: data)
    }

    private static func encodeBinding(_ b: CalendarBinding) throws -> [String: Any] {
        let data = try JSONEncoder().encode(b)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func decodeBinding(from dict: [String: Any]) -> CalendarBinding? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(CalendarBinding.self, from: data)
    }

    private static func encodeMembership(_ m: WorkspaceMembership) throws -> [String: Any] {
        let data = try JSONEncoder().encode(m)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func decodeMembership(from dict: [String: Any]) -> WorkspaceMembership? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(WorkspaceMembership.self, from: data)
    }
}

// MARK: - Wire-format wrappers

private struct NotebookWrapper: Codable {
    var entries: [NoteEntry]
}

private struct TaskStoreWrapper: Codable {
    var items: [TaskItem]
}

private struct DeadlineStoreWrapper: Codable {
    var items: [Deadline]
}
