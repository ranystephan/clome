// RemoteServer.swift
// Clome — macOS remote control server for iOS companion app.
// Listens for TLS connections via Network.framework, advertises via Bonjour and MultipeerConnectivity.

import Foundation
import Network
import MultipeerConnectivity
import Security
import UserNotifications
import FirebaseAuth
import FirebaseFirestore

// MARK: - Notifications

extension Notification.Name {
    static let remoteClientConnected = Notification.Name("clomeRemoteClientConnected")
    static let remoteClientDisconnected = Notification.Name("clomeRemoteClientDisconnected")
    static let remotePairingStarted = Notification.Name("clomeRemotePairingStarted")
    static let remotePairingStopped = Notification.Name("clomeRemotePairingStopped")
    static let remoteCloudStateChanged = Notification.Name("clomeRemoteCloudStateChanged")
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
    private var cloudSender: ((RemoteEnvelope) -> Void)?
    private var receiveBuffer = Data()
    private var isActive = true

    /// Last time we received any data from the remote client on this session.
    /// Used by RemoteServer's liveness sweep to drop sessions whose underlying
    /// transport (TCP, MC, or cloud) has gone silent.
    fileprivate(set) var lastActivityAt: Date = .now
    fileprivate var transportKind: String {
        if nwConnection != nil { return "network" }
        if mcSession != nil { return "multipeer" }
        if cloudSender != nil { return "cloud" }
        return "unknown"
    }

    enum Transport {
        case network(NWConnection)
        case multipeer(MCSession, MCPeerID)
        case cloud((RemoteEnvelope) -> Void)
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
        case .cloud(let sender):
            self.cloudSender = sender
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
            } else if let cloudSender {
                cloudSender(envelope)
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
                    self.lastActivityAt = .now
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
        lastActivityAt = .now
        receiveBuffer.append(data)
        processBuffer()
    }

    /// Called by RemoteServer when an envelope arrives over the cloud transport.
    func noteCloudActivity() {
        lastActivityAt = .now
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
        if nwConnection != nil {
            nwConnection?.cancel()
        }
        nwConnection = nil
        // The multipeer session is owned by RemoteServer and shared across peers.
        // Do not disconnect it here or one logical session teardown will drop every peer.
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
        if nwConnection != nil {
            nwConnection?.cancel()
        }
        nwConnection = nil
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
    private static let pairingPresentationDelayNanoseconds: UInt64 = 1_500_000_000

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
    private var pendingMultipeerPeers: [String: MCPeerID] = [:]
    private var pendingMultipeerReceiveBuffers: [String: Data] = [:]
    private var pendingPairingPresentationTasks: [String: Task<Void, Never>] = [:]
    private var cloudAuthHandle: AuthStateDidChangeListenerHandle?
    private var cloudHostsHeartbeatTimer: Timer?
    private var sessionLivenessTimer: Timer?
    /// Sessions with no inbound activity for longer than this are considered dead.
    private static let sessionStaleTimeout: TimeInterval = 60
    private var cloudSessionsListener: ListenerRegistration?
    private var cloudClientMessageListeners: [String: ListenerRegistration] = [:]
    private var processedCloudClientMessageIds: [String: Set<String>] = [:]
    private var cloudRegisteredUserId: String?
    private var cloudSessionIds = Set<String>()
    private let cloudHostingEnabledKey = "com.clome.remote.cloud.enabled"

    private let pairingManager = PairingManager()
    private let stateProvider = WorkspaceStateProvider()
    private let streamEngine = TerminalStreamEngine()
    private let systemPromptMonitor = SystemPromptMonitor()

    // New feature components
    private let fileHandler = RemoteFileHandler()
    private let sessionRecorder = SessionRecorder()
    private let statsProvider = SystemStatsProvider()
    private let tunnelManager = RemoteTunnelManager()
    private let notificationTrigger = NotificationTriggerEngine()
    private var clipboardChangeCount: Int = 0
    private var clipboardPollTimer: Timer?

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
                nonisolated(unsafe) let state = state
                Task { @MainActor in
                    self?.listenerStateChanged(state)
                }
            }
            nwListener.serviceRegistrationUpdateHandler = { [weak self] change in
                nonisolated(unsafe) let change = change
                Task { @MainActor in
                    self?.serviceRegistrationChanged(change)
                }
            }
            nwListener.newConnectionHandler = { [weak self] connection in
                nonisolated(unsafe) let connection = connection
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

        isRunning = true
        startMultipeerAdvertiser()
        configureCloudRemoteHosting()
        startSessionLivenessSweep()

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
            // Also capture for session recording
            self?.sessionRecorder.captureScreen(screen)
        }
        streamEngine.onDelta = { [weak self] delta in
            self?.broadcastTerminalDelta(delta)
            // Also capture for session recording
            self?.sessionRecorder.captureDelta(delta)
        }
        streamEngine.start()

        // Register active terminal surfaces for streaming
        registerActiveTerminals()

