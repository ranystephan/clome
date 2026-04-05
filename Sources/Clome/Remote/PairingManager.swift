// PairingManager.swift
// Clome — Manages device pairing, auth token generation, and paired device persistence.

import Foundation
import CryptoKit
import Security

@MainActor
final class PairingManager {

    // MARK: - Configuration

    private static let userDefaultsKey = "com.clome.remote.pairedDevices"
    private static let pairingCodeTTL: TimeInterval = 5 * 60 // 5 minutes
    private static let deviceIdKey = "com.clome.remote.deviceId"

    // MARK: - State

    private var currentCode: String?
    private var codeExpiresAt: Date?
    private var serverSigningKey: Curve25519.Signing.PrivateKey

    /// The server's persistent Ed25519 key pair, stored in Keychain.
    /// Used for mutual authentication with paired devices.
    private static let keychainKeyTag = "com.clome.remote.signing-key"

    // MARK: - Init

    init() {
        self.serverSigningKey = Self.loadOrCreateSigningKey()
    }

    // MARK: - Paired Devices

    var pairedDevices: [PairedDevice] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey) else { return [] }
            return (try? JSONDecoder().decode([PairedDevice].self, from: data)) ?? []
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }

    func isPaired(deviceId: String) -> Bool {
        pairedDevices.contains { $0.deviceId == deviceId }
    }

    func removePairedDevice(deviceId: String) {
        pairedDevices.removeAll { $0.deviceId == deviceId }
    }

    func removeAllPairedDevices() {
        pairedDevices = []
    }

    // MARK: - Pairing Code

    /// Generates a cryptographically secure 6-digit pairing code.
    /// The code expires after 5 minutes.
    func generatePairingCode() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let value = bytes.withUnsafeBufferPointer { ptr -> UInt32 in
            ptr.baseAddress!.withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
        }
        let code = String(format: "%06d", value % 1_000_000)
        currentCode = code
        codeExpiresAt = Date().addingTimeInterval(Self.pairingCodeTTL)
        return code
    }

    /// Validates a pairing request against the current active code.
    /// On success, stores the device as paired and returns the auth token + server public key.
    func validatePairing(request: PairingRequest, code: String) -> PairingResponse {
        // Verify pairing code
        guard let activeCode = currentCode, let expires = codeExpiresAt else {
            return PairingResponse(success: false, error: "No active pairing code", serverPublicKey: nil, authToken: nil)
        }
        guard Date() < expires else {
            invalidateCode()
            return PairingResponse(success: false, error: "Pairing code has expired", serverPublicKey: nil, authToken: nil)
        }
        guard constantTimeEqual(request.code, activeCode) else {
            return PairingResponse(success: false, error: "Invalid pairing code", serverPublicKey: nil, authToken: nil)
        }

        // Code matches — generate auth token and store paired device
        let authToken = generateAuthToken()
        let serverPublicKey = Data(serverSigningKey.publicKey.rawRepresentation)

        let device = PairedDevice(
            deviceId: request.deviceId,
            deviceName: request.deviceName,
            publicKey: request.publicKey,
            authToken: authToken,
            pairedAt: Date(),
            lastConnectedAt: Date()
        )

        // Remove any existing pairing for this device, then add new one
        var devices = pairedDevices
        devices.removeAll { $0.deviceId == request.deviceId }
        devices.append(device)
        pairedDevices = devices

        // Invalidate the code after successful pairing
        invalidateCode()

        return PairingResponse(
            success: true,
            error: nil,
            serverPublicKey: serverPublicKey,
            authToken: authToken
        )
    }

    // MARK: - Authentication

    /// Authenticates a returning paired device using its stored auth token.
    /// For v1, we use token-only verification. Signature verification can be added
    /// when iOS implements Ed25519 signing (currently sends empty signature).
    func authenticateDevice(request: AuthRequest, challenge: AuthChallenge) -> AuthResult {
        let allDeviceIds = pairedDevices.map(\.deviceId)
        print("[PairingManager] Looking up device \(request.deviceId) among paired devices: \(allDeviceIds)")
        guard let device = pairedDevices.first(where: { $0.deviceId == request.deviceId }) else {
            print("[PairingManager] Auth failed: device \(request.deviceId) not paired")
            return AuthResult(success: false, error: "Device not paired")
        }

        // Verify the auth token matches
        guard constantTimeEqual(request.authToken, device.authToken) else {
            print("[PairingManager] Auth failed: token mismatch for device \(request.deviceId)")
            return AuthResult(success: false, error: "Invalid auth token")
        }

        // Token matches — device is authenticated
        print("[PairingManager] Auth success for device: \(device.deviceName)")
        updateLastConnected(deviceId: request.deviceId)
        return AuthResult(success: true, error: nil)
    }

    // MARK: - Server Identity

    /// The server's public key bytes for sharing with paired devices.
    var serverPublicKey: Data {
        Data(serverSigningKey.publicKey.rawRepresentation)
    }

    // MARK: - Private Helpers

    private func invalidateCode() {
        currentCode = nil
        codeExpiresAt = nil
    }

    /// Generates a cryptographically random 32-byte auth token.
    private func generateAuthToken() -> Data {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0) }
    }

    private func updateLastConnected(deviceId: String) {
        var devices = pairedDevices
        if let idx = devices.firstIndex(where: { $0.deviceId == deviceId }) {
            devices[idx].lastConnectedAt = Date()
            pairedDevices = devices
        }
    }

    /// Constant-time string comparison to prevent timing attacks on pairing codes.
    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var result: UInt8 = 0
        for i in 0..<aBytes.count {
            result |= aBytes[i] ^ bBytes[i]
        }
        return result == 0
    }

    /// Constant-time data comparison.
    private func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var result: UInt8 = 0
        for i in 0..<a.count {
            result |= a[i] ^ b[i]
        }
        return result == 0
    }

    // MARK: - Signing Key Persistence

    /// Loads the server's Ed25519 signing key from the Keychain, or generates and stores a new one.
    private static func loadOrCreateSigningKey() -> Curve25519.Signing.PrivateKey {
        // Try to load from Keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainKeyTag,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data,
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }

        // Generate new key
        let newKey = Curve25519.Signing.PrivateKey()
        let rawKey = newKey.rawRepresentation

        // Store in Keychain
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainKeyTag,
            kSecValueData as String: rawKey,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess && addStatus != errSecDuplicateItem {
            // If keychain storage fails, the key still works for this session
            // but won't persist across app restarts
        }

        return newKey
    }
}
