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
    /// - Parameter projectDirectory: Optional project directory to search for local venvs
    static func discoverEnvironments(projectDirectory: String? = nil) -> [PythonEnvironment] {
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

        // 3. Local venvs and project environments
        envs.append(contentsOf: discoverLocalVenvs(registeredKernels: registeredKernels, projectDirectory: projectDirectory))
        
        // 4. Project-specific environments (Poetry, Pipenv, conda)
        if let projectDir = projectDirectory {
            envs.append(contentsOf: discoverPoetryEnvs(projectDirectory: projectDir, registeredKernels: registeredKernels))
            envs.append(contentsOf: discoverPipenvEnvs(projectDirectory: projectDir, registeredKernels: registeredKernels))
            envs.append(contentsOf: discoverProjectCondaEnvs(projectDirectory: projectDir, registeredKernels: registeredKernels))
        }

        // 5. Pyenv
        envs.append(contentsOf: discoverPyenvVersions(registeredKernels: registeredKernels))

        // 6. System/Homebrew
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

    private static func discoverLocalVenvs(registeredKernels: Set<String>, projectDirectory: String? = nil) -> [PythonEnvironment] {
        var envs: [PythonEnvironment] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // Build search directories list
        var searchDirs: [String] = []
        
        // 1. Project directory (if provided) - highest priority
        if let projectDir = projectDirectory {
            searchDirs.append(projectDir)
        }
        
        // 2. Current working directory (if different from project directory)
        let currentDir = FileManager.default.currentDirectoryPath
        if projectDirectory != currentDir {
            searchDirs.append(currentDir)
        }
        
        // 3. Home directory - lowest priority, but only check common venv names
        searchDirs.append(home)

        for (index, dir) in searchDirs.enumerated() {
            if index < searchDirs.count - 1 {
                // For project and current directory: scan all subdirectories for venvs
                envs.append(contentsOf: scanDirectoryForVirtualEnvs(dir, parentName: (dir as NSString).lastPathComponent, registeredKernels: registeredKernels))
            } else {
                // For home directory: only check common names to avoid massive scan
                let commonVenvNames = [".venv", "venv", "env", ".env"]
                for venvName in commonVenvNames {
                    if let venv = checkForVirtualEnv(at: "\(dir)/\(venvName)", parentName: "home", registeredKernels: registeredKernels) {
                        envs.append(venv)
                    }
                }
            }
        }

        return envs
    }
    
    /// Scan a directory for potential virtual environments by checking subdirectories
    /// for venv indicators (pyvenv.cfg, bin/python structure, etc.)
    private static func scanDirectoryForVirtualEnvs(_ directory: String, parentName: String, registeredKernels: Set<String>) -> [PythonEnvironment] {
        var envs: [PythonEnvironment] = []
        let fm = FileManager.default
        
        guard let contents = try? fm.contentsOfDirectory(atPath: directory) else { return envs }
        
        // Skip certain directories that are unlikely to contain venvs
        let skipDirs: Set<String> = [
            ".git", ".svn", ".hg", // Version control
            "node_modules", ".npm", // Node.js
            "__pycache__", ".pytest_cache", // Python cache
            ".idea", ".vscode", // IDEs
            "build", "dist", ".build", // Build outputs
            "target", "out", "bin", "obj", // Other build outputs
            ".DS_Store", "Thumbs.db", // OS files
            ".mypy_cache", ".tox", // Python tools
            "coverage", ".coverage", // Coverage tools
            "logs", "log", "tmp", "temp", // Temp/log dirs
        ]
        
        for item in contents {
            // Skip hidden files/dirs (except common venv names)
            if item.hasPrefix(".") && !item.hasPrefix(".env") && item != ".venv" {
                continue
            }
            
            // Skip known non-venv directories
            if skipDirs.contains(item.lowercased()) {
                continue
            }
            
            let itemPath = "\(directory)/\(item)"
            
            // Check if it's a directory
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: itemPath, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            
            // Check if this directory is a virtual environment
            if let venv = checkForVirtualEnv(at: itemPath, parentName: parentName, registeredKernels: registeredKernels) {
                envs.append(venv)
            }
        }
        
        return envs
    }
    
    /// Check if a specific directory is a Python virtual environment
    /// Returns PythonEnvironment if valid, nil otherwise
    private static func checkForVirtualEnv(at path: String, parentName: String, registeredKernels: Set<String>) -> PythonEnvironment? {
        let fm = FileManager.default
        let dirName = (path as NSString).lastPathComponent
        
        // Primary indicator: pyvenv.cfg file (created by python -m venv and similar tools)
        let pyvenvCfgPath = "\(path)/pyvenv.cfg"
        let hasPyvenvCfg = fm.fileExists(atPath: pyvenvCfgPath)
        
        // Secondary indicators: Python executable locations
        let pythonPaths = [
            "\(path)/bin/python3",      // Unix/macOS
            "\(path)/bin/python",       // Unix/macOS fallback
            "\(path)/Scripts/python.exe", // Windows
            "\(path)/Scripts/python3.exe" // Windows
        ]
        
        var validPythonPath: String?
        for pythonPath in pythonPaths {
            if fm.fileExists(atPath: pythonPath) {
                validPythonPath = pythonPath
                break
            }
        }
        
        // Tertiary indicators: activation scripts
        let activationPaths = [
            "\(path)/bin/activate",        // Unix/macOS
            "\(path)/Scripts/activate.bat", // Windows batch
            "\(path)/Scripts/Activate.ps1"  // Windows PowerShell
        ]
        let hasActivationScript = activationPaths.contains { fm.fileExists(atPath: $0) }
        
        // Site-packages directory
        let sitePackagesPaths = [
            "\(path)/lib/python*/site-packages",
            "\(path)/Lib/site-packages"  // Windows
        ]
        let hasSitePackages = sitePackagesPaths.contains { pattern in
            // Simple glob check for lib/python*/site-packages
            if pattern.contains("*") {
                let libDir = "\(path)/lib"
                guard let libContents = try? fm.contentsOfDirectory(atPath: libDir) else { return false }
                return libContents.contains { subdir in
                    subdir.hasPrefix("python") && fm.fileExists(atPath: "\(libDir)/\(subdir)/site-packages")
                }
            } else {
                return fm.fileExists(atPath: pattern)
            }
        }
        
        // Scoring system: we need at least 2 indicators for confidence
        var score = 0
        if hasPyvenvCfg { score += 2 }           // Strong indicator
        if validPythonPath != nil { score += 2 } // Strong indicator
        if hasActivationScript { score += 1 }    // Moderate indicator
        if hasSitePackages { score += 1 }        // Moderate indicator
        
        // Must have at least a Python executable and one other indicator
        guard let pythonPath = validPythonPath, score >= 2 else {
            return nil
        }
        
        // Create display name
        let displayName = parentName == "home" ? "\(dirName) (home)" : "\(parentName)/\(dirName)"
        let id = "venv:\(path)"
        
        return PythonEnvironment(
            id: id,
            name: displayName,
            pythonPath: pythonPath,
            type: .venv,
            isKernelRegistered: registeredKernels.contains(pythonPath)
        )
    }
    
    /// Discover Poetry virtual environments
    /// Poetry stores venvs in various locations and uses pyproject.toml as a marker
    private static func discoverPoetryEnvs(projectDirectory: String, registeredKernels: Set<String>) -> [PythonEnvironment] {
        var envs: [PythonEnvironment] = []
        let fm = FileManager.default
        
        // Check if this is a Poetry project
        let pyprojectPath = "\(projectDirectory)/pyproject.toml"
        guard fm.fileExists(atPath: pyprojectPath) else { return envs }
        
        // Try to read pyproject.toml to confirm it's a Poetry project
        if let content = try? String(contentsOfFile: pyprojectPath),
           content.contains("[tool.poetry]") {
            
            // Try to get Poetry environment info using `poetry env info --path`
            if let result = try? runProcess("/usr/bin/env", args: ["poetry", "env", "info", "--path"], workingDirectory: projectDirectory),
               result.exitCode == 0 {
                let envPath = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !envPath.isEmpty && fm.fileExists(atPath: envPath) {
                    let pythonPath = "\(envPath)/bin/python3"
                    if fm.fileExists(atPath: pythonPath) {
                        let projectName = (projectDirectory as NSString).lastPathComponent
                        envs.append(PythonEnvironment(
                            id: "poetry:\(envPath)",
                            name: "\(projectName) (poetry)",
                            pythonPath: pythonPath,
                            type: .venv,
                            isKernelRegistered: registeredKernels.contains(pythonPath)
                        ))
                    }
                }
            }
            
            // Fallback: check common Poetry venv locations
            if envs.isEmpty {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let projectName = (projectDirectory as NSString).lastPathComponent
                let poetryVenvPaths = [
                    "\(home)/Library/Caches/pypoetry/virtualenvs", // macOS
                    "\(home)/.cache/pypoetry/virtualenvs",          // Linux
                    "\(projectDirectory)/.venv"                      // In-project (poetry config virtualenvs.in-project true)
                ]
                
                for venvDir in poetryVenvPaths {
                    guard let contents = try? fm.contentsOfDirectory(atPath: venvDir) else { continue }
                    
                    for envName in contents {
                        // Poetry typically names envs with project name + hash
                        if envName.hasPrefix(projectName) || venvDir.hasSuffix(".venv") {
                            let envPath = venvDir.hasSuffix(".venv") ? venvDir : "\(venvDir)/\(envName)"
                            let pythonPath = "\(envPath)/bin/python3"
                            if fm.fileExists(atPath: pythonPath) {
                                envs.append(PythonEnvironment(
                                    id: "poetry:\(envPath)",
                                    name: "\(projectName) (poetry)",
                                    pythonPath: pythonPath,
                                    type: .venv,
                                    isKernelRegistered: registeredKernels.contains(pythonPath)
                                ))
                                break // Only take the first match per directory
                            }
                        }
                    }
                }
            }
        }
        
        return envs
    }
    
    /// Discover Pipenv virtual environments
    /// Pipenv uses Pipfile as a marker and stores venvs in various locations
    private static func discoverPipenvEnvs(projectDirectory: String, registeredKernels: Set<String>) -> [PythonEnvironment] {
        var envs: [PythonEnvironment] = []
        let fm = FileManager.default
        
        // Check if this is a Pipenv project
        let pipfilePath = "\(projectDirectory)/Pipfile"
        guard fm.fileExists(atPath: pipfilePath) else { return envs }
        
        // Try to get Pipenv environment path using `pipenv --venv`
        if let result = try? runProcess("/usr/bin/env", args: ["pipenv", "--venv"], workingDirectory: projectDirectory),
           result.exitCode == 0 {
            let envPath = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !envPath.isEmpty && fm.fileExists(atPath: envPath) {
                let pythonPath = "\(envPath)/bin/python3"
                if fm.fileExists(atPath: pythonPath) {
                    let projectName = (projectDirectory as NSString).lastPathComponent
                    envs.append(PythonEnvironment(
                        id: "pipenv:\(envPath)",
                        name: "\(projectName) (pipenv)",
                        pythonPath: pythonPath,
                        type: .venv,
                        isKernelRegistered: registeredKernels.contains(pythonPath)
                    ))
                }
            }
        }
        
        // Fallback: check common Pipenv venv locations
        if envs.isEmpty {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let projectName = (projectDirectory as NSString).lastPathComponent
            let pipenvVenvPaths = [
                "\(home)/.local/share/virtualenvs",  // Default location
                "\(home)/.virtualenvs"               // Alternative location
            ]
            
            for venvDir in pipenvVenvPaths {
                guard let contents = try? fm.contentsOfDirectory(atPath: venvDir) else { continue }
                
                for envName in contents {
                    // Pipenv typically names envs with project name + hash
                    if envName.hasPrefix(projectName) {
                        let envPath = "\(venvDir)/\(envName)"
                        let pythonPath = "\(envPath)/bin/python3"
                        if fm.fileExists(atPath: pythonPath) {
                            envs.append(PythonEnvironment(
                                id: "pipenv:\(envPath)",
                                name: "\(projectName) (pipenv)",
                                pythonPath: pythonPath,
                                type: .venv,
                                isKernelRegistered: registeredKernels.contains(pythonPath)
                            ))
                            break // Only take the first match per directory
                        }
                    }
                }
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
    
    /// Discover conda environments within or related to the project directory
    /// This includes environment.yml based environments and local conda envs
    private static func discoverProjectCondaEnvs(projectDirectory: String, registeredKernels: Set<String>) -> [PythonEnvironment] {
        var envs: [PythonEnvironment] = []
        let fm = FileManager.default
        let projectName = (projectDirectory as NSString).lastPathComponent
        
        // Check for conda environment files
        let condaFiles = ["environment.yml", "environment.yaml", "conda.yml", "conda.yaml"]
        var hasCondaFile = false
        
        for file in condaFiles {
            if fm.fileExists(atPath: "\(projectDirectory)/\(file)") {
                hasCondaFile = true
                break
            }
        }
        
        // If there's a conda environment file, try to find the corresponding environment
        if hasCondaFile {
            // Try to get the current conda environment for this directory
            if let result = try? runProcess("/usr/bin/env", args: ["conda", "info", "--json"], workingDirectory: projectDirectory),
               result.exitCode == 0 {
                // Parse JSON to get active environment
                if let data = result.stdout.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let activeEnvPath = json["active_prefix"] as? String {
                    let pythonPath = "\(activeEnvPath)/bin/python3"
                    if fm.fileExists(atPath: pythonPath) {
                        envs.append(PythonEnvironment(
                            id: "conda-project:\(activeEnvPath)",
                            name: "\(projectName) (conda)",
                            pythonPath: pythonPath,
                            type: .conda,
                            isKernelRegistered: registeredKernels.contains(pythonPath)
                        ))
                    }
                }
            }
            
            // Also check if there's a conda environment with the project name
            if let result = try? runProcess("/usr/bin/env", args: ["conda", "env", "list", "--json"]),
               result.exitCode == 0 {
                if let data = result.stdout.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let envsList = json["envs"] as? [String] {
                    
                    for envPath in envsList {
                        let envName = (envPath as NSString).lastPathComponent
                        // Check if environment name matches project or is located in project
                        if envName == projectName || envPath.hasPrefix(projectDirectory) {
                            let pythonPath = "\(envPath)/bin/python3"
                            if fm.fileExists(atPath: pythonPath) {
                                let id = "conda-project:\(envPath)"
                                // Avoid duplicates
                                if !envs.contains(where: { $0.id == id }) {
                                    envs.append(PythonEnvironment(
                                        id: id,
                                        name: "\(envName) (conda-project)",
                                        pythonPath: pythonPath,
                                        type: .conda,
                                        isKernelRegistered: registeredKernels.contains(pythonPath)
                                    ))
                                }
                            }
                        }
                    }
                }
            }
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

    private static func runProcess(_ executable: String, args: [String], workingDirectory: String? = nil) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.environment = ProcessInfo.processInfo.environment
        
        if let workingDir = workingDirectory {
            proc.currentDirectoryURL = URL(fileURLWithPath: workingDir)
        }

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
