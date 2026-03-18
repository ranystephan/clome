import Foundation

/// Bridges Claude Code's status line data to Clome.
/// Reads context window usage from temp files written by the clome-claude-bridge.sh script.
@MainActor
class ClaudeContextBridge {
    static let shared = ClaudeContextBridge()

    private let contextDir = "/tmp/clome-claude-context"
    private let bridgeScriptName = "clome-claude-bridge.sh"

    /// All sessions keyed by session ID.
    private var sessions: [String: ClaudeSessionContext] = [:]

    /// Tracks which terminal (by ObjectIdentifier) has claimed which session ID.
    private var claimedSessions: [ObjectIdentifier: String] = [:]

    /// Throttle disk reads to avoid hitting the filesystem on every 2-second poll.
    private var lastLoadTime: Date?
    private let loadCacheInterval: TimeInterval = 1.0

    private init() {
        try? FileManager.default.createDirectory(
            atPath: contextDir,
            withIntermediateDirectories: true
        )
        ensureBridgeInstalled()
    }

    // MARK: - Public API

    /// Get context percentage for a specific terminal's Claude Code session.
    /// Each terminal claims its own session to avoid showing duplicate percentages.
    func contextPercentage(forTerminal terminal: AnyObject, directory dir: String?) -> Int? {
        guard let dir else { return nil }
        reloadIfNeeded()

        let terminalId = ObjectIdentifier(terminal)
        let now = Date().timeIntervalSince1970

        // If this terminal already claimed a session, use it
        if let sessionId = claimedSessions[terminalId],
           let session = sessions[sessionId],
           now - session.timestamp < 30 {
            return session.usedPercentage
        }

        // Find an unclaimed session matching this directory
        let alreadyClaimed = Set(claimedSessions.values)
        let resolvedDir = (dir as NSString).resolvingSymlinksInPath

        let best = sessions.values
            .filter { s in
                guard !s.sessionId.isEmpty, !alreadyClaimed.contains(s.sessionId) else { return false }
                guard now - s.timestamp < 30 else { return false }
                return s.cwd == dir || (s.cwd as NSString).resolvingSymlinksInPath == resolvedDir
            }
            .max(by: { $0.timestamp < $1.timestamp })

        if let best {
            claimedSessions[terminalId] = best.sessionId
            return best.usedPercentage
        }

        // Stale claim — clear and retry
        if claimedSessions.removeValue(forKey: terminalId) != nil {
            let stillClaimed = Set(claimedSessions.values)
            let retry = sessions.values
                .filter { s in
                    guard !s.sessionId.isEmpty, !stillClaimed.contains(s.sessionId) else { return false }
                    guard now - s.timestamp < 30 else { return false }
                    return s.cwd == dir || (s.cwd as NSString).resolvingSymlinksInPath == resolvedDir
                }
                .max(by: { $0.timestamp < $1.timestamp })
            if let retry {
                claimedSessions[terminalId] = retry.sessionId
                return retry.usedPercentage
            }
        }

        return nil
    }

    /// Release a terminal's claimed session (call when terminal stops running Claude Code).
    func releaseClaim(forTerminal terminal: AnyObject) {
        claimedSessions.removeValue(forKey: ObjectIdentifier(terminal))
    }

    /// Legacy directory-only lookup (backward compatibility).
    func contextPercentage(forDirectory dir: String?) -> Int? {
        guard let dir else { return nil }
        reloadIfNeeded()
        let resolvedDir = (dir as NSString).resolvingSymlinksInPath
        let now = Date().timeIntervalSince1970
        return sessions.values
            .filter { now - $0.timestamp < 30 && ($0.cwd == dir || ($0.cwd as NSString).resolvingSymlinksInPath == resolvedDir) }
            .max(by: { $0.timestamp < $1.timestamp })?
            .usedPercentage
    }

    /// Get full session context for a directory.
    func sessionContext(forDirectory dir: String?) -> ClaudeSessionContext? {
        guard let dir else { return nil }
        reloadIfNeeded()
        let resolved = (dir as NSString).resolvingSymlinksInPath
        return sessions.values.first {
            $0.cwd == dir || ($0.cwd as NSString).resolvingSymlinksInPath == resolved
        }
    }

    // MARK: - File Reading

    private func reloadIfNeeded() {
        let now = Date()
        if let last = lastLoadTime, now.timeIntervalSince(last) < loadCacheInterval { return }
        lastLoadTime = now
        loadSessionFiles()
    }

