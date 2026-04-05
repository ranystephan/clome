import SwiftUI
import EventKit
import ClomeModels

// MARK: - Harness Inspector View

/// Developer panel for inspecting and controlling what the AI has access to.
/// Shows context, tools, system prompt, and harness status across four tabs.
struct FlowHarnessInspectorView: View {

    enum InspectorTab: String, CaseIterable {
        case context = "Context"
        case tools = "Tools"
        case prompt = "Prompt"
        case status = "Status"

        var icon: String {
            switch self {
            case .context: return "doc.text.magnifyingglass"
            case .tools: return "wrench.and.screwdriver"
            case .prompt: return "text.bubble"
            case .status: return "gauge.with.dots.needle.bottom.50percent"
            }
        }
    }

    @State private var activeTab: InspectorTab = .context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("AI Inspector")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(FlowTokens.textPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(FlowTokens.textHint)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, FlowTokens.spacingLG)
            .padding(.vertical, FlowTokens.spacingMD)

            // Tab bar
            tabBar
            Divider().background(FlowTokens.border)

            // Content
            Group {
                switch activeTab {
                case .context: ContextTabView()
                case .tools: ToolsTabView()
                case .prompt: PromptTabView()
                case .status: StatusTabView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 400, height: 500)
        .background(FlowTokens.bg0)
        .preferredColorScheme(.dark)
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: FlowTokens.spacingXS) {
            ForEach(InspectorTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.flowQuick) { activeTab = tab }
                } label: {
                    HStack(spacing: FlowTokens.spacingSM) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 10, weight: .medium))
                        Text(tab.rawValue)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(activeTab == tab ? FlowTokens.textPrimary : FlowTokens.textHint)
                    .padding(.horizontal, FlowTokens.spacingMD)
                    .padding(.vertical, FlowTokens.spacingSM)
                    .background(
                        RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                            .fill(activeTab == tab ? FlowTokens.bg2 : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, FlowTokens.spacingLG)
        .padding(.vertical, FlowTokens.spacingSM)
    }
}

// MARK: - Tab 1: Context (Interactive)

private struct ContextTabView: View {
    @ObservedObject private var store = FlowChatStore.shared
    @ObservedObject private var sync = FlowSyncService.shared
    @ObservedObject private var calendarManager = CalendarDataManager.shared

    @State private var showPreview = false
    @State private var lastRefresh = Date()

    // Snippet creation
    @State private var isAddingSnippet = false
    @State private var newSnippetTitle = ""
    @State private var newSnippetContent = ""

    private var contextConfig: ContextConfiguration? {
        store.activeConversation?.contextConfig
    }

    private var conversationID: UUID? {
        store.activeConversationID
    }

