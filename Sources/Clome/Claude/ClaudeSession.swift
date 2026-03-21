import Foundation

/// A single message in a Claude Code conversation
struct ClaudeMessage {
    let uuid: String
    let type: MessageType
    let content: String
    let timestamp: Date
    let parentUuid: String?
    let model: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let isSidechain: Bool

    enum MessageType: String {
        case user
        case assistant
        case progress
        case fileHistorySnapshot = "file-history-snapshot"
    }
}

/// Represents a Claude Code session stored on disk
struct ClaudeSession: Identifiable {
    let id: String              // session UUID
    let projectPath: String     // decoded working directory
    var name: String?           // user-assigned display name (from Clome)
    let createdAt: Date
    let lastActiveAt: Date
    let messageCount: Int
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let model: String?          // primary model used
    let gitBranch: String?
    let filePath: String        // path to the .jsonl file
    var pinned: Bool = false

    /// If this session is currently running in a Clome workspace, the workspace name.
    var activeInWorkspace: String?

    /// Estimated cost (rough approximation based on Opus pricing)
    var estimatedCost: Double {
        let inputCost = Double(totalInputTokens) * 15.0 / 1_000_000
        let outputCost = Double(totalOutputTokens) * 75.0 / 1_000_000
        return inputCost + outputCost
    }

    /// First user message in the session (from history.jsonl `display` field).
    /// This is what Claude Code's `/resume` picker shows as the session summary.
    var summary: String?

    /// Last user message (from tail of the JSONL file).
    var lastUserMessage: String?

    /// Human-readable display name: user-assigned name > first message summary > date fallback.
    var displayName: String {
        if let name = name, !name.isEmpty {
            return name
        }
        if let s = summary, !s.isEmpty {
            let clean = s
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip generic commands like "/init"
            if !clean.hasPrefix("/") || clean.count > 20 {
                let truncated = clean.prefix(80)
                return truncated.count < clean.count ? "\(truncated)..." : String(truncated)
            }
        }
        if let msg = lastUserMessage, !msg.isEmpty {
            let clean = msg.replacingOccurrences(of: "\n", with: " ")
            let truncated = clean.prefix(80)
            return truncated.count < clean.count ? "\(truncated)..." : String(truncated)
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Session \(formatter.string(from: createdAt))"
    }

    /// Duration from first to last message
    var duration: TimeInterval {
        return lastActiveAt.timeIntervalSince(createdAt)
    }

    /// Formatted token usage string
    var tokenUsageSummary: String {
        let inK = totalInputTokens > 1000 ? "\(totalInputTokens / 1000)K" : "\(totalInputTokens)"
        let outK = totalOutputTokens > 1000 ? "\(totalOutputTokens / 1000)K" : "\(totalOutputTokens)"
        return "\(inK) in / \(outK) out"
    }
}
