import SwiftUI
import ClomeModels
import ClomeServices

/// AI chat with persistent conversations, conversation history sidebar,
/// rich tool call visualization, and code block rendering.
struct FlowChatView: View {
    let projectContext: String?
    let workspaceID: UUID?

    init(projectContext: String?, workspaceID: UUID? = nil) {
        self.projectContext = projectContext
        self.workspaceID = workspaceID
    }

    @ObservedObject private var store = FlowChatStore.shared
    @State private var inputText = ""
    @State private var isProcessing = false
    @State private var processingStatus: String = ""
    @State private var hoveredMessageID: UUID?
    @State private var showConversationList = false
    @State private var hoveredConversationID: UUID?
    @State private var editingConversationID: UUID?
    @State private var editingTitle = ""
    @State private var confirmingDeleteID: UUID?
    @FocusState private var isInputFocused: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            mainChatView
                .opacity(showConversationList ? 0.4 : 1.0)

            if showConversationList {
                conversationListPanel
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.flowSpring, value: showConversationList)
        .onAppear {
            if store.activeConversationID == nil {
                // Defer to next run-loop tick to avoid publishing during view update
                DispatchQueue.main.async {
                    store.createConversation(workspaceID: workspaceID, projectPath: projectContext)
                }
            }
        }
    }

    // MARK: - Main Chat View

    private var mainChatView: some View {
        VStack(spacing: 0) {
            chatHeader
            Rectangle().fill(FlowTokens.border).frame(height: FlowTokens.hairline)
            messageList
            Rectangle().fill(FlowTokens.border).frame(height: FlowTokens.hairline)
            inputBar
        }
    }

    // MARK: - Chat Header

    private var chatHeader: some View {
        HStack(spacing: FlowTokens.spacingMD) {
            Button {
                withAnimation(.flowSpring) { showConversationList.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(showConversationList ? FlowTokens.textPrimary : FlowTokens.textTertiary)
                    .frame(width: 24, height: 24)
                    .flowControl(isActive: showConversationList)
            }
            .buttonStyle(.plain)
            .help("Chat history")

            if let conv = store.activeConversation {
                Text(conv.title)
                    .flowFont(.bodyMedium)
                    .foregroundColor(FlowTokens.textPrimary)
                    .lineLimit(1)
            }

            Spacer()

            if let conv = store.activeConversation, !conv.messages.isEmpty {
                Text("\(conv.messages.count) msg\(conv.messages.count == 1 ? "" : "s")")
                    .flowFont(.timestamp)
                    .foregroundColor(FlowTokens.textMuted)
            }

            Button {
                store.createConversation(workspaceID: workspaceID, projectPath: projectContext)
                showConversationList = false
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(FlowTokens.textTertiary)
                    .frame(width: 24, height: 24)
                    .flowControl()
            }
            .buttonStyle(.plain)
            .help("New chat")
        }
        .padding(.horizontal, FlowTokens.spacingLG)
        .padding(.vertical, FlowTokens.spacingSM + 2)
        .background(FlowTokens.bg0)
    }

    // MARK: - Conversation List Panel

    private var conversationListPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("CHATS")
                    .flowSectionHeader()
                Spacer()
                Button {
                    store.createConversation(workspaceID: workspaceID, projectPath: projectContext)
                    showConversationList = false
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(FlowTokens.textHint)
                }
                .buttonStyle(.plain)
                .help("New chat")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, FlowTokens.spacingMD)

            Rectangle().fill(FlowTokens.border).frame(height: FlowTokens.hairline)

            ScrollView {
                LazyVStack(spacing: 0) {
                    let grouped = groupedConversations
                    ForEach(Array(grouped.keys.sorted().reversed()), id: \.self) { group in
                        if let convos = grouped[group] {
                            dateSectionHeader(group)
                            ForEach(convos) { conv in
                                conversationRow(conv)
                            }
                        }
                    }

                    if store.conversations(forWorkspace: workspaceID).isEmpty {
                        Text("No conversations yet")
                            .font(.system(size: 11))
                            .foregroundColor(FlowTokens.textMuted)
                            .padding(.top, 20)
                    }
                }
            }

            Rectangle().fill(FlowTokens.border).frame(height: FlowTokens.hairline)

            if !store.conversations(forWorkspace: workspaceID).isEmpty {
                Button {
                    store.clearAllConversations()
                    store.createConversation(workspaceID: workspaceID, projectPath: projectContext)
                } label: {
                    HStack(spacing: FlowTokens.spacingSM) {
                        Image(systemName: "trash")
                            .font(.system(size: 9))
                        Text("Clear All")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(FlowTokens.textMuted)
                    .padding(.vertical, FlowTokens.spacingMD)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 240)
        .background(FlowTokens.bg0)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(FlowTokens.border)
                .frame(width: FlowTokens.hairline)
        }
    }

    private func dateSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 8, weight: .semibold, design: .monospaced))
            .foregroundColor(FlowTokens.textMuted)
            .tracking(1)
            .padding(.horizontal, 10)
            .padding(.top, FlowTokens.spacingLG)
            .padding(.bottom, FlowTokens.spacingXS)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func conversationRow(_ conv: FlowConversation) -> some View {
        let isActive = conv.id == store.activeConversationID
        let isHovered = conv.id == hoveredConversationID

        return HStack(spacing: FlowTokens.spacingSM) {
            if editingConversationID == conv.id {
                TextField("Title", text: $editingTitle, onCommit: {
                    store.renameConversation(conv.id, to: editingTitle)
                    editingConversationID = nil
                })
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(FlowTokens.textPrimary)
                .onExitCommand {
                    editingConversationID = nil
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(conv.title)
                        .font(.system(size: 11, weight: isActive ? .medium : .regular))
                        .foregroundColor(isActive ? FlowTokens.textPrimary : FlowTokens.textSecondary)
                        .lineLimit(1)

                    Text(relativeDate(conv.updatedAt))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(FlowTokens.textMuted)
                }
            }

            Spacer()

            if isHovered && editingConversationID != conv.id {
                HStack(spacing: 2) {
                    Button {
                        editingTitle = conv.title
                        editingConversationID = conv.id
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 9))
                            .foregroundColor(FlowTokens.textHint)
                    }
                    .buttonStyle(.plain)

                    Button {
                        if confirmingDeleteID == conv.id {
                            store.deleteConversation(conv.id)
                            confirmingDeleteID = nil
                            if store.conversations(forWorkspace: workspaceID).isEmpty {
                                store.createConversation(workspaceID: workspaceID, projectPath: projectContext)
                            }
                        } else {
                            confirmingDeleteID = conv.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                if confirmingDeleteID == conv.id {
                                    confirmingDeleteID = nil
                                }
                            }
                        }
                    } label: {
                        Image(systemName: confirmingDeleteID == conv.id ? "trash.fill" : "trash")
                            .font(.system(size: 9))
                            .foregroundColor(confirmingDeleteID == conv.id ? FlowTokens.error : FlowTokens.textHint)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, FlowTokens.spacingSM)
        .background(
            RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                .fill(isActive ? FlowTokens.accentSubtle : (isHovered ? FlowTokens.bg2 : Color.clear))
        )
        .padding(.horizontal, FlowTokens.spacingSM)
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectConversation(conv.id)
            showConversationList = false
        }
        .onHover { h in
            hoveredConversationID = h ? conv.id : nil
            if !h { confirmingDeleteID = nil }
        }
    }

    private var groupedConversations: [String: [FlowConversation]] {
        let cal = Calendar.current
        var groups: [String: [FlowConversation]] = [:]
        let sorted = store.conversations(forWorkspace: workspaceID).sorted { $0.updatedAt > $1.updatedAt }

        for conv in sorted {
            let key: String
            if cal.isDateInToday(conv.updatedAt) {
                key = "Today"
            } else if cal.isDateInYesterday(conv.updatedAt) {
                key = "Yesterday"
            } else if let weekAgo = cal.date(byAdding: .day, value: -7, to: Date()),
                      conv.updatedAt > weekAgo {
                key = "This Week"
            } else if let monthAgo = cal.date(byAdding: .month, value: -1, to: Date()),
                      conv.updatedAt > monthAgo {
                key = "This Month"
            } else {
                key = "Older"
            }
            groups[key, default: []].append(conv)
        }
        return groups
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: FlowTokens.spacingLG) {
                    if let conv = store.activeConversation, conv.messages.isEmpty {
                        emptyState
                    }

                    if let conv = store.activeConversation {
                        ForEach(conv.messages) { message in
                            messageView(message)
                                .id(message.id)
                        }
                    }

                    if isProcessing {
                        typingIndicator
                            .id("typing")
                    }
                }
                .padding(.vertical, FlowTokens.spacingMD)
            }
            .onChange(of: store.activeConversation?.messages.count) { _, _ in
                if let last = store.activeConversation?.messages.last {
                    withAnimation(.flowSmooth) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: isProcessing) { _, processing in
                if processing {
                    withAnimation(.flowSmooth) { proxy.scrollTo("typing", anchor: .bottom) }
                }
            }
            .onChange(of: store.activeConversationID) { _, _ in
                if let last = store.activeConversation?.messages.last {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Message View

    private func messageView(_ message: StoredMessage) -> some View {
        let isUser = message.role == .user

        return VStack(alignment: isUser ? .trailing : .leading, spacing: FlowTokens.spacingXS) {
            Text(isUser ? "You" : "Flow")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(FlowTokens.textMuted)
                .padding(.horizontal, 10)

            HStack(alignment: .top, spacing: 0) {
                if isUser { Spacer(minLength: 30) }

                VStack(alignment: isUser ? .trailing : .leading, spacing: FlowTokens.spacingSM) {
                    ForEach(message.parts) { part in
                        switch part {
                        case .text(let text):
                            if isUser {
                                userBubble(text)
                            } else {
                                aiMessageContent(text)
                            }
                        case .toolCall(let info):
                            toolCallCard(info: info, result: findToolResult(after: part, in: message.parts))
                        case .toolResult:
                            EmptyView()
                        }
                    }

                    Text(timeLabel(message.timestamp))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(FlowTokens.textDisabled)
                }
                .padding(.horizontal, 10)
                .overlay(alignment: isUser ? .topLeading : .topTrailing) {
                    if hoveredMessageID == message.id {
                        copyButton(fullText(of: message))
                            .offset(x: isUser ? -8 : 8, y: -4)
                    }
                }

                if !isUser { Spacer(minLength: 30) }
            }
        }
        .onHover { hovering in
            hoveredMessageID = hovering ? message.id : nil
        }
    }

    private func findToolResult(after part: StoredPart, in parts: [StoredPart]) -> StoredToolResult? {
        guard let idx = parts.firstIndex(where: { $0.id == part.id }),
              idx + 1 < parts.count,
              case .toolResult(let result) = parts[idx + 1] else {
            return nil
        }
        return result
    }

    private func fullText(of message: StoredMessage) -> String {
        message.parts.compactMap { part in
            switch part {
            case .text(let t): return t
            case .toolCall(let tc): return "[\(tc.displayName): \(tc.parameters.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))]"
            case .toolResult(let tr): return tr.message
            }
        }.joined(separator: "\n")
    }

    // MARK: - User Bubble

    private func userBubble(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(FlowTokens.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, FlowTokens.spacingMD)
            .background(
                RoundedRectangle(cornerRadius: FlowTokens.radiusMedium, style: .continuous)
                    .fill(FlowTokens.accentSubtle)
            )
    }

    // MARK: - Tool Call Card

    private func toolCallCard(info: StoredToolCall, result: StoredToolResult?) -> some View {
        let accentColor = colorFromHex(info.accentColorHex)

        return HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1)
                .fill(accentColor)
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: FlowTokens.spacingSM) {
                    Image(systemName: info.icon)
                        .font(.system(size: 9))
                        .foregroundColor(accentColor)
                    Text(info.displayName)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(accentColor)
                }
                .padding(.horizontal, FlowTokens.spacingMD)
                .padding(.top, FlowTokens.spacingMD)
                .padding(.bottom, FlowTokens.spacingSM)

                if !info.parameters.isEmpty {
                    VStack(alignment: .leading, spacing: FlowTokens.spacingXS) {
                        ForEach(info.parameters, id: \.key) { param in
                            HStack(alignment: .top, spacing: FlowTokens.spacingSM) {
                                Text(param.key)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(FlowTokens.textMuted)
                                    .frame(minWidth: 50, alignment: .trailing)
                                Text(param.value)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(FlowTokens.textSecondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .padding(.horizontal, FlowTokens.spacingMD)
                    .padding(.bottom, FlowTokens.spacingSM)
                }

                if let result = result {
                    Rectangle().fill(FlowTokens.border).frame(height: FlowTokens.hairline).padding(.horizontal, FlowTokens.spacingSM)
                    HStack(spacing: FlowTokens.spacingSM) {
                        Image(systemName: result.icon)
                            .font(.system(size: 9))
                            .foregroundColor(result.success ? FlowTokens.success : FlowTokens.error)
                        Text(result.message)
                            .font(.system(size: 10))
                            .foregroundColor(result.success ? FlowTokens.textSecondary : FlowTokens.error)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, FlowTokens.spacingMD)
                    .padding(.vertical, FlowTokens.spacingSM)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: FlowTokens.radiusMedium, style: .continuous)
                .fill(FlowTokens.bg2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FlowTokens.radiusMedium, style: .continuous)
                .stroke(FlowTokens.border, lineWidth: FlowTokens.hairline)
        )
    }

    // MARK: - AI Message Content (with code blocks)

    private func aiMessageContent(_ content: String) -> some View {
        let blocks = parseContentBlocks(content)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(FlowTokens.accent)
                    .frame(width: 2)

                VStack(alignment: .leading, spacing: FlowTokens.spacingSM) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .text(let text):
                            Text(text)
                                .font(.system(size: 12))
                                .foregroundColor(FlowTokens.textSecondary)
                        case .code(let lang, let code):
                            codeBlock(language: lang, code: code)
                        }
                    }
                }
                .padding(.leading, FlowTokens.spacingMD)
                .padding(.trailing, 10)
                .padding(.vertical, FlowTokens.spacingMD)
            }
            .background(
                RoundedRectangle(cornerRadius: FlowTokens.radiusMedium, style: .continuous)
                    .fill(FlowTokens.bg2)
            )
        }
    }

    private func codeBlock(language: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if !language.isEmpty {
                    Text(language)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(FlowTokens.textMuted)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 9))
                        .foregroundColor(FlowTokens.textMuted)
                }
                .buttonStyle(.plain)
                .help("Copy code")
            }
            .padding(.horizontal, FlowTokens.spacingMD)
            .padding(.top, FlowTokens.spacingSM)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(FlowTokens.textPrimary)
                    .padding(FlowTokens.spacingMD)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                .fill(FlowTokens.bg3)
        )
    }

    // MARK: - Copy Button

    private func copyButton(_ text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 9))
                .foregroundColor(FlowTokens.textHint)
                .padding(FlowTokens.spacingSM)
                .background(
                    RoundedRectangle(cornerRadius: FlowTokens.radiusSmall, style: .continuous)
                        .fill(FlowTokens.bg3)
                )
        }
        .buttonStyle(.plain)
        .transition(.opacity)
    }

    // MARK: - Typing Indicator

    private var typingIndicator: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: FlowTokens.spacingXS) {
                Text("Flow")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(FlowTokens.textMuted)

                HStack(spacing: FlowTokens.spacingMD) {
                    if processingStatus.isEmpty {
                        HStack(spacing: FlowTokens.spacingSM) {
                            Circle()
                                .fill(FlowTokens.accent)
                                .frame(width: 6, height: 6)
                                .opacity(pulseOpacity)
                                .animation(
                                    .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                                    value: isProcessing
                                )
                            Text("Thinking...")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(FlowTokens.textTertiary)
                        }
                    } else {
                        HStack(spacing: FlowTokens.spacingSM) {
                            ProgressView()
                                .scaleEffect(0.4)
                                .frame(width: 10, height: 10)
                            Text(processingStatus)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(FlowTokens.textTertiary)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, FlowTokens.spacingMD)
                .background(
                    RoundedRectangle(cornerRadius: FlowTokens.radiusMedium, style: .continuous)
                        .fill(FlowTokens.bg2)
                )
            }
            .padding(.horizontal, 10)
            Spacer()
        }
    }

    private var pulseOpacity: Double {
        isProcessing ? 0.3 : 1.0
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: FlowTokens.spacingLG) {
            Spacer().frame(height: 30)

            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28))
                .foregroundColor(FlowTokens.textDisabled)

            Text("Chat with Clome Flow")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(FlowTokens.textTertiary)

            if let project = projectContext {
                Text("Context: \((project as NSString).lastPathComponent)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(FlowTokens.textDisabled)
            }

            VStack(spacing: FlowTokens.spacingMD) {
                starterPrompt("Summarize my todos", icon: "checklist")
                starterPrompt("What deadlines are coming up?", icon: "flag")
                starterPrompt("Help me plan this sprint", icon: "calendar")
            }
            .padding(.top, FlowTokens.spacingMD)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func starterPrompt(_ text: String, icon: String) -> some View {
        Button {
            inputText = text
            sendMessage()
        } label: {
            HStack(spacing: FlowTokens.spacingMD) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(FlowTokens.accent)
                Text(text)
                    .font(.system(size: 11))
                    .foregroundColor(FlowTokens.textSecondary)
                Spacer()
                Image(systemName: "arrow.up.circle")
                    .font(.system(size: 10))
                    .foregroundColor(FlowTokens.textMuted)
            }
            .padding(.horizontal, FlowTokens.spacingLG)
            .padding(.vertical, FlowTokens.spacingMD)
            .background(
                RoundedRectangle(cornerRadius: FlowTokens.radiusMedium, style: .continuous)
                    .fill(FlowTokens.bg2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FlowTokens.radiusMedium, style: .continuous)
                    .stroke(FlowTokens.border, lineWidth: FlowTokens.hairline)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, FlowTokens.spacingXL)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            contextIndicator

            HStack(spacing: FlowTokens.spacingMD) {
                TextField("Ask Clome Flow…", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .flowFont(.body)
                    .foregroundColor(FlowTokens.textPrimary)
                    .focused($isInputFocused)
                    .lineLimit(1...5)
                    .onSubmit { sendMessage() }

                if isProcessing {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                } else {
                    Button {
                        sendMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundColor(inputText.isEmpty ? FlowTokens.textDisabled : FlowTokens.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(inputText.isEmpty)
                }
            }
            .flowInput(isFocused: isInputFocused)
            .padding(.horizontal, FlowTokens.spacingLG)
            .padding(.vertical, FlowTokens.spacingMD)
        }
        .background(FlowTokens.bg0)
    }

    private var contextIndicator: some View {
        let sync = FlowSyncService.shared
        let todoCount = sync.todos.filter { !$0.isCompleted }.count
        let deadlineCount = sync.deadlines.filter { !$0.isCompleted }.count
        let noteCount = sync.notes.count
        let calMgr = CalendarDataManager.shared
        let now = Date()
        let weekEnd = Calendar.current.date(byAdding: .day, value: 7, to: now)!
        let eventCount = calMgr.hasCalendarAccess
            ? calMgr.items.filter { $0.kind == .systemEvent && $0.startDate >= now && $0.startDate <= weekEnd }.count
            : 0
        let hasData = todoCount > 0 || deadlineCount > 0 || noteCount > 0 || eventCount > 0

        return Group {
            if hasData {
                HStack(spacing: 0) {
                    Text(contextParts(todos: todoCount, deadlines: deadlineCount, notes: noteCount, events: eventCount))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(FlowTokens.textMuted)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, FlowTokens.spacingXS)
            }
        }
    }

    private func contextParts(todos: Int, deadlines: Int, notes: Int, events: Int) -> String {
        var parts: [String] = []
        if events > 0 { parts.append("\(events) event\(events == 1 ? "" : "s")") }
        if todos > 0 { parts.append("\(todos) todo\(todos == 1 ? "" : "s")") }
        if deadlines > 0 { parts.append("\(deadlines) deadline\(deadlines == 1 ? "" : "s")") }
        if notes > 0 { parts.append("\(notes) note\(notes == 1 ? "" : "s")") }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - System Prompt

    private var systemInstruction: String {
        var prompt = """
        You are Clome Flow, a proactive AI scheduling assistant embedded in the Clome \
        development environment. You make smart scheduling decisions and propose concrete plans. \
        You are friendly but decisive. Keep responses concise — the developer is in a coding context. \
        Use markdown formatting for code blocks and emphasis where helpful.

        YOUR CAPABILITIES:

        Todos:
        - create_todo: Create a new to-do item
        - complete_todo: Mark a to-do as done
        - delete_todo: Remove a to-do
        - edit_todo: Edit title, notes, priority, or category of a to-do
        - schedule_todo: Schedule a to-do to a specific date/time on the calendar
        - list_todos: List and filter todos by status, priority, or category

        Deadlines:
        - create_deadline: Create a deadline with prep-time tracking
        - complete_deadline: Mark a deadline as completed
        - delete_deadline: Remove a deadline
        - edit_deadline: Edit title, due date, category, or prep hours

        Notes:
        - create_note: Save a note or idea
        - edit_note: Edit content, summary, or category
        - delete_note: Remove a note
        - search_notes: Search notes by keyword

        Calendar:
        - schedule_event: Schedule a new calendar event
        - reschedule_event: Move an event to a new date/time
        - delete_event: Remove a calendar event
        - edit_event: Edit event title, location, or notes
        - query_events: Query events in a date range
        - check_availability: Check if a time slot is free
        - list_calendars: List available calendars

        RULES:
        - ALWAYS use function calls for actions. Never describe actions in text only.
        - For complex requests (e.g. "schedule my study sessions this week"), break them into \
        multiple function calls.
        - Before scheduling, check the calendar context for conflicts.
        - If a tool fails, explain the issue and suggest alternatives.
        - RESPOND with plain text for greetings, questions, summaries, or general conversation.
        - Be concise — 1-3 sentences max for text responses unless more detail is needed.
        - Use the context provided to give informed answers about the user's schedule and calendar.
        - Infer reasonable defaults: 60 min for meetings, 30 min for errands, 45 min for gym.
        - Always use 24-hour HH:mm format for times in function calls.

        DATE/TIME FORMAT:
        - Dates: YYYY-MM-DD
        - Times: HH:mm in 24-hour format

        PRIORITY LEVELS: high, medium, low
        NOTE CATEGORIES: idea, task, reminder, goal, journal, reference
        HABIT CATEGORIES: sleep, meal, exercise, study, meeting, chores, general, research, \
        personalStudy, reading, socialEvent, selfCare, commute, creative, work, entertainment, lecture
        """

        if let project = projectContext {
            prompt += "\n\nPROJECT CONTEXT: The user is working in \((project as NSString).lastPathComponent) (\(project))"
        }

        return prompt
    }

    // MARK: - Send Message

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let convID = store.activeConversationID else { return }

        let config = store.activeConversation?.contextConfig ?? .default
        let toolConfig = store.activeConversation?.toolConfig ?? .default
        let context = config.assembleContext(
            sync: FlowSyncService.shared,
            calendarManager: CalendarDataManager.shared,
            projectPath: projectContext
        )
        let fullMessage = "\(context)\nUser: \(text)"

        let userMessage = StoredMessage(role: .user, parts: [.text(text)])
        store.appendMessage(userMessage, toConversation: convID)
        store.appendAPIHistory(["role": "user", "parts": [["text": fullMessage]]], toConversation: convID)

        inputText = ""
        isProcessing = true
        processingStatus = ""

        Task {
            do {
                let history = store.getAPIHistory(for: convID)
                let filteredTools = toolConfig.filterDeclarations(ToolRegistry.allDeclarations())
                let response = try await ClomeFlowAPIClient.shared.sendChatMessage(
                    contents: history,
                    systemInstruction: systemInstruction,
                    generationConfig: .init(temperature: 0.3, maxOutputTokens: 4096),
                    tools: filteredTools
                )

                var messageParts: [StoredPart] = []
                var modelParts: [[String: Any]] = []
                var toolResults: [(name: String, result: ToolResult)] = []

                if let candidate = response.candidates.first {
                    for part in candidate.parts {
                        switch part {
                        case .functionCall(let fc):
                            modelParts.append(["functionCall": ["name": fc.name, "args": fc.args.mapValues { $0.rawValue }]])

                            let display = ToolRegistry.displayInfo(for: fc.name)
                            let params: [(key: String, value: String)] = fc.args.compactMap { key, value in
                                guard let strVal = value.coercedStringValue else { return nil }
                                return (key: key, value: strVal)
                            }

                            let callInfo = StoredToolCall(
                                toolName: fc.name,
                                displayName: display.displayName,
                                icon: display.icon,
                                parameters: params,
                                accentColorHex: display.hex
                            )
                            messageParts.append(.toolCall(callInfo))

                            await MainActor.run {
                                processingStatus = "Running \(display.displayName)..."
                            }

                            let result = handleFunctionCall(fc)
                            toolResults.append((name: fc.name, result: result))

                            // Log tool usage
                            store.updateToolConfig(for: convID) { config in
                                config.logUsage(toolName: fc.name, success: result.success)
                            }

                            let resultInfo = StoredToolResult(
                                success: result.success,
                                message: result.message,
                                icon: result.success ? "checkmark.circle.fill" : "xmark.circle.fill"
                            )
                            messageParts.append(.toolResult(resultInfo))

                        case .text(let t):
                            modelParts.append(["text": t])
                            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                messageParts.append(.text(trimmed))
                            }
                        }
                    }
                }

                if !modelParts.isEmpty {
                    store.appendAPIHistory(["role": "model", "parts": modelParts], toConversation: convID)
                }

                // Feed tool results back to the AI so it can see what happened
                if !toolResults.isEmpty {
                    var functionResponseParts: [[String: Any]] = []
                    for tr in toolResults {
                        functionResponseParts.append([
                            "functionResponse": [
                                "name": tr.name,
                                "response": ["result": tr.result.message, "success": tr.result.success]
                            ]
                        ])
                    }
                    store.appendAPIHistory(["role": "function", "parts": functionResponseParts], toConversation: convID)

                    // Make a follow-up call so the AI can respond to the tool results
                    await MainActor.run { processingStatus = "Summarizing..." }
                    let followUpHistory = store.getAPIHistory(for: convID)
                    let followUp = try await ClomeFlowAPIClient.shared.sendChatMessage(
                        contents: followUpHistory,
                        systemInstruction: systemInstruction,
                        generationConfig: .init(temperature: 0.3, maxOutputTokens: 4096),
                        tools: filteredTools
                    )

                    if let candidate = followUp.candidates.first {
                        var followUpModelParts: [[String: Any]] = []
                        for part in candidate.parts {
                            if case .text(let t) = part {
                                followUpModelParts.append(["text": t])
                                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    messageParts.append(.text(trimmed))
                                }
                            }
                        }
                        if !followUpModelParts.isEmpty {
                            store.appendAPIHistory(["role": "model", "parts": followUpModelParts], toConversation: convID)
                        }
                    }
                }

                if messageParts.isEmpty {
                    let fallback = response.text ?? "I couldn't generate a response."
                    messageParts.append(.text(fallback))
                }

                let assistantMessage = StoredMessage(role: .assistant, parts: messageParts)
                store.appendMessage(assistantMessage, toConversation: convID)
            } catch {
                let errorMsg = "Error: \(error.localizedDescription)"
                let errMessage = StoredMessage(role: .assistant, parts: [.text(errorMsg)])
                store.appendMessage(errMessage, toConversation: convID)
            }
            isProcessing = false
            processingStatus = ""
        }
    }

    // MARK: - Function Call Handling

    private struct ToolResult {
        let success: Bool
        let message: String
    }

    private func handleFunctionCall(_ fc: ClomeFlowFunctionCall) -> ToolResult {
        let sync = FlowSyncService.shared
        let calMgr = CalendarDataManager.shared
        let dateFmt = DateFormatter()
        dateFmt.locale = Locale(identifier: "en_US_POSIX")

        switch fc.name {

        // MARK: Todos

        case "create_todo":
            let title = fc.args["title"]?.stringValue ?? "Untitled"
            let notes = fc.args["notes"]?.stringValue
            let catStr = fc.args["category"]?.stringValue
            let priStr = fc.args["priority"]?.stringValue
            let category = catStr.flatMap { HabitCategory(rawValue: $0) } ?? .general
            let priority = priStr.flatMap { TodoPriority(rawValue: $0) } ?? .medium
            let todo = TodoItem(title: title, notes: notes, category: category, priority: priority)
            sync.addTodo(todo)
            let priLabel = priority == .high ? " (high priority)" : ""
            return ToolResult(success: true, message: "Added to your to-do list: \(title)\(priLabel)")

        case "complete_todo":
            let title = fc.args["todo_title"]?.stringValue ?? ""
            if let todo = sync.todos.first(where: { $0.title.lowercased() == title.lowercased() && !$0.isCompleted }) {
                sync.toggleTodoComplete(id: todo.id)
                return ToolResult(success: true, message: "Marked \(todo.title) as done")
            }
            return ToolResult(success: false, message: "I couldn't find an active to-do called \"\(title)\"")

        case "delete_todo":
            let title = fc.args["todo_title"]?.stringValue ?? ""
            if let todo = sync.todos.first(where: { $0.title.lowercased() == title.lowercased() }) {
                sync.deleteTodo(id: todo.id)
                return ToolResult(success: true, message: "Removed \(todo.title) from your to-dos")
            }
            return ToolResult(success: false, message: "I couldn't find a to-do called \"\(title)\"")

        case "edit_todo":
            let title = fc.args["todo_title"]?.stringValue ?? ""
            guard let todo = sync.todos.first(where: { $0.title.lowercased() == title.lowercased() }) else {
                return ToolResult(success: false, message: "I couldn't find a to-do called \"\(title)\"")
            }
            let newTitle = fc.args["new_title"]?.stringValue
            let newNotes = fc.args["new_notes"]?.stringValue
            let newPri = fc.args["new_priority"]?.stringValue.flatMap { TodoPriority(rawValue: $0) }
            let newCat = fc.args["new_category"]?.stringValue.flatMap { HabitCategory(rawValue: $0) }
            sync.updateTodo(id: todo.id, title: newTitle, notes: newNotes, category: newCat, priority: newPri)
            return ToolResult(success: true, message: "Updated to-do: \(newTitle ?? todo.title)")

        case "schedule_todo":
            let title = fc.args["todo_title"]?.stringValue ?? ""
            guard let todo = sync.todos.first(where: { $0.title.lowercased() == title.lowercased() }) else {
                return ToolResult(success: false, message: "I couldn't find a to-do called \"\(title)\"")
            }
            let dateStr = fc.args["date"]?.stringValue ?? ""
            let startStr = fc.args["start_time"]?.stringValue ?? ""
            dateFmt.dateFormat = "yyyy-MM-dd HH:mm"
            guard let start = dateFmt.date(from: "\(dateStr) \(startStr)") else {
                return ToolResult(success: false, message: "I couldn't parse the date/time. Use YYYY-MM-DD and HH:mm.")
            }
            let endDate: Date
            if let endStr = fc.args["end_time"]?.stringValue, let parsed = dateFmt.date(from: "\(dateStr) \(endStr)") {
                endDate = parsed
            } else {
                endDate = start.addingTimeInterval(30 * 60)
            }
            sync.updateTodoSchedule(id: todo.id, scheduledDate: start, scheduledEndDate: endDate)
            let timeFmt = DateFormatter()
            timeFmt.dateFormat = "h:mm a"
            return ToolResult(success: true, message: "Scheduled \(todo.title) at \(timeFmt.string(from: start))")

        case "list_todos":
            let filter = fc.args["filter"]?.stringValue ?? "active"
            let priFilter = fc.args["priority"]?.stringValue.flatMap { TodoPriority(rawValue: $0) }
            let catFilter = fc.args["category"]?.stringValue.flatMap { HabitCategory(rawValue: $0) }
            var filtered = sync.todos
            switch filter {
            case "active": filtered = filtered.filter { !$0.isCompleted }
            case "completed": filtered = filtered.filter { $0.isCompleted }
            default: break
            }
            if let pri = priFilter { filtered = filtered.filter { $0.priority == pri } }
            if let cat = catFilter { filtered = filtered.filter { $0.category == cat } }
            if filtered.isEmpty {
                return ToolResult(success: true, message: "No todos found matching your criteria.")
            }
            let list = filtered.map { "- \($0.title)\($0.priority == .high ? " [HIGH]" : "")\($0.isCompleted ? " [DONE]" : "")" }.joined(separator: "\n")
            return ToolResult(success: true, message: "Found \(filtered.count) todo(s):\n\(list)")

        // MARK: Deadlines

        case "create_deadline":
            let title = fc.args["title"]?.stringValue ?? "Untitled"
            let dueDateStr = fc.args["due_date"]?.stringValue ?? ""
            let dueTime = fc.args["due_time"]?.stringValue
            let catStr = fc.args["category"]?.stringValue
            let prepHours = fc.args["estimated_prep_hours"]?.numberValue
            let category = catStr.flatMap { HabitCategory(rawValue: $0) } ?? .general
            var dueDate: Date?
            if let time = dueTime {
                dateFmt.dateFormat = "yyyy-MM-dd HH:mm"
                dueDate = dateFmt.date(from: "\(dueDateStr) \(time)")
            }
            if dueDate == nil {
                dateFmt.dateFormat = "yyyy-MM-dd"
                dueDate = dateFmt.date(from: dueDateStr)
            }
            guard let date = dueDate else {
                return ToolResult(success: false, message: "I couldn't parse the date \"\(dueDateStr)\". Use YYYY-MM-DD format.")
            }
            let deadline = Deadline(title: title, dueDate: date, category: category, estimatedPrepHours: prepHours)
            sync.addDeadline(deadline)
            let displayFmt = DateFormatter()
            displayFmt.dateFormat = "EEEE, MMM d"
            var msg = "Deadline set: \(title) — due \(displayFmt.string(from: date))"
            if let h = prepHours { msg += " (~\(Int(h))h prep)" }
            return ToolResult(success: true, message: msg)

        case "complete_deadline":
            let title = fc.args["deadline_title"]?.stringValue ?? ""
            if let dl = sync.deadlines.first(where: { $0.title.lowercased() == title.lowercased() && !$0.isCompleted }) {
                sync.toggleDeadlineComplete(id: dl.id)
                return ToolResult(success: true, message: "Marked deadline \(dl.title) as completed")
            }
            return ToolResult(success: false, message: "I couldn't find an active deadline called \"\(title)\"")

        case "delete_deadline":
            let title = fc.args["deadline_title"]?.stringValue ?? ""
            if let dl = sync.deadlines.first(where: { $0.title.lowercased() == title.lowercased() }) {
                sync.deleteDeadline(id: dl.id)
                return ToolResult(success: true, message: "Removed deadline: \(dl.title)")
            }
            return ToolResult(success: false, message: "I couldn't find a deadline called \"\(title)\"")

        case "edit_deadline":
            let title = fc.args["deadline_title"]?.stringValue ?? ""
            guard let dl = sync.deadlines.first(where: { $0.title.lowercased() == title.lowercased() }) else {
                return ToolResult(success: false, message: "I couldn't find a deadline called \"\(title)\"")
            }
            let newTitle = fc.args["new_title"]?.stringValue
            var newDueDate: Date?
            if let dueDateStr = fc.args["new_due_date"]?.stringValue {
                dateFmt.dateFormat = "yyyy-MM-dd"
                newDueDate = dateFmt.date(from: dueDateStr)
            }
            let newCat = fc.args["new_category"]?.stringValue.flatMap { HabitCategory(rawValue: $0) }
            let newPrep = fc.args["new_prep_hours"]?.numberValue
            sync.updateDeadline(id: dl.id, title: newTitle, dueDate: newDueDate, category: newCat, estimatedPrepHours: newPrep)
            return ToolResult(success: true, message: "Updated deadline: \(newTitle ?? dl.title)")

        // MARK: Notes

        case "create_note":
            let content = fc.args["content"]?.stringValue ?? ""
            let summary = fc.args["summary"]?.stringValue ?? content.prefix(50).description
            let catStr = fc.args["category"]?.stringValue
            let category = catStr.flatMap { NoteCategory(rawValue: $0) } ?? .idea
            let note = NoteEntry(rawContent: content, summary: summary, category: category)
            sync.addNote(note)
            return ToolResult(success: true, message: "Note saved: \(summary)")

        case "edit_note":
            let summary = fc.args["note_summary"]?.stringValue ?? ""
            guard let note = sync.notes.first(where: { $0.summary.lowercased().contains(summary.lowercased()) }) else {
                return ToolResult(success: false, message: "I couldn't find a note matching \"\(summary)\"")
            }
            let newSummary = fc.args["new_summary"]?.stringValue
            let newCat = fc.args["new_category"]?.stringValue.flatMap { NoteCategory(rawValue: $0) }
            let newContent = fc.args["new_content"]?.stringValue
            sync.updateNote(id: note.id, summary: newSummary, category: newCat, formattedContent: newContent)
            return ToolResult(success: true, message: "Updated note: \(newSummary ?? note.summary)")

        case "delete_note":
            let summary = fc.args["note_summary"]?.stringValue ?? ""
            guard let note = sync.notes.first(where: { $0.summary.lowercased().contains(summary.lowercased()) }) else {
                return ToolResult(success: false, message: "I couldn't find a note matching \"\(summary)\"")
            }
            sync.deleteNote(id: note.id)
            return ToolResult(success: true, message: "Deleted note: \(note.summary)")

        case "search_notes":
            let query = fc.args["query"]?.stringValue ?? ""
            let results = sync.search(query: query)
            if results.isEmpty {
                return ToolResult(success: true, message: "No notes found matching \"\(query)\".")
            }
            let list = results.prefix(10).map { "- [\($0.category.displayName)] \($0.summary)" }.joined(separator: "\n")
            return ToolResult(success: true, message: "Found \(results.count) note(s):\n\(list)")

        // MARK: Calendar

        case "schedule_event":
            let title = fc.args["title"]?.stringValue ?? "Untitled"
            let dateStr = fc.args["date"]?.stringValue ?? ""
            let startStr = fc.args["start_time"]?.stringValue ?? ""
            let endStr = fc.args["end_time"]?.stringValue
            let duration = fc.args["duration"]?.numberValue.flatMap { Int(exactly: $0) } ?? 60
            dateFmt.dateFormat = "yyyy-MM-dd HH:mm"
            guard let start = dateFmt.date(from: "\(dateStr) \(startStr)") else {
                return ToolResult(success: false, message: "I couldn't parse the date/time. Use YYYY-MM-DD and HH:mm.")
            }
            let end: Date
            if let e = endStr, let parsed = dateFmt.date(from: "\(dateStr) \(e)") {
                end = parsed
            } else {
                end = start.addingTimeInterval(Double(duration) * 60)
            }
            if !calMgr.hasCalendarAccess {
                calMgr.requestCalendarAccess()
                return ToolResult(success: false, message: "Calendar access needed. Please grant permission when prompted.")
            }
            calMgr.createSystemEvent(title: title, start: start, end: end)
            let timeFmt = DateFormatter()
            timeFmt.dateFormat = "h:mm a"
            return ToolResult(success: true, message: "Scheduled \(title) at \(timeFmt.string(from: start))")

        case "reschedule_event":
            let eventTitle = fc.args["event_title"]?.stringValue ?? ""
            let newDateStr = fc.args["new_date"]?.stringValue
            let newStartStr = fc.args["new_start_time"]?.stringValue
            guard let identifier = calMgr.findEventIdentifier(title: eventTitle) else {
                return ToolResult(success: false, message: "I couldn't find \"\(eventTitle)\" on your calendar.")
            }
            guard let current = calMgr.items.first(where: {
                ($0 as? SystemEventItem)?.eventIdentifier == identifier
            }) else {
                return ToolResult(success: false, message: "I couldn't find the event details.")
            }
            let duration2 = current.endDate.timeIntervalSince(current.startDate)
            dateFmt.dateFormat = "yyyy-MM-dd HH:mm"
            let dayFmt = DateFormatter()
            dayFmt.dateFormat = "yyyy-MM-dd"
            var newStart = current.startDate
            if let d = newDateStr, let t = newStartStr {
                if let parsed = dateFmt.date(from: "\(d) \(t)") { newStart = parsed }
            } else if let t = newStartStr {
                let day = dayFmt.string(from: current.startDate)
                if let parsed = dateFmt.date(from: "\(day) \(t)") { newStart = parsed }
            } else if let d = newDateStr {
                let timeFmt2 = DateFormatter()
                timeFmt2.dateFormat = "HH:mm"
                let time = timeFmt2.string(from: current.startDate)
                if let parsed = dateFmt.date(from: "\(d) \(time)") { newStart = parsed }
            }
            let newEnd = newStart.addingTimeInterval(duration2)
            calMgr.moveSystemEvent(identifier: identifier, newStart: newStart, newEnd: newEnd)
            let displayTimeFmt = DateFormatter()
            displayTimeFmt.dateFormat = "h:mm a"
            return ToolResult(success: true, message: "Moved \(eventTitle) to \(displayTimeFmt.string(from: newStart))")

        case "delete_event":
            let eventTitle = fc.args["event_title"]?.stringValue ?? ""
            guard let identifier = calMgr.findEventIdentifier(title: eventTitle) else {
                return ToolResult(success: false, message: "I couldn't find \"\(eventTitle)\" on your calendar.")
            }
            calMgr.deleteSystemEvent(identifier: identifier)
            return ToolResult(success: true, message: "Removed \(eventTitle) from your calendar")

        case "edit_event":
            let eventTitle = fc.args["event_title"]?.stringValue ?? ""
            guard let identifier = calMgr.findEventIdentifier(title: eventTitle) else {
                return ToolResult(success: false, message: "I couldn't find \"\(eventTitle)\" on your calendar.")
            }
            let newTitle = fc.args["new_title"]?.stringValue
            let newLocation = fc.args["new_location"]?.stringValue
            let newNotes = fc.args["new_notes"]?.stringValue
            calMgr.updateSystemEvent(identifier: identifier, title: newTitle, location: newLocation, notes: newNotes)
            return ToolResult(success: true, message: "Updated event: \(newTitle ?? eventTitle)")

        case "list_calendars":
            let calendars = calMgr.listCalendars()
            if calendars.isEmpty {
                return ToolResult(success: true, message: "No calendars found.")
            }
            let list = calendars.map { "- \($0.title)" }.joined(separator: "\n")
            return ToolResult(success: true, message: "Available calendars:\n\(list)")

        case "query_events":
            let calendar = Calendar.current
            dateFmt.dateFormat = "yyyy-MM-dd"
            let start: Date
            let end: Date
            if let dateStr = fc.args["date"]?.stringValue, let d = dateFmt.date(from: dateStr) {
                start = calendar.startOfDay(for: d)
                end = calendar.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-1)
            } else if let startStr = fc.args["date_range_start"]?.stringValue,
                      let endStr = fc.args["date_range_end"]?.stringValue,
                      let s = dateFmt.date(from: startStr), let e = dateFmt.date(from: endStr) {
                start = calendar.startOfDay(for: s)
                end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: e))!.addingTimeInterval(-1)
            } else {
                start = calendar.startOfDay(for: Date())
                end = calendar.date(byAdding: .day, value: 7, to: start)!.addingTimeInterval(-1)
            }
            let events = calMgr.queryEvents(from: start, to: end)
            if events.isEmpty {
                return ToolResult(success: true, message: "No events found in that date range.")
            }
            let timeFmt3 = DateFormatter()
            timeFmt3.dateFormat = "EEE MMM d, h:mm a"
            let list = events.prefix(20).map { "- \(timeFmt3.string(from: $0.startDate)): \($0.title)" }.joined(separator: "\n")
            return ToolResult(success: true, message: "Found \(events.count) event(s):\n\(list)")

        case "check_availability":
            let dateStr = fc.args["date"]?.stringValue ?? ""
            let startStr = fc.args["start_time"]?.stringValue ?? ""
            let endStr = fc.args["end_time"]?.stringValue ?? ""
            dateFmt.dateFormat = "yyyy-MM-dd HH:mm"
            guard let start = dateFmt.date(from: "\(dateStr) \(startStr)"),
                  let end = dateFmt.date(from: "\(dateStr) \(endStr)") else {
                return ToolResult(success: false, message: "I couldn't parse the date/time.")
            }
            let isFree = calMgr.checkAvailability(start: start, end: end)
            let timeFmt4 = DateFormatter()
            timeFmt4.dateFormat = "h:mm a"
            if isFree {
                return ToolResult(success: true, message: "\(timeFmt4.string(from: start))–\(timeFmt4.string(from: end)) is free.")
            } else {
                return ToolResult(success: true, message: "\(timeFmt4.string(from: start))–\(timeFmt4.string(from: end)) has conflicts.")
            }

        default:
            NSLog("[FlowChat] Unknown tool: \(fc.name)")
            return ToolResult(success: false, message: "Unknown tool: \(fc.name)")
        }
    }

    // MARK: - Content Block Parsing

    private enum ContentBlock {
        case text(String)
        case code(language: String, code: String)
    }

    private func parseContentBlocks(_ content: String) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        let lines = content.components(separatedBy: "\n")
        var inCodeBlock = false
        var codeLanguage = ""
        var codeLines: [String] = []
        var textLines: [String] = []

        for line in lines {
            if line.hasPrefix("```") && !inCodeBlock {
                if !textLines.isEmpty {
                    blocks.append(.text(textLines.joined(separator: "\n")))
                    textLines = []
                }
                inCodeBlock = true
                codeLanguage = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                codeLines = []
            } else if line.hasPrefix("```") && inCodeBlock {
                blocks.append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n")))
                inCodeBlock = false
                codeLanguage = ""
                codeLines = []
            } else if inCodeBlock {
                codeLines.append(line)
            } else {
                textLines.append(line)
            }
        }

        if inCodeBlock {
            blocks.append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n")))
        }
        if !textLines.isEmpty {
            blocks.append(.text(textLines.joined(separator: "\n")))
        }

        return blocks
    }

    // MARK: - Formatting Helpers

    private func timeLabel(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        return fmt.string(from: date)
    }

    private func relativeDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let fmt = DateFormatter()
            fmt.dateFormat = "h:mm a"
            return fmt.string(from: date)
        } else if cal.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let fmt = DateFormatter()
            fmt.dateFormat = "MMM d"
            return fmt.string(from: date)
        }
    }

    private func colorFromHex(_ hex: String) -> Color {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let val = UInt64(h, radix: 16) else { return FlowTokens.textTertiary }
        return Color(
            red: Double((val >> 16) & 0xFF) / 255.0,
            green: Double((val >> 8) & 0xFF) / 255.0,
            blue: Double(val & 0xFF) / 255.0
        )
    }
}
