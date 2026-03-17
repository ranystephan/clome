import Foundation

/// Compiles LaTeX files to PDF using available system LaTeX compilers.
class LatexCompiler {
    enum CompilerEngine: String, CaseIterable {
        case pdflatex
        case xelatex
        case lualatex

        var displayName: String {
            switch self {
            case .pdflatex: return "pdfLaTeX"
            case .xelatex: return "XeLaTeX"
            case .lualatex: return "LuaLaTeX"
            }
        }
    }

    struct CompileResult {
        let success: Bool
        let pdfPath: String?
        let log: String
        let errors: [String]
        let warnings: [String]
    }

    /// Discovers which LaTeX engines are installed on the system.
    static func availableEngines() -> [CompilerEngine] {
        CompilerEngine.allCases.filter { engine in
            findExecutable(engine.rawValue) != nil
        }
    }

    /// Compiles a .tex file to PDF.
    /// - Parameters:
    ///   - texPath: Absolute path to the .tex file.
    ///   - engine: Which LaTeX engine to use.
    ///   - runs: Number of compilation passes (2 for references/TOC).
    ///   - completion: Called on main thread with the result.
    static func compile(
        texPath: String,
        engine: CompilerEngine = .pdflatex,
        runs: Int = 2,
        completion: @escaping (CompileResult) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = compileSync(texPath: texPath, engine: engine, runs: runs)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private static func compileSync(texPath: String, engine: CompilerEngine, runs: Int) -> CompileResult {
        guard let execPath = findExecutable(engine.rawValue) else {
            return CompileResult(
                success: false,
                pdfPath: nil,
                log: "\(engine.displayName) not found. Install a LaTeX distribution (e.g., MacTeX or BasicTeX).",
                errors: ["\(engine.displayName) is not installed"],
                warnings: []
            )
        }

        let directory = (texPath as NSString).deletingLastPathComponent
        let baseName = ((texPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let pdfPath = (directory as NSString).appendingPathComponent("\(baseName).pdf")

        var fullLog = ""
        var lastExitCode: Int32 = 0

        for pass in 1...runs {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: execPath)
            process.arguments = [
                "-interaction=nonstopmode",
                "-file-line-error",
                "-halt-on-error",
                texPath
            ]
            process.currentDirectoryURL = URL(fileURLWithPath: directory)

            // Inherit common PATH locations for LaTeX
            var env = ProcessInfo.processInfo.environment
            let extraPaths = ["/usr/local/bin", "/opt/homebrew/bin", "/Library/TeX/texbin", "/usr/texbin"]
            let existingPath = env["PATH"] ?? "/usr/bin:/bin"
            env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return CompileResult(
                    success: false,
                    pdfPath: nil,
                    log: "Failed to launch \(engine.displayName): \(error.localizedDescription)",
                    errors: ["Failed to launch compiler"],
                    warnings: []
                )
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            fullLog += "=== Pass \(pass)/\(runs) ===\n\(output)\n"
            lastExitCode = process.terminationStatus

            // If first pass fails hard, don't continue
            if lastExitCode != 0 && pass < runs {
                // Check for fatal errors (missing files, syntax errors)
                if output.contains("Fatal error") || output.contains("Emergency stop") {
                    break
                }
            }
        }

        let errors = parseErrors(from: fullLog)
        let warnings = parseWarnings(from: fullLog)
        let pdfExists = FileManager.default.fileExists(atPath: pdfPath)

        return CompileResult(
            success: lastExitCode == 0 && pdfExists,
            pdfPath: pdfExists ? pdfPath : nil,
            log: fullLog,
            errors: errors,
            warnings: warnings
        )
    }

    private static func parseErrors(from log: String) -> [String] {
        var errors: [String] = []
        for line in log.components(separatedBy: .newlines) {
            // file:line: error format from -file-line-error
            if line.contains(": error:") || line.contains("! ") {
                let cleaned = line.trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty && !errors.contains(cleaned) {
                    errors.append(cleaned)
                }
            }
        }
        return errors
    }

    private static func parseWarnings(from log: String) -> [String] {
        var warnings: [String] = []
        for line in log.components(separatedBy: .newlines) {
            if line.contains("Warning:") || line.contains("Underfull") || line.contains("Overfull") {
                let cleaned = line.trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty && !warnings.contains(cleaned) {
                    warnings.append(cleaned)
                }
            }
        }
        return warnings
    }

    private static func findExecutable(_ name: String) -> String? {
        // Check common LaTeX installation paths
        let paths = [
            "/Library/TeX/texbin/\(name)",
            "/usr/texbin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fallback: use `which`
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let result = result, !result.isEmpty {
                    return result
                }
            }
        } catch {}

        return nil
    }
}
