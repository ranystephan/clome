import AppKit

/// Manages discovering, parsing, naming, and launching Claude Code sessions.
/// Reads session JSONL files from ~/.claude/projects/ and provides metadata
/// without requiring full file loads.
@MainActor
class ClaudeSessionManager {
    static let shared = ClaudeSessionManager()

    /// Cached sessions keyed by project path
    private var sessionCache: [String: [ClaudeSession]] = [:]

    /// Timestamp of last cache refresh per project path
    private var cacheTimestamps: [String: Date] = [:]

    /// Cache TTL in seconds (refresh if older than this)
    private let cacheTTL: TimeInterval = 30.0

    private let fileManager = FileManager.default

    /// Cached session summaries from history.jsonl: sessionId -> first display text
    private var summaryCache: [String: String] = [:]
    private var summaryCacheTimestamp: Date?

    private init() {}

    // MARK: - Path Encoding

    /// Encodes a working directory path to the Claude projects folder format.
    /// `/Users/foo/bar` becomes `-Users-foo-bar`
    static func encodedCwd(_ path: String) -> String {
        return path.replacingOccurrences(of: "/", with: "-")
    }

    /// Decodes an encoded cwd back to a file path.
    /// `-Users-foo-bar` becomes `/Users/foo/bar`
    static func decodedCwd(_ encoded: String) -> String {
        // The first character is always `-` representing the leading `/`
        guard encoded.hasPrefix("-") else { return encoded }
        return encoded.replacingOccurrences(of: "-", with: "/")
    }

