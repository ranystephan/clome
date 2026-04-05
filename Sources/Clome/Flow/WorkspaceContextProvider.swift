import Foundation

enum WorkspaceContextProvider {

    /// Generates a directory tree string for the project at the given path.
    /// Respects .gitignore patterns, caps at maxDepth levels and maxFiles total.
    static func directoryTree(at path: String, maxDepth: Int = 3, maxFiles: Int = 200) -> String {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)

        guard fm.fileExists(atPath: path) else { return "" }

        // Load .gitignore patterns
        let ignorePatterns = loadGitignore(at: path)

        var lines: [String] = []
        var fileCount = 0

        buildTree(url: url, prefix: "", depth: 0, maxDepth: maxDepth,
                  maxFiles: maxFiles, fileCount: &fileCount,
                  ignorePatterns: ignorePatterns, lines: &lines, fm: fm)

        if fileCount >= maxFiles {
            lines.append("  ... (\(fileCount)+ files, truncated)")
        }

        return lines.joined(separator: "\n")
    }

    /// Reads file content with line limit.
    static func fileContent(at path: String, maxLines: Int = 100) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        if lines.count <= maxLines {
            return text
        }
        return lines.prefix(maxLines).joined(separator: "\n") + "\n... (\(lines.count) lines total)"
    }

    // MARK: - Private

    private static func buildTree(url: URL, prefix: String, depth: Int, maxDepth: Int,
                                   maxFiles: Int, fileCount: inout Int,
                                   ignorePatterns: [String], lines: inout [String],
                                   fm: FileManager) {
        guard depth < maxDepth, fileCount < maxFiles else { return }

        guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { return }

        let sorted = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }

        // Separate directories and files
        var dirs: [URL] = []
        var files: [URL] = []
        for item in sorted {
            let name = item.lastPathComponent
            if shouldIgnore(name: name, patterns: ignorePatterns) { continue }

            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                dirs.append(item)
            } else {
                files.append(item)
            }
        }

        for dir in dirs {
            guard fileCount < maxFiles else { break }
            lines.append("\(prefix)\(dir.lastPathComponent)/")
            buildTree(url: dir, prefix: prefix + "  ", depth: depth + 1, maxDepth: maxDepth,
                      maxFiles: maxFiles, fileCount: &fileCount,
                      ignorePatterns: ignorePatterns, lines: &lines, fm: fm)
        }

        for file in files {
            guard fileCount < maxFiles else { break }
            lines.append("\(prefix)\(file.lastPathComponent)")
            fileCount += 1
        }
    }

    private static func loadGitignore(at projectPath: String) -> [String] {
        let gitignorePath = (projectPath as NSString).appendingPathComponent(".gitignore")
        guard let data = FileManager.default.contents(atPath: gitignorePath),
              let text = String(data: data, encoding: .utf8) else {
            return defaultIgnorePatterns
        }
        var patterns = defaultIgnorePatterns
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                patterns.append(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            }
        }
        return patterns
    }

    private static func shouldIgnore(name: String, patterns: [String]) -> Bool {
        for pattern in patterns {
            if name == pattern { return true }
            if pattern.hasSuffix("*") {
                let prefix = String(pattern.dropLast())
                if name.hasPrefix(prefix) { return true }
            }
            if pattern.hasPrefix("*") {
                let suffix = String(pattern.dropFirst())
                if name.hasSuffix(suffix) { return true }
            }
        }
        return false
    }

    private static let defaultIgnorePatterns = [
        "node_modules", ".git", ".build", ".DS_Store", "DerivedData",
        "Pods", ".swiftpm", "__pycache__", ".env", ".venv",
        "dist", "build", ".next", ".nuxt", "target",
        "vendor", ".cursor", ".history", "*.xcodeproj"
    ]
}
