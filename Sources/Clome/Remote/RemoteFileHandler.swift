// RemoteFileHandler.swift
// Clome — Handles remote file operations (list, read, write) for iOS clients.

import Foundation

@MainActor
final class RemoteFileHandler {

    /// Lists the contents of a directory. Respects TCC via FileAccessManager.
    func listDirectory(path: String, includeHidden: Bool) -> FileListResponse {
        let resolvedPath = (path as NSString).expandingTildeInPath

        // Security: reject path traversal
        if resolvedPath.contains("/../") || resolvedPath.hasSuffix("/..") {
            return FileListResponse(path: path, entries: [], error: "Invalid path")
        }

        // Ensure TCC access
        FileAccessManager.shared.ensureAccess(to: resolvedPath)

        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: resolvedPath)
            var entries: [FileEntry] = []

            for name in contents.sorted() {
                if !includeHidden && name.hasPrefix(".") { continue }

                let fullPath = (resolvedPath as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir)

                var size: Int64?
                var modifiedAt: Date?
                if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath) {
                    size = attrs[.size] as? Int64
                    modifiedAt = attrs[.modificationDate] as? Date
                }

                let iconHint = isDir.boolValue ? "folder.fill" : iconForExtension((name as NSString).pathExtension)

                entries.append(FileEntry(
                    name: name,
                    path: fullPath,
                    isDirectory: isDir.boolValue,
                    size: isDir.boolValue ? nil : size,
                    modifiedAt: modifiedAt,
                    gitStatus: nil,
                    iconHint: iconHint
                ))
            }

            // Sort: directories first, then alphabetically
            entries.sort { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }

            return FileListResponse(path: resolvedPath, entries: entries, error: nil)
        } catch {
            return FileListResponse(path: resolvedPath, entries: [], error: error.localizedDescription)
        }
    }

    /// Reads a file as UTF-8 text. Detects binary files.
    func readFile(path: String) -> FileReadResponse {
        let resolvedPath = (path as NSString).expandingTildeInPath

        if resolvedPath.contains("/../") || resolvedPath.hasSuffix("/..") {
            return FileReadResponse(path: path, content: nil, isBinary: false, error: "Invalid path", language: nil)
        }

        FileAccessManager.shared.ensureAccess(to: resolvedPath)

        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            return FileReadResponse(path: resolvedPath, content: nil, isBinary: false, error: "File not found", language: nil)
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: resolvedPath))

            // Binary detection: check for null bytes in first 8KB
            let checkRange = min(data.count, 8192)
            let isBinary = data.prefix(checkRange).contains(0x00)

            if isBinary {
                return FileReadResponse(path: resolvedPath, content: nil, isBinary: true, error: nil, language: nil)
            }

            guard let content = String(data: data, encoding: .utf8) else {
                return FileReadResponse(path: resolvedPath, content: nil, isBinary: true, error: nil, language: nil)
            }

            let ext = (resolvedPath as NSString).pathExtension
            let language = languageForExtension(ext)

            return FileReadResponse(path: resolvedPath, content: content, isBinary: false, error: nil, language: language)
        } catch {
            return FileReadResponse(path: resolvedPath, content: nil, isBinary: false, error: error.localizedDescription, language: nil)
        }
    }

    /// Writes text content to a file atomically.
    func writeFile(path: String, content: String) -> FileWriteResponse {
        let resolvedPath = (path as NSString).expandingTildeInPath

        if resolvedPath.contains("/../") || resolvedPath.hasSuffix("/..") {
            return FileWriteResponse(path: path, success: false, error: "Invalid path")
        }

        FileAccessManager.shared.ensureAccess(to: resolvedPath)

        do {
            try content.write(toFile: resolvedPath, atomically: true, encoding: .utf8)
            return FileWriteResponse(path: resolvedPath, success: true, error: nil)
        } catch {
            return FileWriteResponse(path: resolvedPath, success: false, error: error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func iconForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "swift": return "swift"
        case "py": return "doc.text"
        case "js", "ts", "jsx", "tsx": return "doc.text"
        case "json": return "curlybraces"
        case "md", "txt": return "doc.plaintext"
        case "html", "css": return "globe"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo"
        case "pdf": return "doc.richtext"
        case "zip", "tar", "gz": return "archivebox"
        default: return "doc"
        }
    }

    private func languageForExtension(_ ext: String) -> String? {
        switch ext.lowercased() {
        case "swift": return "swift"
        case "py": return "python"
        case "js": return "javascript"
        case "ts": return "typescript"
        case "jsx": return "javascriptreact"
        case "tsx": return "typescriptreact"
        case "json": return "json"
        case "md": return "markdown"
        case "html": return "html"
        case "css": return "css"
        case "rs": return "rust"
        case "go": return "go"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp": return "cpp"
        case "java": return "java"
        case "rb": return "ruby"
        case "sh", "bash", "zsh": return "shellscript"
        case "yml", "yaml": return "yaml"
        case "xml": return "xml"
        case "sql": return "sql"
        case "zig": return "zig"
        default: return nil
        }
    }
}
