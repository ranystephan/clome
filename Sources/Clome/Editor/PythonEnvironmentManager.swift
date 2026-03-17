import Foundation

/// Represents a discovered Python environment on the system.
struct PythonEnvironment: Identifiable, Equatable {
    let id: String           // unique key, e.g. "conda:myenv" or "venv:/path"
    let name: String         // human-readable, e.g. "myenv (conda)" or "Data Science (.venv)"
    let pythonPath: String   // absolute path to python3 executable
    let type: EnvironmentType
    let isKernelRegistered: Bool  // whether this env has a jupyter kernelspec

    enum EnvironmentType: String {
        case clome       // Clome built-in venv
        case conda       // conda/mamba environment
        case venv        // virtualenv / python -m venv
        case system      // system or homebrew python
        case pyenv       // pyenv-managed
    }

    /// Short label for the status bar.
    var shortLabel: String {
        switch type {
        case .clome: return "Clome (built-in)"
        case .conda: return name
        case .venv: return name
        case .system: return "System Python"
        case .pyenv: return name
        }
    }
}

/// Discovers Python environments and can register them as Jupyter kernels.
/// All discovery runs on a background queue; results are delivered on main.
final class PythonEnvironmentManager {

    /// Discover all Python environments on the system.
    /// Returns results on a background queue — caller must dispatch to main.
    static func discoverEnvironments() -> [PythonEnvironment] {
        var envs: [PythonEnvironment] = []
        let registeredKernels = discoverRegisteredKernelPythons()

        // 1. Clome built-in
        let clomeVenv = clomeVenvPython()
        if let path = clomeVenv, FileManager.default.fileExists(atPath: path) {
            envs.append(PythonEnvironment(
                id: "clome:built-in",
                name: "Clome (built-in)",
                pythonPath: path,
                type: .clome,
                isKernelRegistered: registeredKernels.contains(path)
            ))
        }

        // 2. Conda environments
        envs.append(contentsOf: discoverCondaEnvs(registeredKernels: registeredKernels))

        // 3. Common venvs in the project directory or home
        envs.append(contentsOf: discoverLocalVenvs(registeredKernels: registeredKernels))

        // 4. Pyenv
        envs.append(contentsOf: discoverPyenvVersions(registeredKernels: registeredKernels))

        // 5. System/Homebrew
        envs.append(contentsOf: discoverSystemPythons(registeredKernels: registeredKernels))

        return envs
    }

