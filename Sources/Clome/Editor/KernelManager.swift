import Foundation

/// Manages a Python bridge subprocess that wraps jupyter_client for kernel execution.
/// Automatically provisions a private venv with jupyter_client + ipykernel so the user
/// never needs to install anything globally.
@MainActor
final class KernelManager {

    // MARK: - Types

    enum State: Equatable {
        case disconnected
        case settingUp(String)   // message describes current setup step
        case starting
        case idle
        case busy
        case error(String)

        var displayString: String {
            switch self {
            case .disconnected: return "No Kernel"
            case .settingUp(let msg): return msg
            case .starting: return "Starting..."
            case .idle: return "Idle"
            case .busy: return "Busy"
            case .error(let msg): return "Error: \(msg)"
            }
        }
    }

    struct KernelSpec {
        let name: String
        let displayName: String
        let language: String
    }

    // MARK: - Properties

    private(set) var state: State = .disconnected {
        didSet {
            if state != oldValue {
                delegate?.kernelManager(self, didChangeState: state)
            }
        }
    }
    private(set) var availableKernels: [KernelSpec] = []
    private(set) var activeKernelName: String?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var readBuffer = Data()

    /// Currently executing cell's callbacks, keyed by exec_id
    private var activeExecId: String?
    private var activeOnOutput: (@MainActor (CellOutput) -> Void)?
    private var activeOnComplete: (@MainActor (Int?, String) -> Void)?

    /// Execution queue for serializing cell runs
    private struct QueuedExecution {
        let code: String
        let cellId: UUID
        let onOutput: @MainActor (CellOutput) -> Void
        let onComplete: @MainActor (Int?, String) -> Void
    }
    private var executionQueue: [QueuedExecution] = []

    weak var delegate: KernelManagerDelegate?

    // MARK: - Venv Management

