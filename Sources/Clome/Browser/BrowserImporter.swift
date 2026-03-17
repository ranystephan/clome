import Foundation
import SQLite3
import WebKit

// MARK: - Browser Type & Profile

/// The underlying browser engine/format family.
enum BrowserType: String, Sendable {
    case chrome   // Chrome, Arc, Brave, Edge — all Chromium-based
    case firefox
    case safari
}

/// A detected browser installation with its data directory.
struct BrowserProfile: Sendable {
    let name: String
    let icon: String          // SF Symbol name
    let profilePath: URL
    let browserType: BrowserType
}

// MARK: - Browser Detector

/// Checks the filesystem for known browser data directories.
struct BrowserDetector {

    static func detectInstalledBrowsers() -> [BrowserProfile] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default
        var results: [BrowserProfile] = []

        // Chrome
        let chromePath = home.appendingPathComponent("Library/Application Support/Google/Chrome/Default")
        if fm.fileExists(atPath: chromePath.path) {
            results.append(BrowserProfile(name: "Google Chrome", icon: "globe", profilePath: chromePath, browserType: .chrome))
        }

        // Arc
        let arcPath = home.appendingPathComponent("Library/Application Support/Arc/User Data/Default")
        if fm.fileExists(atPath: arcPath.path) {
            results.append(BrowserProfile(name: "Arc", icon: "circle.hexagongrid", profilePath: arcPath, browserType: .chrome))
        }

        // Brave
        let bravePath = home.appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser/Default")
        if fm.fileExists(atPath: bravePath.path) {
            results.append(BrowserProfile(name: "Brave", icon: "shield", profilePath: bravePath, browserType: .chrome))
        }

        // Edge
        let edgePath = home.appendingPathComponent("Library/Application Support/Microsoft Edge/Default")
        if fm.fileExists(atPath: edgePath.path) {
            results.append(BrowserProfile(name: "Microsoft Edge", icon: "globe.americas", profilePath: edgePath, browserType: .chrome))
        }

        // Firefox — find default profile
        let firefoxProfiles = home.appendingPathComponent("Library/Application Support/Firefox/Profiles")
        if let firefoxProfile = findFirefoxDefaultProfile(profilesDir: firefoxProfiles) {
            results.append(BrowserProfile(name: "Firefox", icon: "flame", profilePath: firefoxProfile, browserType: .firefox))
        }

        // Safari
        let safariPath = home.appendingPathComponent("Library/Safari")
        if fm.fileExists(atPath: safariPath.path) {
            results.append(BrowserProfile(name: "Safari", icon: "safari", profilePath: safariPath, browserType: .safari))
        }

        return results
    }

    /// Locate the default Firefox profile directory.
    /// Checks `profiles.ini` for `[Install…]` → `Default=` or `[Profile…]` → `Default=1`,
    /// then falls back to the first `*.default-release` directory.
    private static func findFirefoxDefaultProfile(profilesDir: URL) -> URL? {
        let fm = FileManager.default
        let firefoxBase = profilesDir.deletingLastPathComponent() // .../Firefox/
        let iniPath = firefoxBase.appendingPathComponent("profiles.ini")

        if let iniContents = try? String(contentsOf: iniPath, encoding: .utf8) {
            // Parse INI-style file
            var currentSection = ""
            var sectionData: [String: [String: String]] = [:]

            for line in iniContents.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                    currentSection = String(trimmed.dropFirst().dropLast())
                    sectionData[currentSection] = [:]
                } else if let eqIdx = trimmed.firstIndex(of: "=") {
                    let key = String(trimmed[trimmed.startIndex..<eqIdx])
                    let value = String(trimmed[trimmed.index(after: eqIdx)...])
                    sectionData[currentSection]?[key] = value
                }
            }

            // Look for [Install…] sections first — they have the most reliable Default key
            for (section, data) in sectionData {
                if section.hasPrefix("Install"), let relPath = data["Default"] {
                    let candidate = firefoxBase.appendingPathComponent(relPath)
                    if fm.fileExists(atPath: candidate.path) {
                        return candidate
                    }
                }
            }

            // Fall back to [Profile*] with Default=1
            for (section, data) in sectionData {
                if section.hasPrefix("Profile"), data["Default"] == "1", let relPath = data["Path"] {
                    let isRelative = data["IsRelative"] == "1"
                    let candidate = isRelative ? firefoxBase.appendingPathComponent(relPath) : URL(fileURLWithPath: relPath)
                    if fm.fileExists(atPath: candidate.path) {
                        return candidate
                    }
                }
            }
        }

        // Last resort: pick the first *.default-release directory
        if let contents = try? fm.contentsOfDirectory(at: profilesDir, includingPropertiesForKeys: nil) {
            for dir in contents where dir.lastPathComponent.hasSuffix(".default-release") {
                return dir
            }
            // Or any directory at all
            for dir in contents {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
                    return dir
                }
            }
        }

        return nil
    }
}