    var body: some View {
        if let config = contextConfig, let convID = conversationID {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: FlowTokens.spacingMD) {
                        // Time section
                        sectionToggleRow(section: .time, config: config, convID: convID)

                        // Todos section
                        sectionToggleRow(section: .todos, config: config, convID: convID,
                                         itemCount: activeTodos.count) {
                            ForEach(activeTodos) { todo in
                                itemCheckboxRow(
                                    label: todo.title,
                                    isSelected: config.isItemSelected(section: .todos, id: todo.id),
                                    section: .todos, itemID: todo.id, convID: convID,
                                    allIDs: Set(activeTodos.map(\.id))
                                )
                            }
                        }

                        // Deadlines section
                        sectionToggleRow(section: .deadlines, config: config, convID: convID,
                                         itemCount: activeDeadlines.count) {
                            ForEach(activeDeadlines) { dl in
                                let fmt = DateFormatter()
                                let _ = fmt.dateFormat = "MMM d"
                                itemCheckboxRow(
                                    label: "\(dl.title) -- \(fmt.string(from: dl.dueDate))",
                                    isSelected: config.isItemSelected(section: .deadlines, id: dl.id),
                                    section: .deadlines, itemID: dl.id, convID: convID,
                                    allIDs: Set(activeDeadlines.map(\.id))
                                )
                            }
                        }

                        // Calendar section (no per-item selection)
                        sectionToggleRow(section: .calendar, config: config, convID: convID,
                                         itemCount: calendarManager.items.count)

                        // Notes section
                        sectionToggleRow(section: .notes, config: config, convID: convID,
                                         itemCount: recentNotes.count) {
                            ForEach(recentNotes) { note in
                                itemCheckboxRow(
                                    label: "[\(note.category.displayName)] \(note.summary)",
                                    isSelected: config.isItemSelected(section: .notes, id: note.id),
                                    section: .notes, itemID: note.id, convID: convID,
                                    allIDs: Set(recentNotes.map(\.id))
                                )
                            }
                        }

                        // Workspace section
                        sectionToggleRow(section: .workspace, config: config, convID: convID) {
                            if let path = config.workspaceProjectPath ?? store.activeConversation?.contextConfig.workspaceProjectPath {
                                HStack(spacing: FlowTokens.spacingSM) {
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 9))
                                        .foregroundColor(FlowTokens.textHint)
                                    Text((path as NSString).lastPathComponent)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(FlowTokens.textTertiary)
                                    Text(path)
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundColor(FlowTokens.textMuted)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .padding(.leading, FlowTokens.spacingXL)
                            }
                        }

                        // Custom Snippets section
                        customSnippetsSection(config: config, convID: convID)

                        // Preview section
                        previewSection(config: config)
                    }
                    .padding(FlowTokens.spacingLG)
                }

                Divider().background(FlowTokens.border)

                // Footer
                contextFooter(config: config)
            }
        } else {
            placeholderView(message: "No active conversation")
        }
    }

    // MARK: - Data

    private var activeTodos: [TodoItem] { sync.todos.filter { !$0.isCompleted } }
    private var activeDeadlines: [Deadline] { sync.deadlines.filter { !$0.isCompleted } }
    private var recentNotes: [NoteEntry] {
        Array(sync.notes.sorted { $0.updatedAt > $1.updatedAt }.prefix(10))
    }

    // MARK: - Section Toggle Row

    private func sectionToggleRow(
        section: ContextSection,
        config: ContextConfiguration,
        convID: UUID,
        itemCount: Int? = nil,
        @ViewBuilder items: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: FlowTokens.spacingSM) {
                Image(systemName: section.icon)
                    .font(.system(size: 10))
                    .foregroundColor(config.isSectionEnabled(section) ? FlowTokens.accent : FlowTokens.textDisabled)
                    .frame(width: 14)

                Text(section.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(FlowTokens.textPrimary)

                if let count = itemCount {
                    Text("(\(count))")
                        .font(.system(size: 10))
                        .foregroundColor(FlowTokens.textTertiary)
                }

                Spacer()

                Button {
                    store.updateContextConfig(for: convID) { $0.toggleSection(section) }
                } label: {
                    Text(config.isSectionEnabled(section) ? "ON" : "OFF")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(config.isSectionEnabled(section) ? FlowTokens.success : FlowTokens.textDisabled)
                        .padding(.horizontal, FlowTokens.spacingSM)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                                .fill(config.isSectionEnabled(section) ? FlowTokens.success.opacity(0.12) : FlowTokens.bg3)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, FlowTokens.spacingSM)

            if config.isSectionEnabled(section) {
                items()
            }
        }
        .padding(.horizontal, FlowTokens.spacingMD)
        .padding(.vertical, FlowTokens.spacingSM)
        .flowCard()
    }

    // MARK: - Item Checkbox Row

    private func itemCheckboxRow(
        label: String,
        isSelected: Bool,
        section: ContextSection,
        itemID: UUID,
        convID: UUID,
        allIDs: Set<UUID>
    ) -> some View {
        Button {
            store.updateContextConfig(for: convID) {
                $0.toggleItem(section: section, id: itemID, allItemIDs: allIDs)
            }
        } label: {
            HStack(spacing: FlowTokens.spacingSM) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 10))
                    .foregroundColor(isSelected ? FlowTokens.accent : FlowTokens.textDisabled)

                Text(label)
                    .font(.system(size: 10))
                    .foregroundColor(isSelected ? FlowTokens.textSecondary : FlowTokens.textHint)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()
            }
            .padding(.leading, FlowTokens.spacingXL)
            .padding(.vertical, 1)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Custom Snippets

    private func customSnippetsSection(config: ContextConfiguration, convID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: FlowTokens.spacingSM) {
                Image(systemName: ContextSection.custom.icon)
                    .font(.system(size: 10))
                    .foregroundColor(config.isSectionEnabled(.custom) ? FlowTokens.accent : FlowTokens.textDisabled)
                    .frame(width: 14)

                Text("Custom Snippets")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(FlowTokens.textPrimary)

                Spacer()

                Button {
                    withAnimation(.flowQuick) { isAddingSnippet.toggle() }
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "plus")
                            .font(.system(size: 8, weight: .bold))
                        Text("Add")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(FlowTokens.accent)
                    .padding(.horizontal, FlowTokens.spacingSM)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                            .fill(FlowTokens.accentSubtle)
                    )
                }
                .buttonStyle(.plain)

                Button {
                    store.updateContextConfig(for: convID) { $0.toggleSection(.custom) }
                } label: {
                    Text(config.isSectionEnabled(.custom) ? "ON" : "OFF")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(config.isSectionEnabled(.custom) ? FlowTokens.success : FlowTokens.textDisabled)
                        .padding(.horizontal, FlowTokens.spacingSM)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                                .fill(config.isSectionEnabled(.custom) ? FlowTokens.success.opacity(0.12) : FlowTokens.bg3)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, FlowTokens.spacingSM)

            if config.isSectionEnabled(.custom) {
                // Existing snippets
                ForEach(config.customSnippets) { snippet in
                    HStack(spacing: FlowTokens.spacingSM) {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 9))
                            .foregroundColor(FlowTokens.textHint)
                        Text(snippet.title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(FlowTokens.textSecondary)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            store.updateContextConfig(for: convID) { $0.removeSnippet(id: snippet.id) }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(FlowTokens.textHint)
                                .frame(width: 16, height: 16)
                                .background(
                                    RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                                        .fill(FlowTokens.bg3)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.leading, FlowTokens.spacingXL)
                    .padding(.vertical, 2)
                }

                // Add snippet form
                if isAddingSnippet {
                    VStack(alignment: .leading, spacing: FlowTokens.spacingSM) {
                        TextField("Title", text: $newSnippetTitle)
                            .textFieldStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundColor(FlowTokens.textPrimary)
                            .padding(FlowTokens.spacingSM)
                            .background(
                                RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                                    .fill(FlowTokens.bg2)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                                            .stroke(FlowTokens.borderFocused, lineWidth: 0.5)
                                    )
                            )

                        TextEditor(text: $newSnippetContent)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(FlowTokens.textSecondary)
                            .scrollContentBackground(.hidden)
                            .frame(height: 60)
                            .padding(FlowTokens.spacingSM)
                            .background(
                                RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                                    .fill(FlowTokens.bg2)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                                            .stroke(FlowTokens.borderFocused, lineWidth: 0.5)
                                    )
                            )

                        HStack {
                            Spacer()
                            Button {
                                withAnimation(.flowQuick) {
                                    isAddingSnippet = false
                                    newSnippetTitle = ""
                                    newSnippetContent = ""
                                }
                            } label: {
                                Text("Cancel")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(FlowTokens.textTertiary)
                            }
                            .buttonStyle(.plain)

                            Button {
                                let title = newSnippetTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                                let content = newSnippetContent.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !title.isEmpty, !content.isEmpty else { return }
                                store.updateContextConfig(for: convID) {
                                    $0.addSnippet(title: title, content: content)
                                }
                                withAnimation(.flowQuick) {
                                    isAddingSnippet = false
                                    newSnippetTitle = ""
                                    newSnippetContent = ""
                                }
                            } label: {
                                Text("Save")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(FlowTokens.accent)
                                    .padding(.horizontal, FlowTokens.spacingMD)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                                            .fill(FlowTokens.accentSubtle)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.leading, FlowTokens.spacingXL)
                    .padding(.top, FlowTokens.spacingSM)
                }
            }
        }
        .padding(.horizontal, FlowTokens.spacingMD)
        .padding(.vertical, FlowTokens.spacingSM)
        .flowCard()
    }

    // MARK: - Preview Section

    private func previewSection(config: ContextConfiguration) -> some View {
        VStack(alignment: .leading, spacing: FlowTokens.spacingSM) {
            Button {
                withAnimation(.flowQuick) { showPreview.toggle() }
            } label: {
                HStack(spacing: FlowTokens.spacingSM) {
                    Image(systemName: showPreview ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(FlowTokens.textHint)
                    Text("PREVIEW")
                        .flowSectionHeader()
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if showPreview {
                let assembled = config.assembleContext(
                    sync: sync,
                    calendarManager: calendarManager,
                    projectPath: store.activeConversation?.contextConfig.workspaceProjectPath
                )
                Text(assembled)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(FlowTokens.textTertiary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(FlowTokens.spacingMD)
        .flowCard()
    }

    // MARK: - Footer

    private func contextFooter(config: ContextConfiguration) -> some View {
        HStack {
            let tokens = config.estimateTokens(
                sync: sync,
                calendarManager: calendarManager,
                projectPath: store.activeConversation?.contextConfig.workspaceProjectPath
            )
            Text("~\(tokens) tokens")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(FlowTokens.textMuted)
            Spacer()
            Text("Updated \(lastRefresh.formatted(.relative(presentation: .named)))")
                .font(.system(size: 9))
                .foregroundColor(FlowTokens.textMuted)
            Button {
                calendarManager.refresh()
                lastRefresh = Date()
            } label: {
                HStack(spacing: FlowTokens.spacingXS) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9))
                    Text("Refresh")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(FlowTokens.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, FlowTokens.spacingLG)
        .padding(.vertical, FlowTokens.spacingMD)
    }
}

// MARK: - Tab 2: Tools (Interactive)

private struct ToolsTabView: View {
    @ObservedObject private var store = FlowChatStore.shared

    private var toolConfig: ToolConfiguration? {
        store.activeConversation?.toolConfig
    }

    private var conversationID: UUID? {
        store.activeConversationID
    }

    /// Tools grouped by category, preserving category order.
    private var groupedTools: [(category: ToolCategory, tools: [ToolDefinition])] {
        var result: [(category: ToolCategory, tools: [ToolDefinition])] = []
        for category in ToolCategory.allCases {
            let tools = ToolRegistry.all.filter { $0.category == category }
            if !tools.isEmpty {
                result.append((category, tools))
            }
        }
        return result
    }

    var body: some View {
        if let config = toolConfig, let convID = conversationID {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: FlowTokens.spacingLG) {
                        ForEach(groupedTools, id: \.category) { group in
                            toolCategorySection(group.category, tools: group.tools, config: config, convID: convID)
                        }

                        // Usage Log
                        usageLogSection(config: config)
                    }
                    .padding(FlowTokens.spacingLG)
                }

                Divider().background(FlowTokens.border)

                // Footer
                HStack {
                    let enabled = config.enabledTools.count
                    let total = ToolRegistry.all.count
                    Text("\(enabled)/\(total) tools enabled")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(FlowTokens.textMuted)
                    Spacer()
                    Text("\(config.usageLog.count) calls this session")
                        .font(.system(size: 9))
                        .foregroundColor(FlowTokens.textMuted)
                }
                .padding(.horizontal, FlowTokens.spacingLG)
                .padding(.vertical, FlowTokens.spacingMD)
            }
        } else {
            placeholderView(message: "No active conversation")
        }
    }

    // MARK: - Category Section

    private func toolCategorySection(
        _ category: ToolCategory,
        tools: [ToolDefinition],
        config: ToolConfiguration,
        convID: UUID
    ) -> some View {
        VStack(alignment: .leading, spacing: FlowTokens.spacingSM) {
            Text(category.rawValue.uppercased())
                .flowSectionHeader()

            VStack(spacing: 0) {
                ForEach(tools, id: \.name) { tool in
                    toolRow(tool, config: config, convID: convID)
                    if tool.name != tools.last?.name {
                        Divider()
                            .background(FlowTokens.border)
                            .padding(.leading, FlowTokens.spacingXL)
                    }
                }
            }
            .flowCard()
        }
    }

    // MARK: - Tool Row

    private func toolRow(_ tool: ToolDefinition, config: ToolConfiguration, convID: UUID) -> some View {
        HStack(spacing: FlowTokens.spacingMD) {
            // Toggle circle
            Button {
                store.updateToolConfig(for: convID) { $0.toggle(tool.name) }
            } label: {
                ZStack {
                    Circle()
                        .fill(config.isEnabled(tool.name) ? tool.color.opacity(0.15) : FlowTokens.bg3)
                        .frame(width: 22, height: 22)
                    Circle()
                        .fill(config.isEnabled(tool.name) ? tool.color : FlowTokens.textDisabled)
                        .frame(width: 8, height: 8)
                }
            }
            .buttonStyle(.plain)

            // Tool icon + name
            Image(systemName: tool.icon)
                .font(.system(size: 10))
                .foregroundColor(config.isEnabled(tool.name) ? tool.color : FlowTokens.textDisabled)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 0) {
                Text(tool.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(config.isEnabled(tool.name) ? FlowTokens.textPrimary : FlowTokens.textHint)
                Text(tool.description)
                    .font(.system(size: 9))
                    .foregroundColor(FlowTokens.textMuted)
                    .lineLimit(1)
            }

            Spacer()

            // Usage count
            let count = config.usageCount(for: tool.name)
            if count > 0 {
                Text("\(count)x")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(FlowTokens.textTertiary)
                    .padding(.horizontal, FlowTokens.spacingSM)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                            .fill(FlowTokens.bg3)
                    )
            } else {
                Text("0x")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(FlowTokens.textMuted)
            }
        }
        .padding(.horizontal, FlowTokens.spacingMD)
        .padding(.vertical, FlowTokens.spacingSM)
    }

    // MARK: - Usage Log

    private func usageLogSection(config: ToolConfiguration) -> some View {
        VStack(alignment: .leading, spacing: FlowTokens.spacingSM) {
            Text("USAGE LOG")
                .flowSectionHeader()

            if config.usageLog.isEmpty {
                Text("No tool calls yet.")
                    .font(.system(size: 10))
                    .foregroundColor(FlowTokens.textMuted)
                    .padding(FlowTokens.spacingMD)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .flowCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(config.usageLog.suffix(20).reversed()) { entry in
                        HStack(spacing: FlowTokens.spacingMD) {
                            let timeFmt = DateFormatter()
                            let _ = timeFmt.dateFormat = "h:mm a"
                            Text(timeFmt.string(from: entry.timestamp))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(FlowTokens.textMuted)
                                .frame(width: 55, alignment: .leading)

                            let info = ToolRegistry.displayInfo(for: entry.toolName)
                            Image(systemName: info.icon)
                                .font(.system(size: 9))
                                .foregroundColor(info.color)
                                .frame(width: 12)

                            Text(info.displayName)
                                .font(.system(size: 10))
                                .foregroundColor(FlowTokens.textSecondary)
                                .lineLimit(1)

                            Spacer()

                            Image(systemName: entry.success ? "checkmark" : "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(entry.success ? FlowTokens.success : FlowTokens.error)
                        }
                        .padding(.horizontal, FlowTokens.spacingMD)
                        .padding(.vertical, FlowTokens.spacingSM)

                        if entry.id != config.usageLog.suffix(20).reversed().last?.id {
                            Divider()
                                .background(FlowTokens.border)
                                .padding(.leading, FlowTokens.spacingXL)
                        }
                    }
                }
                .flowCard()
            }
        }
    }
}

// MARK: - Tab 3: Prompt

private struct PromptTabView: View {
    @AppStorage("flowChatCustomPrompt") private var customPrompt: String = ""
    @State private var editingPrompt: String = ""
    @State private var isEdited: Bool = false

    private let defaultPrompt: String = """
    You are Clome Flow, a proactive AI scheduling assistant embedded in the Clome \
    development environment. You make smart scheduling decisions and propose concrete plans. \
    You are friendly but decisive. Keep responses concise — the developer is in a coding context. \
    Use markdown formatting for code blocks and emphasis where helpful.

    YOUR CAPABILITIES:
    1. Create to-do items (use create_todo function)
    2. Complete to-do items (use complete_todo function)
    3. Delete to-do items (use delete_todo function)
    4. Create deadlines with prep-time tracking (use create_deadline function)
    5. Create notes (use create_note function)
    6. Answer questions about the user's schedule, todos, deadlines, and notes
    7. Help plan sprints, tasks, and projects
    8. Schedule calendar events (use schedule_event function)
    9. Reschedule existing events (use reschedule_event function)
    10. Delete calendar events (use delete_event function)

    RULES:
    - When the user wants to add a to-do, use create_todo.
    - When the user wants to mark a to-do done, use complete_todo.
    - When the user wants to remove a to-do, use delete_todo.
    - When the user mentions a deadline, use create_deadline.
    - When the user wants to save a note or idea, use create_note.
    - When the user wants to schedule something on their calendar, use schedule_event.
    - When the user wants to move/reschedule an event, use reschedule_event.
    - When the user wants to cancel/delete an event, use delete_event.
    - Always use 24-hour HH:mm format for times.
    - Infer reasonable defaults: 60 min for meetings, 30 min for errands, 45 min for gym, etc.
    - RESPOND with plain text for greetings, questions, summaries, or general conversation.
    - Be concise — 1-3 sentences max for text responses unless more detail is needed.
    - Use the context provided to give informed answers about the user's schedule.

    DATE/TIME FORMAT:
    - Dates: YYYY-MM-DD
    - Times: HH:mm in 24-hour format

    PRIORITY LEVELS: high, medium, low
    NOTE CATEGORIES: idea, task, reminder, goal, journal, reference
    HABIT CATEGORIES: sleep, meal, exercise, study, meeting, chores, general, research, \
    personalStudy, reading, socialEvent, selfCare, commute, creative, work, entertainment, lecture
    """

    var body: some View {
        VStack(spacing: 0) {
            // Status bar
            HStack {
                if customPrompt.isEmpty {
                    Label("Using default prompt", systemImage: "checkmark.circle")
                        .font(.system(size: 10))
                        .foregroundColor(FlowTokens.success)
                } else {
                    Label("Custom prompt active", systemImage: "pencil.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(FlowTokens.warning)
                }
                Spacer()
                Text("\(editingPrompt.count) chars")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(FlowTokens.textMuted)
            }
            .padding(.horizontal, FlowTokens.spacingLG)
            .padding(.vertical, FlowTokens.spacingSM)

            // Editor
            TextEditor(text: $editingPrompt)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(FlowTokens.textSecondary)
                .scrollContentBackground(.hidden)
                .padding(FlowTokens.spacingSM)
                .background(
                    RoundedRectangle(cornerRadius: FlowTokens.radiusMedium, style: .continuous)
                        .fill(FlowTokens.bg2)
                        .overlay(
                            RoundedRectangle(cornerRadius: FlowTokens.radiusMedium, style: .continuous)
                                .stroke(FlowTokens.border, lineWidth: 0.5)
                        )
                )
                .padding(.horizontal, FlowTokens.spacingLG)
                .onChange(of: editingPrompt) { _, _ in
                    isEdited = true
                }

            Divider().background(FlowTokens.border).padding(.top, FlowTokens.spacingMD)

            // Actions
            HStack {
                Button {
                    editingPrompt = defaultPrompt
                    customPrompt = ""
                    isEdited = false
                } label: {
                    Text("Reset to Default")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(FlowTokens.textTertiary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    let trimmed = editingPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed == defaultPrompt.trimmingCharacters(in: .whitespacesAndNewlines) {
                        customPrompt = ""
                    } else {
                        customPrompt = trimmed
                    }
                    isEdited = false
                } label: {
                    Text("Apply")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(isEdited ? FlowTokens.accent : FlowTokens.textDisabled)
                        .padding(.horizontal, FlowTokens.spacingLG)
                        .padding(.vertical, FlowTokens.spacingSM)
                        .background(
                            RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                                .fill(isEdited ? FlowTokens.accentSubtle : FlowTokens.bg2)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!isEdited)
            }
            .padding(.horizontal, FlowTokens.spacingLG)
            .padding(.vertical, FlowTokens.spacingMD)
        }
        .onAppear {
            editingPrompt = customPrompt.isEmpty ? defaultPrompt : customPrompt
            isEdited = false
        }
    }
}

// MARK: - Tab 4: Status

private struct StatusTabView: View {
    @ObservedObject private var syncService = FlowSyncService.shared
    @ObservedObject private var calendarManager = CalendarDataManager.shared
    @ObservedObject private var store = FlowChatStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: FlowTokens.spacingMD) {
                // Calendar Access
                statusCard(title: "Calendar Access") {
                    HStack(spacing: FlowTokens.spacingSM) {
                        Circle()
                            .fill(calendarManager.hasCalendarAccess ? FlowTokens.success : FlowTokens.error)
                            .frame(width: 6, height: 6)
                        Text(calendarManager.hasCalendarAccess ? "Granted" : "Not Granted")
                            .font(.system(size: 11))
                            .foregroundColor(FlowTokens.textSecondary)
                        Spacer()
                        if !calendarManager.hasCalendarAccess {
                            Button {
                                calendarManager.requestCalendarAccess()
                            } label: {
                                Text("Request")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(FlowTokens.accent)
                                    .padding(.horizontal, FlowTokens.spacingMD)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                                            .fill(FlowTokens.accentSubtle)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Sync Status
                statusCard(title: "Sync Status") {
                    HStack(spacing: FlowTokens.spacingSM) {
                        Circle()
                            .fill(syncStatusColor)
                            .frame(width: 6, height: 6)
                        Text(syncStatusLabel)
                            .font(.system(size: 11))
                            .foregroundColor(FlowTokens.textSecondary)
                        Spacer()
                    }
                }

                // Data Counts
                statusCard(title: "Data Counts") {
                    VStack(alignment: .leading, spacing: FlowTokens.spacingSM) {
                        dataRow("Todos", count: syncService.todos.count)
                        dataRow("Deadlines", count: syncService.deadlines.count)
                        dataRow("Notes", count: syncService.notes.count)
                        dataRow("Calendar Events", count: calendarManager.items.count)
                    }
                }

                // Context & Tools Config
                if let conv = store.activeConversation {
                    statusCard(title: "Active Conversation") {
                        VStack(alignment: .leading, spacing: FlowTokens.spacingSM) {
                            dataRow("Title", value: conv.title)
                            let enabledSections = ContextSection.allCases.filter { conv.contextConfig.isSectionEnabled($0) }.count
                            dataRow("Context Sections", value: "\(enabledSections)/\(ContextSection.allCases.count) enabled")
                            dataRow("Tools Enabled", value: "\(conv.toolConfig.enabledTools.count)/\(ToolRegistry.all.count)")
                            dataRow("Tool Calls", count: conv.toolConfig.usageLog.count)
                            dataRow("Custom Snippets", count: conv.contextConfig.customSnippets.count)
                        }
                    }
                }

                // Model
                statusCard(title: "Model") {
                    HStack(spacing: FlowTokens.spacingSM) {
                        Image(systemName: "cpu")
                            .font(.system(size: 10))
                            .foregroundColor(FlowTokens.textHint)
                        Text("gemini-2.5-flash")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(FlowTokens.textSecondary)
                        Spacer()
                    }
                }

                // Feature Flags
                statusCard(title: "Feature Flags") {
                    VStack(alignment: .leading, spacing: FlowTokens.spacingSM) {
                        flagRow("Tool Calling", enabled: true)
                        flagRow("Context Injection", enabled: true)
                        flagRow("Custom Prompt", enabled: !UserDefaults.standard.string(forKey: "flowChatCustomPrompt").isNilOrEmpty)
                        flagRow("Calendar Integration", enabled: calendarManager.hasCalendarAccess)
                        if let conv = store.activeConversation {
                            flagRow("Per-Item Selection", enabled: !conv.contextConfig.selectedItemIDs.isEmpty)
                            flagRow("Tool Filtering", enabled: conv.toolConfig.enabledTools.count < ToolRegistry.all.count)
                        }
                    }
                }
            }
            .padding(FlowTokens.spacingLG)
        }
    }

    // MARK: - Helpers

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
        case .listening: return "Listening"
        case .connecting: return "Connecting..."
        case .error(let msg): return "Error: \(msg)"
        case .disconnected: return "Disconnected"
        }
    }

    private func dataRow(_ label: String, count: Int) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(FlowTokens.textTertiary)
            Spacer()
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(FlowTokens.textSecondary)
        }
    }

    private func dataRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(FlowTokens.textTertiary)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(FlowTokens.textSecondary)
                .lineLimit(1)
        }
    }

    private func flagRow(_ label: String, enabled: Bool) -> some View {
        HStack {
            Circle()
                .fill(enabled ? FlowTokens.success : FlowTokens.textDisabled)
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(FlowTokens.textTertiary)
            Spacer()
            Text(enabled ? "ON" : "OFF")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(enabled ? FlowTokens.success : FlowTokens.textDisabled)
        }
    }

    private func statusCard(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: FlowTokens.spacingSM) {
            Text(title.uppercased())
                .flowSectionHeader()
            content()
        }
        .padding(FlowTokens.spacingMD)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flowCard()
    }
}

// MARK: - Shared Placeholder

private func placeholderView(message: String) -> some View {
    VStack(spacing: FlowTokens.spacingMD) {
        Image(systemName: "bubble.left.and.bubble.right")
            .font(.system(size: 24))
            .foregroundColor(FlowTokens.textMuted)
        Text(message)
            .font(.system(size: 11))
            .foregroundColor(FlowTokens.textHint)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

// MARK: - Optional String Helper

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool {
        switch self {
        case .none: return true
        case .some(let value): return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
