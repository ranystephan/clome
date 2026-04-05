import SwiftUI
import Firebase
import FirebaseAuth
import GoogleSignIn
import AuthenticationServices

/// Sign-in view shown in the Flow panel when no Firebase user is authenticated.
struct FlowAuthView: View {
    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @State private var isAuthenticated = false

    var onAuthenticated: (() -> Void)?

    var body: some View {
        if isAuthenticated {
            ProgressView()
                .scaleEffect(0.7)
        } else {
            VStack(spacing: 16) {
                Spacer()

                // Icon
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "square.grid.3x3.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.white.opacity(0.15))
                    Image(systemName: "music.note")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.25))
                        .offset(x: 4, y: 4)
                }

                Text("Sign in to Clome Flow")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.70))

                Text("Connect your Clome Flow account to access\ntodos, calendar, and AI chat.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
                    .multilineTextAlignment(.center)

                VStack(spacing: 8) {
                    // Sign in with Apple
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.email, .fullName]
                    } onCompletion: { result in
                        handleAppleSignIn(result)
                    }
                    .signInWithAppleButtonStyle(.white)
                    .frame(width: 220, height: 32)
                    .cornerRadius(4)

                    // Sign in with Google
                    Button {
                        signInWithGoogle()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "g.circle.fill")
                                .font(.system(size: 14, weight: .medium))
                            Text("Sign in with Google")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundColor(.black)
                        .frame(width: 220, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.white)
                        )
                    }
                    .buttonStyle(.plain)

                    // Continue without account
                    Button {
                        skipAuth()
                    } label: {
                        Text("Continue without account")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }

                if isSigningIn {
                    ProgressView()
                        .scaleEffect(0.7)
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(Color(red: 0.9, green: 0.4, blue: 0.4))
                        .padding(.horizontal, 20)
                        .multilineTextAlignment(.center)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .onAppear {
                errorMessage = nil
                let user = Auth.auth().currentUser
                if user != nil {
                    isAuthenticated = true
                    onAuthenticated?()
                }
            }
        }
    }

    // MARK: - Error Handling

    /// Returns true for keychain-related errors that can occur even when the
    /// server-side authentication actually succeeded. On macOS, Firebase Auth
    /// throws when it can't persist the token to the Data Protection keychain,
    /// but the user may still be authenticated in-memory.
    private func isKeychainError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let desc = nsError.localizedDescription.lowercased()
        if desc.contains("keychain") { return true }
        if nsError.domain == AuthErrorDomain,
           nsError.code == AuthErrorCode.keychainError.rawValue {
            return true
        }
        return false
    }

    /// Handles a Firebase sign-in error. If the error is a keychain persistence
    /// failure, checks whether the user was actually authenticated in-memory and
    /// proceeds if so (the session won't survive an app restart, but the user
    /// can work now). Otherwise shows the error in the UI.
    private func handleSignInError(_ error: Error) {
        if isKeychainError(error) {
            // Firebase may have authenticated the user in-memory even though
            // persisting the token to the keychain failed.
            if Auth.auth().currentUser != nil {
                NSLog("[FlowAuth] Keychain persistence failed but user IS authenticated in-memory — proceeding")
                isAuthenticated = true
                onAuthenticated?()
                return
            }
            NSLog("[FlowAuth] Keychain error and no in-memory user: \(error.localizedDescription)")
            errorMessage = "Sign-in succeeded but credential storage failed. Please try again."
            return
        }
        errorMessage = error.localizedDescription
    }

    // MARK: - Skip Auth

    private func skipAuth() {
        isSigningIn = true
        errorMessage = nil
        Task {
            do {
                try await Auth.auth().signInAnonymously()
                isAuthenticated = true
                onAuthenticated?()
            } catch {
                NSLog("[FlowAuth] Anonymous sign-in failed: \(error.localizedDescription)")
                // Still let the user through for local-only features
                isAuthenticated = true
                onAuthenticated?()
            }
            isSigningIn = false
        }
    }

    // MARK: - Google Sign-In

    private func signInWithGoogle() {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            errorMessage = "Firebase not configured"
            return
        }

        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config

        guard let window = NSApp.keyWindow else {
            errorMessage = "No active window for sign-in"
            return
        }

        isSigningIn = true
        errorMessage = nil

        GIDSignIn.sharedInstance.signIn(withPresenting: window) { [onAuthenticated] result, error in
            // GIDSignIn may return BOTH a result and an error on macOS — the OAuth
            // flow succeeds but token persistence to the keychain fails. Prefer the
            // result when tokens are available; only treat the error as fatal if we
            // have no tokens to work with.
            let idToken = result?.user.idToken?.tokenString
            let accessToken = result?.user.accessToken.tokenString

            Task { @MainActor in
                // If we have tokens, proceed regardless of any keychain error
                if let idToken, let accessToken {
                    if let error {
                        NSLog("[FlowAuth] Google SDK keychain warning (tokens available, ignoring): \(error.localizedDescription)")
                    }

                    let credential = GoogleAuthProvider.credential(
                        withIDToken: idToken,
                        accessToken: accessToken
                    )

                    do {
                        try await Auth.auth().signIn(with: credential)
                        isAuthenticated = true
                        onAuthenticated?()
                    } catch {
                        NSLog("[FlowAuth] Firebase signIn error: \(error.localizedDescription)")
                        handleSignInError(error)
                    }
                    isSigningIn = false
                    return
                }

                // No tokens — check the error
                if let error {
                    let nsError = error as NSError
                    if nsError.code == GIDSignInError.canceled.rawValue {
                        isSigningIn = false
                        return
                    }
                    NSLog("[FlowAuth] Google SDK error (no tokens): \(error.localizedDescription)")
                    handleSignInError(error)
                    isSigningIn = false
                    return
                }

                // No tokens and no error — shouldn't happen
                isSigningIn = false
                errorMessage = "Failed to get Google credentials"
            }
        }
    }

    // MARK: - Apple Sign-In

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let appleCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = appleCredential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                errorMessage = "Failed to get Apple ID token"
                return
            }

            isSigningIn = true
            let credential = OAuthProvider.credential(
                withProviderID: "apple.com",
                idToken: idToken,
                rawNonce: nil
            )

            Task {
                do {
                    try await Auth.auth().signIn(with: credential)
                    isAuthenticated = true
                    onAuthenticated?()
                } catch {
                    NSLog("[FlowAuth] Apple Firebase signIn error: \(error.localizedDescription)")
                    handleSignInError(error)
                }
                isSigningIn = false
            }

        case .failure(let error):
            let nsError = error as NSError
            NSLog("[FlowAuth] Apple onCompletion failure: code=\(nsError.code) domain=\(nsError.domain) desc=\(nsError.localizedDescription)")
            if nsError.code == ASAuthorizationError.canceled.rawValue { return }
            if isKeychainError(error) { return }
            NSLog("[FlowAuth] Apple failure NOT filtered, setting errorMessage")
            errorMessage = error.localizedDescription
        }
    }
}
