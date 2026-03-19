import AppKit
import WebKit

// MARK: - Save Banner

/// A slide-down banner prompting the user to save captured credentials.
@MainActor
class CredentialSaveBanner: NSView {
    private var host: String = ""
    private var username: String = ""
    private var password: String = ""
    private var formURL: String = ""
    private var dismissTimer: Timer?
    private var topConstraint: NSLayoutConstraint?

    var onDismiss: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private let label = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let neverButton = NSButton(title: "Never", target: nil, action: nil)

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.102, green: 0.102, blue: 0.133, alpha: 1).cgColor // #1a1a22
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer?.cornerRadius = 8

        translatesAutoresizingMaskIntoConstraints = false

        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.bezelStyle = .rounded
        saveButton.contentTintColor = .white
        saveButton.wantsLayer = true
        saveButton.layer?.backgroundColor = NSColor.systemBlue.cgColor
        saveButton.layer?.cornerRadius = 6
        saveButton.isBordered = false
        saveButton.font = .systemFont(ofSize: 12, weight: .semibold)
        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        addSubview(saveButton)

        neverButton.translatesAutoresizingMaskIntoConstraints = false
        neverButton.bezelStyle = .rounded
        neverButton.contentTintColor = NSColor(white: 0.7, alpha: 1)
        neverButton.wantsLayer = true
        neverButton.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
        neverButton.layer?.cornerRadius = 6
        neverButton.isBordered = false
        neverButton.font = .systemFont(ofSize: 12, weight: .medium)
        neverButton.target = self
        neverButton.action = #selector(neverTapped)
        addSubview(neverButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),

            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: neverButton.leadingAnchor, constant: -10),

            saveButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            saveButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            saveButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
            saveButton.heightAnchor.constraint(equalToConstant: 26),

            neverButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
            neverButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            neverButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
            neverButton.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    func configure(host: String, username: String, password: String, formURL: String) {
        self.host = host
        self.username = username
        self.password = password
        self.formURL = formURL

        let displayUser = username.isEmpty ? "credentials" : "\"\(username)\""
        label.stringValue = "Save password for \(host)? (\(displayUser))"
    }

    func showAnimated(in parent: NSView, below topAnchorView: NSView) {
        parent.addSubview(self)

        let top = topAnchor.constraint(equalTo: topAnchorView.bottomAnchor, constant: -44)
        topConstraint = top

        NSLayoutConstraint.activate([
            top,
            leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        ])

        parent.layoutSubtreeIfNeeded()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            top.animator().constant = 0
            parent.layoutSubtreeIfNeeded()
        })

        dismissTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil

        guard let parent = superview else {
            removeFromSuperview()
            onDismiss?()
            return
        }

        topConstraint?.constant = -44
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            parent.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            self?.removeFromSuperview()
            self?.onDismiss?()
        })
    }

    @objc private func saveTapped() {
        CredentialStore.shared.saveCredential(
            host: host,
            username: username,
            password: password,
            formURL: formURL
        )
        dismiss()
    }

    @objc private func neverTapped() {
        dismiss()
    }
}

// MARK: - Form Autofill Manager

