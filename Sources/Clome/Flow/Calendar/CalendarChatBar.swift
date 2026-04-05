import SwiftUI
import ClomeModels
import ClomeServices

// MARK: - Calendar Chat Bar

/// Compact inline AI chat bar at the bottom of the calendar view.
/// Uses the same function-calling harness as FlowChatView for consistent behavior.
struct CalendarChatBar: View {

    // MARK: - State

    @ObservedObject private var dataManager = CalendarDataManager.shared
    @ObservedObject private var syncService = FlowSyncService.shared

    @State private var chatInput = ""
    @State private var isProcessing = false
    @State private var processingLabel = ""
    @State private var lastResults: [ActionResult] = []
    @State private var showResults = false
    @State private var conversationHistory: [[String: Any]] = []
    @FocusState private var inputFocused: Bool

    /// A compact result from a tool call or text response.
    struct ActionResult: Identifiable {
        let id = UUID()
        let icon: String
        let iconColor: Color
        let message: String
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Results area
            if showResults, !lastResults.isEmpty {
                resultsView
            }

            Divider().background(FlowTokens.border)

            // Input bar
            HStack(spacing: FlowTokens.spacingMD) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundColor(FlowTokens.accent)

                TextField("Ask Flow: 'Add meeting at 3pm'...", text: $chatInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(FlowTokens.textPrimary)
                    .focused($inputFocused)
                    .onSubmit { sendMessage() }

                if isProcessing {
                    HStack(spacing: FlowTokens.spacingSM) {
                        ProgressView()
                            .scaleEffect(0.4)
                            .frame(width: 10, height: 10)
                        if !processingLabel.isEmpty {
                            Text(processingLabel)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(FlowTokens.textMuted)
                        }
                    }
                } else if !chatInput.isEmpty {
                    Button {
                        sendMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(FlowTokens.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, FlowTokens.spacingMD)
            .background(FlowTokens.bg1)
        }
    }

    // MARK: - Results View

    private var resultsView: some View {
        VStack(alignment: .leading, spacing: FlowTokens.spacingXS) {
            ForEach(lastResults) { result in
                HStack(spacing: FlowTokens.spacingSM) {
                    Image(systemName: result.icon)
                        .font(.system(size: 9))
                        .foregroundColor(result.iconColor)

                    Text(result.message)
                        .font(.system(size: 10))
                        .foregroundColor(FlowTokens.textSecondary)
                        .lineLimit(2)
                }
            }

            // Dismiss
            HStack {
                Spacer()
                Button {
                    withAnimation(.flowQuick) {
                        showResults = false
                        lastResults = []
                    }
                } label: {
                    Text("Dismiss")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(FlowTokens.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(FlowTokens.spacingMD)
        .background(FlowTokens.bg2)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - System Instruction

    private var systemInstruction: String {
        // Use custom prompt if set, otherwise default
        if let custom = UserDefaults.standard.string(forKey: "flowChatCustomPrompt"),
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return custom
        }

        let cal = Calendar.current
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        let selectedDateFmt = DateFormatter()
        selectedDateFmt.dateFormat = "EEEE, MMMM d, yyyy"
        let selectedDateStr = selectedDateFmt.string(from: dataManager.selectedDate)

        return """
        You are Clome Flow, an AI calendar assistant embedded in a developer's IDE. \
        You are concise — 1-2 sentences max. You are viewing: \(selectedDateStr). \
        Current time: \(dateFormatter.string(from: Date())).

        YOUR TOOLS:
        1. schedule_event — Schedule a new calendar event
        2. reschedule_event — Move an existing event
        3. delete_event — Remove an event
        4. create_todo — Add a to-do item
        5. complete_todo — Mark a to-do done
        6. create_deadline — Set a deadline
        7. create_note — Save a note

        RULES:
        - ALWAYS use function calls for scheduling actions. Never describe actions in text.
        - Be very concise — you're in a compact calendar bar, not a full chat.
        - Infer defaults: 60 min meetings, 30 min errands, 45 min gym.
        - Use the calendar context to avoid conflicts.
        - Dates: YYYY-MM-DD, Times: HH:mm (24-hour).
        """
    }

    // MARK: - Context

    private func buildContext() -> String {
        CalendarDataManager.shared.refresh()

        let cal = Calendar.current
        let now = Date()
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEE, MMM d"

        var ctx = ""

        // Events for selected day
        let dayItems = dataManager.items.filter {
            cal.isDate($0.startDate, inSameDayAs: dataManager.selectedDate) && $0.kind == .systemEvent
        }.sorted { $0.startDate < $1.startDate }

        if !dayItems.isEmpty {
            ctx += "EVENTS ON \(dayFormatter.string(from: dataManager.selectedDate).uppercased()):\n"
            for item in dayItems {
                if item.isAllDay {
                    ctx += "  [All day] \(item.title)\n"
                } else {
                    ctx += "  \(timeFormatter.string(from: item.startDate))-\(timeFormatter.string(from: item.endDate)): \(item.title)\n"
                }
            }
            ctx += "\n"
        } else {
            ctx += "CALENDAR: No events on \(dayFormatter.string(from: dataManager.selectedDate)).\n\n"
        }

        // Active todos
        let activeTodos = syncService.todos.filter { !$0.isCompleted }
        if !activeTodos.isEmpty {
            ctx += "TODOS: \(activeTodos.prefix(5).map { $0.title }.joined(separator: ", "))\n"
        }

        // Deadlines
        let deadlines = syncService.deadlines.filter { !$0.isCompleted }
        if !deadlines.isEmpty {
            let dlFmt = DateFormatter()
            dlFmt.dateFormat = "MMM d"
            ctx += "DEADLINES: \(deadlines.prefix(3).map { "\($0.title) (due \(dlFmt.string(from: $0.dueDate)))" }.joined(separator: ", "))\n"
        }

        return ctx
    }

    // MARK: - Tool Declarations (via ToolRegistry — single source of truth)

    private var toolDeclarations: [[String: Any]] {
        ToolRegistry.allDeclarations()
    }

    // MARK: - Send Message

    private func sendMessage() {
        let text = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let context = buildContext()
        let fullMessage = "\(context)\nUser: \(text)"

        conversationHistory.append(["role": "user", "parts": [["text": fullMessage]]])
        chatInput = ""
        isProcessing = true
        processingLabel = ""
        lastResults = []

        Task {
            do {
                let response = try await ClomeFlowAPIClient.shared.sendChatMessage(
                    contents: conversationHistory,
                    systemInstruction: systemInstruction,
                    generationConfig: ClomeFlowGenerationConfig(temperature: 0.3, maxOutputTokens: 1024),
                    tools: toolDeclarations
                )

                var results: [ActionResult] = []
                var modelParts: [[String: Any]] = []

                if let candidate = response.candidates.first {
                    for part in candidate.parts {
                        switch part {
                        case .functionCall(let fc):
                            modelParts.append(["functionCall": ["name": fc.name, "args": fc.args.mapValues { $0.rawValue }]])

                            let display = toolDisplayInfo(fc.name)
                            await MainActor.run { processingLabel = display.name }

                            let resultText = executeTool(fc)
                            let success = !resultText.contains("couldn't find") && !resultText.contains("couldn't parse")
                            results.append(ActionResult(
                                icon: success ? "checkmark.circle.fill" : "xmark.circle.fill",
                                iconColor: success ? FlowTokens.success : FlowTokens.error,
                                message: resultText
                            ))

                        case .text(let t):
                            modelParts.append(["text": t])
                            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                results.append(ActionResult(
                                    icon: "bubble.left.fill",
                                    iconColor: FlowTokens.accent,
                                    message: trimmed
                                ))
                            }
                        }
                    }
                }

                if !modelParts.isEmpty {
                    conversationHistory.append(["role": "model", "parts": modelParts])
                }

                if results.isEmpty {
                    results.append(ActionResult(
                        icon: "bubble.left.fill",
                        iconColor: FlowTokens.textTertiary,
                        message: response.text ?? "I couldn't process that."
                    ))
                }

                lastResults = results
                withAnimation(.flowQuick) { showResults = true }

                // Auto-dismiss after 5 seconds if only confirmations
                let allSuccess = results.allSatisfy { $0.icon == "checkmark.circle.fill" }
                if allSuccess {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        withAnimation(.flowQuick) { showResults = false }
                    }
                }

            } catch {
                lastResults = [ActionResult(
                    icon: "xmark.circle.fill",
                    iconColor: FlowTokens.error,
                    message: error.localizedDescription
                )]
                withAnimation(.flowQuick) { showResults = true }
            }

            isProcessing = false
            processingLabel = ""
        }
    }

    // MARK: - Tool Display Info

    private func toolDisplayInfo(_ name: String) -> (name: String, icon: String, color: Color) {
        switch name {
        case "schedule_event":   return ("Schedule", "calendar.badge.plus", FlowTokens.accent)
        case "reschedule_event": return ("Reschedule", "calendar.badge.clock", FlowTokens.warning)
        case "delete_event":     return ("Delete Event", "calendar.badge.minus", FlowTokens.error)
        case "create_todo":      return ("Create Todo", "plus.circle.fill", FlowTokens.success)
        case "complete_todo":    return ("Complete Todo", "checkmark.circle.fill", FlowTokens.success)
        case "create_deadline":  return ("Deadline", "flag.fill", FlowTokens.warning)
        case "create_note":      return ("Note", "note.text", FlowTokens.accent)
        default:                 return (name, "gear", FlowTokens.textTertiary)
        }
    }

    // MARK: - Tool Execution

    private func executeTool(_ fc: ClomeFlowFunctionCall) -> String {
        switch fc.name {

        case "schedule_event":
            let title = fc.args["title"]?.stringValue ?? "Untitled"
            let dateStr = fc.args["date"]?.stringValue ?? ""
            let startStr = fc.args["start_time"]?.stringValue ?? ""
            let endStr = fc.args["end_time"]?.stringValue
            let duration = fc.args["duration"]?.numberValue.flatMap { Int(exactly: $0) } ?? 60

            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyy-MM-dd HH:mm"
            guard let start = fmt.date(from: "\(dateStr) \(startStr)") else {
                return "I couldn't parse the date/time."
            }
            let end: Date
            if let e = endStr, let parsed = fmt.date(from: "\(dateStr) \(e)") {
                end = parsed
            } else {
                end = start.addingTimeInterval(Double(duration) * 60)
            }

            if !dataManager.hasCalendarAccess {
                dataManager.requestCalendarAccess()
                return "Calendar access needed. Please grant permission."
            }
            dataManager.createSystemEvent(title: title, start: start, end: end)

            let displayFmt = DateFormatter()
            displayFmt.dateFormat = "h:mm a"
            return "Scheduled \(title) at \(displayFmt.string(from: start))"

        case "reschedule_event":
            let eventTitle = fc.args["event_title"]?.stringValue ?? ""
            let newDateStr = fc.args["new_date"]?.stringValue
            let newStartStr = fc.args["new_start_time"]?.stringValue

            guard let identifier = dataManager.findEventIdentifier(title: eventTitle) else {
                return "I couldn't find \"\(eventTitle)\" on your calendar."
            }
            guard let current = dataManager.items.first(where: {
                ($0 as? SystemEventItem)?.eventIdentifier == identifier
            }) else {
                return "I couldn't find the event details."
            }

            let duration = current.endDate.timeIntervalSince(current.startDate)
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyy-MM-dd HH:mm"

            let dayFmt = DateFormatter()
            dayFmt.dateFormat = "yyyy-MM-dd"

            var newStart = current.startDate
            if let d = newDateStr, let t = newStartStr {
                if let parsed = fmt.date(from: "\(d) \(t)") { newStart = parsed }
            } else if let t = newStartStr {
                let day = dayFmt.string(from: current.startDate)
                if let parsed = fmt.date(from: "\(day) \(t)") { newStart = parsed }
            }

            let newEnd = newStart.addingTimeInterval(duration)
            dataManager.moveSystemEvent(identifier: identifier, newStart: newStart, newEnd: newEnd)

            let displayFmt = DateFormatter()
            displayFmt.dateFormat = "h:mm a"
            return "Moved \(eventTitle) to \(displayFmt.string(from: newStart))"

        case "delete_event":
            let eventTitle = fc.args["event_title"]?.stringValue ?? ""
            guard let identifier = dataManager.findEventIdentifier(title: eventTitle) else {
                return "I couldn't find \"\(eventTitle)\" on your calendar."
            }
            dataManager.deleteSystemEvent(identifier: identifier)
            return "Removed \(eventTitle)"

        case "create_todo":
            let title = fc.args["title"]?.stringValue ?? "Untitled"
            let notes = fc.args["notes"]?.stringValue
            let pri = fc.args["priority"]?.stringValue.flatMap { TodoPriority(rawValue: $0) } ?? .medium
            syncService.addTodo(TodoItem(title: title, notes: notes, priority: pri))
            dataManager.refresh()
            return "Added todo: \(title)"

        case "complete_todo":
            let title = fc.args["todo_title"]?.stringValue ?? ""
            if let todo = syncService.todos.first(where: { $0.title.lowercased() == title.lowercased() && !$0.isCompleted }) {
                syncService.toggleTodoComplete(id: todo.id)
                return "Completed: \(todo.title)"
            }
            return "I couldn't find todo \"\(title)\""

        case "create_deadline":
            let title = fc.args["title"]?.stringValue ?? "Untitled"
            let dueDateStr = fc.args["due_date"]?.stringValue ?? ""
            let prepHours = fc.args["estimated_prep_hours"]?.numberValue
            let catStr = fc.args["category"]?.stringValue
            let category = catStr.flatMap { HabitCategory(rawValue: $0) } ?? .general

            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyy-MM-dd"
            guard let date = fmt.date(from: dueDateStr) else {
                return "I couldn't parse date \"\(dueDateStr)\""
            }
            syncService.addDeadline(Deadline(title: title, dueDate: date, category: category, estimatedPrepHours: prepHours))
            dataManager.refresh()
            return "Deadline set: \(title)"

        case "create_note":
            let content = fc.args["content"]?.stringValue ?? ""
            let summary = fc.args["summary"]?.stringValue ?? String(content.prefix(50))
            let cat = fc.args["category"]?.stringValue.flatMap { NoteCategory(rawValue: $0) } ?? .idea
            syncService.addNote(NoteEntry(rawContent: content, summary: summary, category: cat))
            return "Note saved: \(summary)"

        default:
            return ""
        }
    }
}
