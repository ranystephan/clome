import Foundation

/// Unix socket server for external automation.
/// Enables CLI tools and scripts to interact with Clome.
///
/// Socket path: /tmp/clome-{pid}.sock
/// Protocol: newline-delimited JSON commands
///
/// Commands:
///   {"action": "new-workspace", "name": "My Project"}
///   {"action": "new-tab", "workspace": 0, "type": "terminal"}
///   {"action": "new-tab", "workspace": 0, "type": "browser", "url": "https://..."}
///   {"action": "notify", "workspace": 0, "title": "Build", "message": "Done!"}
///   {"action": "switch-workspace", "index": 1}
///   {"action": "list-workspaces"}
///   {"action": "send-keys", "workspace": 0, "text": "ls -la\n"}
///   {"action": "split", "direction": "right"}
@MainActor
class SocketServer {
    private var socketFD: Int32 = -1
    private let socketPath: String
    private var source: DispatchSourceRead?
    private var clientSources: [DispatchSourceRead] = []

    weak var window: ClomeWindow?

    init() {
        socketPath = "/tmp/clome-\(ProcessInfo.processInfo.processIdentifier).sock"
    }

    func start() {
        // Remove stale socket
        unlink(socketPath)

        // Create socket
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            print("SocketServer: Failed to create socket")
            return
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            for i in 0..<min(pathBytes.count, 104) {
                raw[i] = pathBytes[i]
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(socketFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            print("SocketServer: Failed to bind socket")
            close(socketFD)
            return
        }

        // Listen
        guard listen(socketFD, 5) == 0 else {
            print("SocketServer: Failed to listen")
            close(socketFD)
            return
        }

        // Accept connections via GCD
        let listenSource = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: .main)
        listenSource.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        listenSource.setCancelHandler { [weak self] in
            if let fd = self?.socketFD, fd >= 0 {
                close(fd)
            }
        }
        listenSource.resume()
        self.source = listenSource

        print("SocketServer: Listening on \(socketPath)")
    }

    func stop() {
        source?.cancel()
        source = nil
        clientSources.forEach { $0.cancel() }
        clientSources.removeAll()
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        unlink(socketPath)
    }

    private func acceptConnection() {
        let clientFD = accept(socketFD, nil, nil)
        guard clientFD >= 0 else { return }

        let clientSource = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: .main)
        clientSource.setEventHandler { [weak self] in
            self?.readFromClient(fd: clientFD)
        }
        clientSource.setCancelHandler {
            close(clientFD)
        }
        clientSource.resume()
        clientSources.append(clientSource)
    }

    private func readFromClient(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(fd, &buffer, buffer.count)
        guard bytesRead > 0 else {
            // Client disconnected
            return
        }

        let data = Data(buffer[0..<bytesRead])
        guard let string = String(data: data, encoding: .utf8) else { return }

        // Process each line as a JSON command
        for line in string.components(separatedBy: "\n") where !line.isEmpty {
            let response = handleCommand(line)
            let responseData = (response + "\n").data(using: .utf8)!
            responseData.withUnsafeBytes { ptr in
                _ = write(fd, ptr.baseAddress!, responseData.count)
            }
        }
    }

    private func handleCommand(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let cmd = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = cmd["action"] as? String else {
            return """
            {"error": "Invalid command"}
            """
        }

        switch action {
        case "new-workspace":
            let name = cmd["name"] as? String
            window?.workspaceManager.addWorkspace(name: name)
            return """
            {"ok": true}
            """

        case "new-tab":
            let workspaceIndex = cmd["workspace"] as? Int ?? window?.workspaceManager.activeWorkspaceIndex ?? 0
            let type = cmd["type"] as? String ?? "terminal"
            if workspaceIndex < (window?.workspaceManager.workspaces.count ?? 0) {
                let workspace = window?.workspaceManager.workspaces[workspaceIndex]
                if type == "browser" {
                    let url = cmd["url"] as? String
                    workspace?.addBrowserSurface(url: url)
                } else {
                    workspace?.addSurface()
                }
            }
            return """
            {"ok": true}
            """

        case "notify":
            let title = cmd["title"] as? String ?? "Clome"
            let message = cmd["message"] as? String ?? ""
            if let workspace = window?.workspaceManager.activeWorkspace {
                NotificationSystem.shared.notify(
                    workspaceId: workspace.id,
                    surfaceTitle: title,
                    message: message
                )
            }
            return """
            {"ok": true}
            """

        case "switch-workspace":
            if let index = cmd["index"] as? Int {
                window?.workspaceManager.switchTo(index: index)
            }
            return """
            {"ok": true}
            """

        case "list-workspaces":
            let workspaces = window?.workspaceManager.workspaces.enumerated().map { index, ws in
                ["index": index, "name": ws.name, "active": index == window?.workspaceManager.activeWorkspaceIndex] as [String: Any]
            } ?? []
            let data = try? JSONSerialization.data(withJSONObject: ["workspaces": workspaces])
            return String(data: data ?? Data(), encoding: .utf8) ?? """
            {"error": "serialization failed"}
            """

        case "send-keys":
            let text = cmd["text"] as? String ?? ""
            if let terminal = window?.workspaceManager.activeWorkspace?.activeSurface,
               let surface = terminal.surface {
                text.withCString { ptr in
                    ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
                }
            }
            return """
            {"ok": true}
            """

        case "split":
            let dirStr = cmd["direction"] as? String ?? "right"
            let direction: SplitDirection = switch dirStr {
            case "down": .down
            case "left": .left
            case "up": .up
            default: .right
            }
            window?.workspaceManager.activeWorkspace?.splitActivePane(direction: direction)
            return """
            {"ok": true}
            """

        default:
            return """
            {"error": "Unknown action: \(action)"}
            """
        }
    }
}