// MARK: - SQLite Helper

/// Minimal read-only SQLite query helper using the C API.
/// Returns rows as `[[String: String]]` dictionaries.
private func querySQLite(dbPath: String, query: String) -> [[String: String]] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
        return []
    }
    defer { sqlite3_close(db) }

    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
        return []
    }
    defer { sqlite3_finalize(stmt) }

    let colCount = sqlite3_column_count(stmt)
    var columnNames: [String] = []
    for i in 0..<colCount {
        if let cName = sqlite3_column_name(stmt, i) {
            columnNames.append(String(cString: cName))
        } else {
            columnNames.append("col\(i)")
        }
    }

    var rows: [[String: String]] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        var row: [String: String] = [:]
        for i in 0..<colCount {
            if let cText = sqlite3_column_text(stmt, i) {
                row[columnNames[Int(i)]] = String(cString: cText)
            }
        }
        rows.append(row)
    }
    return rows
}

/// Copy a database file to a temp location so we don't conflict with browser locks.
/// Returns the temp path on success, nil on failure.
private func copyToTemp(_ source: URL) -> URL? {
    let fm = FileManager.default
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clome-import-\(UUID().uuidString)")
    try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    let dest = tmpDir.appendingPathComponent(source.lastPathComponent)
    do {
        try fm.copyItem(at: source, to: dest)

        // Also copy WAL/SHM files if they exist (needed for SQLite WAL mode)
        for suffix in ["-wal", "-shm"] {
            let walSource = source.appendingPathExtension(String(suffix.dropFirst()))
            let walSourceAlt = URL(fileURLWithPath: source.path + suffix)
            for src in [walSource, walSourceAlt] {
                if fm.fileExists(atPath: src.path) {
                    let walDest = URL(fileURLWithPath: dest.path + suffix)
                    try? fm.copyItem(at: src, to: walDest)
                }
            }
        }

        return dest
    } catch {
        return nil
    }
}

/// Remove the temp directory that contains a copied database.
private func cleanupTemp(_ tempFile: URL) {
    try? FileManager.default.removeItem(at: tempFile.deletingLastPathComponent())
}

// MARK: - Browser Data Reader

/// Reads cookies, bookmarks, and history from a detected browser profile.
struct BrowserDataReader {

    // MARK: - Cookies

    static func readCookies(from profile: BrowserProfile) -> [HTTPCookie] {
        switch profile.browserType {
        case .chrome:
            return readChromeCookies(profilePath: profile.profilePath)
        case .firefox:
            return readFirefoxCookies(profilePath: profile.profilePath)
        case .safari:
            // Safari cookies are system-managed; skip import.
            return []
        }
    }

    private static func readChromeCookies(profilePath: URL) -> [HTTPCookie] {
        let cookiesDB = profilePath.appendingPathComponent("Cookies")
        guard FileManager.default.fileExists(atPath: cookiesDB.path),
              let tmp = copyToTemp(cookiesDB) else { return [] }
        defer { cleanupTemp(tmp) }

        // Only import cookies with a non-empty plain `value` column.
        // The `encrypted_value` column requires Keychain access to decrypt.
        let query = """
            SELECT host_key, name, value, path, expires_utc, is_secure, is_httponly
            FROM cookies
            WHERE value != ''
            """
        let rows = querySQLite(dbPath: tmp.path, query: query)
        return rows.compactMap { row in
            guard let domain = row["host_key"],
                  let name = row["name"],
                  let value = row["value"],
                  !value.isEmpty else { return nil }

            let path = row["path"] ?? "/"
            let isSecure = row["is_secure"] == "1"
            let isHttpOnly = row["is_httponly"] == "1"

            // Chrome stores expiry as microseconds since 1601-01-01 00:00:00 UTC.
            var expiresDate: Date?
            if let expiresStr = row["expires_utc"], let microseconds = Int64(expiresStr), microseconds > 0 {
                // Offset from 1601-01-01 to 1970-01-01 in microseconds
                let epochOffset: Int64 = 11_644_473_600_000_000
                let unixMicro = microseconds - epochOffset
                expiresDate = Date(timeIntervalSince1970: Double(unixMicro) / 1_000_000.0)
            }

            var properties: [HTTPCookiePropertyKey: Any] = [
                .domain: domain,
                .path: path,
                .name: name,
                .value: value,
                .secure: isSecure ? "TRUE" : "FALSE",
            ]
            if isHttpOnly {
                properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
            }
            if let expires = expiresDate {
                properties[.expires] = expires
            }

            return HTTPCookie(properties: properties)
        }
    }

