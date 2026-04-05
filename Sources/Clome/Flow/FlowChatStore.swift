import Foundation
import SwiftUI

// MARK: - Conversation Model

struct FlowConversation: Identifiable, Codable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [StoredMessage]
    var apiHistory: [[String: Any]]
    var workspaceID: UUID?
    var contextConfig: ContextConfiguration
    var toolConfig: ToolConfiguration

    init(id: UUID = UUID(), title: String = "New Chat",
         workspaceID: UUID? = nil, projectPath: String? = nil) {
        self.id = id
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.messages = []
        self.apiHistory = []
        self.workspaceID = workspaceID
        var ctxConfig = ContextConfiguration.default
        ctxConfig.workspaceProjectPath = projectPath
        self.contextConfig = ctxConfig
        self.toolConfig = .default
    }

    // MARK: - Codable (apiHistory is [[String: Any]], needs manual coding)

    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, messages, apiHistory
        case workspaceID, contextConfig, toolConfig
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(messages, forKey: .messages)
        let historyData = try JSONSerialization.data(withJSONObject: apiHistory)
        try container.encode(historyData, forKey: .apiHistory)
        try container.encodeIfPresent(workspaceID, forKey: .workspaceID)
        try container.encode(contextConfig, forKey: .contextConfig)
        try container.encode(toolConfig, forKey: .toolConfig)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        messages = try container.decode([StoredMessage].self, forKey: .messages)
        let historyData = try container.decode(Data.self, forKey: .apiHistory)
        apiHistory = (try? JSONSerialization.jsonObject(with: historyData) as? [[String: Any]]) ?? []
        // Migration: existing conversations without these fields get defaults
        workspaceID = try container.decodeIfPresent(UUID.self, forKey: .workspaceID)
        contextConfig = (try? container.decode(ContextConfiguration.self, forKey: .contextConfig)) ?? .default
        toolConfig = (try? container.decode(ToolConfiguration.self, forKey: .toolConfig)) ?? .default
    }
}

// MARK: - Stored Message (Codable version of FlowChatMessage)

struct StoredMessage: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let role: Role
    var parts: [StoredPart]

    enum Role: String, Codable {
        case user
        case assistant
    }

    init(id: UUID = UUID(), timestamp: Date = Date(), role: Role, parts: [StoredPart]) {
        self.id = id
        self.timestamp = timestamp
        self.role = role
        self.parts = parts
    }
}

enum StoredPart: Identifiable, Codable {
    case text(String)
    case toolCall(StoredToolCall)
    case toolResult(StoredToolResult)

    var id: String {
        switch self {
        case .text(let t): return "text-\(t.prefix(20).hashValue)"
        case .toolCall(let tc): return "call-\(tc.id)"
        case .toolResult(let tr): return "result-\(tr.id)"
        }
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey { case type, value }
    enum PartType: String, Codable { case text, toolCall, toolResult }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t):
            try container.encode(PartType.text, forKey: .type)
            try container.encode(t, forKey: .value)
        case .toolCall(let tc):
            try container.encode(PartType.toolCall, forKey: .type)
            try container.encode(tc, forKey: .value)
        case .toolResult(let tr):
            try container.encode(PartType.toolResult, forKey: .type)
            try container.encode(tr, forKey: .value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(PartType.self, forKey: .type)
        switch type {
        case .text:
            self = .text(try container.decode(String.self, forKey: .value))
        case .toolCall:
            self = .toolCall(try container.decode(StoredToolCall.self, forKey: .value))
        case .toolResult:
            self = .toolResult(try container.decode(StoredToolResult.self, forKey: .value))
        }
    }
}

struct StoredToolCall: Identifiable, Codable {
    let id: String
    let toolName: String
    let displayName: String
    let icon: String
    let parameters: [ToolParam]
    let accentColorHex: String

    struct ToolParam: Codable {
        let key: String
        let value: String
    }

    init(id: String = UUID().uuidString, toolName: String, displayName: String, icon: String,
         parameters: [(key: String, value: String)], accentColorHex: String) {
        self.id = id
        self.toolName = toolName
        self.displayName = displayName
        self.icon = icon
        self.parameters = parameters.map { ToolParam(key: $0.key, value: $0.value) }
        self.accentColorHex = accentColorHex
    }
}

struct StoredToolResult: Identifiable, Codable {
    let id: String
    let success: Bool
    let message: String
    let icon: String

    init(id: String = UUID().uuidString, success: Bool, message: String, icon: String) {
        self.id = id
        self.success = success
        self.message = message
        self.icon = icon
    }
}

// MARK: - Chat Store