    /// Register a Python environment as a Jupyter kernel so it appears in the kernel picker.
    /// Installs ipykernel if needed, then runs `python -m ipykernel install --user`.
    static func registerKernel(for env: PythonEnvironment, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // 1. Check/install ipykernel
                let checkResult = try runProcess(env.pythonPath, args: ["-c", "import ipykernel"])
                if checkResult.exitCode != 0 {
                    let installResult = try runProcess(env.pythonPath, args: ["-m", "pip", "install", "--quiet", "ipykernel"])
                    guard installResult.exitCode == 0 else {
                        throw EnvError.installFailed("Failed to install ipykernel: \(installResult.stderr)")
                    }
                }

                // 2. Register the kernel
                let kernelName = sanitizeKernelName(env.name)
                let displayName = env.name
                let regResult = try runProcess(env.pythonPath, args: [
                    "-m", "ipykernel", "install", "--user",
                    "--name", kernelName,
                    "--display-name", displayName
                ])
                guard regResult.exitCode == 0 else {
                    throw EnvError.registrationFailed(regResult.stderr)
                }

                DispatchQueue.main.async {
                    completion(.success(kernelName))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    /// Install a package into the environment that a kernel is running in.
    /// Uses the kernel's Python to run pip.
    static func installPackage(_ packageName: String, pythonPath: String,
                               completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try runProcess(pythonPath, args: ["-m", "pip", "install", packageName])
                if result.exitCode == 0 {
                    let output = result.stdout.isEmpty ? "Installed \(packageName)" : result.stdout
                    DispatchQueue.main.async { completion(.success(output)) }
                } else {
                    DispatchQueue.main.async {
                        completion(.failure(EnvError.installFailed(result.stderr)))
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Discovery Helpers

    private static func clomeVenvPython() -> String? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let path = appSupport.appendingPathComponent("Clome/kernel-venv/bin/python3").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private static func discoverCondaEnvs(registeredKernels: Set<String>) -> [PythonEnvironment] {
        var envs: [PythonEnvironment] = []

        // Try `conda info --envs` first
        if let result = try? runProcess("/usr/bin/env", args: ["conda", "info", "--envs"]),
           result.exitCode == 0 {
            for line in result.stdout.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                // Lines look like: "myenv    /Users/foo/miniconda3/envs/myenv"
                // or "base  *  /Users/foo/miniconda3"
                let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty && $0 != "*" }
                guard parts.count >= 2, let envPath = parts.last else { continue }
                let pythonPath = "\(envPath)/bin/python3"
                guard FileManager.default.fileExists(atPath: pythonPath) else { continue }
                let name = (envPath as NSString).lastPathComponent
                let displayName = name == "miniconda3" || name == "anaconda3" ? "base (conda)" : "\(name) (conda)"
                envs.append(PythonEnvironment(
                    id: "conda:\(name)",
                    name: displayName,
                    pythonPath: pythonPath,
                    type: .conda,
                    isKernelRegistered: registeredKernels.contains(pythonPath)
                ))
            }
        }

        // Fallback: scan common conda locations
        if envs.isEmpty {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let condaDirs = [
                "\(home)/miniconda3/envs",
                "\(home)/anaconda3/envs",
                "\(home)/miniforge3/envs",
                "\(home)/mambaforge/envs",
                "/opt/homebrew/Caskroom/miniconda/base/envs",
            ]
            // Also check base envs
            let baseDirs = [
                "\(home)/miniconda3",
                "\(home)/anaconda3",
                "\(home)/miniforge3",
                "\(home)/mambaforge",
            ]
            for baseDir in baseDirs {
                let pythonPath = "\(baseDir)/bin/python3"
                if FileManager.default.fileExists(atPath: pythonPath) {
                    let name = (baseDir as NSString).lastPathComponent
                    envs.append(PythonEnvironment(
                        id: "conda:base-\(name)",
                        name: "base (\(name))",
                        pythonPath: pythonPath,
                        type: .conda,
                        isKernelRegistered: registeredKernels.contains(pythonPath)
                    ))
                }
            }
            for condaDir in condaDirs {
                guard let contents = try? FileManager.default.contentsOfDirectory(atPath: condaDir) else { continue }
                for envName in contents {
                    let pythonPath = "\(condaDir)/\(envName)/bin/python3"
                    guard FileManager.default.fileExists(atPath: pythonPath) else { continue }
                    envs.append(PythonEnvironment(
                        id: "conda:\(envName)",
                        name: "\(envName) (conda)",
                        pythonPath: pythonPath,
                        type: .conda,
                        isKernelRegistered: registeredKernels.contains(pythonPath)
                    ))
                }
            }
        }

        return envs
    }

    private static func discoverLocalVenvs(registeredKernels: Set<String>) -> [PythonEnvironment] {
        var envs: [PythonEnvironment] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // Common venv directory names
        let venvNames = [".venv", "venv", "env", ".env"]

        // Check current working directory and home
        let searchDirs = [
            FileManager.default.currentDirectoryPath,
            home,
        ]

        for dir in searchDirs {
            for venvName in venvNames {
                let pythonPath = "\(dir)/\(venvName)/bin/python3"
                guard FileManager.default.fileExists(atPath: pythonPath) else { continue }
                let projectName = (dir as NSString).lastPathComponent
                let displayName = dir == home ? "\(venvName) (home)" : "\(projectName)/\(venvName)"
                let id = "venv:\(dir)/\(venvName)"
                // Avoid duplicates
                guard !envs.contains(where: { $0.id == id }) else { continue }
                envs.append(PythonEnvironment(
                    id: id,
                    name: displayName,
                    pythonPath: pythonPath,
                    type: .venv,
                    isKernelRegistered: registeredKernels.contains(pythonPath)
                ))
            }
        }

        return envs
    }

    private static func discoverPyenvVersions(registeredKernels: Set<String>) -> [PythonEnvironment] {
        var envs: [PythonEnvironment] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let pyenvDir = "\(home)/.pyenv/versions"

        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: pyenvDir) else {
            return envs
        }

        for version in contents {
            let pythonPath = "\(pyenvDir)/\(version)/bin/python3"
            guard FileManager.default.fileExists(atPath: pythonPath) else { continue }
            envs.append(PythonEnvironment(
                id: "pyenv:\(version)",
                name: "\(version) (pyenv)",
                pythonPath: pythonPath,
                type: .pyenv,
                isKernelRegistered: registeredKernels.contains(pythonPath)
            ))
        }

        return envs
    }

    private static func discoverSystemPythons(registeredKernels: Set<String>) -> [PythonEnvironment] {
        var envs: [PythonEnvironment] = []
        let candidates = [
            ("/opt/homebrew/bin/python3", "Homebrew Python"),
            ("/usr/local/bin/python3", "Python 3 (usr/local)"),
            ("/usr/bin/python3", "System Python"),
        ]
        for (path, name) in candidates {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            // Resolve symlinks to avoid duplicating the same python
            let resolved = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? path
            let id = "system:\(resolved)"
            guard !envs.contains(where: { $0.id == id }) else { continue }
            envs.append(PythonEnvironment(
                id: id,
                name: name,
                pythonPath: path,
                type: .system,
                isKernelRegistered: registeredKernels.contains(path)
            ))
        }
        return envs
    }

    /// Discover which Python paths are already registered as Jupyter kernels.
    private static func discoverRegisteredKernelPythons() -> Set<String> {
        var paths = Set<String>()
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // Standard kernelspec locations
        let kernelDirs = [
            "\(home)/Library/Jupyter/kernels",
            "\(home)/.local/share/jupyter/kernels",
            "/usr/local/share/jupyter/kernels",
            "/usr/share/jupyter/kernels",
        ]

        for kernelDir in kernelDirs {
            guard let specs = try? FileManager.default.contentsOfDirectory(atPath: kernelDir) else { continue }
            for spec in specs {
                let jsonPath = "\(kernelDir)/\(spec)/kernel.json"
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let argv = json["argv"] as? [String],
                      let pythonPath = argv.first else { continue }
                paths.insert(pythonPath)
            }
        }

        return paths
    }

    private static func sanitizeKernelName(_ name: String) -> String {
        // Kernel names must be alphanumeric + hyphens + underscores
        let cleaned = name.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
        return cleaned.isEmpty ? "clome-env" : cleaned
    }

    // MARK: - Process Helper

    private static func runProcess(_ executable: String, args: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.environment = ProcessInfo.processInfo.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        try proc.run()
        proc.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return (
            proc.terminationStatus,
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    enum EnvError: LocalizedError {
        case installFailed(String)
        case registrationFailed(String)

        var errorDescription: String? {
            switch self {
            case .installFailed(let msg): return msg
            case .registrationFailed(let msg): return "Kernel registration failed: \(msg)"
            }
        }
    }
}