    /// Base directory for Claude projects: ~/.claude/projects/
    private var claudeProjectsDir: String {
        let home = fileManager.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".claude/projects")
    }

    // MARK: - Session Discovery

    /// Discovers all Claude sessions for a given project directory.
    /// `projectPath` can be a real path (e.g. `/Users/x/Desktop/clome`) or an already-encoded
    /// directory name (e.g. `-Users-x-Desktop-clome`).
    /// Returns sessions sorted by last active date (most recent first).
    func discoverSessions(forProject projectPath: String) -> [ClaudeSession] {
        // If projectPath starts with `-`, it's already an encoded directory name.
        // Don't re-encode it (encoding is lossy for paths containing literal dashes).
        let encodedPath: String
        if projectPath.hasPrefix("-") || projectPath.hasPrefix("/private/tmp") {
            encodedPath = projectPath
        } else {
            encodedPath = Self.encodedCwd(projectPath)
        }
        let projectDir = (claudeProjectsDir as NSString).appendingPathComponent(encodedPath)

        // Check cache validity
        if let cached = sessionCache[projectPath],
           let timestamp = cacheTimestamps[projectPath],
           Date().timeIntervalSince(timestamp) < cacheTTL {
            return cached
        }

        guard fileManager.fileExists(atPath: projectDir) else {
            sessionCache[projectPath] = []
            cacheTimestamps[projectPath] = Date()
            return []
        }

        var sessions: [ClaudeSession] = []

        guard let files = try? fileManager.contentsOfDirectory(atPath: projectDir) else {
            return []
        }

        // Resolve a real filesystem path for sessions (used for launching).
        // If projectPath is encoded (starts with `-`), try to decode it.
        // The decoding is lossy, so also check the actual JSONL for the cwd.
        let realProjectPath: String
        if projectPath.hasPrefix("-") {
            realProjectPath = Self.decodedCwd(projectPath)
        } else {
            realProjectPath = projectPath
        }

        for file in files where file.hasSuffix(".jsonl") {
            let filePath = (projectDir as NSString).appendingPathComponent(file)
            if let session = parseSessionMetadata(at: filePath, projectPath: realProjectPath) {
                sessions.append(session)
            }
        }

        // Apply session summaries from history.jsonl
        let summaries = loadSessionSummaries()
        for i in sessions.indices {
            sessions[i].summary = summaries[sessions[i].id]
        }

        // Apply saved names and pinned state from SQLite
        let savedNames = SessionState.shared.getAllClaudeSessionNames()
        for i in sessions.indices {
            if let info = savedNames[sessions[i].id] {
                sessions[i].name = info.name
                sessions[i].pinned = info.pinned
            }
        }

        // Match active sessions to workspaces
        let activeMap = findActiveSessionWorkspaces()
        for i in sessions.indices {
            sessions[i].activeInWorkspace = activeMap[sessions[i].id]
        }

        // Sort: pinned first, then active sessions, then by last active date descending
        sessions.sort { a, b in
            if a.pinned != b.pinned { return a.pinned }
            let aActive = a.activeInWorkspace != nil
            let bActive = b.activeInWorkspace != nil
            if aActive != bActive { return aActive }
            return a.lastActiveAt > b.lastActiveAt
        }

        sessionCache[projectPath] = sessions
        cacheTimestamps[projectPath] = Date()
        return sessions
    }

    /// Discovers all Claude sessions across all projects.
    func discoverAllSessions() -> [ClaudeSession] {
        guard fileManager.fileExists(atPath: claudeProjectsDir),
              let dirs = try? fileManager.contentsOfDirectory(atPath: claudeProjectsDir) else {
            return []
        }

        var allSessions: [ClaudeSession] = []
        for dir in dirs {
            // Pass the raw encoded directory name directly — don't decode/re-encode
            // because the encoding is lossy (can't distinguish `-` from `/` in paths).
            let sessions = discoverSessions(forProject: dir)
            allSessions.append(contentsOf: sessions)
        }

        allSessions.sort { $0.lastActiveAt > $1.lastActiveAt }
        return allSessions
    }

    /// Force-refreshes the cache for a given project.
    func refreshSessions(forProject projectPath: String) -> [ClaudeSession] {
        sessionCache.removeValue(forKey: projectPath)
        cacheTimestamps.removeValue(forKey: projectPath)
        return discoverSessions(forProject: projectPath)
    }

    /// Invalidates the entire cache.
    func invalidateCache() {
        sessionCache.removeAll()
        cacheTimestamps.removeAll()
        summaryCache.removeAll()
        summaryCacheTimestamp = nil
    }

    // MARK: - Active Session Detection

    /// Finds which Claude sessions are currently running.
    /// Returns a map of sessionId → label ("Active" or workspace name).
    ///
    /// Reads ~/.claude/sessions/*.json for PID → sessionId, checks PID alive,
    /// then tries to match to a Clome workspace terminal for a richer label.
    private func findActiveSessionWorkspaces() -> [String: String] {
        var result: [String: String] = [:]

        // Step 1: Build sessionId → alive status from ~/.claude/sessions/*.json
        let home = fileManager.homeDirectoryForCurrentUser.path
        let sessionsDir = (home as NSString).appendingPathComponent(".claude/sessions")
        guard let files = try? fileManager.contentsOfDirectory(atPath: sessionsDir) else { return result }

        var aliveSessionIds: Set<String> = []
        var pidToSession: [Int: String] = [:]
        for file in files where file.hasSuffix(".json") {
            let path = (sessionsDir as NSString).appendingPathComponent(file)
            guard let data = fileManager.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = json["pid"] as? Int,
                  let sessionId = json["sessionId"] as? String else { continue }
            if kill(Int32(pid), 0) == 0 {
                aliveSessionIds.insert(sessionId)
                pidToSession[pid] = sessionId
            }
        }

        guard !aliveSessionIds.isEmpty else { return result }

        // Step 2: Mark all alive sessions as "Active" by default
        for sid in aliveSessionIds {
            result[sid] = "Active"
        }

        // Step 3: Try to upgrade "Active" to workspace name.
        guard let appDelegate = NSApp.delegate as? ClomeAppDelegate,
              let window = appDelegate.mainWindow else { return result }

        // 3a: Direct tag match — terminals launched via addClaudeSessionTab
        for workspace in window.workspaceManager.workspaces {
            for tab in workspace.tabs {
                for leaf in tab.splitContainer.allLeafViews {
                    guard let terminal = leaf as? TerminalSurface,
                          let taggedId = terminal.claudeSessionId,
                          aliveSessionIds.contains(taggedId) else { continue }
                    result[taggedId] = workspace.name
                }
            }
        }

        // 3b: PID ancestry match — for sessions launched before the tag was added.
        // Walk each alive claude PID's parent chain; if Clome's PID is an ancestor,
        // the session runs inside Clome. Match the specific workspace by finding
        // which terminal surface detected "Claude Code" with a matching cwd.
        let clomePid = ProcessInfo.processInfo.processIdentifier
        for (pid, sessionId) in pidToSession where result[sessionId] == "Active" {
            // Walk up the parent chain (max 8 levels: claude → zsh → login → ghostty → Clome)
            var current = Int32(pid)
            var isClomeChild = false
            for _ in 0..<8 {
                var info = kinfo_proc()
                var size = MemoryLayout<kinfo_proc>.size
                var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
                guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
                let ppid = info.kp_eproc.e_ppid
                if ppid <= 1 { break }
                if ppid == clomePid {
                    isClomeChild = true
                    break
                }
                current = ppid
            }

            guard isClomeChild else { continue }

            // Find the workspace — match by cwd from context bridge
            let ctxPath = "/tmp/clome-claude-context/\(sessionId).json"
            guard let data = fileManager.contents(atPath: ctxPath),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cwd = json["cwd"] as? String else { continue }

            for workspace in window.workspaceManager.workspaces {
                for tab in workspace.tabs {
                    for leaf in tab.splitContainer.allLeafViews {
                        guard let terminal = leaf as? TerminalSurface,
                              terminal.detectedProgram == "Claude Code",
                              terminal.workingDirectory == cwd else { continue }
                        result[sessionId] = workspace.name
                    }
                }
            }
        }

        return result
    }

    // MARK: - Session Summaries from history.jsonl

    /// Parses ~/.claude/history.jsonl to build a map of sessionId -> first meaningful user message.
    /// This is the same data source Claude Code's `/resume` picker uses for session titles.
    private func loadSessionSummaries() -> [String: String] {
        // Cache for 30 seconds
        if let ts = summaryCacheTimestamp, Date().timeIntervalSince(ts) < cacheTTL, !summaryCache.isEmpty {
            return summaryCache
        }

        let home = fileManager.homeDirectoryForCurrentUser.path
        let historyPath = (home as NSString).appendingPathComponent(".claude/history.jsonl")

        guard let data = fileManager.contents(atPath: historyPath),
              let content = String(data: data, encoding: .utf8) else {
            return summaryCache
        }

        var result: [String: String] = [:]
        let lines = content.components(separatedBy: "\n")

        for line in lines where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let sessionId = json["sessionId"] as? String,
                  let display = json["display"] as? String else {
                continue
            }

            // Only keep the first meaningful entry per session
            guard result[sessionId] == nil else { continue }

            let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip empty or slash-only commands like "/init"
            if !trimmed.isEmpty && !(trimmed.hasPrefix("/") && trimmed.count < 20) {
                result[sessionId] = trimmed
            }
        }

        summaryCache = result
        summaryCacheTimestamp = Date()
        return result
    }

    // MARK: - Session Metadata Parsing

    /// Parses session metadata by reading only the first 5 and last 10 lines of the JSONL file.
    /// This avoids loading potentially large conversation files into memory.
    private func parseSessionMetadata(at filePath: String, projectPath: String) -> ClaudeSession? {
        guard let fileHandle = FileHandle(forReadingAtPath: filePath) else { return nil }
        defer { fileHandle.closeFile() }

        let sessionId = ((filePath as NSString).lastPathComponent as NSString).deletingPathExtension

        // Read first ~4KB for the opening lines
        let headData = fileHandle.readData(ofLength: 4096)
        guard !headData.isEmpty else { return nil }

        let headString = String(data: headData, encoding: .utf8) ?? ""
        let headLines = headString.components(separatedBy: "\n").filter { !$0.isEmpty }

        // Read last ~8KB for the closing lines
        let fileSize = fileHandle.seekToEndOfFile()
        let tailOffset = fileSize > 8192 ? fileSize - 8192 : 0
        fileHandle.seek(toFileOffset: tailOffset)
        let tailData = fileHandle.readData(ofLength: Int(min(fileSize, 8192)))
        let tailString = String(data: tailData, encoding: .utf8) ?? ""
        let tailLines = tailString.components(separatedBy: "\n").filter { !$0.isEmpty }

        // Parse metadata from head and tail lines
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var messageCount = 0
        var totalInputTokens = 0
        var totalOutputTokens = 0
        var model: String?
        var gitBranch: String?
        var lastUserMessage: String?
        var realCwd: String?

        let linesToParse = Array(headLines.prefix(5)) + Array(tailLines.suffix(10))

        for line in linesToParse {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            // Extract timestamp
            if let ts = json["timestamp"] as? String {
                if let date = Self.parseISO8601(ts) {
                    if firstTimestamp == nil { firstTimestamp = date }
                    lastTimestamp = date
                }
            }

            let type = json["type"] as? String ?? ""

            // Count user/assistant messages
            if type == "user" || type == "assistant" {
                messageCount += 1
            }

            // Extract real working directory from the JSONL record
            if realCwd == nil, let cwd = json["cwd"] as? String, !cwd.isEmpty {
                realCwd = cwd
            }

            // Extract git branch
            if gitBranch == nil, let branch = json["gitBranch"] as? String, !branch.isEmpty {
                gitBranch = branch
            }

            // Extract model and token usage from assistant messages
            if type == "assistant", let message = json["message"] as? [String: Any] {
                if let m = message["model"] as? String {
                    model = m
                }
                if let usage = message["usage"] as? [String: Any] {
                    if let input = usage["input_tokens"] as? Int {
                        totalInputTokens += input
                    }
                    if let output = usage["output_tokens"] as? Int {
                        totalOutputTokens += output
                    }
                }
            }

            // Extract last user message content
            if type == "user", let message = json["message"] as? [String: Any] {
                if let content = message["content"] as? String {
                    lastUserMessage = content
                } else if let contentArray = message["content"] as? [[String: Any]] {
                    // Content can be an array of blocks
                    for block in contentArray {
                        if block["type"] as? String == "text",
                           let text = block["text"] as? String {
                            lastUserMessage = text
                            break
                        }
                    }
                }
            }
        }

        // We need at least a timestamp to consider this a valid session
        guard let created = firstTimestamp else { return nil }
        let lastActive = lastTimestamp ?? created

        // Prefer the real cwd from inside the JSONL (most accurate),
        // fall back to the decoded project path.
        let resolvedProjectPath = realCwd ?? projectPath

        return ClaudeSession(
            id: sessionId,
            projectPath: resolvedProjectPath,
            name: nil,
            createdAt: created,
            lastActiveAt: lastActive,
            messageCount: messageCount,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            model: model,
            gitBranch: gitBranch,
            filePath: filePath,
            pinned: false,
            summary: nil,
            lastUserMessage: lastUserMessage
        )
    }

    // MARK: - Full Message Loading

    /// Loads all messages from a session for display.
    /// This reads the entire JSONL file - use sparingly.
    func loadMessages(sessionId: String, projectPath: String) -> [ClaudeMessage] {
        let encodedPath = Self.encodedCwd(projectPath)
        let projectDir = (claudeProjectsDir as NSString).appendingPathComponent(encodedPath)
        let filePath = (projectDir as NSString).appendingPathComponent("\(sessionId).jsonl")

        guard let data = fileManager.contents(atPath: filePath),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        var messages: [ClaudeMessage] = []
        let lines = content.components(separatedBy: "\n")

        for line in lines where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let type = json["type"] as? String ?? ""
            guard type == "user" || type == "assistant" else { continue }
            guard let msgType = ClaudeMessage.MessageType(rawValue: type) else { continue }

            let uuid = json["uuid"] as? String ?? UUID().uuidString
            let parentUuid = json["parentUuid"] as? String
            let isSidechain = json["isSidechain"] as? Bool ?? false

            var timestamp = Date()
            if let ts = json["timestamp"] as? String, let date = Self.parseISO8601(ts) {
                timestamp = date
            }

            var content = ""
            var model: String?
            var inputTokens: Int?
            var outputTokens: Int?

            if let message = json["message"] as? [String: Any] {
                // Extract content
                if let textContent = message["content"] as? String {
                    content = textContent
                } else if let contentArray = message["content"] as? [[String: Any]] {
                    let texts = contentArray.compactMap { block -> String? in
                        if block["type"] as? String == "text" {
                            return block["text"] as? String
                        }
                        if block["type"] as? String == "tool_use" {
                            let name = block["name"] as? String ?? "tool"
                            return "[\(name)]"
                        }
                        return nil
                    }
                    content = texts.joined(separator: "\n")
                }

                // Extract model and usage for assistant messages
                if type == "assistant" {
                    model = message["model"] as? String
                    if let usage = message["usage"] as? [String: Any] {
                        inputTokens = usage["input_tokens"] as? Int
                        outputTokens = usage["output_tokens"] as? Int
                    }
                }
            }

            messages.append(ClaudeMessage(
                uuid: uuid,
                type: msgType,
                content: content,
                timestamp: timestamp,
                parentUuid: parentUuid,
                model: model,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                isSidechain: isSidechain
            ))
        }

        return messages
    }

    // MARK: - Session Naming

    /// Saves a user-assigned name for a session.
    func saveSessionName(_ sessionId: String, name: String) {
        SessionState.shared.saveClaudeSessionName(sessionId: sessionId, name: name)
        // Invalidate cache so next fetch picks up the name
        sessionCache.removeAll()
        cacheTimestamps.removeAll()
    }

    /// Pins or unpins a session.
    func pinSession(_ sessionId: String, pinned: Bool) {
        SessionState.shared.pinClaudeSession(sessionId: sessionId, pinned: pinned)
        sessionCache.removeAll()
        cacheTimestamps.removeAll()
    }

    // MARK: - Session Launch

    /// Returns the command string to resume a specific session in the terminal.
    func launchCommand(sessionId: String) -> String {
        return "claude --resume \(sessionId)"
    }

    /// Returns the command string to continue the latest session.
    func continueLatestCommand() -> String {
        return "claude --continue"
    }

    /// Returns the command string to start a new Claude session in a directory.
    func newSessionCommand() -> String {
        return "claude"
    }

    // MARK: - Helpers

    /// Parses an ISO 8601 timestamp string into a Date.
    private static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        // Retry without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