/// Injects JavaScript to detect login forms, autofill saved credentials, and capture
/// new credential submissions from the WKWebView browser.
@MainActor
class FormAutofillManager: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    weak var parentView: NSView?

    /// Reference to the navBar so the save banner can anchor below it.
    weak var navBar: NSView?

    private var currentBanner: CredentialSaveBanner?
    private weak var registeredController: WKUserContentController?
    private(set) var isRegistered = false

    // MARK: - Registration

    /// Register user scripts and message handlers on the web view configuration.
    func register(on config: WKWebViewConfiguration) {
        let controller = config.userContentController

        if isRegistered {
            if registeredController === controller {
                NSLog("[FormAutofill] register skipped: already registered on this controller")
                return
            }
            unregisterCurrentController()
        }

        // Register message handlers
        controller.removeScriptMessageHandler(forName: "clomeFormDetected")
        controller.removeScriptMessageHandler(forName: "clomeCredentialCaptured")
        controller.add(self, name: "clomeFormDetected")
        controller.add(self, name: "clomeCredentialCaptured")
        NSLog("[FormAutofill] Registered message handlers: clomeFormDetected, clomeCredentialCaptured")

        // Inject form detection / autofill / capture script at document end, main frame only
        let script = WKUserScript(
            source: Self.injectedJavaScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        controller.addUserScript(script)
        NSLog("[FormAutofill] Injected form detection JS script")

        registeredController = controller
        isRegistered = true
    }

    /// Unregister message handlers from a web view configuration.
    func unregister(from config: WKWebViewConfiguration) {
        unregister(controller: config.userContentController)
    }

    private func unregisterCurrentController() {
        unregister(controller: registeredController)
    }

    private func unregister(controller: WKUserContentController?) {
        guard let controller else { return }
        controller.removeScriptMessageHandler(forName: "clomeFormDetected")
        controller.removeScriptMessageHandler(forName: "clomeCredentialCaptured")
        if registeredController === controller {
            registeredController = nil
            isRegistered = false
        }
        NSLog("[FormAutofill] Unregistered message handlers")
    }

    // MARK: - Page lifecycle

    /// Called by BrowserPanel when a page finishes loading. Triggers autofill check.
    nonisolated func pageDidFinish(url: URL?) {
        Task { @MainActor [weak self] in
            self?.handlePageDidFinish(url: url)
        }
    }

    private func handlePageDidFinish(url: URL?) {
        let urlString = url?.absoluteString ?? "nil"
        guard isRegistered else {
            NSLog("[FormAutofill] pageDidFinish ignored (manager not registered)")
            return
        }
        guard let webView else {
            NSLog("[FormAutofill] pageDidFinish ignored (webView unavailable)")
            return
        }

        // Keep log payload simple and avoid optional/bridging churn during teardown races.
        NSLog("[FormAutofill] pageDidFinish, webView=true, url=%@", urlString)
        // The injected JS will post clomeFormDetected automatically on load.
        // We can also re-trigger a scan for SPAs that may have changed content.
        webView.evaluateJavaScript("if (window.__clomeScanForms) window.__clomeScanForms(); else console.log('[Clome] __clomeScanForms not found');") { [weak self] _, error in
            Task { @MainActor in
                guard self != nil else { return }
                if let error {
                    NSLog("[FormAutofill] JS scan error on %@: %@", urlString, error.localizedDescription)
                } else {
                    NSLog("[FormAutofill] JS scan triggered OK for %@", urlString)
                }
            }
        }
    }

    // MARK: - WKScriptMessageHandler

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        Task { @MainActor in
            NSLog("[FormAutofill] Received message: name=\(message.name), body=\(message.body)")
            self.handleMessage(name: message.name, body: message.body)
        }
    }

    private func handleMessage(name: String, body: Any) {
        guard isRegistered else {
            NSLog("[FormAutofill] Ignoring message while unregistered: \(name)")
            return
        }

        guard let dict = body as? [String: Any] else {
            NSLog("[FormAutofill] Message body is not a dictionary: \(type(of: body))")
            return
        }

        switch name {
        case "clomeFormDetected":
            NSLog("[FormAutofill] Handling formDetected: \(dict)")
            handleFormDetected(dict)
        case "clomeCredentialCaptured":
            NSLog("[FormAutofill] Handling credentialCaptured: \(dict)")
            handleCredentialCaptured(dict)
        default:
            break
        }
    }

    // MARK: - Form detected → autofill

    private func handleFormDetected(_ info: [String: Any]) {
        guard let host = info["host"] as? String,
              let hasPassword = info["hasPasswordField"] as? Bool,
              hasPassword else { return }

        let credentials = CredentialStore.shared.credentialsForHost(host)
        guard let cred = credentials.first else { return }

        // Touch the credential so it sorts as recently used
        CredentialStore.shared.touchCredential(host: host, username: cred.username)

        // Escape values for safe JS injection
        let safeUser = escapeForJS(cred.username)
        let safePass = escapeForJS(cred.password)

        let js = "if (window.__clomeFillCredentials) window.__clomeFillCredentials('\(safeUser)', '\(safePass)');"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Credential captured → save prompt

    private func handleCredentialCaptured(_ info: [String: Any]) {
        guard let host = info["host"] as? String,
              let username = info["username"] as? String,
              let password = info["password"] as? String,
              !password.isEmpty else { return }

        let formAction = info["formAction"] as? String ?? ""

        // Check if we already have this exact credential
        let existing = CredentialStore.shared.credentialsForHost(host)
        let alreadySaved = existing.contains { $0.username == username && $0.password == password }
        if alreadySaved { return }

        // Dismiss any existing banner
        currentBanner?.dismiss()

        // Show save banner
        guard let parent = parentView, let nav = navBar else { return }

        let banner = CredentialSaveBanner()
        banner.configure(host: host, username: username, password: password, formURL: formAction)
        banner.onDismiss = { [weak self] in
            self?.currentBanner = nil
        }
        banner.showAnimated(in: parent, below: nav)
        currentBanner = banner
    }

    // MARK: - JS escape helper

    private func escapeForJS(_ string: String) -> String {
        var result = string
        result = result.replacingOccurrences(of: "\\", with: "\\\\")
        result = result.replacingOccurrences(of: "'", with: "\\'")
        result = result.replacingOccurrences(of: "\n", with: "\\n")
        result = result.replacingOccurrences(of: "\r", with: "\\r")
        result = result.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        result = result.replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return result
    }

    // MARK: - Injected JavaScript

    private static let injectedJavaScript: String = """
    (function() {
        'use strict';
        console.log('[Clome FormAutofill] Script injected on: ' + window.location.hostname);

        // Track detected forms to avoid duplicate processing
        var detectedForms = new WeakSet();
        var trackedPasswordFields = [];
        var trackedUserFields = [];

        // Identify the username field near a password field
        function findUsernameField(form, passwordField) {
            // Strategy 1: look for autocomplete hints
            var candidates = form.querySelectorAll(
                'input[autocomplete="username"], input[autocomplete="email"], input[autocomplete="user"]'
            );
            if (candidates.length > 0) return candidates[0];

            // Strategy 2: look for name/id containing user-like strings
            var inputs = form.querySelectorAll('input[type="text"], input[type="email"], input[type="tel"], input:not([type])');
            for (var i = 0; i < inputs.length; i++) {
                var inp = inputs[i];
                var nameId = ((inp.name || '') + ' ' + (inp.id || '') + ' ' + (inp.placeholder || '')).toLowerCase();
                if (/user|email|login|name|account|id/.test(nameId)) {
                    return inp;
                }
            }

            // Strategy 3: pick the visible text/email input that comes before the password field in DOM order
            var allInputs = Array.from(form.querySelectorAll('input'));
            var pwIndex = allInputs.indexOf(passwordField);
            for (var j = pwIndex - 1; j >= 0; j--) {
                var t = (allInputs[j].type || 'text').toLowerCase();
                if ((t === 'text' || t === 'email' || t === 'tel' || t === '') && allInputs[j].offsetParent !== null) {
                    return allInputs[j];
                }
            }

            return null;
        }

        // Dispatch input + change events so JS frameworks detect the value change
        function dispatchInputEvents(el) {
            var nativeInputValueSetter = Object.getOwnPropertyDescriptor(
                window.HTMLInputElement.prototype, 'value'
            ).set;
            nativeInputValueSetter.call(el, el.value);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
        }

        // Fill credentials into detected form fields
        window.__clomeFillCredentials = function(username, password) {
            if (trackedUserFields.length > 0 && username) {
                trackedUserFields[0].value = username;
                dispatchInputEvents(trackedUserFields[0]);
            }
            if (trackedPasswordFields.length > 0 && password) {
                trackedPasswordFields[0].value = password;
                dispatchInputEvents(trackedPasswordFields[0]);
            }
        };

        // Extract credentials from a form
        function extractCredentials(form) {
            var passwordField = form.querySelector('input[type="password"]');
            if (!passwordField) return null;
            var userField = findUsernameField(form, passwordField);
            var username = userField ? userField.value : '';
            var password = passwordField.value;
            if (!password) return null;
            return {
                host: window.location.hostname,
                username: username,
                password: password,
                formAction: form.action || window.location.href
            };
        }

        // Handle a form submission
        function onFormSubmit(form) {
            var creds = extractCredentials(form);
            if (creds) {
                window.webkit.messageHandlers.clomeCredentialCaptured.postMessage(creds);
            }
        }

        // Scan for login forms in the document
        function scanForms() {
            var forms = document.querySelectorAll('form');
            var foundAny = false;

            trackedPasswordFields = [];
            trackedUserFields = [];

            forms.forEach(function(form) {
                var pwField = form.querySelector('input[type="password"]');
                if (!pwField) return;

                foundAny = true;
                trackedPasswordFields.push(pwField);

                var userField = findUsernameField(form, pwField);
                if (userField) trackedUserFields.push(userField);

                if (detectedForms.has(form)) return;
                detectedForms.add(form);

                // Listen for submit event
                form.addEventListener('submit', function() {
                    onFormSubmit(form);
                }, true);

                // Listen for Enter in password field
                pwField.addEventListener('keydown', function(e) {
                    if (e.key === 'Enter') {
                        onFormSubmit(form);
                    }
                });

                // Listen for click on submit buttons
                var submitBtns = form.querySelectorAll(
                    'button[type="submit"], input[type="submit"], button:not([type])'
                );
                submitBtns.forEach(function(btn) {
                    btn.addEventListener('click', function() {
                        // Small delay so the form values are set
                        setTimeout(function() { onFormSubmit(form); }, 50);
                    });
                });
            });

            // Also detect standalone password fields not inside a <form> (common in SPAs)
            var standalonePw = document.querySelectorAll('input[type="password"]');
            standalonePw.forEach(function(pwField) {
                if (pwField.form) return; // already handled above
                foundAny = true;
                trackedPasswordFields.push(pwField);

                // Try to find a nearby username field
                var parent = pwField.closest('div, section, main, body');
                if (parent) {
                    var inputs = parent.querySelectorAll('input[type="text"], input[type="email"], input:not([type])');
                    for (var i = 0; i < inputs.length; i++) {
                        if (inputs[i].offsetParent !== null) {
                            trackedUserFields.push(inputs[i]);
                            break;
                        }
                    }
                }

                pwField.addEventListener('keydown', function(e) {
                    if (e.key === 'Enter') {
                        var creds = {
                            host: window.location.hostname,
                            username: trackedUserFields.length > 0 ? trackedUserFields[0].value : '',
                            password: pwField.value,
                            formAction: window.location.href
                        };
                        if (creds.password) {
                            window.webkit.messageHandlers.clomeCredentialCaptured.postMessage(creds);
                        }
                    }
                });
            });

            console.log('[Clome FormAutofill] scanForms: found ' + trackedPasswordFields.length + ' pw fields, ' + trackedUserFields.length + ' user fields, foundAny=' + foundAny);

            if (foundAny) {
                try {
                    window.webkit.messageHandlers.clomeFormDetected.postMessage({
                        host: window.location.hostname,
                        formCount: forms.length,
                        hasPasswordField: true
                    });
                    console.log('[Clome FormAutofill] Posted clomeFormDetected message');
                } catch(e) {
                    console.error('[Clome FormAutofill] Failed to post message: ' + e);
                }
            }
        }

        // Expose scan function for re-triggering on SPA navigation
        window.__clomeScanForms = scanForms;

        // Initial scan
        scanForms();

        // MutationObserver for SPAs that dynamically add forms
        var observer = new MutationObserver(function(mutations) {
            var shouldRescan = false;
            for (var i = 0; i < mutations.length; i++) {
                var added = mutations[i].addedNodes;
                for (var j = 0; j < added.length; j++) {
                    var node = added[j];
                    if (node.nodeType !== 1) continue;
                    if (node.tagName === 'FORM' || node.tagName === 'INPUT' ||
                        (node.querySelector && (node.querySelector('form') || node.querySelector('input[type="password"]')))) {
                        shouldRescan = true;
                        break;
                    }
                }
                if (shouldRescan) break;
            }
            if (shouldRescan) {
                setTimeout(scanForms, 200);
            }
        });

        observer.observe(document.body || document.documentElement, {
            childList: true,
            subtree: true
        });
    })();
    """
}
