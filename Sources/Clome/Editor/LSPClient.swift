import Foundation

/// A Language Server Protocol client that communicates with language servers
/// over stdin/stdout using JSON-RPC 2.0.
@MainActor
class LSPClient {
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var requestId: Int = 0
    private var pendingRequests: [Int: CheckedContinuation<LSPResponse, Error>] = [:]
    private var readBuffer = Data()

    /// Maximum read buffer size (10 MB) — protects against runaway LSP output.
    private static let maxReadBufferSize = 10 * 1024 * 1024

    let language: String
    let serverCommand: String
    let serverArgs: [String]

    weak var delegate: LSPClientDelegate?

    init(language: String, command: String, args: [String] = []) {
        self.language = language
        self.serverCommand = command
        self.serverArgs = args
    }

    // MARK: - Lifecycle

    func start(rootPath: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: serverCommand)
        proc.arguments = serverArgs

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        try proc.run()
        process = proc
        stdin = stdinPipe.fileHandleForWriting
        stdout = stdoutPipe.fileHandleForReading

        // Read stdout in background
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                self?.handleData(data)
            }
        }

        // Initialize
        Task {
            try await initialize(rootPath: rootPath)
        }
    }

    func stop() {
        sendNotification("shutdown", params: [:])
        sendNotification("exit", params: [:])
        process?.terminate()
        process = nil
        stdin = nil
        stdout?.readabilityHandler = nil
        stdout = nil
        readBuffer.removeAll()
        // Cancel all pending requests
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: LSPError.requestTimeout)
        }
        pendingRequests.removeAll()
    }

    // MARK: - LSP Methods

    private func initialize(rootPath: String) async throws {
        let params: [String: Any] = [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "rootUri": "file://\(rootPath)",
            "capabilities": [
                "textDocument": [
                    "completion": [
                        "completionItem": ["snippetSupport": true]
                    ],
                    "hover": [:],
                    "definition": [:],
                    "references": [:],
                    "documentSymbol": [:],
                    "diagnostic": [:]
                ]
            ] as [String: Any]
        ]

        _ = try await sendRequest("initialize", params: params)
        sendNotification("initialized", params: [:])
    }

    func openDocument(uri: String, language: String, text: String) {
        sendNotification("textDocument/didOpen", params: [
            "textDocument": [
                "uri": uri,
                "languageId": language,
                "version": 1,
                "text": text
            ]
        ])
    }

    func closeDocument(uri: String) {
        sendNotification("textDocument/didClose", params: [
            "textDocument": ["uri": uri]
        ])
    }

    func didChangeDocument(uri: String, version: Int, changes: [[String: Any]]) {
        sendNotification("textDocument/didChange", params: [
            "textDocument": ["uri": uri, "version": version],
            "contentChanges": changes
        ])
    }

    func completion(uri: String, line: Int, character: Int) async throws -> LSPResponse {
        try await sendRequest("textDocument/completion", params: [
            "textDocument": ["uri": uri],
            "position": ["line": line, "character": character]
        ])
    }

    func hover(uri: String, line: Int, character: Int) async throws -> LSPResponse {
        try await sendRequest("textDocument/hover", params: [
            "textDocument": ["uri": uri],
            "position": ["line": line, "character": character]
        ])
    }

    func definition(uri: String, line: Int, character: Int) async throws -> LSPResponse {
        try await sendRequest("textDocument/definition", params: [
            "textDocument": ["uri": uri],
            "position": ["line": line, "character": character]
        ])
    }

    func references(uri: String, line: Int, character: Int) async throws -> LSPResponse {
        try await sendRequest("textDocument/references", params: [
            "textDocument": ["uri": uri],
            "position": ["line": line, "character": character],
            "context": ["includeDeclaration": true]
        ])
    }

    // MARK: - JSON-RPC

    private func sendRequest(_ method: String, params: [String: Any]) async throws -> LSPResponse {
        requestId += 1
        let id = requestId

        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
            sendMessage(message)

            // Timeout: cancel stale requests after 30 seconds to prevent memory leaks
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                if let cont = self?.pendingRequests.removeValue(forKey: id) {
                    cont.resume(throwing: LSPError.requestTimeout)
                }
            }
        }
    }

    private func sendNotification(_ method: String, params: [String: Any]) {
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ]
        sendMessage(message)
    }

    private func sendMessage(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let content = String(data: data, encoding: .utf8) else { return }
        let header = "Content-Length: \(data.count)\r\n\r\n"
        let full = header + content
        stdin?.write(full.data(using: .utf8)!)
    }

    // MARK: - Response Handling

    private func handleData(_ data: Data) {
        readBuffer.append(data)
        // Safety valve: if the buffer grows beyond the cap, discard it.
        // This prevents unbounded memory growth from a misbehaving LSP server.
        if readBuffer.count > LSPClient.maxReadBufferSize {
            readBuffer.removeAll()
            // Cancel all pending requests since the buffer state is lost
            for (_, continuation) in pendingRequests {
                continuation.resume(throwing: LSPError.bufferOverflow)
            }
            pendingRequests.removeAll()
            return
        }
        processBuffer()
    }

    private func processBuffer() {
        while true {
            guard let headerEnd = findHeaderEnd() else { return }
            let headerData = readBuffer[readBuffer.startIndex..<headerEnd]
            guard let headerStr = String(data: headerData, encoding: .utf8),
                  let contentLength = parseContentLength(headerStr) else {
                readBuffer.removeAll()
                return
            }

            let contentStart = headerEnd + 4 // skip \r\n\r\n
            let contentEnd = contentStart + contentLength
            guard readBuffer.count >= contentEnd else { return }

            let contentData = readBuffer[contentStart..<contentEnd]
            readBuffer = Data(readBuffer[contentEnd...])

            if let json = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any] {
                handleMessage(json)
            }
        }
    }

    private func findHeaderEnd() -> Data.Index? {
        let separator = Data("\r\n\r\n".utf8)
        for i in readBuffer.startIndex...(readBuffer.endIndex - separator.count) {
            if readBuffer[i..<(i + separator.count)] == separator {
                return i
            }
        }
        return nil
    }

    private func parseContentLength(_ header: String) -> Int? {
        for line in header.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value)
            }
        }
        return nil
    }

    private func handleMessage(_ json: [String: Any]) {
        // Response to our request
        if let id = json["id"] as? Int, let continuation = pendingRequests.removeValue(forKey: id) {
            let response = LSPResponse(json: json)
            continuation.resume(returning: response)
            return
        }

        // Server notification
        if let method = json["method"] as? String {
            handleNotification(method, params: json["params"] as? [String: Any] ?? [:])
        }
    }

    private func handleNotification(_ method: String, params: [String: Any]) {
        switch method {
        case "textDocument/publishDiagnostics":
            delegate?.lspClient(self, didReceiveDiagnostics: params)
        case "window/logMessage", "window/showMessage":
            if let message = params["message"] as? String {
                delegate?.lspClient(self, didLog: message)
            }
        default:
            break
        }
    }

    // MARK: - Server Discovery

    static func serverCommand(for language: String) -> (command: String, args: [String])? {
        switch language {
        case "swift":
            return ("/usr/bin/xcrun", ["sourcekit-lsp"])
        case "python":
            return ("/usr/local/bin/pyright-langserver", ["--stdio"])
        case "typescript", "javascript", "tsx":
            return ("/usr/local/bin/typescript-language-server", ["--stdio"])
        case "rust":
            return ("/usr/local/bin/rust-analyzer", [])
        case "go":
            return ("/usr/local/bin/gopls", [])
        case "c", "cpp":
            return ("/usr/bin/clangd", [])
        case "zig":
            return ("/usr/local/bin/zls", [])
        case "latex", "bibtex":
            return ("/usr/local/bin/texlab", [])
        default:
            return nil
        }
    }
}

// MARK: - Types

enum LSPError: Error {
    case bufferOverflow
    case requestTimeout
}

struct LSPResponse: @unchecked Sendable {
    let json: [String: Any]

    var result: Any? { json["result"] }
    var error: [String: Any]? { json["error"] as? [String: Any] }
    var isError: Bool { error != nil }

    var completionItems: [[String: Any]] {
        if let items = result as? [[String: Any]] { return items }
        if let obj = result as? [String: Any], let items = obj["items"] as? [[String: Any]] { return items }
        return []
    }
}

@MainActor
protocol LSPClientDelegate: AnyObject {
    func lspClient(_ client: LSPClient, didReceiveDiagnostics params: [String: Any])
    func lspClient(_ client: LSPClient, didLog message: String)
}
