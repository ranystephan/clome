// RemoteProtocol.swift
// Clome Remote Control Protocol — shared message types between macOS server and iOS client.
// JSON-RPC 2.0 over length-prefixed TLS frames.

import Foundation

// MARK: - Frame Format

/// Wire format: [4-byte big-endian payload length][JSON payload]
enum RemoteFrame {
    static let maxPayloadSize: UInt32 = 4 * 1024 * 1024 // 4 MB max message

    static func encode(_ message: Encodable) throws -> Data {
        let json = try JSONEncoder().encode(message)
        var length = UInt32(json.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(json)
        return frame
    }

    /// Extracts a complete message from a buffer. Returns (message bytes, consumed count) or nil if incomplete.
    static func extract(from buffer: Data) -> (payload: Data, consumed: Int)? {
        guard buffer.count >= 4 else { return nil }
        // Read length manually to avoid misaligned pointer crash when buffer is a Data slice
        let length: UInt32 = (UInt32(buffer[buffer.startIndex]) << 24)
                           | (UInt32(buffer[buffer.startIndex + 1]) << 16)
                           | (UInt32(buffer[buffer.startIndex + 2]) << 8)
                           | UInt32(buffer[buffer.startIndex + 3])
        guard length <= maxPayloadSize else { return nil }
        let total = 4 + Int(length)
        guard buffer.count >= total else { return nil }
        let payloadStart = buffer.startIndex + 4
        let payloadEnd = buffer.startIndex + total
        return (buffer.subdata(in: payloadStart..<payloadEnd), total)
    }
}

// MARK: - Envelope

/// Top-level message envelope. Every message on the wire is wrapped in this.
struct RemoteEnvelope: Codable {
    let type: String        // message type discriminator
    let id: String?         // request ID for request/response correlation
    let payload: Data       // nested JSON for the specific message type

    init<T: Encodable>(type: String, id: String? = nil, payload: T) throws {
        self.type = type
        self.id = id
        self.payload = try JSONEncoder().encode(payload)
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: payload)
    }
}

// MARK: - Connection & Pairing

struct HelloMessage: Codable {
    let protocolVersion: Int        // 1
    let deviceName: String          // e.g. "Rany's MacBook Pro"
    let deviceId: String            // persistent UUID for this device
    let capabilities: [String]      // ["terminal", "workspace", "editor"]
}

struct PairingRequest: Codable {
    let code: String                // 6-digit pairing code entered by user
    let deviceName: String          // iOS device name
    let deviceId: String            // persistent iOS device UUID
    let publicKey: Data             // Ed25519 public key for future auth
}

struct PairingResponse: Codable {
    let success: Bool
    let error: String?
    let serverPublicKey: Data?      // server's public key for mutual auth
    let authToken: Data?            // token for reconnection without re-pairing
}

struct AuthRequest: Codable {
    let deviceId: String
    let authToken: Data             // token from initial pairing
    let signature: Data             // sign(nonce + authToken) with device private key
}

struct AuthChallenge: Codable {
    let nonce: Data                 // random challenge for auth signature
}

struct AuthResult: Codable {
    let success: Bool
    let error: String?
}

// MARK: - Workspace State

struct WorkspaceSnapshot: Codable {
    let version: UInt64                     // monotonic, increments on any change
    let workspaces: [WorkspaceState]
    let activeWorkspaceIndex: Int
}

struct WorkspaceState: Codable {
    let id: String                          // UUID string
    let name: String
    let icon: String                        // SF Symbol name
    let color: String                       // WorkspaceColor raw value
    let gitBranch: String?
    let workingDirectory: String?
    let tabs: [TabState]
    let activeTabIndex: Int
    let unreadCount: Int
}

struct TabState: Codable {
    let id: String                          // UUID string
    let type: TabType
    let title: String
    let isDirty: Bool
    let activity: TerminalActivity?         // nil for non-terminal tabs

    enum TabType: String, Codable {
        case terminal
        case browser
        case editor
        case pdf
        case notebook
        case project
        case diff
    }
}

struct TerminalActivity: Codable {
    let state: ActivityState
    let runningProgram: String?
    let programIcon: String?               // SF Symbol
    let isClaudeCode: Bool
    let claudeContextPercentage: Int?      // 0-100
    let outputPreview: String?             // last 2-3 lines
    let needsAttention: Bool

    enum ActivityState: String, Codable {
        case idle
        case running
        case waitingInput
        case completed
    }
}

// MARK: - Terminal Streaming

