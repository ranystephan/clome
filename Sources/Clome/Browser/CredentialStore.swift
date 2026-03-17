import Foundation

struct SavedCredential: Codable {
    let host: String
    let username: String
    let password: String
    let formURL: String
    var dateCreated: Date
    var dateLastUsed: Date
}

/// JSON-file-backed credential store for the Clome browser password manager.
/// Stores at ~/.config/clome/credentials.json (same dir as bookmarks/history).
/// Uses a simple XOR obfuscation to avoid plaintext on disk — not cryptographic
/// security, but sufficient for local dev use. Switch to Keychain when code-signed.
@MainActor
class CredentialStore {
    static let shared = CredentialStore()

    private var credentials: [SavedCredential] = []
    private let filePath: URL

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configDir = home.appendingPathComponent(".config/clome")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        filePath = configDir.appendingPathComponent("credentials.json")
        load()
    }

    // MARK: - Save

    func saveCredential(host: String, username: String, password: String, formURL: String) {
        // Update existing or add new
        if let idx = credentials.firstIndex(where: { $0.host == host && $0.username == username }) {
            credentials[idx] = SavedCredential(
                host: host, username: username, password: password,
                formURL: formURL,
                dateCreated: credentials[idx].dateCreated,
                dateLastUsed: Date()
            )
        } else {
            credentials.append(SavedCredential(
                host: host, username: username, password: password,
                formURL: formURL,
                dateCreated: Date(), dateLastUsed: Date()
            ))
        }
        save()
        NSLog("[CredentialStore] Saved credential for \(host) user=\(username), total=\(credentials.count)")
    }

    // MARK: - Query

    func credentialsForHost(_ host: String) -> [SavedCredential] {
        let results = credentials.filter { $0.host == host }
        NSLog("[CredentialStore] Query for '\(host)': found \(results.count) credentials")
        return results
    }

    // MARK: - Delete

    func deleteCredential(host: String, username: String) {
        credentials.removeAll { $0.host == host && $0.username == username }
        save()
    }

    // MARK: - List

    func allSavedHosts() -> [String] {
        Array(Set(credentials.map { $0.host })).sorted()
    }

    // MARK: - Touch

    func touchCredential(host: String, username: String) {
        if let idx = credentials.firstIndex(where: { $0.host == host && $0.username == username }) {
            credentials[idx].dateLastUsed = Date()
            save()
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: filePath) else { return }
        // Decode from obfuscated JSON
        let decoded = obfuscate(data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        credentials = (try? decoder.decode([SavedCredential].self, from: decoded)) ?? []
        NSLog("[CredentialStore] Loaded \(credentials.count) credentials from disk")
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(credentials) else { return }
        // Obfuscate before writing
        let encoded = obfuscate(data)
        try? encoded.write(to: filePath, options: .atomic)
    }

    /// Simple XOR obfuscation — NOT encryption, just avoids plaintext passwords on disk.
    /// Symmetric: obfuscate(obfuscate(data)) == data
    private func obfuscate(_ data: Data) -> Data {
        let key: [UInt8] = [0x4E, 0x65, 0x78, 0x75, 0x73, 0x42, 0x72, 0x6F] // "ClomeBro"
        var result = Data(count: data.count)
        for i in 0..<data.count {
            result[i] = data[i] ^ key[i % key.count]
        }
        return result
    }
}
