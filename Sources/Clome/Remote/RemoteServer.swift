// RemoteServer.swift
// Clome — macOS remote control server for iOS companion app.
// Listens for TLS connections via Network.framework, advertises via Bonjour and MultipeerConnectivity.

import Foundation
import Network
import MultipeerConnectivity
import Security
import UserNotifications

// MARK: - Notifications

extension Notification.Name {
    static let remoteClientConnected = Notification.Name("clomeRemoteClientConnected")
    static let remoteClientDisconnected = Notification.Name("clomeRemoteClientDisconnected")
    static let remotePairingStarted = Notification.Name("clomeRemotePairingStarted")
}

// MARK: - RemoteSessionHandler

/// Manages a single authenticated remote client connection.
@MainActor
final class RemoteSessionHandler: @unchecked Sendable {
    let id: String
    let deviceId: String
    let deviceName: String

    private var nwConnection: NWConnection?
    private var mcSession: MCSession?
    private var mcPeerID: MCPeerID?
    private var receiveBuffer = Data()
    private var isActive = true

    enum Transport {
        case network(NWConnection)
        case multipeer(MCSession, MCPeerID)
    }

    init(id: String, deviceId: String, deviceName: String, transport: Transport) {
        self.id = id
        self.deviceId = deviceId
        self.deviceName = deviceName
        switch transport {
        case .network(let conn):
            self.nwConnection = conn
        case .multipeer(let session, let peer):
            self.mcSession = session
            self.mcPeerID = peer
        }
    }

    // MARK: - Send

    func send(_ envelope: RemoteEnvelope) {
        guard isActive else { return }
        do {
            let frameData = try RemoteFrame.encode(envelope)
            if let conn = nwConnection {
                conn.send(content: frameData, completion: .contentProcessed { [weak self] error in
                    if let error {
                        Task { @MainActor in
                            self?.handleTransportError(error)
                        }
                    }
                })
            } else if let session = mcSession, let peer = mcPeerID {
                try session.send(frameData, toPeers: [peer], with: .reliable)
            }
        } catch {
            handleTransportError(error)
        }
    }

    // MARK: - Receive (NWConnection)

    func startReceiving() {
        guard let conn = nwConnection else { return }
        receiveLoop(on: conn)
    }

    private func receiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                if let data = content {
                    self.receiveBuffer.append(data)
                    self.processBuffer()
                }
                if isComplete {
                    self.disconnect()
                } else if let error {
                    self.handleTransportError(error)
                } else {
                    self.receiveLoop(on: connection)
                }
            }
        }
    }

    /// Called from MultipeerConnectivity delegate when data arrives for this peer.
    func receivedMultipeerData(_ data: Data) {
        guard isActive else { return }
        receiveBuffer.append(data)
        processBuffer()
    }

    private func processBuffer() {
        while let extracted = RemoteFrame.extract(from: receiveBuffer) {
            receiveBuffer.removeFirst(extracted.consumed)
            do {
                let envelope = try JSONDecoder().decode(RemoteEnvelope.self, from: extracted.payload)
                RemoteServer.shared.handleMessage(envelope, from: self)
            } catch {
                // Malformed message — skip
            }
        }
    }

    // MARK: - Lifecycle

    func disconnect() {
        guard isActive else { return }
        isActive = false
        print("[RemoteSession] Disconnecting session \(id.prefix(8)) for device '\(deviceName)'")
        nwConnection?.cancel()
        nwConnection = nil
        if let session = mcSession, let peer = mcPeerID {
            session.disconnect()
            _ = peer // silence unused warning
        }
        mcSession = nil
        mcPeerID = nil
        RemoteServer.shared.sessionDisconnected(self)
    }

    /// Silently deactivate this session when being replaced by a new session
    /// from the same device. Does NOT post a disconnect notification, since the
    /// device is still connected (just on a new session). The underlying
    /// NWConnection is cancelled to free resources, but the iOS client already
    /// has a new connection at this point so the FIN is harmless.
    func replaceQuietly() {
        guard isActive else { return }
        isActive = false
        print("[RemoteSession] Session \(id.prefix(8)) quietly replaced for device '\(deviceName)'")
        nwConnection?.cancel()
        nwConnection = nil
        mcSession?.disconnect()
        mcSession = nil
        mcPeerID = nil
        // Intentionally NOT calling RemoteServer.shared.sessionDisconnected(self)
    }

    private func handleTransportError(_ error: Error) {
        print("[RemoteSession] Transport error on session \(id.prefix(8)): \(error.localizedDescription)")
        disconnect()
    }
}

// MARK: - RemoteServer

@MainActor
final class RemoteServer: NSObject, @unchecked Sendable {
    static let shared = RemoteServer()

    // MARK: - Configuration

    private static let serviceType = "_clome._tcp"
    private static let mcServiceType = "clome-remote"
    private static let defaultPort: UInt16 = 9847
    private static let keychainLabel = "com.clome.remote-tls"

    // MARK: - State

    private(set) var isRunning = false
    private(set) var isPairingMode = false
    private var activePairingCode: String?

    private var listener: NWListener?
    private var mcAdvertiser: MCNearbyServiceAdvertiser?
    private var mcLocalPeerID: MCPeerID?
    private var mcSession: MCSession?

    /// All currently connected sessions keyed by session ID.
    private var sessions: [String: RemoteSessionHandler] = [:]

    /// Pending NWConnections waiting for authentication.
    private var pendingConnections: [String: NWConnection] = [:]

    /// Messages received on pending connections before promotion completes.
    /// Keyed by connectionId, value is an ordered list of envelopes to replay.
    private var pendingMessageBuffers: [String: [RemoteEnvelope]] = [:]

    private let pairingManager = PairingManager()
    private let stateProvider = WorkspaceStateProvider()
    private let streamEngine = TerminalStreamEngine()
    private let systemPromptMonitor = SystemPromptMonitor()

    /// Set by AppDelegate after window creation.
    weak var workspaceManager: WorkspaceManager?

