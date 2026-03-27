import Foundation
import os.log

/// Lightweight crash reporter that writes crash logs to ~/Library/Logs/Clome/
/// and installs signal + uncaught exception handlers so crashes leave a trail.
@MainActor
final class CrashReporter {
    static let shared = CrashReporter()

    private static let logger = Logger(subsystem: "com.clome.app", category: "crash")
    static let appLogger = Logger(subsystem: "com.clome.app", category: "general")

    private let logDirectory: URL
    private let sessionLogURL: URL

    private init() {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Clome", isDirectory: true)
        self.logDirectory = logsDir
        self.sessionLogURL = logsDir.appendingPathComponent("session.log")

        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    }

    /// Call once at app launch, before anything else.
    func install() {
        // Rotate old logs (keep last 10 crash logs)
        rotateLogs()

        // Write a session-start marker
        appendToSessionLog("=== Clome session started at \(ISO8601DateFormatter().string(from: Date())) ===")
        appendToSessionLog("macOS \(ProcessInfo.processInfo.operatingSystemVersionString), pid \(ProcessInfo.processInfo.processIdentifier)")

        // Uncaught Objective-C exceptions
        NSSetUncaughtExceptionHandler { exception in
            let info = """
            UNCAUGHT EXCEPTION: \(exception.name.rawValue)
            Reason: \(exception.reason ?? "nil")
            Stack:
            \(exception.callStackSymbols.joined(separator: "\n"))
            """
            CrashReporter.writeCrashLog(info)
            CrashReporter.logger.fault("Uncaught exception: \(exception.name.rawValue) — \(exception.reason ?? "nil")")
        }

        // POSIX signals: SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGTRAP
        for sig: Int32 in [SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGTRAP] {
            signal(sig) { signum in
                let name: String
                switch signum {
                case SIGABRT: name = "SIGABRT"
                case SIGSEGV: name = "SIGSEGV"
                case SIGBUS:  name = "SIGBUS"
                case SIGFPE:  name = "SIGFPE"
                case SIGILL:  name = "SIGILL"
                case SIGTRAP: name = "SIGTRAP"
                default:      name = "SIG\(signum)"
                }

                var info = "FATAL SIGNAL: \(name) (\(signum))\nStack:\n"
                // Capture backtrace (signal-safe-ish on Darwin)
                var callstack = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
                let frames = backtrace(&callstack, Int32(callstack.count))
                if let symbols = backtrace_symbols(&callstack, frames) {
                    for i in 0..<Int(frames) {
                        if let sym = symbols[i] {
                            info += String(cString: sym) + "\n"
                        }
                    }
                    free(symbols)
                }

                CrashReporter.writeCrashLog(info)

                // Re-raise so macOS generates the standard crash report too
                signal(signum, SIG_DFL)
                raise(signum)
            }
        }

        Self.logger.info("CrashReporter installed")
    }

    /// Log an event to the session log (non-fatal).
    func log(_ message: String, category: String = "general") {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [\(category)] \(message)"
        appendToSessionLog(line)
        Self.appLogger.info("\(message)")
    }

    /// Log a warning.
    func warn(_ message: String, category: String = "general") {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [WARN/\(category)] \(message)"
        appendToSessionLog(line)
        Self.appLogger.warning("\(message)")
    }

    /// Log an error (non-fatal).
    func error(_ message: String, category: String = "general") {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [ERROR/\(category)] \(message)"
        appendToSessionLog(line)
        Self.appLogger.error("\(message)")
    }

    /// Write the session-end marker.
    func logCleanShutdown() {
        appendToSessionLog("=== Clome session ended cleanly at \(ISO8601DateFormatter().string(from: Date())) ===\n")
    }

    /// Returns the path to the logs directory for user inspection.
    var logsPath: String {
        logDirectory.path
    }

    // MARK: - Private

    private func appendToSessionLog(_ text: String) {
        let data = (text + "\n").data(using: .utf8) ?? Data()
        if FileManager.default.fileExists(atPath: sessionLogURL.path) {
            if let handle = try? FileHandle(forWritingTo: sessionLogURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: sessionLogURL)
        }
    }

    /// Write a crash report to a timestamped file. Called from signal/exception handlers
    /// so must be as simple as possible (no allocations ideally, but we accept the trade-off).
    nonisolated static func writeCrashLog(_ info: String) {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Clome", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "crash_\(formatter.string(from: Date())).log"
        let url = logsDir.appendingPathComponent(filename)

        let header = """
        Clome Crash Report
        Date: \(Date())
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        PID: \(ProcessInfo.processInfo.processIdentifier)

        \(info)
        """

        try? header.data(using: .utf8)?.write(to: url)

        // Also append to session log
        let sessionURL = logsDir.appendingPathComponent("session.log")
        if let handle = try? FileHandle(forWritingTo: sessionURL) {
            handle.seekToEndOfFile()
            handle.write(("\n!!! CRASH: \(info.prefix(200))...\nFull report: \(url.path)\n").data(using: .utf8) ?? Data())
            handle.closeFile()
        }
    }

    private func rotateLogs() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let crashLogs = files.filter { $0.lastPathComponent.hasPrefix("crash_") }
            .sorted { ($0.lastPathComponent) > ($1.lastPathComponent) }

        // Keep only the 10 most recent crash logs
        if crashLogs.count > 10 {
            for old in crashLogs.dropFirst(10) {
                try? FileManager.default.removeItem(at: old)
            }
        }

        // Truncate session log if over 1MB
        if let attrs = try? FileManager.default.attributesOfItem(atPath: sessionLogURL.path),
           let size = attrs[.size] as? Int, size > 1_000_000 {
            // Keep last 500KB
            if let data = try? Data(contentsOf: sessionLogURL) {
                let keep = data.suffix(500_000)
                try? keep.write(to: sessionLogURL)
            }
        }
    }
}