struct TerminalScreenState: Codable {
    let paneId: String
    let tabIndex: Int
    let sequenceNumber: UInt64
    let rows: Int
    let cols: Int
    let cursorRow: Int
    let cursorCol: Int
    let cursorVisible: Bool
    let title: String
    let workingDirectory: String?
    let text: String                        // full viewport text content
    let activityState: TerminalActivity.ActivityState
}

struct TerminalDelta: Codable {
    let paneId: String
    let tabIndex: Int
    let sequenceNumber: UInt64
    let changedLines: [String: String]       // line index string -> new line content
    let cursorRow: Int
    let cursorCol: Int
    let title: String?                      // nil = unchanged
    let activityState: TerminalActivity.ActivityState?
    let outputPreview: String?
}

// MARK: - Commands (iOS -> macOS)

enum RemoteCommand: Codable {
    case switchWorkspace(index: Int)
    case createWorkspace(name: String?)
    case deleteWorkspace(index: Int)
    case renameWorkspace(index: Int, name: String)

    case switchTab(workspaceIndex: Int, tabIndex: Int)
    case closeTab(workspaceIndex: Int, tabIndex: Int)
    case createTerminalTab(workspaceIndex: Int)
    case createBrowserTab(workspaceIndex: Int, url: String?)

    case splitPane(direction: String)       // "right", "down", "left", "up"
    case focusPane(paneId: String)

    case terminalInput(workspaceIndex: Int, tabIndex: Int, input: TerminalInput)
    case terminalResize(workspaceIndex: Int, tabIndex: Int, rows: Int, cols: Int)

    case requestFullSync
    case requestTerminalContent(workspaceIndex: Int, tabIndex: Int)

    case ping
}

struct TerminalInput: Codable {
    let text: String?                       // printable text, nil for special keys
    let specialKey: SpecialKey?
    let modifiers: KeyModifiers

    enum SpecialKey: String, Codable {
        case arrowUp, arrowDown, arrowLeft, arrowRight
        case home, end, pageUp, pageDown
        case tab, escape, backspace, delete
        case enter
        case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
        // Common terminal signals
        case ctrlC, ctrlD, ctrlZ, ctrlL, ctrlA, ctrlE, ctrlK, ctrlU, ctrlW, ctrlR
    }

    struct KeyModifiers: Codable {
        let ctrl: Bool
        let alt: Bool
        let shift: Bool

        static let none = KeyModifiers(ctrl: false, alt: false, shift: false)
    }
}

// MARK: - Command Response

struct CommandResponse: Codable {
    let requestId: String
    let success: Bool
    let error: String?
}

// MARK: - Notifications (macOS -> iOS)

struct RemoteNotification: Codable {
    let workspaceIndex: Int
    let title: String
    let message: String
    let type: NotificationType

    enum NotificationType: String, Codable {
        case terminalBell
        case commandFinished
        case claudeNeedsInput
        case agentFileChanged
        case generic
    }
}

// MARK: - Message Type Constants

enum MessageType {
    // Connection
    static let hello = "hello"
    static let pairingRequest = "pairing.request"
    static let pairingResponse = "pairing.response"
    static let authChallenge = "auth.challenge"
    static let authRequest = "auth.request"
    static let authResult = "auth.result"

    // State sync
    static let workspaceSnapshot = "workspace.snapshot"
    static let terminalScreen = "terminal.screen"
    static let terminalDelta = "terminal.delta"

    // Commands & responses
    static let command = "command"
    static let commandResponse = "command.response"

    // Notifications
    static let notification = "notification"

    // System prompts
    static let systemPrompt = "system.prompt"
    static let systemPromptResponse = "system.prompt.response"

    // Keepalive
    static let ping = "ping"
    static let pong = "pong"
}

// MARK: - System Prompt (macOS dialogs forwarded to iOS)

struct SystemPromptInfo: Codable {
    let id: String                          // unique ID for this prompt
    let title: String                       // dialog title or app name
    let message: String                     // dialog body text
    let buttons: [String]                   // button labels, e.g. ["Don't Allow", "OK"]
    let sourceApp: String?                  // app that triggered the dialog
    let promptType: PromptType
    let timestamp: Date

    enum PromptType: String, Codable {
        case folderAccess                   // TCC folder permission
        case accessibility                  // Accessibility permission
        case microphone                     // Microphone access
        case camera                         // Camera access
        case generic                        // Unknown system dialog
    }
}

struct SystemPromptResponse: Codable {
    let promptId: String
    let selectedButton: String              // label of the button to click
    let buttonIndex: Int                    // 0-based index as fallback
}

// MARK: - Paired Device Persistence

struct PairedDevice: Codable {
    let deviceId: String
    let deviceName: String
    let publicKey: Data
    let authToken: Data
    let pairedAt: Date
    var lastConnectedAt: Date
}
