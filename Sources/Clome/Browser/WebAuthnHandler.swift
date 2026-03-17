import AppKit
import AuthenticationServices
import WebKit

// MARK: - WebAuthn Bridge
//
// This bridges the JavaScript WebAuthn API (navigator.credentials.get/create) to
// native macOS ASAuthorization, bypassing WKWebView's lack of built-in passkey
// support without the com.apple.developer.web-browser entitlement.
//
// Flow:
// 1. JS shim overrides navigator.credentials.get() / .create()
// 2. Shim posts a WKScriptMessage to native code with the WebAuthn options
// 3. Native code performs ASAuthorizationController passkey request
// 4. On success, native code calls back into JS with the credential response
// 5. The JS promise resolves and the website's auth flow completes

/// JavaScript shim that intercepts WebAuthn API calls and bridges them to native code.
/// Injected at document-start so it's available before any page scripts run.
let webAuthnBridgeScript = """
(function() {
    'use strict';

    // Store original credentials API (may be undefined in WKWebView without entitlement)
    const _origCredentials = navigator.credentials;

    // Base64URL encode/decode helpers
    function bufferToBase64URL(buffer) {
        const bytes = new Uint8Array(buffer);
        let binary = '';
        for (let i = 0; i < bytes.byteLength; i++) { binary += String.fromCharCode(bytes[i]); }
        return btoa(binary).replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, '');
    }

    function base64URLToBuffer(base64url) {
        const base64 = base64url.replace(/-/g, '+').replace(/_/g, '/');
        const pad = base64.length % 4;
        const padded = pad ? base64 + '===='.slice(pad) : base64;
        const binary = atob(padded);
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) { bytes[i] = binary.charCodeAt(i); }
        return bytes.buffer;
    }

    // Pending request tracking
    let _pendingResolve = null;
    let _pendingReject = null;

    // Called from native code when passkey assertion/registration succeeds
    window.__clomeWebAuthnSuccess = function(responseJSON) {
        if (!_pendingResolve) return;
        try {
            const resp = JSON.parse(responseJSON);

            if (resp.type === 'assertion') {
                // Build PublicKeyCredential-like object for assertion
                const credential = {
                    id: resp.credentialID,
                    rawId: base64URLToBuffer(resp.credentialID),
                    type: 'public-key',
                    authenticatorAttachment: 'platform',
                    response: {
                        authenticatorData: base64URLToBuffer(resp.authenticatorData),
                        clientDataJSON: base64URLToBuffer(resp.clientDataJSON),
                        signature: base64URLToBuffer(resp.signature),
                        userHandle: resp.userHandle ? base64URLToBuffer(resp.userHandle) : null,
                    },
                    getClientExtensionResults: () => ({}),
                };
                // Add ArrayBuffer-returning methods
                credential.response.getAuthenticatorData = () => credential.response.authenticatorData;
                _pendingResolve(credential);
            } else if (resp.type === 'registration') {
                const credential = {
                    id: resp.credentialID,
                    rawId: base64URLToBuffer(resp.credentialID),
                    type: 'public-key',
                    authenticatorAttachment: 'platform',
                    response: {
                        attestationObject: base64URLToBuffer(resp.attestationObject),
                        clientDataJSON: base64URLToBuffer(resp.clientDataJSON),
                        getTransports: () => ['internal'],
                        getAuthenticatorData: () => base64URLToBuffer(resp.authenticatorData || ''),
                        getPublicKey: () => null,
                        getPublicKeyAlgorithm: () => -7,
                    },
                    getClientExtensionResults: () => ({}),
                };
                _pendingResolve(credential);
            }
        } catch (e) {
            if (_pendingReject) _pendingReject(new DOMException('Native bridge error: ' + e.message, 'NotAllowedError'));
        }
        _pendingResolve = null;
        _pendingReject = null;
    };

    // Called from native code when passkey operation fails
    window.__clomeWebAuthnError = function(errorMessage) {
        if (_pendingReject) {
            _pendingReject(new DOMException(errorMessage, 'NotAllowedError'));
        }
        _pendingResolve = null;
        _pendingReject = null;
    };

    // Override navigator.credentials
    const credentialsProxy = {
        get: function(options) {
            // Only intercept publicKey (WebAuthn) requests
            if (!options || !options.publicKey) {
                if (_origCredentials && _origCredentials.get) {
                    return _origCredentials.get.call(_origCredentials, options);
                }
                return Promise.reject(new DOMException('Not supported', 'NotSupportedError'));
            }

            const pk = options.publicKey;
            return new Promise(function(resolve, reject) {
                _pendingResolve = resolve;
                _pendingReject = reject;

                const msg = {
                    action: 'get',
                    rpId: pk.rpId || window.location.hostname,
                    challenge: bufferToBase64URL(pk.challenge),
                    timeout: pk.timeout || 60000,
                    userVerification: pk.userVerification || 'preferred',
                    allowCredentials: (pk.allowCredentials || []).map(function(c) {
                        return { id: bufferToBase64URL(c.id), type: c.type || 'public-key' };
                    }),
                };
                window.webkit.messageHandlers.clomeWebAuthn.postMessage(JSON.stringify(msg));
            });
        },

        create: function(options) {
            if (!options || !options.publicKey) {
                if (_origCredentials && _origCredentials.create) {
                    return _origCredentials.create.call(_origCredentials, options);
                }
                return Promise.reject(new DOMException('Not supported', 'NotSupportedError'));
            }

            const pk = options.publicKey;
            return new Promise(function(resolve, reject) {
                _pendingResolve = resolve;
                _pendingReject = reject;

                const msg = {
                    action: 'create',
                    rpId: pk.rp.id || window.location.hostname,
                    rpName: pk.rp.name || '',
                    challenge: bufferToBase64URL(pk.challenge),
                    userId: bufferToBase64URL(pk.user.id),
                    userName: pk.user.name || '',
                    userDisplayName: pk.user.displayName || '',
                    timeout: pk.timeout || 60000,
                    userVerification: pk.authenticatorSelection?.userVerification || 'preferred',
                    attestation: pk.attestation || 'none',
                };
                window.webkit.messageHandlers.clomeWebAuthn.postMessage(JSON.stringify(msg));
            });
        },

        preventSilentAccess: function() {
            return Promise.resolve();
        },

        store: function(credential) {
            return Promise.resolve(credential);
        },
    };

    // Install the override
    try {
        Object.defineProperty(navigator, 'credentials', {
            get: function() { return credentialsProxy; },
            configurable: true,
        });
    } catch(e) {}

    // Ensure PublicKeyCredential is defined (needed by feature-detection code on sites)
    if (typeof PublicKeyCredential === 'undefined') {
        window.PublicKeyCredential = function() {};
        window.PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = function() {
            return Promise.resolve(true);
        };
        window.PublicKeyCredential.isConditionalMediationAvailable = function() {
            return Promise.resolve(false);
        };
    } else {
        // Override the check to ensure it returns true (platform authenticator = Touch ID)
        const origCheck = PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable;
        PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = function() {
            return Promise.resolve(true);
        };
    }
})();
"""

