import SwiftUI
import ClomeModels

/// Redesigned todo list for the Flow panel with priority grouping,
/// animated checkboxes, and Firestore sync via FlowSyncService.
struct FlowTodoListView: View {
    let projectContext: String?

    @ObservedObject private var syncService = FlowSyncService.shared
    @State private var newTodoText = ""
    @State private var newTodoPriority: TodoPriority = .medium
    @State private var showPriorityPicker = false
    @State private var showCompleted = false
    @State private var editingTodoID: UUID?
    @State private var editingText = ""
    @FocusState private var isInputFocused: Bool
    @FocusState private var isEditFocused: Bool

    private var activeTodos: [TodoItem] {
        syncService.todos
            .filter { !$0.isCompleted }
            .sorted { $0.priority.sortOrder < $1.priority.sortOrder }
    }

    private var completedTodos: [TodoItem] {
        syncService.todos
            .filter { $0.isCompleted }
            .sorted { ($0.completedDate ?? $0.createdDate) > ($1.completedDate ?? $1.createdDate) }
    }

    private func todosForPriority(_ priority: TodoPriority) -> [TodoItem] {
        activeTodos.filter { $0.priority == priority }
    }

    var body: some View {
        VStack(spacing: 0) {
            inputBar
            Rectangle().fill(FlowTokens.border).frame(height: FlowTokens.hairline)
            todoList
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: FlowTokens.spacingSM) {
            HStack(spacing: FlowTokens.spacingMD) {
                Button {
                    withAnimation(.flowQuick) { showPriorityPicker.toggle() }
                } label: {
                    Circle()
                        .fill(priorityColor(newTodoPriority))
                        .frame(width: 8, height: 8)
                }
                .buttonStyle(.plain)
                .help("Priority: \(newTodoPriority.displayName)")

                TextField("Add todo…", text: $newTodoText)
                    .textFieldStyle(.plain)
                    .flowFont(.body)
                    .foregroundColor(FlowTokens.textPrimary)
                    .focused($isInputFocused)
                    .onSubmit { addTodo() }

                if !newTodoText.isEmpty {
                    Button {
                        addTodo()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundColor(FlowTokens.accent)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .flowInput(isFocused: isInputFocused)

            if showPriorityPicker || isInputFocused {
                HStack(spacing: FlowTokens.spacingSM) {
                    ForEach(TodoPriority.allCases, id: \.self) { priority in
                        priorityPill(priority)
                    }
                    Spacer()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, FlowTokens.spacingLG)
        .padding(.vertical, FlowTokens.spacingMD)
    }

    private func priorityPill(_ priority: TodoPriority) -> some View {
        let isActive = newTodoPriority == priority
        return Button {
            withAnimation(.flowQuick) { newTodoPriority = priority }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(priorityColor(priority))
                    .frame(width: 6, height: 6)
                Text(priority.displayName)
                    .flowFont(.micro)
            }
            .foregroundColor(isActive ? FlowTokens.textPrimary : FlowTokens.textTertiary)
            .padding(.horizontal, FlowTokens.spacingMD - 2)
            .padding(.vertical, 4)
            .flowControl(isActive: isActive, radius: FlowTokens.radiusControl)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Todo List

    private var todoList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if activeTodos.isEmpty && completedTodos.isEmpty {
                    emptyState
                } else {
                    // Priority sections
                    ForEach(TodoPriority.allCases, id: \.self) { priority in
                        let items = todosForPriority(priority)
                        if !items.isEmpty {
                            prioritySection(priority, items: items)
                        }
                    }

                    // Completed section
                    if !completedTodos.isEmpty {
                        completedSection
                    }
                }
            }
            .padding(.vertical, FlowTokens.spacingSM)
        }
    }

    // MARK: - Priority Section

    private func prioritySection(_ priority: TodoPriority, items: [TodoItem]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(priority.displayName.uppercased())
                    .flowSectionHeader()
                Spacer()
                Text("\(items.count)")
                    .flowFont(.timestamp)
                    .foregroundColor(FlowTokens.textMuted)
            }
            .padding(.horizontal, FlowTokens.spacingLG)
            .padding(.top, FlowTokens.spacingLG)
            .padding(.bottom, FlowTokens.spacingSM)

            ForEach(items) { todo in
                todoRow(todo)
            }
        }
    }

    // MARK: - Todo Row

    private func todoRow(_ todo: TodoItem) -> some View {
        HStack(spacing: FlowTokens.spacingMD) {
            // Priority accent bar (tokenized)
            RoundedRectangle(cornerRadius: 1)
                .fill(priorityColor(todo.priority))
                .frame(width: FlowTokens.accentBarWidth)
                .padding(.vertical, 6)

            Button {
                withAnimation(.flowSpring) {
                    syncService.toggleTodoComplete(id: todo.id)
                }
            } label: {
                Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(todo.isCompleted ? FlowTokens.success.opacity(0.7) : FlowTokens.textTertiary)
            }
            .buttonStyle(.plain)

            if editingTodoID == todo.id {
                TextField("", text: $editingText)
                    .textFieldStyle(.plain)
                    .flowFont(.body)
                    .foregroundColor(FlowTokens.textPrimary)
                    .focused($isEditFocused)
                    .onSubmit { commitEdit(todo.id) }
                    .onExitCommand { cancelEdit() }
            } else {
                Text(todo.title)
                    .flowFont(.body)
                    .foregroundColor(todo.isCompleted ? FlowTokens.textDisabled : FlowTokens.textPrimary)
                    .strikethrough(todo.isCompleted, color: FlowTokens.textDisabled)
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        startEdit(todo)
                    }
            }

            Spacer()

            Image(systemName: todo.category.icon)
                .font(.system(size: 10))
                .foregroundColor(FlowTokens.textMuted)

            Button {
                withAnimation(.flowSpring) {
                    syncService.deleteTodo(id: todo.id)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(FlowTokens.textMuted)
            }
            .buttonStyle(.plain)
            .opacity(0.5)
        }
        .padding(.leading, FlowTokens.spacingLG - 2)
        .padding(.trailing, FlowTokens.spacingLG)
        .frame(height: FlowTokens.rowHeight)
        .background(Color.clear)
        .contentShape(Rectangle())
    }

    // MARK: - Completed Section

    private var completedSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.flowSpring) { showCompleted.toggle() }
            } label: {
                HStack(spacing: FlowTokens.spacingSM) {
                    Image(systemName: showCompleted ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(FlowTokens.textMuted)
                    Text("COMPLETED")
                        .flowSectionHeader()
                    Spacer()
                    Text("\(completedTodos.count)")
                        .flowFont(.timestamp)
                        .foregroundColor(FlowTokens.textMuted)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, FlowTokens.spacingLG)
            .padding(.top, FlowTokens.spacingLG)
            .padding(.bottom, FlowTokens.spacingSM)

            if showCompleted {
                ForEach(completedTodos) { todo in
                    todoRow(todo)
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: FlowTokens.spacingMD) {
            Spacer().frame(height: 48)
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(FlowTokens.textDisabled)
            Text("All clear")
                .flowFont(.title3)
                .foregroundColor(FlowTokens.textTertiary)
            Text("Add a todo above to get started")
                .flowFont(.caption)
                .foregroundColor(FlowTokens.textMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func addTodo() {
        let trimmed = newTodoText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let todo = TodoItem(title: trimmed, priority: newTodoPriority)
        withAnimation(.flowSpring) {
            syncService.addTodo(todo)
        }
        newTodoText = ""
    }

    private func startEdit(_ todo: TodoItem) {
        editingTodoID = todo.id
        editingText = todo.title
        isEditFocused = true
    }

    private func commitEdit(_ id: UUID) {
        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            syncService.updateTodo(id: id, title: trimmed)
        }
        editingTodoID = nil
    }

    private func cancelEdit() {
        editingTodoID = nil
    }

    private func priorityColor(_ priority: TodoPriority) -> Color {
        switch priority {
        case .high: return FlowTokens.priorityHigh
        case .medium: return FlowTokens.priorityMedium
        case .low: return FlowTokens.priorityLow
        }
    }
}
