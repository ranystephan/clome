import Foundation

// MARK: - Tool Configuration

/// Per-conversation tool enable/disable state and usage tracking.
struct ToolConfiguration: Codable {

    /// Tool names that are enabled for this conversation. Defaults to all tools.
    var enabledTools: Set<String>

    /// Chronological log of tool calls made in this conversation.
    var usageLog: [ToolUsageEntry]

    // MARK: - Usage Entry

    struct ToolUsageEntry: Codable, Identifiable {
        let id: UUID
        let toolName: String
        let timestamp: Date
        let success: Bool

        init(toolName: String, success: Bool) {
            self.id = UUID()
            self.toolName = toolName
            self.timestamp = Date()
            self.success = success
        }
    }

    // MARK: - Factory

    /// Default configuration with all tools enabled and an empty usage log.
    static var `default`: ToolConfiguration {
        ToolConfiguration(
            enabledTools: Set(ToolRegistry.allToolNames),
            usageLog: []
        )
    }

    // MARK: - Declaration Filtering

    /// Filters Gemini API declarations to only include enabled tools.
    func filterDeclarations(_ allDeclarations: [[String: Any]]) -> [[String: Any]] {
        allDeclarations.filter { decl in
            guard let name = decl["name"] as? String else { return false }
            return enabledTools.contains(name)
        }
    }

    // MARK: - Mutations

    /// Toggles the enabled state of a tool.
    mutating func toggle(_ toolName: String) {
        if enabledTools.contains(toolName) {
            enabledTools.remove(toolName)
        } else {
            enabledTools.insert(toolName)
        }
    }

    /// Returns whether a tool is currently enabled.
    func isEnabled(_ toolName: String) -> Bool {
        enabledTools.contains(toolName)
    }

    /// Records a tool invocation in the usage log.
    mutating func logUsage(toolName: String, success: Bool) {
        usageLog.append(ToolUsageEntry(toolName: toolName, success: success))
    }

    /// Returns the number of times a tool has been called in this conversation.
    func usageCount(for toolName: String) -> Int {
        usageLog.filter { $0.toolName == toolName }.count
    }
}