    private let serverQueue = DispatchQueue(label: "com.clome.remote-server", qos: .userInitiated)

    /// Tracks Bonjour service registration retries to resolve name collisions.
    private var serviceRegistrationRetries = 0
    private static let maxServiceRetries = 3

    // MARK: - Init

    private override init() {
        super.init()
    }

    // MARK: - Start / Stop

    func start() {
        guard !isRunning else { return }

        // Use plain TCP for discovery and connection. Authentication is handled at the
        // application layer via pairing tokens. TLS can be added once a proper SecIdentity
        // is generated (requires PKCS12 import or SPI).
        let tcpParams = NWParameters.tcp
        tcpParams.includePeerToPeer = true

        do {
            // Use any available port (0) instead of fixed port to avoid conflicts
            let nwListener = try NWListener(using: tcpParams)
            // Include PID in service name to avoid Bonjour collision (-72008)
            // with stale registrations from a previous Clome instance.
            let macName = Host.current().localizedName ?? "Mac"
            let serviceName = "Clome-\(macName)-\(ProcessInfo.processInfo.processIdentifier)"
            nwListener.service = NWListener.Service(
                name: serviceName,
                type: Self.serviceType
            )
            nwListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.listenerStateChanged(state)
                }
            }
            nwListener.serviceRegistrationUpdateHandler = { [weak self] change in
                Task { @MainActor in
                    self?.serviceRegistrationChanged(change)
                }
            }
            nwListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleNewConnection(connection)
                }
            }
            serviceRegistrationRetries = 0
            nwListener.start(queue: self.serverQueue)
            self.listener = nwListener
            print("[RemoteServer] Listener starting, advertising as \(serviceName) (\(Self.serviceType))")
        } catch {
            print("[RemoteServer] Failed to create listener: \(error)")
            return
        }

        startMultipeerAdvertiser()
        isRunning = true

        // Wire up workspace state broadcasting
        if let manager = workspaceManager {
            stateProvider.onStateChanged = { [weak self] snapshot in
                self?.broadcastWorkspaceUpdate(snapshot)
            }
            stateProvider.observeChanges(manager: manager)
        }

        // Wire up terminal streaming
        streamEngine.onScreenState = { [weak self] screen in
            guard let envelope = try? RemoteEnvelope(type: MessageType.terminalScreen, payload: screen) else { return }
            for session in self?.sessions.values ?? [:].values {
                session.send(envelope)
            }
        }
        streamEngine.onDelta = { [weak self] delta in
            self?.broadcastTerminalDelta(delta)
        }
        streamEngine.start()

        // Register active terminal surfaces for streaming
        registerActiveTerminals()

        // Start system prompt detection (TCC dialogs, folder access, etc.)
        systemPromptMonitor.onPromptDetected = { [weak self] prompt in
            self?.broadcastSystemPrompt(prompt)
        }
        systemPromptMonitor.start()
    }

    /// Registers the currently active terminal surfaces with the stream engine.
    private func registerActiveTerminals() {
        guard let manager = workspaceManager else { return }
        for (_, workspace) in manager.workspaces.enumerated() {
            for (tabIdx, tab) in workspace.tabs.enumerated() {
                if let terminal = findTerminalSurface(in: tab) {
                    streamEngine.register(
                        surface: terminal,
                        paneId: tab.id.uuidString,
                        tabIndex: tabIdx
                    )
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopPairing()

        listener?.cancel()
        listener = nil

        mcAdvertiser?.stopAdvertisingPeer()
        mcAdvertiser = nil
        mcSession?.disconnect()
        mcSession = nil

        let allSessions = Array(sessions.values)
        sessions.removeAll()
        pendingConnections.values.forEach { $0.cancel() }
        pendingConnections.removeAll()
        promotedConnectionIds.removeAll()
        pendingMessageBuffers.removeAll()
        for session in allSessions {
            session.disconnect()
        }
    }

    // MARK: - Pairing

    func startPairing() -> String {
        let code = pairingManager.generatePairingCode()
        activePairingCode = code
        isPairingMode = true
        return code
    }

    func stopPairing() {
        isPairingMode = false
        activePairingCode = nil
    }

    // MARK: - Broadcasting

    func broadcastWorkspaceUpdate(_ snapshot: WorkspaceSnapshot) {
        guard let envelope = try? RemoteEnvelope(type: MessageType.workspaceSnapshot, payload: snapshot) else { return }
        for session in sessions.values {
            session.send(envelope)
        }
    }

    func broadcastTerminalDelta(_ delta: TerminalDelta) {
        guard let envelope = try? RemoteEnvelope(type: MessageType.terminalDelta, payload: delta) else { return }
        for session in sessions.values {
            session.send(envelope)
        }
    }

    func broadcastSystemPrompt(_ prompt: SystemPromptInfo) {
        guard let envelope = try? RemoteEnvelope(type: MessageType.systemPrompt, payload: prompt) else { return }
        for session in sessions.values {
            session.send(envelope)
        }
    }

    func broadcastNotification(_ notification: RemoteNotification) {
        guard let envelope = try? RemoteEnvelope(type: MessageType.notification, payload: notification) else { return }
        for session in sessions.values {
            session.send(envelope)
        }
    }

    // MARK: - Message Handling

    func handleMessage(_ envelope: RemoteEnvelope, from session: RemoteSessionHandler) {
        switch envelope.type {
        case MessageType.command:
            handleCommand(envelope, from: session)
        case MessageType.systemPromptResponse:
            if let response = try? envelope.decode(SystemPromptResponse.self) {
                systemPromptMonitor.respondToPrompt(response)
            }
        case MessageType.ping:
            let pong = try? RemoteEnvelope(type: MessageType.pong, id: envelope.id, payload: EmptyPayload())
            if let pong { session.send(pong) }
        default:
            break
        }
    }

    /// Handle an incoming message on a pending (unauthenticated) connection.
    private func handlePendingMessage(_ envelope: RemoteEnvelope, connectionId: String, connection: NWConnection) {
        switch envelope.type {
        case MessageType.hello:
            // Send auth challenge
            let nonce = generateRandomBytes(32)
            if let challenge = try? RemoteEnvelope(type: MessageType.authChallenge, payload: AuthChallenge(nonce: nonce)) {
                let frame = try? RemoteFrame.encode(challenge)
                if let frame {
                    connection.send(content: frame, completion: .contentProcessed { _ in })
                }
            }

        case MessageType.pairingRequest:
            guard let request = try? envelope.decode(PairingRequest.self) else { return }
            guard let code = activePairingCode else {
                sendPairingFailure(to: connection, error: "Pairing mode is not active")
                return
            }
            let response = pairingManager.validatePairing(request: request, code: code)
            if let respEnvelope = try? RemoteEnvelope(type: MessageType.pairingResponse, id: envelope.id, payload: response) {
                let frame = try? RemoteFrame.encode(respEnvelope)
                if let frame {
                    connection.send(content: frame, completion: .contentProcessed { _ in })
                }
            }
            if response.success {
                stopPairing()
                promoteConnection(connectionId: connectionId, connection: connection,
                                  deviceId: request.deviceId, deviceName: request.deviceName)
            }

        case MessageType.authRequest:
            print("[RemoteServer] Received auth request")
            guard let request = try? envelope.decode(AuthRequest.self) else {
                print("[RemoteServer] Failed to decode auth request")
                return
            }
            print("[RemoteServer] Auth request from device: \(request.deviceId)")
            let challenge = AuthChallenge(nonce: generateRandomBytes(32))
            let result = pairingManager.authenticateDevice(request: request, challenge: challenge)
            print("[RemoteServer] Auth result: success=\(result.success) error=\(result.error ?? "none")")
            if let respEnvelope = try? RemoteEnvelope(type: MessageType.authResult, id: envelope.id, payload: result) {
                let frame = try? RemoteFrame.encode(respEnvelope)
                if let frame {
                    connection.send(content: frame, completion: .contentProcessed { error in
                        if let error {
                            print("[RemoteServer] Failed to send auth result: \(error)")
                        } else {
                            print("[RemoteServer] Sent auth result to client")
                        }
                    })
                }
            }
            if result.success {
                let deviceName = pairingManager.pairedDevices.first { $0.deviceId == request.deviceId }?.deviceName ?? "Unknown"
                promoteConnection(connectionId: connectionId, connection: connection,
                                  deviceId: request.deviceId, deviceName: deviceName)
            }

        default:
            // Buffer the message for replay after the connection is promoted.
            print("[RemoteServer] Buffering message type '\(envelope.type)' on pending connection \(connectionId)")
            var buffer = pendingMessageBuffers[connectionId] ?? []
            buffer.append(envelope)
            pendingMessageBuffers[connectionId] = buffer
        }
    }

    // MARK: - Connection Management

    private func handleNewConnection(_ connection: NWConnection) {
        let connectionId = UUID().uuidString
        pendingConnections[connectionId] = connection
        print("[RemoteServer] New incoming connection: \(connectionId)")

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    print("[RemoteServer] Pending connection ready: \(connectionId)")
                    // Send Hello so the client knows our identity
                    self?.sendHello(to: connection)
                    // Auto-start pairing mode for new connections
                    if !(self?.isPairingMode ?? false) {
                        let code = self?.startPairing() ?? "000000"
                        print("[RemoteServer] ========================================")
                        print("[RemoteServer] PAIRING CODE: \(code)")
                        print("[RemoteServer] Enter this code on your iOS device")
                        print("[RemoteServer] ========================================")
                        // Show macOS notification with pairing code
                        self?.showPairingNotification(code: code)
                    }
                    self?.startPendingReceive(connectionId: connectionId, connection: connection)
                case .failed(let error):
                    print("[RemoteServer] Pending connection failed: \(error)")
                    self?.pendingConnections.removeValue(forKey: connectionId)
                    self?.pendingMessageBuffers.removeValue(forKey: connectionId)
                case .cancelled:
                    self?.pendingConnections.removeValue(forKey: connectionId)
                    self?.pendingMessageBuffers.removeValue(forKey: connectionId)
                default:
                    break
                }
            }
        }
        connection.start(queue: serverQueue)
    }

    private func sendHello(to connection: NWConnection) {
        let hello = HelloMessage(
            protocolVersion: 1,
            deviceName: Host.current().localizedName ?? "Clome",
            deviceId: getOrCreateDeviceId(),
            capabilities: ["terminal", "workspace", "editor"]
        )
        if let envelope = try? RemoteEnvelope(type: MessageType.hello, payload: hello),
           let frame = try? RemoteFrame.encode(envelope) {
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    print("[RemoteServer] Failed to send hello: \(error)")
                } else {
                    print("[RemoteServer] Sent hello to new connection")
                }
            })
        }
    }

    /// Connection IDs that have been promoted to sessions. Used to stop the
    /// pending receive loop so it doesn't compete with the session handler's loop.
    private var promotedConnectionIds: Set<String> = []

    private func startPendingReceive(connectionId: String, connection: NWConnection) {
        // Buffer held per-connection for accumulating partial frames.
        // Using a dict on self (MainActor-isolated) avoids Sendable capture issues.
        pendingReceiveBuffers[connectionId] = Data()
        pendingReceiveLoop(connectionId: connectionId, connection: connection)
    }

    /// Buffers for pending connections (keyed by connectionId).
    private var pendingReceiveBuffers: [String: Data] = [:]

    private func pendingReceiveLoop(connectionId: String, connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                // Stop the pending receive loop once the connection has been promoted.
                if self.promotedConnectionIds.contains(connectionId) {
                    print("[RemoteServer] Pending receive loop stopping — connection \(connectionId) was promoted")
                    self.pendingReceiveBuffers.removeValue(forKey: connectionId)
                    return
                }
                if let data = content {
                    print("[RemoteServer] Received \(data.count) bytes on pending connection \(connectionId)")
                    self.pendingReceiveBuffers[connectionId, default: Data()].append(data)
                    while let extracted = RemoteFrame.extract(from: self.pendingReceiveBuffers[connectionId] ?? Data()) {
                        self.pendingReceiveBuffers[connectionId] = Data((self.pendingReceiveBuffers[connectionId] ?? Data()).dropFirst(extracted.consumed))
                        if let envelope = try? JSONDecoder().decode(RemoteEnvelope.self, from: extracted.payload) {
                            print("[RemoteServer] Decoded message type: \(envelope.type) on pending connection")
                            self.handlePendingMessage(envelope, connectionId: connectionId, connection: connection)
                        } else {
                            print("[RemoteServer] Failed to decode envelope from pending connection")
                        }
                    }
                }
                if isComplete {
                    print("[RemoteServer] Pending connection \(connectionId) completed")
                    self.pendingConnections.removeValue(forKey: connectionId)
                    self.pendingMessageBuffers.removeValue(forKey: connectionId)
                    self.pendingReceiveBuffers.removeValue(forKey: connectionId)
                } else if let error {
                    print("[RemoteServer] Pending connection \(connectionId) error: \(error)")
                    self.pendingConnections.removeValue(forKey: connectionId)
                    self.pendingMessageBuffers.removeValue(forKey: connectionId)
                    self.pendingReceiveBuffers.removeValue(forKey: connectionId)
                } else {
                    self.pendingReceiveLoop(connectionId: connectionId, connection: connection)
                }
            }
        }
    }

    private func promoteConnection(connectionId: String, connection: NWConnection, deviceId: String, deviceName: String) {
        pendingConnections.removeValue(forKey: connectionId)
        // Signal the pending receive loop to stop so it doesn't compete with the session handler
        promotedConnectionIds.insert(connectionId)

        // Replace old sessions for this device quietly — the device is reconnecting
        // on a new connection, so we deactivate old sessions without posting a
        // disconnect notification (which would confuse the UI into thinking the
        // device left). Using replaceQuietly() instead of disconnect() avoids
        // the sessionDisconnected callback that posts .remoteClientDisconnected.
        let staleSessionIds = sessions.filter { $0.value.deviceId == deviceId }.map(\.key)
        for staleId in staleSessionIds {
            print("[RemoteServer] Replacing stale session \(staleId) for device \(deviceId)")
            sessions.removeValue(forKey: staleId)?.replaceQuietly()
        }

        let sessionId = UUID().uuidString
        let handler = RemoteSessionHandler(
            id: sessionId,
            deviceId: deviceId,
            deviceName: deviceName,
            transport: .network(connection)
        )
        sessions[sessionId] = handler
        handler.startReceiving()

        print("[RemoteServer] Connection promoted to session \(sessionId) for device '\(deviceName)'")

        // Send initial workspace snapshot so the client has state immediately
        sendWorkspaceSnapshot(to: handler)

        // Replay any messages that were buffered while the connection was pending
        if let buffered = pendingMessageBuffers.removeValue(forKey: connectionId) {
            print("[RemoteServer] Replaying \(buffered.count) buffered message(s) for session \(sessionId)")
            for envelope in buffered {
                handleMessage(envelope, from: handler)
            }
        }

        NotificationCenter.default.post(
            name: .remoteClientConnected,
            object: nil,
            userInfo: ["deviceId": deviceId, "deviceName": deviceName, "sessionId": sessionId]
        )
    }

    func sessionDisconnected(_ session: RemoteSessionHandler) {
        sessions.removeValue(forKey: session.id)
        print("[RemoteServer] Session \(session.id.prefix(8)) disconnected for device '\(session.deviceName)' (\(session.deviceId.prefix(8))). Active sessions: \(sessions.count)")
        NotificationCenter.default.post(
            name: .remoteClientDisconnected,
            object: nil,
            userInfo: ["deviceId": session.deviceId, "deviceName": session.deviceName, "sessionId": session.id]
        )
    }

    // MARK: - NWListener State

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port {
                print("[RemoteServer] Listener ready on port \(port)")
            } else {
                print("[RemoteServer] Listener ready")
            }
        case .failed(let error):
            print("[RemoteServer] Listener failed: \(error)")
            listener?.cancel()
            listener = nil
            // Retry once after a short delay instead of giving up
            if serviceRegistrationRetries < Self.maxServiceRetries {
                serviceRegistrationRetries += 1
                print("[RemoteServer] Retrying listener (attempt \(serviceRegistrationRetries))...")
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                    guard let self, self.isRunning else { return }
                    self.restartListener()
                }
            } else {
                isRunning = false
            }
        case .waiting(let error):
            print("[RemoteServer] Listener waiting: \(error)")
            // Listener is viable but not yet ready — don't cancel, let it recover
        case .cancelled:
            print("[RemoteServer] Listener cancelled")
        default:
            break
        }
    }

    /// Restart just the NWListener (e.g. after a Bonjour collision).
    /// Uses a randomized suffix to avoid colliding with stale registrations.
    private func restartListener() {
        listener?.cancel()
        listener = nil

        let tcpParams = NWParameters.tcp
        tcpParams.includePeerToPeer = true

        do {
            let nwListener = try NWListener(using: tcpParams)
            let macName = Host.current().localizedName ?? "Mac"
            let suffix = "\(ProcessInfo.processInfo.processIdentifier)-\(Int.random(in: 100...999))"
            let serviceName = "Clome-\(macName)-\(suffix)"
            nwListener.service = NWListener.Service(name: serviceName, type: Self.serviceType)
            nwListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerStateChanged(state) }
            }
            nwListener.serviceRegistrationUpdateHandler = { [weak self] change in
                Task { @MainActor in self?.serviceRegistrationChanged(change) }
            }
            nwListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.handleNewConnection(connection) }
            }
            nwListener.start(queue: serverQueue)
            self.listener = nwListener
            print("[RemoteServer] Restarted listener as \(serviceName)")
        } catch {
            print("[RemoteServer] Failed to restart listener: \(error)")
            isRunning = false
        }
    }

    private func serviceRegistrationChanged(_ change: NWListener.ServiceRegistrationChange) {
        switch change {
        case .add(let endpoint):
            print("[RemoteServer] Bonjour service registered: \(endpoint)")
        case .remove(let endpoint):
            print("[RemoteServer] Bonjour service removed: \(endpoint)")
        @unknown default:
            break
        }
    }

    // MARK: - Command Routing

    private func handleCommand(_ envelope: RemoteEnvelope, from session: RemoteSessionHandler) {
        guard let command = try? envelope.decode(RemoteCommand.self) else {
            let resp = CommandResponse(requestId: envelope.id ?? "", success: false, error: "Malformed command")
            if let e = try? RemoteEnvelope(type: MessageType.commandResponse, id: envelope.id, payload: resp) {
                session.send(e)
            }
            return
        }

        guard let manager = workspaceManager else {
            sendCommandResponse(success: false, error: "No workspace manager", id: envelope.id, to: session)
            return
        }

        switch command {
        case .switchWorkspace(let index):
            manager.switchTo(index: index)
            sendCommandResponse(success: true, id: envelope.id, to: session)
            sendWorkspaceSnapshot(to: session)

        case .createWorkspace(let name):
            manager.addWorkspace(name: name)
            sendCommandResponse(success: true, id: envelope.id, to: session)
            sendWorkspaceSnapshot(to: session)

        case .deleteWorkspace(let index):
            manager.removeWorkspace(at: index)
            sendCommandResponse(success: true, id: envelope.id, to: session)
            sendWorkspaceSnapshot(to: session)

        case .renameWorkspace(let index, let name):
            manager.renameWorkspace(at: index, to: name)
            sendCommandResponse(success: true, id: envelope.id, to: session)

        case .switchTab(let wsIndex, let tabIndex):
            if wsIndex < manager.workspaces.count {
                let ws = manager.workspaces[wsIndex]
                ws.selectTab(tabIndex)
            }
            sendCommandResponse(success: true, id: envelope.id, to: session)

        case .closeTab(let wsIndex, let tabIndex):
            if wsIndex < manager.workspaces.count {
                manager.workspaces[wsIndex].closeTab(tabIndex)
            }
            sendCommandResponse(success: true, id: envelope.id, to: session)
            sendWorkspaceSnapshot(to: session)

        case .createTerminalTab(let wsIndex):
            if wsIndex < manager.workspaces.count {
                manager.workspaces[wsIndex].addTerminalTab(workingDirectory: nil, restoreCommand: nil)
            }
            sendCommandResponse(success: true, id: envelope.id, to: session)
            sendWorkspaceSnapshot(to: session)

        case .createBrowserTab(let wsIndex, let url):
            if wsIndex < manager.workspaces.count {
                manager.workspaces[wsIndex].addBrowserTab(url: url)
            }
            sendCommandResponse(success: true, id: envelope.id, to: session)

        case .splitPane(let direction):
            if let ws = manager.activeWorkspace {
                if let dir = parseSplitDirection(direction) {
                    ws.splitActivePane(direction: dir)
                }
            }
            sendCommandResponse(success: true, id: envelope.id, to: session)

        case .focusPane:
            sendCommandResponse(success: true, id: envelope.id, to: session)

        case .terminalInput(let wsIndex, let tabIndex, let input):
            injectTerminalInput(input, workspaceIndex: wsIndex, tabIndex: tabIndex, manager: manager)
            sendCommandResponse(success: true, id: envelope.id, to: session)

        case .terminalResize:
            sendCommandResponse(success: true, id: envelope.id, to: session)

        case .requestFullSync:
            sendWorkspaceSnapshot(to: session)
            sendCommandResponse(success: true, id: envelope.id, to: session)

        case .requestTerminalContent(let wsIndex, let tabIndex):
            sendTerminalContent(workspaceIndex: wsIndex, tabIndex: tabIndex, to: session)
            sendCommandResponse(success: true, id: envelope.id, to: session)

        case .ping:
            sendCommandResponse(success: true, id: envelope.id, to: session)
            // Also send explicit pong so iOS keepalive updates lastPongTime
            if let pong = try? RemoteEnvelope(type: MessageType.pong, id: envelope.id, payload: EmptyPayload()) {
                session.send(pong)
            }
        }
    }

    private func sendCommandResponse(success: Bool, error: String? = nil, id: String?, to session: RemoteSessionHandler) {
        let resp = CommandResponse(requestId: id ?? "", success: success, error: error)
        if let e = try? RemoteEnvelope(type: MessageType.commandResponse, id: id, payload: resp) {
            session.send(e)
        }
    }

    private func sendWorkspaceSnapshot(to session: RemoteSessionHandler) {
        guard let manager = workspaceManager else { return }
        let snapshot = stateProvider.versionedSnapshot(from: manager)
        if let e = try? RemoteEnvelope(type: MessageType.workspaceSnapshot, payload: snapshot) {
            session.send(e)
        }
    }

    private func sendTerminalContent(workspaceIndex: Int, tabIndex: Int, to session: RemoteSessionHandler) {
        guard let manager = workspaceManager,
              workspaceIndex < manager.workspaces.count else { return }
        let ws = manager.workspaces[workspaceIndex]
        guard tabIndex < ws.tabs.count else { return }
        let tab = ws.tabs[tabIndex]

        // Find the terminal surface in this tab
        if let terminal = findTerminalSurface(in: tab) {
            if let text = terminal.readFullScrollback() {
                let size = terminal.surface != nil ? ghostty_surface_size(terminal.surface!) : ghostty_surface_size_s()
                let screen = TerminalScreenState(
                    paneId: tab.id.uuidString,
                    tabIndex: tabIndex,
                    sequenceNumber: 0,
                    rows: Int(size.rows),
                    cols: Int(size.columns),
                    cursorRow: Int(size.rows) - 1,
                    cursorCol: 0,
                    cursorVisible: true,
                    title: terminal.title,
                    workingDirectory: terminal.workingDirectory,
                    text: text,
                    activityState: mapActivityState(terminal.activityState)
                )
                if let e = try? RemoteEnvelope(type: MessageType.terminalScreen, payload: screen) {
                    session.send(e)
                }
            }
        }
    }

    /// Pending text waiting to be combined with a following Enter key.
    /// Key: "\(workspaceIndex):\(tabIndex)", Value: text string
    private var pendingTextForEnter: [String: String] = [:]

    private func injectTerminalInput(_ input: TerminalInput, workspaceIndex: Int, tabIndex: Int, manager: WorkspaceManager) {
        guard workspaceIndex < manager.workspaces.count else { return }
        let ws = manager.workspaces[workspaceIndex]
        guard tabIndex < ws.tabs.count else { return }
        let tab = ws.tabs[tabIndex]

        guard let terminal = findTerminalSurface(in: tab), let surface = terminal.surface else {
            print("[RemoteServer] No terminal surface found for ws:\(workspaceIndex) tab:\(tabIndex)")
            return
        }

        let paneKey = "\(workspaceIndex):\(tabIndex)"

        if let specialKey = input.specialKey {
            print("[RemoteServer] Injecting special key: \(specialKey), mods: \(input.modifiers)")

            if specialKey == .enter && !input.modifiers.ctrl && !input.modifiers.alt && !input.modifiers.shift {
                // If we have pending text, combine it with Enter into a single pty write.
                // This avoids the issue where bracketed paste (from injectText) + separate
                // Enter don't reliably submit in apps like Claude Code.
                if let pendingText = pendingTextForEnter.removeValue(forKey: paneKey) {
                    print("[RemoteServer] Combining pending text '\(pendingText)' with Enter via injectTextAndReturn")
                    terminal.injectTextAndReturn(pendingText)
                } else {
                    print("[RemoteServer] Standalone Enter via injectReturn()")
                    terminal.injectReturn()
                }
                return
            }

            // Flush any pending text before other special keys
            if let pendingText = pendingTextForEnter.removeValue(forKey: paneKey) {
                print("[RemoteServer] Flushing pending text '\(pendingText)' before special key")
                terminal.injectText(pendingText)
            }

            let info = specialKeyInfo(specialKey)
            var mods = ghosttyMods(from: input.modifiers)
            if info.addCtrl {
                mods = ghostty_input_mods_e(rawValue: mods.rawValue | GHOSTTY_MODS_CTRL.rawValue)
            }
            injectGhosttyKeyPress(keycode: info.keycode, unshiftedCodepoint: info.codepoint, mods: mods, surface: surface)
        } else if let text = input.text, !text.isEmpty {
            print("[RemoteServer] Buffering text: '\(text)' (\(text.count) chars) — waiting for Enter")
            // Buffer text — if Enter arrives next, we combine them into a single pty write.
            // If something else arrives, we flush it as a normal paste.
            pendingTextForEnter[paneKey] = text
        }
    }

    /// Send a press+release key event to the ghostty surface using the proper key input API.
    /// The keycode is a macOS virtual keycode (same as NSEvent.keyCode). Ghostty maps it
    /// internally to the terminal escape sequence via its keycode lookup table.
    private func injectGhosttyKeyPress(keycode: UInt32, unshiftedCodepoint: UInt32, mods: ghostty_input_mods_e, surface: ghostty_surface_t) {
        // For keys that produce a character (codepoint != 0), we must pass the text
        // payload so ghostty delivers the actual byte to the application's stdin.
        // Without text, apps that read character data (e.g. Claude Code / Node.js)
        // see the key event but receive no input character — Enter wouldn't submit.
        let effectiveCodepoint: UInt32
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0, unshiftedCodepoint >= 0x60, unshiftedCodepoint <= 0x7A {
            // Ctrl+letter: terminal expects the control character (e.g. Ctrl+C = 0x03)
            effectiveCodepoint = unshiftedCodepoint - 0x60
        } else {
            effectiveCodepoint = unshiftedCodepoint
        }

        if effectiveCodepoint != 0, let scalar = Unicode.Scalar(effectiveCodepoint) {
            let text = String(scalar)
            text.withCString { ptr in
                var event = ghostty_input_key_s(
                    action: GHOSTTY_ACTION_PRESS,
                    mods: mods,
                    consumed_mods: GHOSTTY_MODS_NONE,
                    keycode: keycode,
                    text: ptr,
                    unshifted_codepoint: unshiftedCodepoint,
                    composing: false
                )
                ghostty_surface_key(surface, event)

                // Send release (no text on release)
                event.action = GHOSTTY_ACTION_RELEASE
                event.text = nil
                ghostty_surface_key(surface, event)
            }
        } else {
            // Non-character keys (arrows, function keys, etc.) — no text needed
            var event = ghostty_input_key_s(
                action: GHOSTTY_ACTION_PRESS,
                mods: mods,
                consumed_mods: GHOSTTY_MODS_NONE,
                keycode: keycode,
                text: nil,
                unshifted_codepoint: unshiftedCodepoint,
                composing: false
            )
            ghostty_surface_key(surface, event)

            // Send release
            event.action = GHOSTTY_ACTION_RELEASE
            ghostty_surface_key(surface, event)
        }
    }

    /// Info needed to synthesize a ghostty key event for a given special key.
    private struct SpecialKeyInfo {
        let keycode: UInt32      // macOS virtual keycode
        let codepoint: UInt32    // unshifted Unicode codepoint (0 for non-character keys)
        let addCtrl: Bool        // whether to add CTRL modifier (for ctrl+letter combos)
    }

    /// Map TerminalInput.SpecialKey to macOS virtual keycode + metadata.
    /// Virtual keycodes from Carbon Events.h / HIToolbox.
    private func specialKeyInfo(_ key: TerminalInput.SpecialKey) -> SpecialKeyInfo {
        switch key {
        // Functional keys
        case .enter:      return SpecialKeyInfo(keycode: 0x24, codepoint: 0x0D, addCtrl: false)  // kVK_Return
        case .tab:        return SpecialKeyInfo(keycode: 0x30, codepoint: 0x09, addCtrl: false)  // kVK_Tab
        case .escape:     return SpecialKeyInfo(keycode: 0x35, codepoint: 0x1B, addCtrl: false)  // kVK_Escape
        case .backspace:  return SpecialKeyInfo(keycode: 0x33, codepoint: 0x7F, addCtrl: false)  // kVK_Delete
        case .delete:     return SpecialKeyInfo(keycode: 0x75, codepoint: 0,    addCtrl: false)  // kVK_ForwardDelete
        // Arrow keys
        case .arrowUp:    return SpecialKeyInfo(keycode: 0x7E, codepoint: 0, addCtrl: false)  // kVK_UpArrow
        case .arrowDown:  return SpecialKeyInfo(keycode: 0x7D, codepoint: 0, addCtrl: false)  // kVK_DownArrow
        case .arrowLeft:  return SpecialKeyInfo(keycode: 0x7B, codepoint: 0, addCtrl: false)  // kVK_LeftArrow
        case .arrowRight: return SpecialKeyInfo(keycode: 0x7C, codepoint: 0, addCtrl: false)  // kVK_RightArrow
        // Navigation keys
        case .home:       return SpecialKeyInfo(keycode: 0x73, codepoint: 0, addCtrl: false)  // kVK_Home
        case .end:        return SpecialKeyInfo(keycode: 0x77, codepoint: 0, addCtrl: false)  // kVK_End
        case .pageUp:     return SpecialKeyInfo(keycode: 0x74, codepoint: 0, addCtrl: false)  // kVK_PageUp
        case .pageDown:   return SpecialKeyInfo(keycode: 0x79, codepoint: 0, addCtrl: false)  // kVK_PageDown
        // Ctrl+letter combos — use the letter's virtual keycode + ctrl modifier
        case .ctrlA:      return SpecialKeyInfo(keycode: 0x00, codepoint: 0x61, addCtrl: true)   // kVK_ANSI_A
        case .ctrlC:      return SpecialKeyInfo(keycode: 0x08, codepoint: 0x63, addCtrl: true)   // kVK_ANSI_C
        case .ctrlD:      return SpecialKeyInfo(keycode: 0x02, codepoint: 0x64, addCtrl: true)   // kVK_ANSI_D
        case .ctrlE:      return SpecialKeyInfo(keycode: 0x0E, codepoint: 0x65, addCtrl: true)   // kVK_ANSI_E
        case .ctrlK:      return SpecialKeyInfo(keycode: 0x28, codepoint: 0x6B, addCtrl: true)   // kVK_ANSI_K
        case .ctrlL:      return SpecialKeyInfo(keycode: 0x25, codepoint: 0x6C, addCtrl: true)   // kVK_ANSI_L
        case .ctrlR:      return SpecialKeyInfo(keycode: 0x0F, codepoint: 0x72, addCtrl: true)   // kVK_ANSI_R
        case .ctrlU:      return SpecialKeyInfo(keycode: 0x20, codepoint: 0x75, addCtrl: true)   // kVK_ANSI_U
        case .ctrlW:      return SpecialKeyInfo(keycode: 0x0D, codepoint: 0x77, addCtrl: true)   // kVK_ANSI_W
        case .ctrlZ:      return SpecialKeyInfo(keycode: 0x06, codepoint: 0x7A, addCtrl: true)   // kVK_ANSI_Z
        // Function keys
        case .f1:         return SpecialKeyInfo(keycode: 0x7A, codepoint: 0, addCtrl: false)  // kVK_F1
        case .f2:         return SpecialKeyInfo(keycode: 0x78, codepoint: 0, addCtrl: false)  // kVK_F2
        case .f3:         return SpecialKeyInfo(keycode: 0x63, codepoint: 0, addCtrl: false)  // kVK_F3
        case .f4:         return SpecialKeyInfo(keycode: 0x76, codepoint: 0, addCtrl: false)  // kVK_F4
        case .f5:         return SpecialKeyInfo(keycode: 0x60, codepoint: 0, addCtrl: false)  // kVK_F5
        case .f6:         return SpecialKeyInfo(keycode: 0x61, codepoint: 0, addCtrl: false)  // kVK_F6
        case .f7:         return SpecialKeyInfo(keycode: 0x62, codepoint: 0, addCtrl: false)  // kVK_F7
        case .f8:         return SpecialKeyInfo(keycode: 0x64, codepoint: 0, addCtrl: false)  // kVK_F8
        case .f9:         return SpecialKeyInfo(keycode: 0x65, codepoint: 0, addCtrl: false)  // kVK_F9
        case .f10:        return SpecialKeyInfo(keycode: 0x6D, codepoint: 0, addCtrl: false)  // kVK_F10
        case .f11:        return SpecialKeyInfo(keycode: 0x67, codepoint: 0, addCtrl: false)  // kVK_F11
        case .f12:        return SpecialKeyInfo(keycode: 0x6F, codepoint: 0, addCtrl: false)  // kVK_F12
        }
    }

    private func findTerminalSurface(in tab: WorkspaceTab) -> TerminalSurface? {
        if let terminal = tab.view as? TerminalSurface {
            return terminal
        }
        // Check inside split container
        for pane in tab.splitContainer.allLeafViews {
            if let terminal = pane as? TerminalSurface {
                return terminal
            }
        }
        return nil
    }

    private func mapActivityState(_ state: TerminalSurface.ActivityState) -> TerminalActivity.ActivityState {
        switch state {
        case .idle: return .idle
        case .running: return .running
        case .waitingInput: return .waitingInput
        case .completed: return .completed
        }
    }

    private func parseSplitDirection(_ direction: String) -> SplitDirection? {
        switch direction {
        case "right": return .right
        case "down": return .down
        case "left": return .left
        case "up": return .up
        default: return nil
        }
    }

    /// Convert TerminalInput.KeyModifiers to ghostty modifier flags.
    private func ghosttyMods(from modifiers: TerminalInput.KeyModifiers) -> ghostty_input_mods_e {
        var raw: UInt32 = 0
        if modifiers.ctrl  { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if modifiers.alt   { raw |= GHOSTTY_MODS_ALT.rawValue }
        if modifiers.shift { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    // MARK: - TLS Configuration

    private func makeTLSParameters() -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()

        if let identity = loadOrCreateTLSIdentity() {
            sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, identity)
        }

        // Accept any client cert (we authenticate at the application layer via pairing tokens)
        sec_protocol_options_set_peer_authentication_required(tlsOptions.securityProtocolOptions, false)

        let params = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        return params
    }

    private func loadOrCreateTLSIdentity() -> sec_identity_t? {
        // Try to load existing identity from Keychain
        if let existing = loadIdentityFromKeychain() {
            return existing
        }
        // Generate self-signed certificate and store in Keychain
        return generateAndStoreSelfSignedIdentity()
    }

    private func loadIdentityFromKeychain() -> sec_identity_t? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: Self.keychainLabel,
            kSecReturnRef as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let identity = item else { return nil }
        // swiftlint:disable:next force_cast
        return sec_identity_create(identity as! SecIdentity)
    }

    private func generateAndStoreSelfSignedIdentity() -> sec_identity_t? {
        // Self-signed certificate generation requires private Apple SPI on macOS.
        // For the remote control feature, we rely on application-layer authentication
        // (pairing tokens + Ed25519 signatures) rather than TLS client/server cert
        // verification. TLS still encrypts the channel even without a verified identity.
        //
        // A future enhancement could use `openssl` CLI to generate a PKCS12 identity
        // and import it via `SecPKCS12Import`, but for now we return nil and let
        // NWListener use its default anonymous TLS behavior.
        return nil
    }

    // MARK: - MultipeerConnectivity

    private func startMultipeerAdvertiser() {
        let localPeer = MCPeerID(displayName: Host.current().localizedName ?? "Clome")
        mcLocalPeerID = localPeer

        let session = MCSession(peer: localPeer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        mcSession = session

        let advertiser = MCNearbyServiceAdvertiser(
            peer: localPeer,
            discoveryInfo: ["version": "1"],
            serviceType: Self.mcServiceType
        )
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        mcAdvertiser = advertiser
    }

    // MARK: - Helpers

    private func generateRandomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private func showPairingNotification(code: String) {
        // System notification as fallback
        let content = UNMutableNotificationContent()
        content.title = "Clome Remote Pairing"
        content.body = "Pairing code: \(code)"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "clome-pairing-\(code)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)

        // In-app overlay
        PairingOverlayController.shared.show(code: code)

        // Notify observers that pairing has started
        NotificationCenter.default.post(
            name: .remotePairingStarted,
            object: nil,
            userInfo: ["pairingCode": code]
        )
    }

    private func sendPairingFailure(to connection: NWConnection, error: String) {
        let response = PairingResponse(success: false, error: error, serverPublicKey: nil, authToken: nil)
        if let envelope = try? RemoteEnvelope(type: MessageType.pairingResponse, payload: response),
           let frame = try? RemoteFrame.encode(envelope) {
            connection.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    /// Connected session count.
    var connectedDeviceCount: Int { sessions.count }

    /// All connected device names.
    var connectedDeviceNames: [String] { sessions.values.map(\.deviceName) }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension RemoteServer: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // MCNearbyServiceAdvertiserDelegate predates Swift Concurrency; its invitationHandler
        // is not Sendable. We wrap it in nonisolated(unsafe) to cross the isolation boundary.
        nonisolated(unsafe) let handler = invitationHandler
        let ctx = context
        Task { @MainActor [weak self] in
            guard let self else { handler(false, nil); return }
            if self.isPairingMode {
                handler(true, self.mcSession)
            } else if let ctx,
                      let deviceId = String(data: ctx, encoding: .utf8),
                      self.pairingManager.isPaired(deviceId: deviceId) {
                handler(true, self.mcSession)
            } else {
                handler(false, nil)
            }
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        // Multipeer advertising failed — network-only mode continues
    }
}

// MARK: - MCSessionDelegate

extension RemoteServer: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let peerName = peerID.displayName
        let stateValue = state
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch stateValue {
            case .connected:
                self.handleMultipeerConnected(peerName: peerName)
            case .notConnected:
                self.handleMultipeerDisconnected(peerName: peerName)
            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let peerName = peerID.displayName
        let receivedData = data
        Task { @MainActor [weak self] in
            guard let self else { return }
            let handler = self.sessions.values.first { $0.deviceName == peerName }
            handler?.receivedMultipeerData(receivedData)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    @MainActor
    private func handleMultipeerConnected(peerName: String) {
        let sessionId = UUID().uuidString

        // For Multipeer, we use a lightweight session handler without a direct transport reference.
        // Messages are routed via the MCSession delegate's didReceive callback.
        guard let session = mcSession else { return }
        // Find the MCPeerID matching this name
        guard let peer = session.connectedPeers.first(where: { $0.displayName == peerName }) else { return }

        let handler = RemoteSessionHandler(
            id: sessionId,
            deviceId: peerName,
            deviceName: peerName,
            transport: .multipeer(session, peer)
        )
        sessions[sessionId] = handler

        // Send hello so the client knows we accepted
        let hello = HelloMessage(
            protocolVersion: 1,
            deviceName: Host.current().localizedName ?? "Clome",
            deviceId: getOrCreateDeviceId(),
            capabilities: ["terminal", "workspace", "editor"]
        )
        if let envelope = try? RemoteEnvelope(type: MessageType.hello, payload: hello) {
            handler.send(envelope)
        }

        NotificationCenter.default.post(
            name: .remoteClientConnected,
            object: nil,
            userInfo: ["deviceId": peerName, "deviceName": peerName, "sessionId": sessionId]
        )
    }

    @MainActor
    private func handleMultipeerDisconnected(peerName: String) {
        if let session = sessions.values.first(where: { $0.deviceName == peerName }) {
            session.disconnect()
        }
    }

    private func getOrCreateDeviceId() -> String {
        let key = "com.clome.remote.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}

// MARK: - Empty Payload Helper

private struct EmptyPayload: Codable {}