/// Handles WebAuthn/Passkey authorization flows by bridging JavaScript WebAuthn API
/// calls to native macOS ASAuthorization, enabling passkeys without the web-browser entitlement.
@MainActor
class WebAuthnHandler: NSObject, WKScriptMessageHandler, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {

    weak var presentationWindow: NSWindow?
    weak var webView: WKWebView?

    /// The origin (scheme + host) of the page requesting WebAuthn
    private var currentOrigin: String = ""

    init(window: NSWindow?) {
        self.presentationWindow = window
        super.init()
    }

    /// Registers this handler as a WKScriptMessageHandler on the given configuration.
    /// Call this BEFORE creating the WKWebView.
    func register(on config: WKWebViewConfiguration) {
        config.userContentController.addUserScript(
            WKUserScript(source: webAuthnBridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        config.userContentController.add(self, name: "clomeWebAuthn")
    }

    // MARK: - WKScriptMessageHandler

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor in
            self.handleMessage(message)
        }
    }

    private func handleMessage(_ message: WKScriptMessage) {
        guard #available(macOS 14.0, *) else {
            rejectWithError("Passkeys require macOS 14.0 or later")
            return
        }

        guard let body = message.body as? String,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else {
            rejectWithError("Invalid WebAuthn request")
            return
        }

        // Capture the origin for clientDataJSON
        if let url = webView?.url, let scheme = url.scheme, let host = url.host {
            currentOrigin = "\(scheme)://\(host)"
        }