@MainActor
final class FlowChatStore: ObservableObject {
    static let shared = FlowChatStore()

    @Published var conversations: [FlowConversation] = []
    @Published var activeConversationID: UUID?

    private static let storageKey = "FlowChatStore.conversations"
    private static let activeIDKey = "FlowChatStore.activeConversationID"

    var activeConversation: FlowConversation? {
        get { conversations.first(where: { $0.id == activeConversationID }) }
    }

    var activeIndex: Int? {
        conversations.firstIndex(where: { $0.id == activeConversationID })
    }

    private init() {
        loadFromDisk()
    }

    // MARK: - Conversation Management

    @discardableResult
    func createConversation(title: String = "New Chat", workspaceID: UUID? = nil,
                            projectPath: String? = nil) -> FlowConversation {
        let conv = FlowConversation(title: title, workspaceID: workspaceID, projectPath: projectPath)
        conversations.insert(conv, at: 0)
        activeConversationID = conv.id
        saveToDisk()
        return conv
    }

    /// Returns conversations filtered by workspace. nil = global (no workspace).
    func conversations(forWorkspace id: UUID?) -> [FlowConversation] {
        conversations.filter { $0.workspaceID == id }
    }

    func selectConversation(_ id: UUID) {
        activeConversationID = id
        UserDefaults.standard.set(id.uuidString, forKey: Self.activeIDKey)
    }

    func deleteConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if activeConversationID == id {
            activeConversationID = conversations.first?.id
        }
        saveToDisk()
    }

    func renameConversation(_ id: UUID, to title: String) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].title = title
        saveToDisk()
    }

    func clearAllConversations() {
        conversations.removeAll()
        activeConversationID = nil
        saveToDisk()
    }

    // MARK: - Message Operations

    func appendMessage(_ message: StoredMessage, toConversation id: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].messages.append(message)
        conversations[idx].updatedAt = Date()

        // Auto-title from first user message
        if conversations[idx].title == "New Chat",
           message.role == .user,
           case .text(let text) = message.parts.first {
            let trimmed = String(text.prefix(40))
            conversations[idx].title = trimmed + (text.count > 40 ? "..." : "")
        }

        saveToDisk()
    }

    func appendAPIHistory(_ entry: [String: Any], toConversation id: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].apiHistory.append(entry)

        // Prune history if it exceeds 50 entries to prevent unbounded growth
        if conversations[idx].apiHistory.count > 50 {
            let excess = conversations[idx].apiHistory.count - 40
            conversations[idx].apiHistory.removeFirst(excess)
        }
        // No save here — saved when message is appended
    }

    func getAPIHistory(for id: UUID) -> [[String: Any]] {
        conversations.first(where: { $0.id == id })?.apiHistory ?? []
    }

    // MARK: - Configuration Mutation

    /// Updates the context configuration for a conversation and persists.
    func updateContextConfig(for conversationID: UUID, _ transform: (inout ContextConfiguration) -> Void) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        transform(&conversations[idx].contextConfig)
        saveToDisk()
    }

    /// Updates the tool configuration for a conversation and persists.
    func updateToolConfig(for conversationID: UUID, _ transform: (inout ToolConfiguration) -> Void) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        transform(&conversations[idx].toolConfig)
        saveToDisk()
    }

    // MARK: - Persistence

    private func saveToDisk() {
        do {
            let data = try JSONEncoder().encode(conversations)
            UserDefaults.standard.set(data, forKey: Self.storageKey)
            if let activeID = activeConversationID {
                UserDefaults.standard.set(activeID.uuidString, forKey: Self.activeIDKey)
            }
        } catch {
            NSLog("[FlowChatStore] Save failed: \(error)")
        }
    }

    private func loadFromDisk() {
        // Decode outside of @Published assignment to avoid triggering
        // SwiftUI view updates if the singleton is first accessed during body.
        var loadedConvos: [FlowConversation] = []
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let convos = try? JSONDecoder().decode([FlowConversation].self, from: data) {
            loadedConvos = convos
            NSLog("[FlowChatStore] Loaded \(convos.count) conversations")
        }

        let loadedActiveID: UUID?
        if let idStr = UserDefaults.standard.string(forKey: Self.activeIDKey),
           let id = UUID(uuidString: idStr),
           loadedConvos.contains(where: { $0.id == id }) {
            loadedActiveID = id
        } else {
            loadedActiveID = loadedConvos.first?.id
        }

        // Assign via backing storage to avoid publishing during init
        _conversations = Published(initialValue: loadedConvos)
        _activeConversationID = Published(initialValue: loadedActiveID)
    }
}
