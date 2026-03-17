import Foundation

/// Bridges Claude Code's status line data to Clome.
/// Reads context window usage from temp files written by the clome-claude-bridge.sh script.
@MainActor
class ClaudeContextBridge {
    static let shared = ClaudeContextBridge()

    private let contextDir = "/tmp/clome-claude-context"
    private let bridgeScriptName = "clome-claude-bridge.sh"

    /// Cached session data keyed by working directory.
    private var sessionsByDir: [String: ClaudeSessionContext] = [:]

    private init() {
        // Ensure the context directory exists
        try? FileManager.default.createDirectory(
            atPath: contextDir,
            withIntermediateDirectories: true
        )
        ensureBridgeInstalled()
    }

    // MARK: - Public API

    /// Get context percentage for a Claude Code session running in the given directory.
    func contextPercentage(forDirectory dir: String?) -> Int? {
        guard let dir else { return nil }
        // Reload from disk
        loadSessionFiles()

        // Match by directory
        if let session = sessionsByDir[dir] {
            // Only return if data is recent (within 30 seconds)
            if Date().timeIntervalSince1970 - session.timestamp < 30 {
                return session.usedPercentage
            }
        }

        // Try matching with resolved/canonical paths
        let resolvedDir = (dir as NSString).resolvingSymlinksInPath
        for (path, session) in sessionsByDir {
            let resolvedPath = (path as NSString).resolvingSymlinksInPath
            if resolvedPath == resolvedDir {
                if Date().timeIntervalSince1970 - session.timestamp < 30 {
                    return session.usedPercentage
                }
            }
        }

        return nil
    }

    /// Get full session context for a directory.
    func sessionContext(forDirectory dir: String?) -> ClaudeSessionContext? {
        guard let dir else { return nil }
        loadSessionFiles()
        return sessionsByDir[dir] ?? {
            let resolved = (dir as NSString).resolvingSymlinksInPath
            return sessionsByDir.first { ($0.key as NSString).resolvingSymlinksInPath == resolved }?.value
        }()
    }

    // MARK: - File Reading

    private func loadSessionFiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: contextDir) else { return }

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

            if !session.cwd.isEmpty {
                sessionsByDir[session.cwd] = session
            }

            // Clean up stale files (older than 2 minutes)
            if Date().timeIntervalSince1970 - session.timestamp > 120 {
                try? fm.removeItem(atPath: path)
            }
        }
    }

    // MARK: - Bridge Installation

    /// Ensure the bridge script is installed and Claude Code is configured to use it.
    private func ensureBridgeInstalled() {
        let bridgePath = NSHomeDirectory() + "/.config/clome/\(bridgeScriptName)"
        let bridgeDir = (bridgePath as NSString).deletingLastPathComponent
        let fm = FileManager.default

        // Create directory
        try? fm.createDirectory(atPath: bridgeDir, withIntermediateDirectories: true)

        // Install/update the bridge script
        installBridgeScript(to: bridgePath)

        // Configure Claude Code's settings to use our bridge
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

        // Write script with no leading indentation (heredoc-sensitive)
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

    /// Read the current Claude Code status line command from settings.
    private func readOriginalStatusLine() -> String? {
        let settingsPath = NSHomeDirectory() + "/.claude/settings.json"
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusLine = json["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else {
            return nil
        }

        // Don't return our own bridge as the "original"
        if command.contains("clome-claude-bridge") { return nil }

        return command
    }

    /// Configure Claude Code's settings.json to use our bridge script.
    private func configureClaude(bridgePath: String) {
        let settingsPath = NSHomeDirectory() + "/.claude/settings.json"
        let fm = FileManager.default

        // Read existing settings
        var settings: [String: Any] = [:]
        if let data = fm.contents(atPath: settingsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json

            // Check if already configured
            if let statusLine = json["statusLine"] as? [String: Any],
               let command = statusLine["command"] as? String,
               command.contains("clome-claude-bridge") {
                return // Already configured
            }
        }

        // Set the status line to our bridge
        settings["statusLine"] = [
            "type": "command",
            "command": bridgePath
        ]

        // Write back
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            // Ensure directory exists
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