        // Start system prompt detection (TCC dialogs, folder access, etc.)
        systemPromptMonitor.onPromptDetected = { [weak self] prompt in
            self?.broadcastSystemPrompt(prompt)
        }
        systemPromptMonitor.start()

        // Wire up smart notification engine
        notificationTrigger.onNotification = { [weak self] notification in
            self?.broadcastNotification(notification)
        }

        // Start clipboard change polling (2s interval)
        clipboardChangeCount = NSPasteboard.general.changeCount
        clipboardPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let current = NSPasteboard.general.changeCount
                if current != self.clipboardChangeCount {
                    self.clipboardChangeCount = current
                    let text = NSPasteboard.general.string(forType: .string)
                    let content = ClipboardContent(text: text, hasImage: false, changeCount: current)
                    if let env = try? RemoteEnvelope(type: MessageType.clipboardContent, payload: content) {
                        for session in self.sessions.values {
                            session.send(env)
                        }
                    }
                }
            }
        }
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
        sessionLivenessTimer?.invalidate()
        sessionLivenessTimer = nil
        clipboardPollTimer?.invalidate()
        clipboardPollTimer = nil
        if sessionRecorder.isRecording { sessionRecorder.stopRecording() }
        tunnelManager.closeAllTunnels(forSession: "")  // close all on shutdown
        stopCloudRemoteHosting(markOffline: true)

        let allSessions = Array(sessions.values)
        pendingConnections.values.forEach { $0.cancel() }
        pendingConnections.removeAll()
        promotedConnectionIds.removeAll()
        pendingMultipeerPeers.removeAll()
        pendingMultipeerReceiveBuffers.removeAll()
        pendingPairingPresentationTasks.values.forEach { $0.cancel() }
        pendingPairingPresentationTasks.removeAll()
        pendingMessageBuffers.removeAll()
        for session in allSessions {
            session.disconnect()
        }
    }

    // MARK: - Remote Anywhere

    private func configureCloudRemoteHosting() {
        if cloudAuthHandle == nil {
            cloudAuthHandle = Auth.auth().addStateDidChangeListener { [weak self] _, _ in
                Task { @MainActor in
                    self?.refreshCloudRemoteHosting()
                }
            }
        }
        refreshCloudRemoteHosting()
    }

    private func refreshCloudRemoteHosting() {
        guard isRunning else {
            print("[RemoteServer] Cloud hosting skipped — server not running yet")
            return
        }

        guard isCloudHostingEnabled else {
            print("[RemoteServer] Cloud hosting disabled by user setting")
            stopCloudRemoteHosting(markOffline: true)
            return
        }

        guard let user = Auth.auth().currentUser else {
            print("[RemoteServer] Cloud hosting unavailable — not signed into Firebase Auth")
            stopCloudRemoteHosting(markOffline: true)
            return
        }

        if cloudRegisteredUserId != user.uid {
            stopCloudRemoteHosting(markOffline: false)
            cloudRegisteredUserId = user.uid
        }

        print("[RemoteServer] Publishing cloud presence for \(user.email ?? user.uid)")
        updateCloudPresenceDocument()

        if cloudHostsHeartbeatTimer == nil {
            cloudHostsHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateCloudPresenceDocument()
                }
            }
        }

        if cloudSessionsListener == nil {
            cloudSessionsListener = Firestore.firestore()
                .collection("users")
                .document(user.uid)
                .collection("remoteSessions")
                .addSnapshotListener { [weak self] snapshot, error in
                    Task { @MainActor [weak self] in
                        self?.handleCloudSessionsSnapshot(snapshot: snapshot, error: error)
                    }
                }
        }

        NotificationCenter.default.post(name: .remoteCloudStateChanged, object: nil)
    }

    private func stopCloudRemoteHosting(markOffline: Bool) {
        let previousUserId = cloudRegisteredUserId ?? Auth.auth().currentUser?.uid

        let activeCloudSessionIds = Array(cloudSessionIds)
        for sessionId in activeCloudSessionIds {
            sessions[sessionId]?.disconnect()
        }

        cloudHostsHeartbeatTimer?.invalidate()
        cloudHostsHeartbeatTimer = nil
        cloudSessionsListener?.remove()
        cloudSessionsListener = nil
        for listener in cloudClientMessageListeners.values {
            listener.remove()
        }
        cloudClientMessageListeners.removeAll()
        processedCloudClientMessageIds.removeAll()
        cloudSessionIds.removeAll()

        if markOffline, let previousUserId {
            Firestore.firestore()
                .collection("users")
                .document(previousUserId)
                .collection("remoteHosts")
                .document(getOrCreateDeviceId())
                .setData([
                    "deviceId": getOrCreateDeviceId(),
                    "deviceName": Host.current().localizedName ?? "Clome",
                    "platform": "macOS",
                    "status": isCloudHostingEnabled ? "offline" : "disabled",
                    "updatedAt": Date(),
                    "activeSessionCount": 0,
                    "pairedDeviceCount": pairingManager.pairedDevices.count
                ], merge: true)
        }

        cloudRegisteredUserId = nil
        NotificationCenter.default.post(name: .remoteCloudStateChanged, object: nil)
    }

    private func updateCloudPresenceDocument() {
        guard isRunning,
              isCloudHostingEnabled,
              let userId = cloudRegisteredUserId ?? Auth.auth().currentUser?.uid else {
            return
        }

        cloudRegisteredUserId = userId
        let devId = getOrCreateDeviceId()
        let devName = Host.current().localizedName ?? "Clome"

        print("[RemoteServer] Cloud heartbeat → users/\(userId)/remoteHosts/\(devId) (\(devName))")
        Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("remoteHosts")
            .document(devId)
            .setData({
                var data: [String: Any] = [
                    "deviceId": devId,
                    "deviceName": devName,
                    "platform": "macOS",
                    "status": "online",
                    "updatedAt": Date(),
                    "activeSessionCount": cloudSessionIds.count,
                    "pairedDeviceCount": pairingManager.pairedDevices.count
                ]
                // Include system stats for Multi-Mac Dashboard
                let stats = statsProvider.collectStats()
                data["cpuUsagePercent"] = stats.cpuUsagePercent
                data["memoryUsedGB"] = stats.memoryUsedGB
                data["memoryTotalGB"] = stats.memoryTotalGB
                data["diskUsedGB"] = stats.diskUsedGB
                data["diskTotalGB"] = stats.diskTotalGB
                data["activeProcesses"] = stats.activeProcesses
                data["uptimeSeconds"] = stats.uptimeSeconds
                return data
            }(), merge: true) { error in
                if let error {
                    print("[RemoteServer] Cloud heartbeat FAILED: \(error.localizedDescription)")
                }
            }
    }

    /// Only freshly-requested sessions should be accepted. A session older than
    /// this window was almost certainly abandoned (client killed, network lost,
    /// host restarted) and must not be resurrected — otherwise ghost sessions
    /// accumulate and Clome reports "always connected" with no real client.
    private static let cloudSessionFreshnessWindow: TimeInterval = 120

    private func handleCloudSessionsSnapshot(snapshot: QuerySnapshot?, error: Error?) {
        if let error {
            print("[RemoteServer] Cloud session listener error: \(error.localizedDescription)")
            return
        }
        guard let snapshot, let userId = cloudRegisteredUserId else { return }

        // Process only actual changes — iterating all documents every time
        // causes write amplification and makes status updates we sent ourselves
        // (e.g. "connected") feed back into this handler.
        let freshnessThreshold = Date().addingTimeInterval(-Self.cloudSessionFreshnessWindow)
        let myDeviceId = getOrCreateDeviceId()
        var sawStaleDocs: [String] = []

        for change in snapshot.documentChanges {
            let document = change.document
            let data = document.data()
            guard let hostDeviceId = data["hostDeviceId"] as? String,
                  hostDeviceId == myDeviceId else {
                continue
            }

            let sessionId = document.documentID
            let status = data["status"] as? String ?? "requested"
            let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? .distantPast
            let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() ?? createdAt

            switch status {
            case "requested":
                if cloudSessionIds.contains(sessionId) { break }
                // Reject stale "requested" docs — these are leftovers from a
                // previous client run that never got cleaned up.
                guard updatedAt >= freshnessThreshold else {
                    sawStaleDocs.append(sessionId)
                    break
                }
                acceptCloudSession(sessionId: sessionId, userId: userId, data: data)

            case "connecting":
                // Ignore — only we transition a session to "connected".
                break

            case "connected":
                // We're the only writer of "connected". If we already have this
                // session locally, it's an echo of our own write — ignore. If we
                // DON'T have it locally, it's a leftover from a previous run of
                // this host: sweep it so activeSessionCount doesn't stay inflated.
                if !cloudSessionIds.contains(sessionId) {
                    sawStaleDocs.append(sessionId)
                }

            case "ended", "cancelled", "rejected":
                if cloudSessionIds.contains(sessionId) {
                    if let handler = sessions[sessionId] {
                        handler.disconnect()
                    } else {
                        endCloudSession(sessionId, reason: "remote_ended")
                    }
                }
            default:
                break
            }
        }

        // Best-effort sweep of stale docs in one batch. Marking them "ended"
        // clears the client's discovery list and stops the freshness check on
        // the next snapshot.
        if !sawStaleDocs.isEmpty {
            let db = Firestore.firestore()
            for staleId in sawStaleDocs {
                db.collection("users")
                    .document(userId)
                    .collection("remoteSessions")
                    .document(staleId)
                    .setData([
                        "status": "ended",
                        "endedBy": "host",
                        "endedReason": "stale_on_host_startup",
                        "updatedAt": Date()
                    ], merge: true)
            }
            // Presence count may have been inflated by ghost docs — refresh it.
            updateCloudPresenceDocument()
        }
    }

    private func acceptCloudSession(sessionId: String, userId: String, data: [String: Any]) {
        let clientDeviceId = data["clientDeviceId"] as? String ?? "unknown-client"
        let clientDeviceName = data["clientDeviceName"] as? String ?? "Remote iPhone"

        // Enforce one active cloud session per client device. When a phone
        // reconnects it generates a new sessionId — if the prior one was never
        // cleanly ended (backgrounded, killed, lost network), it would linger
        // here and inflate `activeSessionCount`. End any prior sessions from
        // the same device before accepting the new one.
        let stalePriorSessionIds = cloudSessionIds.filter { priorId in
            guard priorId != sessionId else { return false }
            if let prior = sessions[priorId] {
                return prior.deviceId == clientDeviceId
            }
            // No local handler — treat any tracked session as stale so the
            // count doesn't drift after host restarts.
            return true
        }
        for priorId in stalePriorSessionIds {
            if let prior = sessions[priorId] {
                prior.disconnect()
            } else {
                endCloudSession(priorId, reason: "superseded_by_new_session")
            }
        }

        let handler = RemoteSessionHandler(
            id: sessionId,
            deviceId: clientDeviceId,
            deviceName: clientDeviceName,
            transport: .cloud({ [weak self] envelope in
                self?.sendCloudEnvelope(envelope, userId: userId, sessionId: sessionId)
            })
        )

        cloudSessionIds.insert(sessionId)
        sessions[sessionId] = handler
        processedCloudClientMessageIds[sessionId] = []
        startCloudClientMessageListener(userId: userId, sessionId: sessionId)

        Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("remoteSessions")
            .document(sessionId)
            .setData([
                "status": "connected",
                "updatedAt": Date(),
                "hostAcceptedAt": Date()
            ], merge: true)

        updateCloudPresenceDocument()
        NotificationCenter.default.post(
            name: .remoteClientConnected,
            object: nil,
            userInfo: ["deviceId": clientDeviceId, "deviceName": clientDeviceName, "sessionId": sessionId]
        )
        sendWorkspaceSnapshot(to: handler)
        NotificationCenter.default.post(name: .remoteCloudStateChanged, object: nil)
    }

    private func startCloudClientMessageListener(userId: String, sessionId: String) {
        cloudClientMessageListeners[sessionId]?.remove()
        cloudClientMessageListeners[sessionId] = Firestore.firestore()
            .collection("users")
            .document(userId)
            .collection("remoteSessions")
            .document(sessionId)
            .collection("clientMessages")
            .order(by: "createdAt")
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let error {
                        print("[RemoteServer] Cloud client listener error: \(error.localizedDescription)")
                        return
                    }
                    guard let snapshot, let handler = self.sessions[sessionId] else { return }

                    for change in snapshot.documentChanges where change.type == .added || change.type == .modified {
                        let document = change.document
                        guard !(self.processedCloudClientMessageIds[sessionId] ?? []).contains(document.documentID),
                              let payloadBase64 = document.data()["payloadBase64"] as? String,
                              let payload = Data(base64Encoded: payloadBase64),
                              let envelope = try? JSONDecoder().decode(RemoteEnvelope.self, from: payload) else {
                            continue
                        }

                        self.processedCloudClientMessageIds[sessionId, default: []].insert(document.documentID)
                        handler.noteCloudActivity()
                        self.handleMessage(envelope, from: handler)
                        document.reference.delete()
                    }
                }
            }
    }

    private func sendCloudEnvelope(_ envelope: RemoteEnvelope, userId: String, sessionId: String) {
        guard cloudSessionIds.contains(sessionId) else { return }
        do {
            let payload = try JSONEncoder().encode(envelope)
            let messageId = UUID().uuidString
            Firestore.firestore()
                .collection("users")
                .document(userId)
                .collection("remoteSessions")
                .document(sessionId)
                .collection("hostMessages")
                .document(messageId)
                .setData([
                    "id": messageId,
                    "createdAt": Date(),
                    "senderDeviceId": getOrCreateDeviceId(),
                    "payloadBase64": payload.base64EncodedString()
                ])

            // Intentionally do NOT touch the session document on every send.
            // Writing "status: connected" here causes the session listener to
            // re-fire on every message, producing write amplification and
            // Remote Anywhere flicker. The status is set once in
            // acceptCloudSession() and that is enough.
        } catch {
            print("[RemoteServer] Cloud send encode error: \(error)")
        }
    }

    /// Periodically drop sessions whose underlying transport has gone silent.
    /// Without this, a client that vanishes (phone locked, network dropped,
    /// process killed) leaves the server reporting "connected" indefinitely
    /// because neither TCP FIN nor Firestore tells us the peer is gone.
    private func startSessionLivenessSweep() {
        sessionLivenessTimer?.invalidate()
        sessionLivenessTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sweepDeadSessions()
            }
        }
    }

    private func sweepDeadSessions() {
        let now = Date()
        let threshold = now.addingTimeInterval(-Self.sessionStaleTimeout)
        let dead = sessions.values.filter { $0.lastActivityAt < threshold }
        for handler in dead {
            print("[RemoteServer] Session \(handler.id.prefix(8)) (\(handler.transportKind), device '\(handler.deviceName)') is stale — last activity \(Int(now.timeIntervalSince(handler.lastActivityAt)))s ago, dropping")
            handler.disconnect()
        }
    }

    private func endCloudSession(_ sessionId: String, reason: String) {
        cloudClientMessageListeners[sessionId]?.remove()
        cloudClientMessageListeners.removeValue(forKey: sessionId)
        processedCloudClientMessageIds.removeValue(forKey: sessionId)
        cloudSessionIds.remove(sessionId)

        if let userId = cloudRegisteredUserId ?? Auth.auth().currentUser?.uid {
            Firestore.firestore()
                .collection("users")
                .document(userId)
                .collection("remoteSessions")
                .document(sessionId)
                .setData([
                    "status": "ended",
                    "endedBy": "host",
                    "endedReason": reason,
                    "updatedAt": Date()
                ], merge: true)
        }

        updateCloudPresenceDocument()
        NotificationCenter.default.post(name: .remoteCloudStateChanged, object: nil)
    }

    // MARK: - Pairing

    func startPairing() -> String {
        if isPairingMode, let activePairingCode {
            showPairingNotification(code: activePairingCode)
            return activePairingCode
        }
        let code = pairingManager.generatePairingCode()
        activePairingCode = code
        isPairingMode = true
        showPairingNotification(code: code)
        NotificationCenter.default.post(
            name: .remotePairingStarted,
            object: nil,
            userInfo: ["pairingCode": code]
        )
        return code
    }

    func stopPairing() {
        guard isPairingMode || activePairingCode != nil else { return }
        isPairingMode = false
        activePairingCode = nil
        PairingOverlayController.shared.dismiss()
        NotificationCenter.default.post(name: .remotePairingStopped, object: nil)
    }

    func disconnectAllClients() {
        pendingPairingPresentationTasks.values.forEach { $0.cancel() }
        pendingPairingPresentationTasks.removeAll()

        pendingConnections.values.forEach { $0.cancel() }
        pendingConnections.removeAll()
        promotedConnectionIds.removeAll()
        pendingMessageBuffers.removeAll()
        pendingMultipeerPeers.removeAll()
        pendingMultipeerReceiveBuffers.removeAll()

        let allSessions = Array(sessions.values)
        for session in allSessions {
            session.disconnect()
        }

        mcAdvertiser?.stopAdvertisingPeer()
        mcAdvertiser = nil
        mcSession?.disconnect()
        mcSession = nil
        mcLocalPeerID = nil

        if isRunning {
            startMultipeerAdvertiser()
        }
    }

    func resetTrustedDevices() {
        disconnectAllClients()
        stopPairing()
        pairingManager.removeAllPairedDevices()
        updateCloudPresenceDocument()
    }

    var isCloudHostingEnabled: Bool {
        UserDefaults.standard.object(forKey: cloudHostingEnabledKey) as? Bool ?? true
    }

    var cloudStatusSummary: String {
        if !isCloudHostingEnabled {
            return "Remote Anywhere paused"
        }
        guard let user = Auth.auth().currentUser else {
            return "Sign in to enable Remote Anywhere"
        }
        if cloudSessionIds.isEmpty {
            return "Ready anywhere as \(user.email ?? "signed-in user")"
        }
        return "\(cloudSessionIds.count) remote session(s) active"
    }

    func setCloudHostingEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: cloudHostingEnabledKey)
        if enabled {
            configureCloudRemoteHosting()
        } else {
            stopCloudRemoteHosting(markOffline: true)
        }
        NotificationCenter.default.post(name: .remoteCloudStateChanged, object: nil)
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

        // Clipboard sync
        case MessageType.clipboardPush:
            if let content = try? envelope.decode(ClipboardContent.self), let text = content.text {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case MessageType.clipboardPull:
            let text = NSPasteboard.general.string(forType: .string)
            let content = ClipboardContent(text: text, hasImage: false, changeCount: NSPasteboard.general.changeCount)
            if let env = try? RemoteEnvelope(type: MessageType.clipboardContent, payload: content) {
                session.send(env)
            }

        // Port forwarding: HTTP proxy request
        case MessageType.tunnelHTTPRequest:
            if let req = try? envelope.decode(TunnelHTTPRequest.self) {
                Task { [weak self, weak session] in
                    guard let self, let session else { return }
                    let response = await self.tunnelManager.handleHTTPRequest(req)
                    if let env = try? RemoteEnvelope(type: MessageType.tunnelHTTPResponse, payload: response) {
                        session.send(env)
                    }
                }
            }

        default:
            break
        }
    }

    /// Handle an incoming message on a pending (unauthenticated) connection.
    private func handlePendingMessage(_ envelope: RemoteEnvelope, connectionId: String, connection: NWConnection) {
        let transport = PendingTransport.network(connectionId: connectionId, connection: connection)
        handlePendingMessage(envelope, pendingId: connectionId, transport: transport)
    }

    private enum PendingTransport {
        case network(connectionId: String, connection: NWConnection)
        case multipeer(pendingId: String, peer: MCPeerID)
    }

    private func handlePendingMessage(_ envelope: RemoteEnvelope, pendingId: String, transport: PendingTransport) {
        switch envelope.type {
        case MessageType.hello:
            // Send auth challenge
            let nonce = generateRandomBytes(32)
            if let challenge = try? RemoteEnvelope(type: MessageType.authChallenge, payload: AuthChallenge(nonce: nonce)) {
                sendPendingEnvelope(challenge, via: transport)
            }

        case MessageType.pairingRequest:
            cancelPairingPresentation(for: pendingId)
            guard let request = try? envelope.decode(PairingRequest.self) else { return }
            guard let code = activePairingCode else {
                sendPairingFailure(via: transport, error: "Pairing mode is not active")
                return
            }
            let response = pairingManager.validatePairing(request: request, code: code)
            if let respEnvelope = try? RemoteEnvelope(type: MessageType.pairingResponse, id: envelope.id, payload: response) {
                sendPendingEnvelope(respEnvelope, via: transport)
            }
            if response.success {
                stopPairing()
                promotePendingTransport(
                    pendingId: pendingId,
                    transport: transport,
                    deviceId: request.deviceId,
                    deviceName: request.deviceName
                )
            }

        case MessageType.authRequest:
            cancelPairingPresentation(for: pendingId)
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
                sendPendingEnvelope(respEnvelope, via: transport)
            }
            if result.success {
                let deviceName = pairingManager.pairedDevices.first { $0.deviceId == request.deviceId }?.deviceName ?? "Unknown"
                promotePendingTransport(
                    pendingId: pendingId,
                    transport: transport,
                    deviceId: request.deviceId,
                    deviceName: deviceName
                )
            } else {
                _ = startPairing()
            }

        default:
            // Buffer the message for replay after the connection is promoted.
            print("[RemoteServer] Buffering message type '\(envelope.type)' on pending client \(pendingId)")
            var buffer = pendingMessageBuffers[pendingId] ?? []
            buffer.append(envelope)
            pendingMessageBuffers[pendingId] = buffer
        }
    }

    // MARK: - Connection Management

    private func handleNewConnection(_ connection: NWConnection) {
        let connectionId = UUID().uuidString
        pendingConnections[connectionId] = connection
        print("[RemoteServer] New incoming connection: \(connectionId)")

        connection.stateUpdateHandler = { [weak self] state in
            nonisolated(unsafe) let state = state
            nonisolated(unsafe) let connection = connection
            Task { @MainActor in
                switch state {
                case .ready:
                    print("[RemoteServer] Pending connection ready: \(connectionId)")
                    // Send Hello so the client knows our identity
                    self?.sendHello(to: connection)
                    self?.schedulePairingPresentation(for: connectionId)
                    self?.startPendingReceive(connectionId: connectionId, connection: connection)
                case .failed(let error):
                    print("[RemoteServer] Pending connection failed: \(error)")
                    self?.cancelPairingPresentation(for: connectionId)
                    self?.pendingConnections.removeValue(forKey: connectionId)
                    self?.pendingMessageBuffers.removeValue(forKey: connectionId)
                case .cancelled:
                    self?.cancelPairingPresentation(for: connectionId)
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
            nonisolated(unsafe) let connection = connection
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
                    self.cancelPairingPresentation(for: connectionId)
                    self.pendingConnections.removeValue(forKey: connectionId)
                    self.pendingMessageBuffers.removeValue(forKey: connectionId)
                    self.pendingReceiveBuffers.removeValue(forKey: connectionId)
                } else if let error {
                    print("[RemoteServer] Pending connection \(connectionId) error: \(error)")
                    self.cancelPairingPresentation(for: connectionId)
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
        cancelPairingPresentation(for: connectionId)
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

    private func promotePendingTransport(pendingId: String, transport: PendingTransport, deviceId: String, deviceName: String) {
        switch transport {
        case .network(let connectionId, let connection):
            promoteConnection(connectionId: connectionId, connection: connection, deviceId: deviceId, deviceName: deviceName)
        case .multipeer(_, let peer):
            promoteMultipeerPeer(pendingId: pendingId, peer: peer, deviceId: deviceId, deviceName: deviceName)
        }
    }

    private func promoteMultipeerPeer(pendingId: String, peer: MCPeerID, deviceId: String, deviceName: String) {
        cancelPairingPresentation(for: pendingId)
        pendingMultipeerPeers.removeValue(forKey: pendingId)
        pendingMultipeerReceiveBuffers.removeValue(forKey: pendingId)

        let staleSessionIds = sessions.filter { $0.value.deviceId == deviceId }.map(\.key)
        for staleId in staleSessionIds {
            print("[RemoteServer] Replacing stale session \(staleId) for device \(deviceId)")
            sessions.removeValue(forKey: staleId)?.replaceQuietly()
        }

        guard let session = mcSession else { return }
        let sessionId = UUID().uuidString
        let handler = RemoteSessionHandler(
            id: sessionId,
            deviceId: deviceId,
            deviceName: deviceName,
            transport: .multipeer(session, peer)
        )
        sessions[sessionId] = handler

        print("[RemoteServer] Multipeer peer promoted to session \(sessionId) for device '\(deviceName)'")

        sendWorkspaceSnapshot(to: handler)

        if let buffered = pendingMessageBuffers.removeValue(forKey: pendingId) {
            print("[RemoteServer] Replaying \(buffered.count) buffered message(s) for multipeer session \(sessionId)")
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
        if cloudSessionIds.contains(session.id) {
            endCloudSession(session.id, reason: "session_disconnected")
        } else {
            updateCloudPresenceDocument()
        }
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
                nonisolated(unsafe) let state = state
                Task { @MainActor in self?.listenerStateChanged(state) }
            }
            nwListener.serviceRegistrationUpdateHandler = { [weak self] change in
                nonisolated(unsafe) let change = change
                Task { @MainActor in self?.serviceRegistrationChanged(change) }
            }
            nwListener.newConnectionHandler = { [weak self] connection in
                nonisolated(unsafe) let connection = connection
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

        // Clipboard
        case .clipboardPush(let content):
            if let text = content.text {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            sendCommandResponse(success: true, id: envelope.id, to: session)

        case .clipboardPull:
            let text = NSPasteboard.general.string(forType: .string)
            let content = ClipboardContent(text: text, hasImage: false, changeCount: NSPasteboard.general.changeCount)
            if let env = try? RemoteEnvelope(type: MessageType.clipboardContent, payload: content) {
                session.send(env)
            }
            sendCommandResponse(success: true, id: envelope.id, to: session)

        // File browser
        case .fileList(let path, let includeHidden):
            let response = fileHandler.listDirectory(path: path, includeHidden: includeHidden)
            if let env = try? RemoteEnvelope(type: MessageType.fileListResponse, payload: response) {
                session.send(env)
            }
            sendCommandResponse(success: response.error == nil, error: response.error, id: envelope.id, to: session)

        case .fileRead(let path):
            let response = fileHandler.readFile(path: path)
            if let env = try? RemoteEnvelope(type: MessageType.fileReadResponse, payload: response) {
                session.send(env)
            }
            sendCommandResponse(success: response.error == nil, error: response.error, id: envelope.id, to: session)

        case .fileWrite(let path, let content):
            let response = fileHandler.writeFile(path: path, content: content)
            if let env = try? RemoteEnvelope(type: MessageType.fileWriteResponse, payload: response) {
                session.send(env)
            }
            sendCommandResponse(success: response.success, error: response.error, id: envelope.id, to: session)

        // Session recording
        case .recordingStart(let name):
            let id = sessionRecorder.startRecording(name: name)
            sendCommandResponse(success: true, id: envelope.id, to: session)
            print("[Remote] Recording started: \(id)")

        case .recordingStop:
            sessionRecorder.stopRecording()
            sendCommandResponse(success: true, id: envelope.id, to: session)

        case .recordingList:
            let list = sessionRecorder.listRecordings()
            if let env = try? RemoteEnvelope(type: MessageType.recordingListResponse, payload: list) {
                session.send(env)
            }
            sendCommandResponse(success: true, id: envelope.id, to: session)

        case .recordingPlayback(let recordingId, let fromTimestamp):
            let chunk = sessionRecorder.playback(recordingId: recordingId, from: fromTimestamp)
            if let env = try? RemoteEnvelope(type: MessageType.recordingData, payload: chunk) {
                session.send(env)
            }
            sendCommandResponse(success: true, id: envelope.id, to: session)

        // Port forwarding
        case .tunnelOpen(let port, let label):
            let response = tunnelManager.openTunnel(port: port, label: label, sessionId: session.id)
            if let env = try? RemoteEnvelope(type: MessageType.tunnelOpened, payload: response) {
                session.send(env)
            }
            sendCommandResponse(success: response.success, error: response.error, id: envelope.id, to: session)

        case .tunnelClose(let tunnelId):
            tunnelManager.closeTunnel(tunnelId: tunnelId)
            sendCommandResponse(success: true, id: envelope.id, to: session)
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
    }

    private func sendPairingFailure(via transport: PendingTransport, error: String) {
        let response = PairingResponse(success: false, error: error, serverPublicKey: nil, authToken: nil)
        if let envelope = try? RemoteEnvelope(type: MessageType.pairingResponse, payload: response) {
            sendPendingEnvelope(envelope, via: transport)
        }
    }

    private func sendPendingEnvelope(_ envelope: RemoteEnvelope, via transport: PendingTransport) {
        guard let frame = try? RemoteFrame.encode(envelope) else { return }
        switch transport {
        case .network(_, let connection):
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    print("[RemoteServer] Failed to send pending network message: \(error)")
                }
            })
        case .multipeer(_, let peer):
            guard let session = mcSession else { return }
            do {
                try session.send(frame, toPeers: [peer], with: .reliable)
            } catch {
                print("[RemoteServer] Failed to send pending multipeer message: \(error)")
            }
        }
    }

    private func schedulePairingPresentation(for pendingId: String) {
        cancelPairingPresentation(for: pendingId)
        pendingPairingPresentationTasks[pendingId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.pairingPresentationDelayNanoseconds)
            guard let self, !Task.isCancelled else { return }
            guard self.pendingConnections[pendingId] != nil || self.pendingMultipeerPeers[pendingId] != nil else { return }
            let code = self.startPairing()
            print("[RemoteServer] ========================================")
            print("[RemoteServer] PAIRING CODE: \(code)")
            print("[RemoteServer] Enter this code on your iOS device")
            print("[RemoteServer] ========================================")
        }
    }

    private func cancelPairingPresentation(for pendingId: String) {
        pendingPairingPresentationTasks.removeValue(forKey: pendingId)?.cancel()
    }

    private func pendingMultipeerId(for peerName: String) -> String {
        "mc:\(peerName)"
    }

    /// Connected session count.
    var connectedDeviceCount: Int { sessions.count }

    /// All connected device names.
    var connectedDeviceNames: [String] { sessions.values.map(\.deviceName) }

    var currentPairingCode: String? { activePairingCode }

    var pairedDeviceCount: Int { pairingManager.pairedDevices.count }
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
        Task { @MainActor [weak self] in
            guard let self, self.mcSession != nil else { handler(false, nil); return }
            // Accept the transport first, then enforce pairing/auth at the app layer.
            // This keeps initial Bluetooth/USB pairing possible and lets paired devices reconnect
            // without the advertiser having to predict intent up front.
            handler(true, self.mcSession)
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
        // Capture the session pointer so we can ignore callbacks from a
        // previously-replaced MCSession instance (can happen when the advertiser
        // is restarted, e.g. via disconnectAllClients()).
        // MCSession isn't Sendable; we only use it for identity comparison on
        // the main actor, so marking the capture nonisolated(unsafe) is safe.
        nonisolated(unsafe) let callbackSession = session
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.mcSession === callbackSession else {
                print("[RemoteServer] Ignoring MCSession state from stale session instance for peer \(peerName)")
                return
            }
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
        nonisolated(unsafe) let callbackSession = session
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.mcSession === callbackSession else { return }
            if let handler = self.sessions.values.first(where: { $0.deviceName == peerName }) {
                handler.receivedMultipeerData(receivedData)
                return
            }

            let pendingId = self.pendingMultipeerId(for: peerName)
            guard let pendingPeer = self.pendingMultipeerPeers[pendingId] else { return }
            self.handlePendingMultipeerData(receivedData, pendingId: pendingId, peer: pendingPeer)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    @MainActor
    private func handleMultipeerConnected(peerName: String) {
        guard let session = mcSession else { return }
        guard let peer = session.connectedPeers.first(where: { $0.displayName == peerName }) else { return }
        let pendingId = pendingMultipeerId(for: peerName)
        pendingMultipeerPeers[pendingId] = peer
        pendingMultipeerReceiveBuffers[pendingId] = Data()
        schedulePairingPresentation(for: pendingId)
        sendHello(to: peer, session: session)
    }

    @MainActor
    private func handleMultipeerDisconnected(peerName: String) {
        let pendingId = pendingMultipeerId(for: peerName)
        if pendingMultipeerPeers.removeValue(forKey: pendingId) != nil {
            cancelPairingPresentation(for: pendingId)
            pendingMessageBuffers.removeValue(forKey: pendingId)
            pendingMultipeerReceiveBuffers.removeValue(forKey: pendingId)
        }
        if let session = sessions.values.first(where: { $0.deviceName == peerName }) {
            session.disconnect()
        }
    }

    private func handlePendingMultipeerData(_ data: Data, pendingId: String, peer: MCPeerID) {
        pendingMultipeerReceiveBuffers[pendingId, default: Data()].append(data)

        while let extracted = RemoteFrame.extract(from: pendingMultipeerReceiveBuffers[pendingId] ?? Data()) {
            pendingMultipeerReceiveBuffers[pendingId] = Data((pendingMultipeerReceiveBuffers[pendingId] ?? Data()).dropFirst(extracted.consumed))
            guard let envelope = try? JSONDecoder().decode(RemoteEnvelope.self, from: extracted.payload) else {
                print("[RemoteServer] Failed to decode envelope from pending multipeer peer \(peer.displayName)")
                continue
            }

            let transport = PendingTransport.multipeer(pendingId: pendingId, peer: peer)
            handlePendingMessage(envelope, pendingId: pendingId, transport: transport)
        }
    }

    private func sendHello(to peer: MCPeerID, session: MCSession) {
        let hello = HelloMessage(
            protocolVersion: 1,
            deviceName: Host.current().localizedName ?? "Clome",
            deviceId: getOrCreateDeviceId(),
            capabilities: ["terminal", "workspace", "editor"]
        )
        guard let envelope = try? RemoteEnvelope(type: MessageType.hello, payload: hello),
              let frame = try? RemoteFrame.encode(envelope) else { return }
        do {
            try session.send(frame, toPeers: [peer], with: .reliable)
        } catch {
            print("[RemoteServer] Failed to send multipeer hello: \(error)")
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