        if action == "get" {
            handleAssertion(json)
        } else if action == "create" {
            handleRegistration(json)
        } else {
            rejectWithError("Unknown WebAuthn action: \(action)")
        }
    }

    // MARK: - Assertion (Sign In)

    @available(macOS 14.0, *)
    private func handleAssertion(_ json: [String: Any]) {
        guard let challengeB64 = json["challenge"] as? String,
              let challenge = base64URLDecode(challengeB64),
              let rpId = json["rpId"] as? String else {
            rejectWithError("Missing challenge or rpId")
            return
        }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
        let request = provider.createCredentialAssertionRequest(challenge: challenge)

        if let uv = json["userVerification"] as? String {
            switch uv {
            case "required": request.userVerificationPreference = .required
            case "discouraged": request.userVerificationPreference = .discouraged
            default: request.userVerificationPreference = .preferred
            }
        }

        // Set allowed credentials if specified
        if let allowList = json["allowCredentials"] as? [[String: Any]] {
            let descriptors: [ASAuthorizationPlatformPublicKeyCredentialDescriptor] = allowList.compactMap { cred in
                guard let idB64 = cred["id"] as? String,
                      let idData = base64URLDecode(idB64) else { return nil }
                return ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: idData)
            }
            if !descriptors.isEmpty {
                request.allowedCredentials = descriptors
            }
        }

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    // MARK: - Registration (Sign Up / Add Passkey)

    @available(macOS 14.0, *)
    private func handleRegistration(_ json: [String: Any]) {
        guard let challengeB64 = json["challenge"] as? String,
              let challenge = base64URLDecode(challengeB64),
              let rpId = json["rpId"] as? String,
              let userIdB64 = json["userId"] as? String,
              let userId = base64URLDecode(userIdB64),
              let userName = json["userName"] as? String else {
            rejectWithError("Missing required registration fields")
            return
        }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
        let request = provider.createCredentialRegistrationRequest(challenge: challenge, name: userName, userID: userId)

        if let uv = json["userVerification"] as? String {
            switch uv {
            case "required": request.userVerificationPreference = .required
            case "discouraged": request.userVerificationPreference = .discouraged
            default: request.userVerificationPreference = .preferred
            }
        }

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    // MARK: - ASAuthorizationControllerPresentationContextProviding

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            presentationWindow ?? NSApp.keyWindow ?? NSApp.mainWindow ?? ASPresentationAnchor()
        }
    }

    // MARK: - ASAuthorizationControllerDelegate

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        Task { @MainActor in
            self.handleSuccess(authorization)
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        Task { @MainActor in
            let authError = error as? ASAuthorizationError
            let message: String
            switch authError?.code {
            case .canceled:
                message = "User cancelled"
            default:
                message = error.localizedDescription
            }
            NSLog("[WebAuthn] Authorization error: \(message)")
            self.rejectWithError(message)
        }
    }

    // MARK: - Success Handling

    private func handleSuccess(_ authorization: ASAuthorization) {
        guard #available(macOS 14.0, *) else { return }

        if let assertion = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion {
            let response: [String: Any] = [
                "type": "assertion",
                "credentialID": base64URLEncode(assertion.credentialID),
                "authenticatorData": base64URLEncode(assertion.rawAuthenticatorData),
                "clientDataJSON": base64URLEncode(assertion.rawClientDataJSON),
                "signature": base64URLEncode(assertion.signature),
                "userHandle": assertion.userID.map { base64URLEncode($0) } ?? "",
            ]
            resolveWithSuccess(response)

        } else if let registration = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration {
            let response: [String: Any] = [
                "type": "registration",
                "credentialID": base64URLEncode(registration.credentialID),
                "clientDataJSON": base64URLEncode(registration.rawClientDataJSON),
                "attestationObject": base64URLEncode(registration.rawAttestationObject ?? Data()),
            ]
            resolveWithSuccess(response)

        } else {
            rejectWithError("Unknown credential type")
        }
    }

    // MARK: - JS Callbacks

    private func resolveWithSuccess(_ response: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: response),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            rejectWithError("Failed to serialize response")
            return
        }
        let escaped = jsonString.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let js = "window.__clomeWebAuthnSuccess('\(escaped)');"
        webView?.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("[WebAuthn] Failed to call JS success callback: \(error)")
            }
        }
    }

    private func rejectWithError(_ message: String) {
        let escaped = message.replacingOccurrences(of: "'", with: "\\'")
        let js = "window.__clomeWebAuthnError('\(escaped)');"
        webView?.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("[WebAuthn] Failed to call JS error callback: \(error)")
            }
        }
    }

    // MARK: - Base64URL Helpers

    private func base64URLDecode(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