    private func loadSessionFiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: contextDir) else { return }
        let now = Date().timeIntervalSince1970
        var foundIds = Set<String>()

        for file in files where file.hasSuffix(".json") {
            let path = "\(contextDir)/\(file)"
            guard let data = fm.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let session = ClaudeSessionContext(
                sessionId: json["session_id"] as? String ?? "",
                cwd: json["cwd"] as? String ?? "",
                usedPercentage: json["used_percentage"] as? Int,
                remainingPercentage: json["remaining_percentage"] as? Int,
                contextWindowSize: json["context_window_size"] as? Int,
                inputTokens: json["input_tokens"] as? Int,
                outputTokens: json["output_tokens"] as? Int,
                model: json["model"] as? String,
                cost: json["cost"] as? Double,
                timestamp: json["timestamp"] as? Double ?? 0
            )

            if !session.sessionId.isEmpty {
                sessions[session.sessionId] = session
                foundIds.insert(session.sessionId)
            }

            // Clean up stale files (older than 2 minutes)
            if now - session.timestamp > 120 {
                try? fm.removeItem(atPath: path)
            }
        }

        // Remove sessions whose files no longer exist
        sessions = sessions.filter { foundIds.contains($0.key) }
        // Remove claims for gone sessions
        claimedSessions = claimedSessions.filter { sessions[$0.value] != nil }
    }

    // MARK: - Bridge Installation

    private func ensureBridgeInstalled() {
        let bridgePath = NSHomeDirectory() + "/.config/clome/\(bridgeScriptName)"
        let bridgeDir = (bridgePath as NSString).deletingLastPathComponent
        let fm = FileManager.default

        try? fm.createDirectory(atPath: bridgeDir, withIntermediateDirectories: true)
        installBridgeScript(to: bridgePath)
        configureClaude(bridgePath: bridgePath)
    }

    private func installBridgeScript(to path: String) {
        let originalCommand = readOriginalStatusLine() ?? ""
        let passthrough: String
        if originalCommand.isEmpty {
            passthrough = ""
        } else {
            passthrough = "echo \"$INPUT\" | \(originalCommand)"
        }

        let script = [
            "#!/bin/bash",
            "# Clome <-> Claude Code context bridge",
            "# Writes context data to /tmp for Clome sidebar, then passes through to original statusline.",
            "CLOME_DIR=\"/tmp/clome-claude-context\"",
            "mkdir -p \"$CLOME_DIR\"",
            "INPUT=$(cat)",
            "if command -v jq &>/dev/null; then",
            "  SID=$(echo \"$INPUT\" | jq -r '.session_id // empty')",
            "  CWD=$(echo \"$INPUT\" | jq -r '.cwd // empty')",
            "  UP=$(echo \"$INPUT\" | jq -r '.context_window.used_percentage // empty')",
            "  RP=$(echo \"$INPUT\" | jq -r '.context_window.remaining_percentage // empty')",
            "  CS=$(echo \"$INPUT\" | jq -r '.context_window.context_window_size // empty')",
            "  IT=$(echo \"$INPUT\" | jq -r '.context_window.total_input_tokens // empty')",
            "  OT=$(echo \"$INPUT\" | jq -r '.context_window.total_output_tokens // empty')",
            "  MDL=$(echo \"$INPUT\" | jq -r '.model.display_name // empty')",
            "  COST=$(echo \"$INPUT\" | jq -r '.cost.total_cost_usd // empty')",
            "  if [ -n \"$SID\" ]; then",
            "    echo \"{\\\"session_id\\\":\\\"$SID\\\",\\\"cwd\\\":\\\"$CWD\\\",\\\"used_percentage\\\":${UP:-null},\\\"remaining_percentage\\\":${RP:-null},\\\"context_window_size\\\":${CS:-null},\\\"input_tokens\\\":${IT:-null},\\\"output_tokens\\\":${OT:-null},\\\"model\\\":\\\"$MDL\\\",\\\"cost\\\":${COST:-null},\\\"timestamp\\\":$(date +%s)}\" > \"$CLOME_DIR/$SID.json\"",
            "  fi",
            "fi",
            passthrough,
        ].joined(separator: "\n")

        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: path
        )
    }

    private func readOriginalStatusLine() -> String? {
        let settingsPath = NSHomeDirectory() + "/.claude/settings.json"
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusLine = json["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else {
            return nil
        }
        if command.contains("clome-claude-bridge") { return nil }
        return command
    }

    private func configureClaude(bridgePath: String) {
        let settingsPath = NSHomeDirectory() + "/.claude/settings.json"
        let fm = FileManager.default

        var settings: [String: Any] = [:]
        if let data = fm.contents(atPath: settingsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
            if let statusLine = json["statusLine"] as? [String: Any],
               let command = statusLine["command"] as? String,
               command.contains("clome-claude-bridge") {
                return
            }
        }

        settings["statusLine"] = [
            "type": "command",
            "command": bridgePath
        ]

        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            let dir = (settingsPath as NSString).deletingLastPathComponent
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: settingsPath))
        }
    }
}

// MARK: - Session Context Data

struct ClaudeSessionContext {
    let sessionId: String
    let cwd: String
    let usedPercentage: Int?
    let remainingPercentage: Int?
    let contextWindowSize: Int?
    let inputTokens: Int?
    let outputTokens: Int?
    let model: String?
    let cost: Double?
    let timestamp: Double
}