    /// Directory for the Clome-managed kernel venv.
    private static var venvDir: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Clome/kernel-venv").path
    }

    /// Python executable inside our managed venv.
    private static var venvPython: String {
        "\(venvDir)/bin/python3"
    }

    /// Marker file we write after successful pip install to avoid re-checking every launch.
    private static var depsMarkerPath: String {
        "\(venvDir)/.clome-deps-installed"
    }

    /// Required pip packages.
    private static let requiredPackages = ["jupyter_client", "ipykernel"]

    /// Check if the venv exists and has deps installed.
    private static var isVenvReady: Bool {
        FileManager.default.fileExists(atPath: venvPython) &&
        FileManager.default.fileExists(atPath: depsMarkerPath)
    }

    /// Ensure the venv and dependencies are ready. Runs on a background queue.
    /// Calls back on main with success/failure.
    func ensureVenv(completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        let venvDir = Self.venvDir
        let venvPython = Self.venvPython
        let markerPath = Self.depsMarkerPath
        let packages = Self.requiredPackages

        // Fast path: already set up
        if Self.isVenvReady {
            completion(.success(venvPython))
            return
        }

        state = .settingUp("Setting up kernel environment...")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let fm = FileManager.default

                // 1. Create parent directory
                let parentDir = (venvDir as NSString).deletingLastPathComponent
                if !fm.fileExists(atPath: parentDir) {
                    try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
                }

                // 2. Find system python3
                let systemPython = Self.findSystemPython()
                guard let python = systemPython else {
                    throw KernelSetupError.pythonNotFound
                }

                // 3. Create venv if it doesn't exist
                if !fm.fileExists(atPath: venvPython) {
                    DispatchQueue.main.async { [weak self] in
                        self?.state = .settingUp("Creating Python environment...")
                    }

                    let venvResult = try Self.runProcess(
                        executable: python,
                        arguments: ["-m", "venv", venvDir]
                    )
                    guard venvResult.exitCode == 0 else {
                        throw KernelSetupError.venvCreationFailed(venvResult.stderr)
                    }
                }

                // 4. Install dependencies
                if !fm.fileExists(atPath: markerPath) {
                    DispatchQueue.main.async { [weak self] in
                        self?.state = .settingUp("Installing kernel packages...")
                    }

                    let pipResult = try Self.runProcess(
                        executable: venvPython,
                        arguments: ["-m", "pip", "install", "--quiet"] + packages
                    )
                    guard pipResult.exitCode == 0 else {
                        throw KernelSetupError.pipInstallFailed(pipResult.stderr)
                    }

                    // Write marker
                    let marker = "installed: \(packages.joined(separator: ", "))\ndate: \(Date())\n"
                    try marker.write(toFile: markerPath, atomically: true, encoding: .utf8)
                }

                DispatchQueue.main.async {
                    completion(.success(venvPython))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    /// Locate a usable system Python 3.
    private static func findSystemPython() -> String? {
        // Check common locations in priority order
        let candidates = [
            "/usr/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        // Try PATH via /usr/bin/env
        if let result = try? runProcess(executable: "/usr/bin/which", arguments: ["python3"]),
           result.exitCode == 0, !result.stdout.isEmpty {
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Run a process synchronously and capture output.
    private static func runProcess(executable: String, arguments: [String]) throws -> ProcessResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        // Use enriched PATH so venv pip can find git, compilers, etc.
        // in Release builds where Finder provides a minimal PATH.
        proc.environment = PythonEnvironmentManager.enrichedEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        try proc.run()
        proc.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return ProcessResult(
            exitCode: proc.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    enum KernelSetupError: LocalizedError {
        case pythonNotFound
        case venvCreationFailed(String)
        case pipInstallFailed(String)

        var errorDescription: String? {
            switch self {
            case .pythonNotFound:
                return "Python 3 not found. Install Python from python.org or via Homebrew (brew install python3)."
            case .venvCreationFailed(let detail):
                return "Failed to create Python environment: \(detail)"
            case .pipInstallFailed(let detail):
                return "Failed to install kernel packages: \(detail)"
            }
        }
    }

    // MARK: - Bridge Lifecycle

    func startBridge() {
        guard process == nil else { return }

        guard let bridgePath = findBridgeScript() else {
            state = .error("kernel_bridge.py not found")
            return
        }

        state = .starting

        // Ensure venv is ready, then launch bridge with the venv python
        ensureVenv { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let pythonPath):
                do {
                    try self.launchBridge(pythonPath: pythonPath, bridgePath: bridgePath)
                } catch {
                    self.state = .error("Failed to launch bridge: \(error.localizedDescription)")
                }
            case .failure(let error):
                self.state = .error(error.localizedDescription)
            }
        }
    }

    private func launchBridge(pythonPath: String, bridgePath: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [bridgePath]
        proc.environment = PythonEnvironmentManager.enrichedEnvironment().merging(
            ["PYTHONUNBUFFERED": "1"], uniquingKeysWith: { _, new in new }
        )

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                // EOF — bridge process closed stdout
                DispatchQueue.main.async {
                    self?.handleBridgeTermination()
                }
                return
            }
            DispatchQueue.main.async {
                self?.handleData(data)
            }
        }

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleBridgeTermination()
            }
        }

        try proc.run()
        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        state = .starting
    }

    func shutdown() {
        guard process != nil else { return }
        sendCommand(["action": "shutdown"])
        cleanupProcess()
        state = .disconnected
        activeKernelName = nil
    }

    private func cleanupProcess() {
        // Nil out readability handler before terminating to prevent double-fire
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdinPipe?.fileHandleForWriting.closeFile()
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        readBuffer = Data()
        clearActiveExecution()
        failAllQueued(message: "Bridge shut down")
    }

    private func clearActiveExecution() {
        activeExecId = nil
        activeOnOutput = nil
        activeOnComplete = nil
    }

    private func failAllQueued(message: String) {
        let queued = executionQueue
        executionQueue.removeAll()
        for entry in queued {
            entry.onComplete(nil, "error")
        }
    }

    private func handleBridgeTermination() {
        // Guard against double-fire from both readabilityHandler EOF and terminationHandler
        guard process != nil else { return }

        if let onComplete = activeOnComplete {
            onComplete(nil, "error")
        }
        clearActiveExecution()
        failAllQueued(message: "Bridge terminated")

        // Nil out readability handler to prevent further callbacks
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        if case .error = state { } else {
            state = .error("Bridge process terminated")
        }
    }

    // MARK: - Commands

    func discoverKernels() {
        sendCommand(["action": "list_kernels"])
    }

    func startKernel(name: String) {
        state = .starting
        activeKernelName = name
        sendCommand(["action": "start_kernel", "kernel_name": name])
    }

    /// Execute code. If the kernel is busy, the execution is queued and runs when the current one completes.
    func execute(code: String, cellId: UUID,
                 onOutput: @escaping @MainActor (CellOutput) -> Void,
                 onComplete: @escaping @MainActor (Int?, String) -> Void) {
        if state == .busy {
            executionQueue.append(QueuedExecution(code: code, cellId: cellId, onOutput: onOutput, onComplete: onComplete))
            return
        }
        startExecution(code: code, cellId: cellId, onOutput: onOutput, onComplete: onComplete)
    }

    private func startExecution(code: String, cellId: UUID,
                                onOutput: @escaping @MainActor (CellOutput) -> Void,
                                onComplete: @escaping @MainActor (Int?, String) -> Void) {
        let execId = UUID().uuidString
        activeExecId = execId
        activeOnOutput = onOutput
        activeOnComplete = onComplete
        state = .busy
        sendCommand([
            "action": "execute",
            "code": code,
            "exec_id": execId,
        ])
    }

    func interrupt() {
        sendCommand(["action": "interrupt"])
    }

    func restart() {
        state = .starting
        if let onComplete = activeOnComplete {
            onComplete(nil, "error")
        }
        clearActiveExecution()
        failAllQueued(message: "Kernel restarted")
        sendCommand(["action": "restart"])
    }

    // MARK: - Communication

    private func sendCommand(_ dict: [String: Any]) {
        guard let pipe = stdinPipe,
              process?.isRunning == true,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              var str = String(data: data, encoding: .utf8) else { return }
        str += "\n"
        pipe.fileHandleForWriting.write(str.data(using: .utf8)!)
    }

    // MARK: - Response Parsing

    private func handleData(_ data: Data) {
        readBuffer.append(data)
        while let newlineIndex = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = readBuffer[readBuffer.startIndex..<newlineIndex]
            readBuffer = Data(readBuffer[readBuffer.index(after: newlineIndex)...])

            guard !lineData.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            routeMessage(json)
        }
    }

    private func routeMessage(_ json: [String: Any]) {
        guard let type = json["type"] as? String else { return }

        switch type {
        case "ready":
            state = .idle
            discoverKernels()

        case "response":
            handleResponse(json)

        case "output":
            handleOutput(json)

        case "complete":
            handleComplete(json)

        case "error":
            let msg = json["message"] as? String ?? "Unknown error"
            state = .error(msg)

        default:
            break
        }
    }

    private func handleResponse(_ json: [String: Any]) {
        guard let action = json["action"] as? String else { return }

        switch action {
        case "list_kernels":
            if let kernels = json["kernels"] as? [[String: Any]] {
                availableKernels = kernels.map { k in
                    KernelSpec(
                        name: k["name"] as? String ?? "",
                        displayName: k["display_name"] as? String ?? "",
                        language: k["language"] as? String ?? ""
                    )
                }
                delegate?.kernelManager(self, didChangeState: state)
            }

        case "start_kernel":
            if (json["status"] as? String) == "ok" {
                state = .idle
            } else {
                state = .error(json["message"] as? String ?? "Failed to start kernel")
            }

        case "restart":
            if (json["status"] as? String) == "ok" {
                state = .idle
            } else {
                state = .error(json["message"] as? String ?? "Failed to restart kernel")
            }

        case "interrupt", "shutdown":
            break

        default:
            break
        }
    }

    private func handleOutput(_ json: [String: Any]) {
        guard let execId = json["exec_id"] as? String,
              execId == activeExecId,
              let onOutput = activeOnOutput else { return }

        let msgType = json["msg_type"] as? String ?? ""
        let output: CellOutput

        switch msgType {
        case "stream":
            output = CellOutput(
                output_type: .stream,
                text: .string(json["text"] as? String ?? ""),
                name: json["name"] as? String ?? "stdout"
            )

        case "execute_result", "display_data":
            let outputType: CellOutput.OutputType = msgType == "execute_result" ? .execute_result : .display_data
            var outData = OutputData()
            if let tp = json["text_plain"] as? String { outData.text_plain = .string(tp) }
            if let th = json["text_html"] as? String { outData.text_html = .string(th) }
            if let ip = json["image_png"] as? String { outData.image_png = ip }
            if let ij = json["image_jpeg"] as? String { outData.image_jpeg = ij }
            if let svg = json["image_svg"] as? String { outData.image_svg = .string(svg) }
            output = CellOutput(
                output_type: outputType,
                data: outData,
                execution_count: json["execution_count"] as? Int
            )

        case "error":
            output = CellOutput(
                output_type: .error,
                ename: json["ename"] as? String,
                evalue: json["evalue"] as? String,
                traceback: json["traceback"] as? [String]
            )

        default:
            return
        }

        onOutput(output)
    }

    private func handleComplete(_ json: [String: Any]) {
        guard let execId = json["exec_id"] as? String,
              execId == activeExecId,
              let onComplete = activeOnComplete else { return }

        let execCount = json["execution_count"] as? Int
        let status = json["status"] as? String ?? "ok"

        clearActiveExecution()

        // Dequeue next execution if available, otherwise go idle
        if let next = executionQueue.first {
            executionQueue.removeFirst()
            onComplete(execCount, status)
            startExecution(code: next.code, cellId: next.cellId, onOutput: next.onOutput, onComplete: next.onComplete)
        } else {
            state = .idle
            onComplete(execCount, status)
        }
    }

    // MARK: - Bridge Script Location

    private func findBridgeScript() -> String? {
        if let bundled = Bundle.main.path(forResource: "kernel_bridge", ofType: "py") {
            return bundled
        }
        // Development fallback: check near the executable
        let execDir = (Bundle.main.executablePath! as NSString).deletingLastPathComponent
        let nearby = (execDir as NSString).appendingPathComponent("../Resources/kernel_bridge.py")
        if FileManager.default.fileExists(atPath: nearby) {
            return nearby
        }
        return nil
    }
}

// MARK: - Delegate

@MainActor
protocol KernelManagerDelegate: AnyObject {
    func kernelManager(_ manager: KernelManager, didChangeState state: KernelManager.State)
}