    private static func readFirefoxCookies(profilePath: URL) -> [HTTPCookie] {
        let cookiesDB = profilePath.appendingPathComponent("cookies.sqlite")
        guard FileManager.default.fileExists(atPath: cookiesDB.path),
              let tmp = copyToTemp(cookiesDB) else { return [] }
        defer { cleanupTemp(tmp) }

        let query = "SELECT host, name, value, path, expiry, isSecure, isHttpOnly FROM moz_cookies"
        let rows = querySQLite(dbPath: tmp.path, query: query)
        return rows.compactMap { row in
            guard let domain = row["host"],
                  let name = row["name"],
                  let value = row["value"] else { return nil }

            let path = row["path"] ?? "/"
            let isSecure = row["isSecure"] == "1"
            let isHttpOnly = row["isHttpOnly"] == "1"

            var expiresDate: Date?
            if let expiryStr = row["expiry"], let expiry = Int64(expiryStr), expiry > 0 {
                expiresDate = Date(timeIntervalSince1970: Double(expiry))
            }

            var properties: [HTTPCookiePropertyKey: Any] = [
                .domain: domain,
                .path: path,
                .name: name,
                .value: value,
                .secure: isSecure ? "TRUE" : "FALSE",
            ]
            if isHttpOnly {
                properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
            }
            if let expires = expiresDate {
                properties[.expires] = expires
            }

            return HTTPCookie(properties: properties)
        }
    }

    // MARK: - Bookmarks

    static func readBookmarks(from profile: BrowserProfile) -> [(title: String, url: String)] {
        switch profile.browserType {
        case .chrome:
            return readChromeBookmarks(profilePath: profile.profilePath)
        case .firefox:
            return readFirefoxBookmarks(profilePath: profile.profilePath)
        case .safari:
            return readSafariBookmarks(profilePath: profile.profilePath)
        }
    }

