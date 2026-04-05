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
            Divider().background(FlowTokens.border)
            todoList
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: FlowTokens.spacingSM) {
                // Priority indicator
                Button {
                    withAnimation(.flowQuick) { showPriorityPicker.toggle() }
                } label: {
                    Circle()
                        .fill(priorityColor(newTodoPriority))
                        .frame(width: 8, height: 8)
                }
                .buttonStyle(.plain)
                .help("Priority: \(newTodoPriority.displayName)")

                TextField("Add todo...", text: $newTodoText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(FlowTokens.textPrimary)
                    .focused($isInputFocused)
                    .onSubmit { addTodo() }

                if !newTodoText.isEmpty {
                    Button {
                        addTodo()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(FlowTokens.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, FlowTokens.spacingMD)
            .background(FlowTokens.bg1)

            // Priority picker row
            if showPriorityPicker || isInputFocused {
                HStack(spacing: FlowTokens.spacingSM) {
                    ForEach(TodoPriority.allCases, id: \.self) { priority in
                        priorityPill(priority)
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, FlowTokens.spacingSM)
                .background(FlowTokens.bg1)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func priorityPill(_ priority: TodoPriority) -> some View {
        Button {
            withAnimation(.flowQuick) { newTodoPriority = priority }
        } label: {
            HStack(spacing: 3) {
                Circle()
                    .fill(priorityColor(priority))
                    .frame(width: 6, height: 6)
                Text(priority.displayName)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundColor(newTodoPriority == priority ? FlowTokens.textPrimary : FlowTokens.textTertiary)
            .padding(.horizontal, FlowTokens.spacingMD)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                    .fill(newTodoPriority == priority ? FlowTokens.bg3 : Color.clear)
            )
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
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(FlowTokens.textMuted)
            }
            .padding(.horizontal, 10)
            .padding(.top, FlowTokens.spacingLG)
            .padding(.bottom, FlowTokens.spacingSM)

            ForEach(items) { todo in
                todoRow(todo)
            }
        }
    }

    // MARK: - Todo Row

    private func todoRow(_ todo: TodoItem) -> some View {
        HStack(spacing: 0) {
            // Left priority bar
            RoundedRectangle(cornerRadius: 1)
                .fill(priorityColor(todo.priority))
                .frame(width: 3)
                .padding(.vertical, 4)

            HStack(spacing: FlowTokens.spacingMD) {
                // Checkbox
                Button {
                    withAnimation(.flowSpring) {
                        syncService.toggleTodoComplete(id: todo.id)
                    }
                } label: {
                    Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundColor(todo.isCompleted ? FlowTokens.success.opacity(0.6) : FlowTokens.textTertiary)
                }
                .buttonStyle(.plain)

                // Title (inline edit or display)
                if editingTodoID == todo.id {
                    TextField("", text: $editingText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(FlowTokens.textPrimary)
                        .focused($isEditFocused)
                        .onSubmit { commitEdit(todo.id) }
                        .onExitCommand { cancelEdit() }
                } else {
                    Text(todo.title)
                        .font(.system(size: 12))
                        .foregroundColor(todo.isCompleted ? FlowTokens.textDisabled : FlowTokens.textPrimary)
                        .strikethrough(todo.isCompleted, color: FlowTokens.textDisabled)
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            startEdit(todo)
                        }
                }

                Spacer()

                // Category icon
                Image(systemName: todo.category.icon)
                    .font(.system(size: 9))
                    .foregroundColor(FlowTokens.textMuted)

                // Delete button
                Button {
                    withAnimation(.flowSpring) {
                        syncService.deleteTodo(id: todo.id)
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(FlowTokens.textMuted)
                }
                .buttonStyle(.plain)
                .opacity(0.5)
            }
            .padding(.leading, FlowTokens.spacingMD)
            .padding(.trailing, 10)
        }
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
                HStack {
                    Image(systemName: showCompleted ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(FlowTokens.textMuted)
                    Text("COMPLETED")
                        .flowSectionHeader()
                    Spacer()
                    Text("\(completedTodos.count)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(FlowTokens.textMuted)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
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
            Spacer().frame(height: 40)
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28))
                .foregroundColor(FlowTokens.textDisabled)
            Text("All clear")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(FlowTokens.textTertiary)
            Text("Add a todo above to get started")
                .font(.system(size: 11))
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
