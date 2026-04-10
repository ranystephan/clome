import AppKit
import Firebase
import FirebaseAuth
import FirebaseFirestore
import GoogleSignIn
import GTMAppAuth
import Security

// Configure Firebase before anything else can access Auth.auth().
if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
    FirebaseApp.configure()

    // Use memory-only Firestore cache to avoid LevelDB lock conflicts with
    // other processes (e.g. a previous Clome instance, or Clome Flow macOS
    // target) that share the same Firebase project cache directory.
    let settings = Firestore.firestore().settings
    settings.cacheSettings = MemoryCacheSettings()
    Firestore.firestore().settings = settings

    do {
        try Auth.auth().useUserAccessGroup(nil)
        NSLog("[FlowAuth] Firebase Auth configured to use the private keychain access group")
    } catch {
        NSLog("[FlowAuth] Failed to reset Firebase Auth access group: \(error)")
    }
} else {
    print("[Clome] GoogleService-Info.plist not found — skipping Firebase configuration")
}

// One-time cleanup of stale keychain items and Firebase access group preferences
// from previous builds. Bump version suffix when keychain strategy changes.
let signingMigrationKey = "com.clome.keychain-signing-migrated-v5"
if !UserDefaults.standard.bool(forKey: signingMigrationKey) {
    // 1. Delete stale keychain items from all previous configurations
    let queries: [[String: Any]] = [
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.clome.app"],
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "firebase_auth"],
        [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: "firebase_auth_firebase_user"],
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.clome.app.firebaseauth"],
    ]
    for q in queries { SecItemDelete(q as CFDictionary) }

    // 2. Clear Firebase Auth's stored access group preference from UserDefaults.
    //    Firebase stores this in persistent domain "com.google.Firebase.Auth.<service>"
    //    where service = "firebase_auth_<GOOGLE_APP_ID>".
    let firebaseGoogleAppID = FirebaseApp.app()?.options.googleAppID ?? ""
    let firebaseAuthDomain = "com.google.Firebase.Auth.firebase_auth_\(firebaseGoogleAppID)"
    UserDefaults.standard.removePersistentDomain(forName: firebaseAuthDomain)
    NSLog("[FlowAuth] Cleared Firebase Auth UserDefaults domain: \(firebaseAuthDomain)")

    // 3. Sign out to clear any in-memory auth state
    try? Auth.auth().signOut()

    UserDefaults.standard.set(true, forKey: signingMigrationKey)
    NSLog("[FlowAuth] Keychain migration v5 complete — stale items + stored access group cleared")
}

// Fix GIDSignIn's keychain access on macOS with Hardened Runtime.
// GIDSignIn creates a GTMKeychainStore WITHOUT the Data Protection keychain flag,
// so it falls back to the legacy macOS keychain which is blocked by Hardened Runtime.
// Replace the internal keychain store with one that uses the Data Protection keychain.
let fixedStore = KeychainStore(
    itemName: "auth",
    keychainAttributes: [KeychainAttribute.useDataProtectionKeychain]
)
GIDSignIn.sharedInstance.setValue(fixedStore, forKey: "keychainStore")
NSLog("[FlowAuth] Patched GIDSignIn keychain store with Data Protection flag")

let app = NSApplication.shared

let delegate = MainActor.assumeIsolated {
    CrashReporter.shared.install()
    return ClomeAppDelegate()
}
app.delegate = delegate
app.run()