    private static func readChromeBookmarks(profilePath: URL) -> [(title: String, url: String)] {
        let bookmarksFile = profilePath.appendingPathComponent("Bookmarks")
        guard let data = try? Data(contentsOf: bookmarksFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else { return [] }

        var results: [(title: String, url: String)] = []

        for key in ["bookmark_bar", "other", "synced"] {
            if let folder = roots[key] as? [String: Any],
               let children = folder["children"] as? [[String: Any]] {
                collectChromeBookmarks(children: children, into: &results)
            }
        }

        return results
    }

    private static func collectChromeBookmarks(children: [[String: Any]], into results: inout [(title: String, url: String)]) {
        for child in children {
            let type = child["type"] as? String ?? ""
            if type == "url" {
                let name = child["name"] as? String ?? ""
                let url = child["url"] as? String ?? ""
                if !url.isEmpty {
                    results.append((title: name, url: url))
                }
            } else if type == "folder" {
                if let subChildren = child["children"] as? [[String: Any]] {
                    collectChromeBookmarks(children: subChildren, into: &results)
                }
            }
        }
    }

    private static func readFirefoxBookmarks(profilePath: URL) -> [(title: String, url: String)] {
        let placesDB = profilePath.appendingPathComponent("places.sqlite")
        guard FileManager.default.fileExists(atPath: placesDB.path),
              let tmp = copyToTemp(placesDB) else { return [] }
        defer { cleanupTemp(tmp) }

        let query = """
            SELECT b.title, p.url
            FROM moz_bookmarks b
            JOIN moz_places p ON b.fk = p.id
            WHERE b.type = 1 AND p.url IS NOT NULL AND p.url != ''
            """
        let rows = querySQLite(dbPath: tmp.path, query: query)
        return rows.compactMap { row in
            guard let url = row["url"], !url.isEmpty else { return nil }
            let title = row["title"] ?? ""
            return (title: title, url: url)
        }
    }

    private static func readSafariBookmarks(profilePath: URL) -> [(title: String, url: String)] {
        let plistPath = profilePath.appendingPathComponent("Bookmarks.plist")
        guard let data = try? Data(contentsOf: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return []
        }

        var results: [(title: String, url: String)] = []
        collectSafariBookmarks(dict: plist, into: &results)
        return results
    }

    private static func collectSafariBookmarks(dict: [String: Any], into results: inout [(title: String, url: String)]) {
        let type = dict["WebBookmarkType"] as? String ?? ""

        if type == "WebBookmarkTypeLeaf" {
            let url = dict["URLString"] as? String ?? ""
            var title = ""
            if let uriDict = dict["URIDictionary"] as? [String: Any] {
                title = uriDict["title"] as? String ?? ""
            }
            if !url.isEmpty {
                results.append((title: title, url: url))
            }
        }

        if let children = dict["Children"] as? [[String: Any]] {
            for child in children {
                collectSafariBookmarks(dict: child, into: &results)
            }
        }
    }

    // MARK: - History

    static func readHistory(from profile: BrowserProfile) -> [(title: String, url: String, date: Date)] {
        switch profile.browserType {
        case .chrome:
            return readChromeHistory(profilePath: profile.profilePath)
        case .firefox:
            return readFirefoxHistory(profilePath: profile.profilePath)
        case .safari:
            return readSafariHistory(profilePath: profile.profilePath)
        }
    }

    private static func readChromeHistory(profilePath: URL) -> [(title: String, url: String, date: Date)] {
        let historyDB = profilePath.appendingPathComponent("History")
        guard FileManager.default.fileExists(atPath: historyDB.path),
              let tmp = copyToTemp(historyDB) else { return [] }
        defer { cleanupTemp(tmp) }

        let query = "SELECT url, title, last_visit_time FROM urls ORDER BY last_visit_time DESC LIMIT 1000"
        let rows = querySQLite(dbPath: tmp.path, query: query)

        // Chrome timestamps: microseconds since 1601-01-01 00:00:00 UTC
        let epochOffset: Int64 = 11_644_473_600_000_000

        return rows.compactMap { row in
            guard let url = row["url"], !url.isEmpty else { return nil }
            let title = row["title"] ?? ""
            var date = Date()
            if let timeStr = row["last_visit_time"], let microseconds = Int64(timeStr), microseconds > 0 {
                let unixMicro = microseconds - epochOffset
                date = Date(timeIntervalSince1970: Double(unixMicro) / 1_000_000.0)
            }
            return (title: title, url: url, date: date)
        }
    }

    private static func readFirefoxHistory(profilePath: URL) -> [(title: String, url: String, date: Date)] {
        let placesDB = profilePath.appendingPathComponent("places.sqlite")
        guard FileManager.default.fileExists(atPath: placesDB.path),
              let tmp = copyToTemp(placesDB) else { return [] }
        defer { cleanupTemp(tmp) }

        // Firefox timestamps: microseconds since Unix epoch
        let query = """
            SELECT p.url, p.title, MAX(v.visit_date) as last_visit
            FROM moz_places p
            JOIN moz_historyvisits v ON p.id = v.place_id
            WHERE p.url IS NOT NULL AND p.url != ''
            GROUP BY p.id
            ORDER BY last_visit DESC
            LIMIT 1000
            """
        let rows = querySQLite(dbPath: tmp.path, query: query)
        return rows.compactMap { row in
            guard let url = row["url"], !url.isEmpty else { return nil }
            let title = row["title"] ?? ""
            var date = Date()
            if let timeStr = row["last_visit"], let microseconds = Int64(timeStr), microseconds > 0 {
                date = Date(timeIntervalSince1970: Double(microseconds) / 1_000_000.0)
            }
            return (title: title, url: url, date: date)
        }
    }

    private static func readSafariHistory(profilePath: URL) -> [(title: String, url: String, date: Date)] {
        let historyDB = profilePath.appendingPathComponent("History.db")
        guard FileManager.default.fileExists(atPath: historyDB.path),
              let tmp = copyToTemp(historyDB) else { return [] }
        defer { cleanupTemp(tmp) }

        // Safari visit_time: seconds since 2001-01-01 00:00:00 UTC (Core Data / NSDate epoch)
        let query = """
            SELECT hi.url, hi.domain_expansion, MAX(hv.visit_time) as last_visit
            FROM history_items hi
            JOIN history_visits hv ON hi.id = hv.history_item
            WHERE hi.url IS NOT NULL AND hi.url != ''
            GROUP BY hi.id
            ORDER BY last_visit DESC
            LIMIT 1000
            """
        let rows = querySQLite(dbPath: tmp.path, query: query)

        // Core Data epoch offset: seconds between 2001-01-01 and 1970-01-01
        let coreDataEpoch: TimeInterval = 978_307_200.0

        return rows.compactMap { row in
            guard let url = row["url"], !url.isEmpty else { return nil }
            let title = row["domain_expansion"] ?? ""
            var date = Date()
            if let timeStr = row["last_visit"], let seconds = Double(timeStr) {
                date = Date(timeIntervalSince1970: seconds + coreDataEpoch)
            }
            return (title: title, url: url, date: date)
        }
    }
}

// MARK: - Import Options & Result

struct ImportOptions: Sendable {
    var cookies: Bool = true
    var bookmarks: Bool = true
    var history: Bool = true
}

struct ImportResult: Sendable {
    var cookiesImported: Int = 0
    var bookmarksImported: Int = 0
    var historyImported: Int = 0
    var errors: [String] = []
}

// MARK: - Import Coordinator

/// Orchestrates importing browser data into Clome.
@MainActor
struct BrowserImportCoordinator {

