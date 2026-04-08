import Foundation

extension Notification.Name {
    static let browserDataDidChange = Notification.Name("clomeBrowserDataDidChange")
}

/// Simple JSON-backed bookmark and history manager.
/// Stores at ~/.config/clome/bookmarks.json and ~/.config/clome/history.json
@MainActor
class BookmarkManager {
    static let shared = BookmarkManager()

    struct Bookmark: Codable, Identifiable {
        let id: UUID
        var title: String
        var url: String
        var dateAdded: Date

        init(title: String, url: String) {
            self.id = UUID()
            self.title = title
            self.url = url
            self.dateAdded = Date()
        }
    }

    struct HistoryEntry: Codable {
        var title: String
        var url: String
        var date: Date
    }

    private(set) var bookmarks: [Bookmark] = []
    private(set) var history: [HistoryEntry] = []

    private let configDir: URL
    private let bookmarksFile: URL
    private let historyFile: URL
    private let maxHistory = 500

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        configDir = home.appendingPathComponent(".config/clome")
        bookmarksFile = configDir.appendingPathComponent("bookmarks.json")
        historyFile = configDir.appendingPathComponent("history.json")

        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        loadBookmarks()
        loadHistory()
    }

    // MARK: - Bookmarks

    func addBookmark(title: String, url: String) {
        guard !bookmarks.contains(where: { $0.url == url }) else { return }
        bookmarks.append(Bookmark(title: title, url: url))
        saveBookmarks()
    }

    func removeBookmark(url: String) {
        bookmarks.removeAll { $0.url == url }
        saveBookmarks()
    }

    func isBookmarked(url: String) -> Bool {
        bookmarks.contains { $0.url == url }
    }

    // MARK: - History

    func addHistory(title: String, url: String) {
        // Don't duplicate sequential visits to the same URL
        if history.first?.url == url { return }
        history.insert(HistoryEntry(title: title, url: url, date: Date()), at: 0)
        if history.count > maxHistory {
            history = Array(history.prefix(maxHistory))
        }
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    func recentHistory(limit: Int, dedupeByHost: Bool = true) -> [HistoryEntry] {
        guard dedupeByHost else {
            return Array(history.prefix(limit))
        }

        var results: [HistoryEntry] = []
        var seenHosts = Set<String>()

        for entry in history {
            guard let url = URL(string: entry.url) else { continue }
            let key = (url.host ?? entry.url).lowercased()
            guard !seenHosts.contains(key) else { continue }
            seenHosts.insert(key)
            results.append(entry)
            if results.count >= limit { break }
        }

        return results
    }

    // MARK: - Persistence

    private func loadBookmarks() {
        guard let data = try? Data(contentsOf: bookmarksFile) else { return }
        bookmarks = (try? JSONDecoder().decode([Bookmark].self, from: data)) ?? []
    }

    private func saveBookmarks() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(bookmarks) else { return }
        try? data.write(to: bookmarksFile, options: .atomic)
        NotificationCenter.default.post(name: .browserDataDidChange, object: self)
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyFile) else { return }
        history = (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    private func saveHistory() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(history) else { return }
        try? data.write(to: historyFile, options: .atomic)
        NotificationCenter.default.post(name: .browserDataDidChange, object: self)
    }
}