    /// Import data from the given browser profile into Clome.
    ///
    /// - Parameters:
    ///   - profile: The detected browser profile to import from.
    ///   - options: Which data types to import.
    ///   - cookieStore: The WKHTTPCookieStore to inject cookies into.
    ///   - completion: Called on the main thread with the import results.
    static func performImport(
        from profile: BrowserProfile,
        options: ImportOptions,
        cookieStore: WKHTTPCookieStore,
        completion: @escaping @MainActor (ImportResult) -> Void
    ) {
        // Perform heavy I/O off the main thread
        Task.detached {
            var result = ImportResult()

            // --- Cookies ---
            var importedCookies: [HTTPCookie] = []
            if options.cookies && profile.browserType != .safari {
                let cookies = BrowserDataReader.readCookies(from: profile)
                if cookies.isEmpty && profile.browserType != .safari {
                    result.errors.append("No importable cookies found (encrypted cookies are skipped).")
                }
                importedCookies = cookies
                result.cookiesImported = cookies.count
            }

            // --- Bookmarks ---
            var importedBookmarks: [(title: String, url: String)] = []
            if options.bookmarks {
                let bookmarks = BrowserDataReader.readBookmarks(from: profile)
                if bookmarks.isEmpty {
                    result.errors.append("No bookmarks found in \(profile.name).")
                }
                importedBookmarks = bookmarks
                result.bookmarksImported = bookmarks.count
            }

            // --- History ---
            var importedHistory: [(title: String, url: String, date: Date)] = []
            if options.history {
                let history = BrowserDataReader.readHistory(from: profile)
                if history.isEmpty {
                    result.errors.append("No history found in \(profile.name).")
                }
                importedHistory = history
                result.historyImported = history.count
            }

            // Switch to main actor for UI-bound operations
            let finalResult = result
            let finalCookies = importedCookies
            let finalBookmarks = importedBookmarks
            let finalHistory = importedHistory

            await MainActor.run {
                // Inject cookies into WKHTTPCookieStore
                for cookie in finalCookies {
                    cookieStore.setCookie(cookie)
                }

                // Add bookmarks via BookmarkManager
                for bookmark in finalBookmarks {
                    BookmarkManager.shared.addBookmark(title: bookmark.title, url: bookmark.url)
                }

                // Add history via BookmarkManager
                // Insert in reverse chronological order (oldest first so newest ends up on top)
                for entry in finalHistory.reversed() {
                    BookmarkManager.shared.addHistory(title: entry.title, url: entry.url)
                }

                completion(finalResult)
            }
        }
    }
}
