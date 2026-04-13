import AppKit
import AuthenticationServices
import WebKit

/// Shared persistent data store so cookies/logins survive across launches.
@MainActor let persistentDataStore: WKWebsiteDataStore = {
    WKWebsiteDataStore(forIdentifier: UUID(uuidString: "4E5F6A7B-8C9D-0E1F-2A3B-4C5D6E7F8A9B")!)
}()

/// Known OAuth provider hosts that need permissive cookie/navigation handling.
private let oauthProviderHosts: Set<String> = [
    "github.com",
    "accounts.google.com",
    "login.microsoftonline.com",
    "appleid.apple.com",
    "auth0.com",
    "login.live.com",
    "accounts.spotify.com",
    "discord.com",
    "id.twitch.tv",
    "oauth.slack-edge.com",
]

/// Delegate for browser events that need to interact with the tab/pane system.
@MainActor
protocol BrowserPanelDelegate: AnyObject {
    /// Open a URL in a new browser tab. Returns true if handled.
    func browserPanel(_ panel: BrowserPanel, openNewTabWith url: URL) -> Bool
}

/// An embedded browser panel that can be placed in any split pane.
/// Supports persistent cookies, bookmarks, history, and send-to-context.
class BrowserPanel: NSView, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate, WKHTTPCookieStoreObserver, WKScriptMessageHandler {
    /// Shared process pool for all browser panels. Using a single pool means all
    /// WKWebView instances share WebContent processes, reducing the number of
    /// child processes that need sandbox/entitlement validation.
    static let sharedProcessPool = WKProcessPool()

    private(set) var webView: WKWebView!
    private var navBar: NSVisualEffectView!
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var homeButton: NSButton!
    private var reloadButton: NSButton!
    private var loadingBar: NSView!
    private var loadingBarFill: NSView!
    private var loadingBarFillWidth: NSLayoutConstraint!
    private var bookmarkButton: NSButton!
    private var menuButton: NSButton!
    private var cookieButton: NSButton!
    private var popupToggleButton: NSButton!
    private var keyButton: NSButton!
    private var navBottomBorder: NSView!
    private var startPageView: BrowserStartPageView!

    weak var delegate: BrowserPanelDelegate?

    /// Whether popups (window.open / target="_blank") open in a new tab.
    /// When false, popups are blocked entirely.
    var popupsAllowed: Bool = true {
        didSet { updatePopupToggleIcon() }
    }

    // URL bar
    private var urlPill: NSView!
    private var urlField: NSTextField!
    private var lockIcon: NSImageView!
    private var storedURL: URL?
    private var isUrlFocused = false
    private var currentDomainCookieCount: Int = 0
    private var autocompletePopup: URLAutocompletePopup?

    private var idleBg: NSColor { ClomeMacColor.border.withAlphaComponent(0.4) }
    private var hoverBg: NSColor { ClomeMacColor.border.withAlphaComponent(0.6) }
    private var editBg: NSColor { ClomeMacColor.elevatedSurface }
    private let activeAccent = NSColor(red: 0.38, green: 0.56, blue: 1.0, alpha: 1.0)
    private var chromeTint: NSColor { ClomeMacColor.textSecondary }
    private var chromeMutedTint: NSColor { ClomeMacColor.textTertiary }
    private var chromeStroke: NSColor { ClomeMacColor.border }
    private var isPageLoading = false

    private(set) var favicon: NSImage?

    /// WebAuthn/Passkey handler for authentication flows
    private var webAuthnHandler: WebAuthnHandler?

    /// Form autofill / password manager
    private var formAutofillManager: FormAutofillManager?

    var title: String = "Browser" {
        didSet {
            NotificationCenter.default.post(name: .terminalSurfaceTitleChanged, object: self)
        }
    }

    var currentURL: URL? {
        storedURL
    }

    override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = ClomeSettings.shared.backgroundWithOpacity.cgColor
        NotificationCenter.default.addObserver(self, selector: #selector(browserDataChanged(_:)), name: .browserDataDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged(_:)), name: .appearanceSettingsChanged, object: nil)
        setupUI()
    }

    /// Create a browser panel using an external WKWebViewConfiguration.
    /// Used for popups so the new tab shares session state with the parent.
    convenience init(configuration: WKWebViewConfiguration) {
        self.init(frame: .zero)
        // The webView was already created in setupUI with default config.
        // Replace it with one using the provided configuration to share session.
        let oldWebView = webView!
        oldWebView.navigationDelegate = nil
        oldWebView.uiDelegate = nil
        oldWebView.stopLoading()
        formAutofillManager?.unregister(from: oldWebView.configuration)
        formAutofillManager?.webView = nil
        oldWebView.removeObserver(self, forKeyPath: "title")
        oldWebView.removeObserver(self, forKeyPath: "estimatedProgress")
        oldWebView.removeFromSuperview()

        // Add our scripts to the provided configuration
        webAuthnHandler?.register(on: configuration)
        formAutofillManager?.register(on: configuration)

        let newWebView = ClomeWebView(frame: .zero, configuration: configuration)
        newWebView.browserPanel = self
        newWebView.navigationDelegate = self
        newWebView.uiDelegate = self
        newWebView.allowsBackForwardNavigationGestures = true
        newWebView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15"
        newWebView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) {
            newWebView.isInspectable = true
        }
        newWebView.addObserver(self, forKeyPath: "title", options: .new, context: nil)
        newWebView.addObserver(self, forKeyPath: "estimatedProgress", options: .new, context: nil)
        webView = newWebView
        webAuthnHandler?.webView = newWebView
        formAutofillManager?.webView = newWebView
        newWebView.translatesAutoresizingMaskIntoConstraints = true
        newWebView.autoresizingMask = [.width, .height]
        if let startPageView {
            addSubview(newWebView, positioned: .below, relativeTo: startPageView)
        } else {
            addSubview(newWebView)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override var acceptsFirstResponder: Bool { true }

    private func setupUI() {
        navBar = NSVisualEffectView()
        navBar.translatesAutoresizingMaskIntoConstraints = false
        navBar.material = .headerView
        navBar.blendingMode = .withinWindow
        navBar.state = .active
        navBar.wantsLayer = true
        navBar.layer?.cornerCurve = .continuous
        addSubview(navBar)

        // Back button
        backButton = makeNavButton(symbol: "chevron.left", action: #selector(goBack))
        navBar.addSubview(backButton)

        // Forward button
        forwardButton = makeNavButton(symbol: "chevron.right", action: #selector(goForward))
        navBar.addSubview(forwardButton)

        // Home / start page button
        homeButton = makeNavButton(symbol: "house", action: #selector(showStartPageFromChrome))
        homeButton.toolTip = "Show start page"
        navBar.addSubview(homeButton)

        // Reload button
        reloadButton = makeNavButton(symbol: "arrow.clockwise", action: #selector(reload))
        navBar.addSubview(reloadButton)

        // Loading bar — minimal determinate line pinned to bottom of nav bar.
        // Fills left→right based on WKWebView.estimatedProgress, fades out on finish.
        loadingBar = NSView()
        loadingBar.translatesAutoresizingMaskIntoConstraints = false
        loadingBar.wantsLayer = true
        loadingBar.alphaValue = 0
        navBar.addSubview(loadingBar)

        loadingBarFill = NSView()
        loadingBarFill.translatesAutoresizingMaskIntoConstraints = false
        loadingBarFill.wantsLayer = true
        loadingBarFill.layer?.backgroundColor = activeAccent.cgColor
        loadingBarFill.layer?.cornerRadius = 0.75
        loadingBar.addSubview(loadingBarFill)

        // URL pill background
        urlPill = NSView()
        urlPill.translatesAutoresizingMaskIntoConstraints = false
        urlPill.wantsLayer = true
        urlPill.layer?.backgroundColor = idleBg.cgColor
        urlPill.layer?.cornerRadius = 6
        urlPill.layer?.cornerCurve = .continuous
        urlPill.layer?.borderWidth = 1
        urlPill.layer?.borderColor = chromeStroke.cgColor
        navBar.addSubview(urlPill)

        // Lock icon
        lockIcon = NSImageView()
        lockIcon.translatesAutoresizingMaskIntoConstraints = false
        let lockCfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        lockIcon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Secure")?.withSymbolConfiguration(lockCfg)
        lockIcon.contentTintColor = NSColor(white: 0.45, alpha: 1.0)
        lockIcon.imageScaling = .scaleProportionallyDown
        lockIcon.isHidden = true
        urlPill.addSubview(lockIcon)

        // URL text field (custom subclass to detect focus)
        let field = URLBarTextField()
        field.browserPanel = self
        field.onBecomeFirstResponder = { [weak self] in
            guard let self = self, !self.isUrlFocused else { return }
            self.isUrlFocused = true
            self.showFullURL()
            self.showAutocomplete(for: self.currentAddressBarText())
            DispatchQueue.main.async {
                self.urlField.currentEditor()?.selectAll(nil)
            }
        }
        urlField = field
        urlField.translatesAutoresizingMaskIntoConstraints = false
        urlField.font = .systemFont(ofSize: 13, weight: .regular)
        urlField.textColor = chromeMutedTint
        urlField.placeholderString = "Search or enter a website"
        urlField.drawsBackground = false
        urlField.isBordered = false
        urlField.focusRingType = .none
        urlField.alignment = .left
        urlField.isEditable = true
        urlField.isSelectable = true
        urlField.delegate = self
        if let cell = urlField.cell as? NSTextFieldCell {
            cell.drawsBackground = false
            cell.isScrollable = true
            cell.sendsActionOnEndEditing = false
        }
        urlPill.addSubview(urlField)

        // Key icon — shows when saved passwords exist for this site, click to autofill
        keyButton = NSButton()
        keyButton.translatesAutoresizingMaskIntoConstraints = false
        keyButton.bezelStyle = .texturedRounded
        keyButton.isBordered = false
        let keyCfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        keyButton.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "Saved passwords")?.withSymbolConfiguration(keyCfg)
        keyButton.contentTintColor = NSColor.systemYellow.withAlphaComponent(0.8)
        keyButton.isHidden = true
        keyButton.target = self
        keyButton.action = #selector(showPasswordMenu)
        keyButton.toolTip = "Saved passwords available — click to autofill"
        urlPill.addSubview(keyButton)

        // Cookie/shield indicator button (inside URL pill, after lock icon)
        cookieButton = NSButton()
        cookieButton.translatesAutoresizingMaskIntoConstraints = false
        cookieButton.bezelStyle = .texturedRounded
        cookieButton.isBordered = false
        let cookieCfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        cookieButton.image = NSImage(systemSymbolName: "shield.fill", accessibilityDescription: "Cookies")?.withSymbolConfiguration(cookieCfg)
        cookieButton.contentTintColor = NSColor(white: 0.35, alpha: 1.0)
        cookieButton.isHidden = true
        cookieButton.target = self
        cookieButton.action = #selector(showCookiePopover)
        urlPill.addSubview(cookieButton)

        // Popup toggle button
        popupToggleButton = makeNavButton(symbol: "macwindow.badge.plus", action: #selector(togglePopups))
        popupToggleButton.toolTip = "Popups allowed — click to block"
        navBar.addSubview(popupToggleButton)
        updatePopupToggleIcon()

        // Bookmark star button
        bookmarkButton = makeNavButton(symbol: "star", action: #selector(toggleBookmark))
        navBar.addSubview(bookmarkButton)

        // Menu button (bookmarks & history)
        menuButton = makeNavButton(symbol: "line.3.horizontal", action: #selector(showBrowserMenu))
        navBar.addSubview(menuButton)

        navBottomBorder = NSView()
        navBottomBorder.translatesAutoresizingMaskIntoConstraints = false
        navBottomBorder.wantsLayer = true
        navBar.addSubview(navBottomBorder)

        // WebView — with persistent data store and shared process pool for cookies
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        config.websiteDataStore = persistentDataStore

        // Share a single process pool across all browser panels to reduce the number
        // of WebContent processes and avoid redundant sandbox entitlement checks.
        config.processPool = BrowserPanel.sharedProcessPool

        // Media playback configuration — reduces WebContent/GPU process restrictions
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        if #available(macOS 14.0, *) {
            config.preferences.isTextInteractionEnabled = true
        }

        let pagePrefs = WKWebpagePreferences()
        pagePrefs.allowsContentJavaScript = true
        pagePrefs.preferredContentMode = .desktop
        config.defaultWebpagePreferences = pagePrefs

        // Apply anti-fingerprint patch only for known OAuth providers.
        // Running this globally can interfere with SPA boot/runtime checks on normal sites.
        let oauthHostsJS = oauthProviderHosts.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
        let antiFingerprint = WKUserScript(source: """
            (function() {
                var host = (window.location && window.location.hostname || '').toLowerCase();
                var allowlist = [\(oauthHostsJS)];
                var shouldPatch = allowlist.some(function(allowed) {
                    return host === allowed || host.endsWith('.' + allowed);
                });
                if (!shouldPatch) return;

                // Remove WKWebView-specific properties that OAuth providers check.
                Object.defineProperty(navigator, 'standalone', { get: function() { return undefined; } });
                if (!window.safari) {
                    window.safari = { pushNotification: { permission: function() { return 'denied'; }, requestPermission: function() {} } };
                }
                delete window.__gCrWeb;
                delete window.__crWeb;
                if (!window.MediaSource) { window.MediaSource = class MediaSource {}; }
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(antiFingerprint)

        // Register WebAuthn bridge — intercepts navigator.credentials.get/create and
        // performs passkey operations natively via ASAuthorization (no entitlement needed)
        webAuthnHandler = WebAuthnHandler(window: nil)
        webAuthnHandler?.register(on: config)

        formAutofillManager = FormAutofillManager()
        formAutofillManager?.parentView = self
        formAutofillManager?.register(on: config)

        // Eruda dev tools — injected as user script to bypass CSP
        if let erudaURL = Bundle.main.url(forResource: "eruda.min", withExtension: "js"),
           let erudaSource = try? String(contentsOf: erudaURL, encoding: .utf8) {
            print("[DevTools] Loaded eruda.min.js from bundle (\(erudaSource.count) chars)")
            // Create a permissive Trusted Types policy so eruda can use innerHTML on sites like YouTube
            let trustedTypesPolyfill = WKUserScript(source: """
                if (window.trustedTypes && window.trustedTypes.createPolicy) {
                    try {
                        window.trustedTypes.createPolicy('default', {
                            createHTML: function(s) { return s; },
                            createScript: function(s) { return s; },
                            createScriptURL: function(s) { return s; }
                        });
                    } catch(e) {}
                }
                """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            config.userContentController.addUserScript(trustedTypesPolyfill)
            let erudaScript = WKUserScript(source: erudaSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            config.userContentController.addUserScript(erudaScript)
            let erudaBootstrap = WKUserScript(source: """
                window.__clomeDevToolsReady = true;
                window.__clomeToggleDevTools = function() {
                    if (typeof eruda !== 'undefined') {
                        if (eruda._isInit) { eruda.show(); } else { eruda.init(); eruda.show(); }
                    }
                };
                """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            config.userContentController.addUserScript(erudaBootstrap)
        } else {
            print("[DevTools] ERROR: Could not load eruda.min.js from bundle")
        }

        // JS to capture right-click link URL before the menu opens
        let contextMenuJS = WKUserScript(source: """
            document.addEventListener('contextmenu', function(e) {
                var el = e.target;
                var linkURL = null;
                while (el && el !== document) {
                    if (el.tagName === 'A' && el.href) { linkURL = el.href; break; }
                    el = el.parentElement;
                }
                window.webkit.messageHandlers.clomeContextMenu.postMessage({ linkURL: linkURL || '' });
            }, true);
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(contextMenuJS)
        config.userContentController.add(self, name: "clomeContextMenu")

        let nWebView = ClomeWebView(frame: .zero, configuration: config)
        nWebView.browserPanel = self
        webView = nWebView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15"
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        webView.addObserver(self, forKeyPath: "title", options: .new, context: nil)
        webView.addObserver(self, forKeyPath: "estimatedProgress", options: .new, context: nil)
        webAuthnHandler?.webView = webView
        formAutofillManager?.webView = webView
        formAutofillManager?.navBar = navBar

        // Use autoresizing masks instead of Auto Layout for the webView.
        // Auto Layout constraints conflict with Web Inspector's internal NSSplitView,
        // causing recursive layout loops and flickering when the inspector is docked.
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)

        startPageView = BrowserStartPageView()
        startPageView.translatesAutoresizingMaskIntoConstraints = false
        startPageView.onOpenURL = { [weak self] url in
            self?.loadURL(url)
        }
        startPageView.onFocusAddressBar = { [weak self] in
            self?.focusAddressBar()
        }
        startPageView.onImportBrowserData = {
            BrowserImportWindowController.show()
        }
        startPageView.onClearHistory = {
            BookmarkManager.shared.clearHistory()
        }
        addSubview(startPageView)

        // Observe cookie changes for persistence tracking
        persistentDataStore.httpCookieStore.add(self)

        NSLayoutConstraint.activate([
            navBar.topAnchor.constraint(equalTo: topAnchor),
            navBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            navBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            navBar.heightAnchor.constraint(equalToConstant: 34),

            backButton.leadingAnchor.constraint(equalTo: navBar.leadingAnchor, constant: 12),
            backButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 22),
            backButton.heightAnchor.constraint(equalToConstant: 22),

            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 2),
            forwardButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: 22),
            forwardButton.heightAnchor.constraint(equalToConstant: 22),

            homeButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 4),
            homeButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            homeButton.widthAnchor.constraint(equalToConstant: 22),
            homeButton.heightAnchor.constraint(equalToConstant: 22),

            reloadButton.leadingAnchor.constraint(equalTo: homeButton.trailingAnchor, constant: 4),
            reloadButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            reloadButton.widthAnchor.constraint(equalToConstant: 22),
            reloadButton.heightAnchor.constraint(equalToConstant: 22),

            // URL pill — leave room for popup toggle + bookmark + menu buttons on the right
            urlPill.leadingAnchor.constraint(equalTo: reloadButton.trailingAnchor, constant: 10),
            urlPill.trailingAnchor.constraint(equalTo: popupToggleButton.leadingAnchor, constant: -8),
            urlPill.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            urlPill.heightAnchor.constraint(equalToConstant: 24),

            // Lock icon inside pill
            lockIcon.leadingAnchor.constraint(equalTo: urlPill.leadingAnchor, constant: 12),
            lockIcon.centerYAnchor.constraint(equalTo: urlPill.centerYAnchor),
            lockIcon.widthAnchor.constraint(equalToConstant: 12),
            lockIcon.heightAnchor.constraint(equalToConstant: 12),

            // Key icon inside pill (before cookie indicator)
            keyButton.trailingAnchor.constraint(equalTo: cookieButton.leadingAnchor, constant: -2),
            keyButton.centerYAnchor.constraint(equalTo: urlPill.centerYAnchor),
            keyButton.widthAnchor.constraint(equalToConstant: 20),
            keyButton.heightAnchor.constraint(equalToConstant: 20),

            // Cookie indicator inside pill (right edge)
            cookieButton.trailingAnchor.constraint(equalTo: urlPill.trailingAnchor, constant: -8),
            cookieButton.centerYAnchor.constraint(equalTo: urlPill.centerYAnchor),
            cookieButton.widthAnchor.constraint(equalToConstant: 20),
            cookieButton.heightAnchor.constraint(equalToConstant: 20),

            // Text field inside pill — vertically centered
            urlField.leadingAnchor.constraint(equalTo: lockIcon.trailingAnchor, constant: 10),
            urlField.trailingAnchor.constraint(equalTo: cookieButton.leadingAnchor, constant: -4),
            urlField.centerYAnchor.constraint(equalTo: urlPill.centerYAnchor),

            // Popup toggle button
            popupToggleButton.trailingAnchor.constraint(equalTo: bookmarkButton.leadingAnchor, constant: -2),
            popupToggleButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            popupToggleButton.widthAnchor.constraint(equalToConstant: 22),
            popupToggleButton.heightAnchor.constraint(equalToConstant: 22),

            // Bookmark button
            bookmarkButton.trailingAnchor.constraint(equalTo: menuButton.leadingAnchor, constant: -2),
            bookmarkButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            bookmarkButton.widthAnchor.constraint(equalToConstant: 22),
            bookmarkButton.heightAnchor.constraint(equalToConstant: 22),

            // Menu button
            menuButton.trailingAnchor.constraint(equalTo: navBar.trailingAnchor, constant: -12),
            menuButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 22),
            menuButton.heightAnchor.constraint(equalToConstant: 22),

            loadingBar.leadingAnchor.constraint(equalTo: navBar.leadingAnchor),
            loadingBar.trailingAnchor.constraint(equalTo: navBar.trailingAnchor),
            loadingBar.bottomAnchor.constraint(equalTo: navBar.bottomAnchor),
            loadingBar.heightAnchor.constraint(equalToConstant: 1.5),

            loadingBarFill.leadingAnchor.constraint(equalTo: loadingBar.leadingAnchor),
            loadingBarFill.topAnchor.constraint(equalTo: loadingBar.topAnchor),
            loadingBarFill.bottomAnchor.constraint(equalTo: loadingBar.bottomAnchor),

            navBottomBorder.leadingAnchor.constraint(equalTo: navBar.leadingAnchor),
            navBottomBorder.trailingAnchor.constraint(equalTo: navBar.trailingAnchor),
            navBottomBorder.bottomAnchor.constraint(equalTo: navBar.bottomAnchor),
            navBottomBorder.heightAnchor.constraint(equalToConstant: 1),

            startPageView.topAnchor.constraint(equalTo: navBar.bottomAnchor),
            startPageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            startPageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            startPageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        loadingBarFillWidth = loadingBarFill.widthAnchor.constraint(equalToConstant: 0)
        loadingBarFillWidth.isActive = true

        // Hover tracking on pill
        urlPill.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        ))

        applyChromeAppearance()
        refreshStartPage()
        updateStartPageVisibility()
    }

    override func layout() {
        super.layout()
        // Manually position the webView below the browser chrome.
        // Using autoresizing masks instead of Auto Layout to avoid
        // conflicting with Web Inspector's internal NSSplitView.
        let navHeight = navBar?.frame.height ?? 54
        let webFrame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - navHeight)
        if webView.frame != webFrame {
            webView.frame = webFrame
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        webAuthnHandler?.presentationWindow = window
    }

    private func makeNavButton(symbol: String, action: Selector) -> NSButton {
        let button = BrowserChromeButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        button.contentTintColor = chromeTint
        button.target = self
        button.action = action
        button.baseBackgroundColor = NSColor(white: 1.0, alpha: 0.035)
        button.hoverBackgroundColor = NSColor(white: 1.0, alpha: 0.08)
        button.borderColor = chromeStroke
        return button
    }

    func willClose() {
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        persistentDataStore.httpCookieStore.remove(self)
        if let config = webView?.configuration {
            formAutofillManager?.unregister(from: config)
        }
        formAutofillManager?.webView = nil
        webView?.removeObserver(self, forKeyPath: "title")
        webView?.removeObserver(self, forKeyPath: "estimatedProgress")

        // Clear per-webview caches to reclaim WebContent process memory
        let dataTypes: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]
        webView?.configuration.websiteDataStore.removeData(
            ofTypes: dataTypes,
            modifiedSince: Date.distantPast
        ) { /* done */ }

        webView?.removeFromSuperview()
        webView = nil
        autocompletePopup = nil
    }

    /// Suspend heavy resources when this browser is in a background tab.
    func suspendForBackground() {
        // WKWebView doesn't have a public suspend API, but loading about:blank
        // releases the page's JS heap and DOM tree while keeping the process alive.
        // We skip this for lightweight pages to avoid losing state.
    }

    /// Resume from background — just trigger a re-display.
    func resumeFromBackground() {
        webView?.needsDisplay = true
    }

    /// Aggressively free memory under system memory pressure.
    func releaseMemory() {
        // Clear all cached data for this webview's data store
        webView?.configuration.websiteDataStore.removeData(
            ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache],
            modifiedSince: Date.distantPast
        ) { /* done */ }
    }

    deinit {
        MainActor.assumeIsolated {
            webView?.stopLoading()
            webView?.navigationDelegate = nil
            webView?.uiDelegate = nil
            persistentDataStore.httpCookieStore.remove(self)
                if let config = webView?.configuration {
                formAutofillManager?.unregister(from: config)
            }
            formAutofillManager?.webView = nil
            webView?.removeObserver(self, forKeyPath: "title")
        webView?.removeObserver(self, forKeyPath: "estimatedProgress")
            NotificationCenter.default.removeObserver(self)
        }
    }

    override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        Task { @MainActor in
            if keyPath == "title", let pageTitle = webView?.title, !pageTitle.isEmpty {
                title = pageTitle
            } else if keyPath == "estimatedProgress", let wv = webView {
                updateLoadingProgress(CGFloat(wv.estimatedProgress))
            }
        }
    }

    @objc private func appearanceChanged(_ notification: Notification) {
        layer?.backgroundColor = ClomeSettings.shared.backgroundWithOpacity.cgColor
        applyChromeAppearance()
    }

    @objc private func browserDataChanged(_ notification: Notification) {
        updateBookmarkButton()
        refreshStartPage()
    }

    private func applyChromeAppearance() {
        navBar.layer?.backgroundColor = ClomeMacTheme.surfaceColor(.chrome).cgColor
        navBar.layer?.borderColor = chromeStroke.cgColor
        navBar.layer?.borderWidth = 0.5
        navBottomBorder.layer?.backgroundColor = chromeStroke.cgColor
        urlPill.layer?.borderColor = chromeStroke.cgColor
        if !isUrlFocused {
            urlPill.layer?.backgroundColor = idleBg.cgColor
        }
    }

    private func isShowingStartPage(for url: URL?) -> Bool {
        guard let url else { return true }
        return url.absoluteString == "about:blank"
    }

    private func updateStartPageVisibility() {
        let shouldShow = isShowingStartPage(for: storedURL)
        startPageView?.isHidden = !shouldShow
        if shouldShow {
            refreshStartPage()
        }
    }

    private func refreshStartPage() {
        startPageView?.reloadContent(
            bookmarks: BookmarkManager.shared.bookmarks,
            history: BookmarkManager.shared.recentHistory(limit: 10)
        )
    }

    func focusAddressBar(selectAll: Bool = true) {
        window?.makeFirstResponder(urlField)
        guard selectAll else { return }
        DispatchQueue.main.async { [weak self] in
            self?.urlField.currentEditor()?.selectAll(nil)
        }
    }

    func showStartPage() {
        webView.stopLoading()
        if webView.url != nil {
            webView.load(URLRequest(url: URL(string: "about:blank")!))
        }
        storedURL = nil
        title = "Browser"
        urlField.stringValue = ""
        setLoadingState(false)
        updateNavigationButtons()
        showDomain()
        updateStartPageVisibility()
        window?.makeFirstResponder(urlField)
    }

    func reloadPage(fromOrigin: Bool = false) {
        if fromOrigin {
            webView.reloadFromOrigin()
        } else {
            webView.reload()
        }
    }

    func navigateBack() {
        webView.goBack()
    }

    func navigateForward() {
        webView.goForward()
    }

    func toggleSavedSite() {
        toggleBookmark()
    }

    private func updateNavigationButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
    }

    private func currentAddressBarText() -> String {
        if let editor = urlField.currentEditor() {
            return editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func setAddressBarIcon(symbol: String, tint: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        lockIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        lockIcon.contentTintColor = tint
        lockIcon.isHidden = false
    }

    private func relativeTimeString(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func looksLikeDirectNavigation(_ query: String) -> Bool {
        let lower = query.lowercased()
        return lower.contains("://")
            || lower.hasPrefix("localhost")
            || lower.hasPrefix("127.")
            || lower.hasPrefix("192.168.")
            || lower.hasPrefix("10.")
            || (lower.contains(".") && !lower.contains(" "))
    }

    private func cleanedDisplayURL(_ value: String) -> String {
        var cleaned = value
        if cleaned.hasPrefix("https://") { cleaned = String(cleaned.dropFirst(8)) }
        else if cleaned.hasPrefix("http://") { cleaned = String(cleaned.dropFirst(7)) }
        if cleaned.hasPrefix("www.") { cleaned = String(cleaned.dropFirst(4)) }
        if cleaned.hasSuffix("/") { cleaned = String(cleaned.dropLast()) }
        return cleaned
    }

    private func scoreAutocompleteMatch(query: String, title: String, url: String, isBookmark: Bool) -> Int {
        let normalizedQuery = query.lowercased()
        let normalizedTitle = title.lowercased()
        let normalizedURL = url.lowercased()
        let host = URL(string: url)?.host?.lowercased() ?? ""

        var score = 0
        if host == normalizedQuery { score += 160 }
        if host.hasPrefix(normalizedQuery) { score += 120 }
        if normalizedTitle.hasPrefix(normalizedQuery) { score += 100 }
        if normalizedURL.hasPrefix(normalizedQuery) { score += 90 }
        if host.contains(normalizedQuery) { score += 72 }
        if normalizedTitle.contains(normalizedQuery) { score += 58 }
        if normalizedURL.contains(normalizedQuery) { score += 46 }
        if isBookmark { score += 18 }
        return score
    }

    private func activateSuggestion(_ suggestion: URLSuggestion) {
        dismissAutocomplete()
        loadURL(suggestion.value)
        window?.makeFirstResponder(webView)
    }

    fileprivate func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""

        if flags == .command && chars == "r" {
            reloadPage()
            return true
        }
        if flags == [.command, .shift] && chars == "R" {
            reloadPage(fromOrigin: true)
            return true
        }
        if flags == .command && chars == "l" {
            focusAddressBar()
            return true
        }
        if flags == [.command, .shift] && chars == "L" {
            showStartPage()
            return true
        }
        if flags == .command && chars == "[" {
            navigateBack()
            return true
        }
        if flags == .command && chars == "]" {
            navigateForward()
            return true
        }
        if flags == .command && chars == "." {
            webView.stopLoading()
            return true
        }
        if flags == [.option, .command] && chars == "u" {
            viewPageSource()
            return true
        }
        if flags == [.option, .command] && chars == "i" {
            openWebInspector()
            return true
        }

        return false
    }

    // MARK: - URL Bar Display

    func setURL(_ url: URL?) {
        storedURL = url
        if !isUrlFocused { showDomain() }
        updateBookmarkButton()
        updateStartPageVisibility()
    }

    private func showDomain() {
        urlField.alignment = .left
        urlField.textColor = chromeMutedTint

        if let url = storedURL {
            if url.scheme == "https" {
                setAddressBarIcon(symbol: "lock.fill", tint: NSColor.white.withAlphaComponent(0.45))
            } else {
                setAddressBarIcon(symbol: "globe", tint: NSColor.white.withAlphaComponent(0.42))
            }
            if let host = url.host {
                urlField.stringValue = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            } else {
                urlField.stringValue = url.absoluteString
            }
        } else {
            setAddressBarIcon(symbol: "magnifyingglass", tint: NSColor.white.withAlphaComponent(0.36))
            urlField.stringValue = ""
        }

        urlPill.layer?.backgroundColor = idleBg.cgColor
    }

    private func showFullURL() {
        setAddressBarIcon(symbol: "magnifyingglass", tint: NSColor.white.withAlphaComponent(0.46))
        urlPill.layer?.backgroundColor = editBg.cgColor

        let fullURL = storedURL?.absoluteString ?? ""

        if let editor = urlField.currentEditor() as? NSTextView {
            editor.string = fullURL
            editor.setSelectedRange(NSRange(location: 0, length: fullURL.count))
            editor.alignment = .left
            editor.textColor = chromeTint
        } else {
            // Editor not yet active (e.g. double-click before editing starts) —
            // set the value directly and select all on next run loop when editor exists
            urlField.stringValue = fullURL
            urlField.alignment = .left
            urlField.textColor = chromeTint
            DispatchQueue.main.async { [weak self] in
                if let editor = self?.urlField.currentEditor() as? NSTextView {
                    editor.setSelectedRange(NSRange(location: 0, length: fullURL.count))
                    editor.alignment = .left
                    editor.textColor = NSColor(white: 1.0, alpha: 0.72)
                }
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        // Clicks outside URL pill dismiss autocomplete
        if !urlPill.frame.contains(loc) {
            dismissAutocomplete()
        }
        super.mouseDown(with: event)
    }

    // MARK: - Bookmarks

    private func updateBookmarkButton() {
        guard let url = storedURL?.absoluteString else {
            bookmarkButton.contentTintColor = chromeTint
            setBookmarkIcon(filled: false)
            return
        }
        let isBookmarked = BookmarkManager.shared.isBookmarked(url: url)
        setBookmarkIcon(filled: isBookmarked)
        bookmarkButton.contentTintColor = isBookmarked
            ? NSColor.systemYellow
            : chromeTint
    }

    private func setBookmarkIcon(filled: Bool) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let name = filled ? "star.fill" : "star"
        bookmarkButton.image = NSImage(systemSymbolName: name, accessibilityDescription: "Bookmark")?.withSymbolConfiguration(cfg)
    }

    @objc private func toggleBookmark() {
        guard let url = storedURL?.absoluteString else { return }
        if BookmarkManager.shared.isBookmarked(url: url) {
            BookmarkManager.shared.removeBookmark(url: url)
        } else {
            BookmarkManager.shared.addBookmark(title: title, url: url)
        }
        updateBookmarkButton()
    }

    // MARK: - Browser Menu (Bookmarks + History)

    @objc private func showBrowserMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Bookmarks section
        let bookmarksHeader = NSMenuItem(title: "Bookmarks", action: nil, keyEquivalent: "")
        bookmarksHeader.isEnabled = false
        let headerAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor(white: 0.5, alpha: 1.0),
        ]

        let startPageItem = NSMenuItem(title: "Show Start Page", action: #selector(showStartPageFromChrome), keyEquivalent: "")
        startPageItem.target = self
        menu.addItem(startPageItem)

        let importItem = NSMenuItem(title: "Import Browser Data…", action: #selector(importBrowserDataFromMenu), keyEquivalent: "")
        importItem.target = self
        menu.addItem(importItem)

        let popupItem = NSMenuItem(title: popupsAllowed ? "Block Popups" : "Allow Popups", action: #selector(togglePopups), keyEquivalent: "")
        popupItem.target = self
        menu.addItem(popupItem)

        menu.addItem(NSMenuItem.separator())

        bookmarksHeader.attributedTitle = NSAttributedString(string: "BOOKMARKS", attributes: headerAttr)
        menu.addItem(bookmarksHeader)

        let bookmarks = BookmarkManager.shared.bookmarks
        if bookmarks.isEmpty {
            let empty = NSMenuItem(title: "No bookmarks yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for bookmark in bookmarks.prefix(20) {
                let item = NSMenuItem(title: bookmark.title.isEmpty ? bookmark.url : bookmark.title, action: #selector(openBookmark(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = bookmark.url
                // Show domain as subtitle
                if let url = URL(string: bookmark.url), let host = url.host {
                    item.toolTip = host
                }
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // History section
        let historyHeader = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        historyHeader.isEnabled = false
        historyHeader.attributedTitle = NSAttributedString(string: "RECENT HISTORY", attributes: headerAttr)
        menu.addItem(historyHeader)

        let history = BookmarkManager.shared.history
        if history.isEmpty {
            let empty = NSMenuItem(title: "No history yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for entry in history.prefix(15) {
                let displayTitle = entry.title.isEmpty ? entry.url : entry.title
                let item = NSMenuItem(title: displayTitle, action: #selector(openHistoryItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.url
                if let url = URL(string: entry.url), let host = url.host {
                    item.toolTip = host
                }
                menu.addItem(item)
            }

            menu.addItem(NSMenuItem.separator())
            let clearItem = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
            clearItem.target = self
            menu.addItem(clearItem)
        }

        // Site data section
        menu.addItem(NSMenuItem.separator())

        let siteDataHeader = NSMenuItem(title: "Site Data", action: nil, keyEquivalent: "")
        siteDataHeader.isEnabled = false
        siteDataHeader.attributedTitle = NSAttributedString(string: "SITE DATA", attributes: headerAttr)
        menu.addItem(siteDataHeader)

        if let host = storedURL?.host {
            let clearSiteItem = NSMenuItem(title: "Clear Cookies for \(host)", action: #selector(clearCookiesForCurrentSite), keyEquivalent: "")
            clearSiteItem.target = self
            menu.addItem(clearSiteItem)
        }

        let clearAllItem = NSMenuItem(title: "Clear All Cookies & Site Data...", action: #selector(clearAllSiteData), keyEquivalent: "")
        clearAllItem.target = self
        menu.addItem(clearAllItem)

        // View source
        menu.addItem(NSMenuItem.separator())

        let sourceMenuItem = NSMenuItem(title: "View Page Source", action: #selector(menuViewSource), keyEquivalent: "u")
        sourceMenuItem.keyEquivalentModifierMask = [.option, .command]
        sourceMenuItem.target = self
        menu.addItem(sourceMenuItem)

        // Position below the menu button
        menu.popUp(positioning: nil, at: NSPoint(x: menuButton.frame.minX, y: menuButton.frame.minY), in: menuButton.superview)
    }

    @objc private func openBookmark(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        loadURL(url)
    }

    @objc private func importBrowserDataFromMenu() {
        BrowserImportWindowController.show()
    }

    @objc private func openHistoryItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        loadURL(url)
    }

    @objc private func clearHistory() {
        BookmarkManager.shared.clearHistory()
    }

    @objc private func menuViewSource() {
        viewPageSource()
    }

    // MARK: - Clear Site Data

    @objc private func clearCookiesForCurrentSite() {
        guard let host = storedURL?.host else { return }
        persistentDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self else { return }
            let domainCookies = cookies.filter { cookie in
                let cookieDomain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                return host == cookieDomain || host.hasSuffix(".\(cookieDomain)")
            }
            for cookie in domainCookies {
                persistentDataStore.httpCookieStore.delete(cookie)
            }
            DispatchQueue.main.async {
                self.updateCookieIndicator()
            }
        }
    }

    @objc private func clearAllSiteData() {
        let alert = NSAlert()
        alert.messageText = "Clear All Site Data?"
        alert.informativeText = "This will remove all cookies, local storage, caches, and other website data. You will be signed out of all websites."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
            persistentDataStore.removeData(ofTypes: allTypes, modifiedSince: .distantPast) {
                DispatchQueue.main.async {
                    self?.updateCookieIndicator()
                    self?.webView.reload()
                }
            }
        }

        if let window = self.window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            let response = alert.runModal()
            handler(response)
        }
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidBeginEditing(_ obj: Notification) {
        // Focus is already handled by URLBarTextField.onBecomeFirstResponder
        // This fires on first keystroke — just ensure state is correct
        if !isUrlFocused {
            isUrlFocused = true
            showFullURL()
        }
        showAutocomplete(for: currentAddressBarText())
    }


    func controlTextDidChange(_ obj: Notification) {
        showAutocomplete(for: currentAddressBarText())
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        isUrlFocused = false
        showDomain()
        // Dismiss after a short delay so click-on-row can fire first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.dismissAutocomplete()
        }
    }

    /// Intercept Enter, arrow keys, Escape for autocomplete navigation.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            // If autocomplete has a selection, use it
            if let popup = autocompletePopup, popup.selectedIndex >= 0, popup.selectedIndex < popup.suggestions.count {
                let suggestion = popup.suggestions[popup.selectedIndex]
                activateSuggestion(suggestion)
                return true
            }
            let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                dismissAutocomplete()
                loadURL(text)
            }
            window?.makeFirstResponder(webView)
            return true
        }
        if commandSelector == #selector(insertTab(_:)) {
            if let popup = autocompletePopup, popup.selectedIndex >= 0, popup.selectedIndex < popup.suggestions.count {
                let suggestion = popup.suggestions[popup.selectedIndex]
                activateSuggestion(suggestion)
                return true
            }
            return false
        }
        if commandSelector == #selector(moveDown(_:)) {
            autocompletePopup?.moveSelection(down: true)
            return true
        }
        if commandSelector == #selector(moveUp(_:)) {
            autocompletePopup?.moveSelection(down: false)
            return true
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            if autocompletePopup != nil {
                dismissAutocomplete()
                return true
            }
            window?.makeFirstResponder(webView)
            isUrlFocused = false
            showDomain()
            return true
        }
        return false
    }

    // MARK: - Autocomplete

    private func showAutocomplete(for query: String) {
        var suggestions: [URLSuggestion] = []
        var seen = Set<String>()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedQuery.isEmpty {
            for bookmark in BookmarkManager.shared.bookmarks.suffix(5).reversed() {
                let key = bookmark.url.lowercased()
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                suggestions.append(URLSuggestion(
                    title: bookmark.title.isEmpty ? cleanedDisplayURL(bookmark.url) : bookmark.title,
                    subtitle: cleanedDisplayURL(bookmark.url),
                    value: bookmark.url,
                    kind: .bookmark
                ))
            }

            for entry in BookmarkManager.shared.recentHistory(limit: 6, dedupeByHost: false) {
                let key = entry.url.lowercased()
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                suggestions.append(URLSuggestion(
                    title: entry.title.isEmpty ? cleanedDisplayURL(entry.url) : entry.title,
                    subtitle: "\(cleanedDisplayURL(entry.url))  •  \(relativeTimeString(for: entry.date))",
                    value: entry.url,
                    kind: .history
                ))
            }
        } else {
            suggestions.append(URLSuggestion(
                title: looksLikeDirectNavigation(trimmedQuery) ? "Open \(cleanedDisplayURL(trimmedQuery))" : "Try \(trimmedQuery) as a website",
                subtitle: "Navigate directly from the address bar",
                value: trimmedQuery,
                kind: .directNavigation
            ))
            suggestions.append(URLSuggestion(
                title: "Search Google for “\(trimmedQuery)”",
                subtitle: "Use the address bar as search",
                value: trimmedQuery,
                kind: .search
            ))

            var rankedMatches: [(Int, URLSuggestion)] = []

            for bookmark in BookmarkManager.shared.bookmarks {
                let score = scoreAutocompleteMatch(query: trimmedQuery, title: bookmark.title, url: bookmark.url, isBookmark: true)
                guard score > 0 else { continue }
                rankedMatches.append((
                    score,
                    URLSuggestion(
                        title: bookmark.title.isEmpty ? cleanedDisplayURL(bookmark.url) : bookmark.title,
                        subtitle: cleanedDisplayURL(bookmark.url),
                        value: bookmark.url,
                        kind: .bookmark
                    )
                ))
            }

            for entry in BookmarkManager.shared.history {
                let score = scoreAutocompleteMatch(query: trimmedQuery, title: entry.title, url: entry.url, isBookmark: false)
                guard score > 0 else { continue }
                rankedMatches.append((
                    score,
                    URLSuggestion(
                        title: entry.title.isEmpty ? cleanedDisplayURL(entry.url) : entry.title,
                        subtitle: "\(cleanedDisplayURL(entry.url))  •  \(relativeTimeString(for: entry.date))",
                        value: entry.url,
                        kind: .history
                    )
                ))
            }

            for suggestion in rankedMatches.sorted(by: { lhs, rhs in
                if lhs.0 == rhs.0 {
                    return lhs.1.title.localizedCaseInsensitiveCompare(rhs.1.title) == .orderedAscending
                }
                return lhs.0 > rhs.0
            }).map(\.1) {
                let key = suggestion.value.lowercased()
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                suggestions.append(suggestion)
                if suggestions.count >= 10 { break }
            }
        }

        if suggestions.isEmpty {
            dismissAutocomplete()
            return
        }

        guard let parentWindow = window else { return }

        if autocompletePopup == nil {
            let popup = URLAutocompletePopup()
            popup.onSelect = { [weak self] suggestion in
                self?.activateSuggestion(suggestion)
            }
            autocompletePopup = popup
        }

        guard let popup = autocompletePopup else { return }
        popup.update(suggestions: suggestions)
        popup.showBelow(view: urlPill, in: parentWindow)
    }

    private func dismissAutocomplete() {
        autocompletePopup?.dismiss()
        autocompletePopup = nil
    }

    // MARK: - Hover

    override func mouseEntered(with event: NSEvent) {
        if !isUrlFocused { urlPill.layer?.backgroundColor = hoverBg.cgColor }
    }

    override func mouseExited(with event: NSEvent) {
        if !isUrlFocused { urlPill.layer?.backgroundColor = idleBg.cgColor }
    }

    // MARK: - Navigation

    func loadURL(_ url: URL) {
        startPageView?.isHidden = true
        webView.load(URLRequest(url: url))
    }

    func loadURL(_ urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let isURL = trimmed.contains("://")
            || (trimmed.contains(".") && !trimmed.contains(" "))

        let finalString: String
        if isURL {
            finalString = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        } else {
            let query = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
            finalString = "https://www.google.com/search?q=\(query)"
        }

        guard let url = URL(string: finalString) else { return }
        loadURL(url)
    }

    @objc private func goBack() {
        navigateBack()
    }

    @objc private func goForward() {
        navigateForward()
    }

    @objc private func reload() {
        reloadPage()
    }

    @objc private func showStartPageFromChrome() {
        showStartPage()
    }

    // MARK: - WKNavigationDelegate

    func webView(_ finishedWebView: WKWebView, didFinish navigation: WKNavigation!) {
        guard finishedWebView === webView else {
            return
        }
        setLoadingState(false)

        setURL(finishedWebView.url)
        if let pageTitle = finishedWebView.title, !pageTitle.isEmpty {
            title = pageTitle
        }
        updateNavigationButtons()
        fetchFavicon()

        // Track in history
        if let url = finishedWebView.url?.absoluteString {
            BookmarkManager.shared.addHistory(title: title, url: url)
        }

        // Update indicators for new page
        updateCookieIndicator()
        updateKeyIndicator()

        // Trigger autofill check for the loaded page
        formAutofillManager?.pageDidFinish(url: finishedWebView.url)
    }

    private func fetchFavicon() {
        let js = """
        (function() {
            var link = document.querySelector('link[rel~="icon"]') || document.querySelector('link[rel="shortcut icon"]');
            return link ? link.href : '';
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self else { return }
            var faviconURL: URL?
            if let href = result as? String, !href.isEmpty {
                faviconURL = URL(string: href)
            } else if let pageURL = self.storedURL, let scheme = pageURL.scheme, let host = pageURL.host {
                faviconURL = URL(string: "\(scheme)://\(host)/favicon.ico")
            }
            guard let url = faviconURL else { return }
            URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
                guard let data = data,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let image = NSImage(data: data) else { return }
                DispatchQueue.main.async {
                    self?.favicon = image
                    NotificationCenter.default.post(name: .terminalSurfaceTitleChanged, object: self)
                }
            }.resume()
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        setLoadingState(true)
        setURL(webView.url)
        updateNavigationButtons()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        setLoadingState(false)
        let nsError = error as NSError
        // Ignore cancellations (user navigated away before load finished)
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        CrashReporter.shared.error("Provisional navigation failed: \(error.localizedDescription) url=\(webView.url?.absoluteString ?? "nil")", category: "browser")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        setLoadingState(false)
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        CrashReporter.shared.error("Navigation failed: \(error.localizedDescription) url=\(webView.url?.absoluteString ?? "nil")", category: "browser")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        setLoadingState(false)
        CrashReporter.shared.error("WebContent process terminated, reloading. url=\(webView.url?.absoluteString ?? "nil")", category: "browser")
        webView.reload()
    }

    // MARK: - WKNavigationDelegate — Navigation Policy

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow, preferences)
            return
        }

        let host = url.host?.lowercased() ?? ""
        let scheme = url.scheme?.lowercased() ?? ""

        // For OAuth provider hosts, ensure JavaScript is enabled and cookies flow through
        if oauthProviderHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
            preferences.allowsContentJavaScript = true
            decisionHandler(.allow, preferences)
            return
        }

        if scheme == "https" || scheme == "http" || scheme == "about" || scheme == "blob" || scheme == "data" {
            decisionHandler(.allow, preferences)
            return
        }

        if scheme.contains("auth") || scheme.contains("callback") || scheme.contains("oauth") {
            decisionHandler(.allow, preferences)
            return
        }

        if scheme == "mailto" || scheme == "tel" || scheme == "sms" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel, preferences)
            return
        }

        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        // Always allow responses -- never block auth redirects or passkey ceremony responses
        decisionHandler(.allow)
    }

    private func setLoadingState(_ loading: Bool) {
        guard isPageLoading != loading else { return }
        isPageLoading = loading

        if loading {
            reloadButton.contentTintColor = activeAccent
            // Reset to a small head-start so the line is immediately visible.
            loadingBarFillWidth.constant = 0
            loadingBar.layoutSubtreeIfNeeded()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                loadingBar.animator().alphaValue = 1
            }
        } else {
            reloadButton.contentTintColor = chromeTint
            // Snap to full, then fade out.
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                ctx.allowsImplicitAnimation = true
                loadingBarFillWidth.constant = loadingBar.bounds.width
                loadingBar.layoutSubtreeIfNeeded()
            }, completionHandler: { [weak self] in
                guard let self = self else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.22
                    self.loadingBar.animator().alphaValue = 0
                }, completionHandler: {
                    self.loadingBarFillWidth.constant = 0
                })
            })
        }
    }

    private func updateLoadingProgress(_ progress: CGFloat) {
        guard isPageLoading else { return }
        let total = loadingBar.bounds.width
        guard total > 0 else { return }
        // Minimum 6% so the bar is always perceptible at load start.
        let clamped = max(0.06, min(progress, 1.0))
        let target = total * clamped
        // Only animate forward — never shrink.
        guard target > loadingBarFillWidth.constant else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            loadingBarFillWidth.constant = target
            loadingBar.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - Send to Context

    func getSelectedText(completion: @escaping (String?) -> Void) {
        webView.evaluateJavaScript("window.getSelection().toString()") { result, _ in
            completion(result as? String)
        }
    }

    // MARK: - WKUIDelegate — JavaScript Dialogs

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Alert"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if let window = self.window {
            alert.beginSheetModal(for: window) { _ in
                completionHandler()
            }
        } else {
            alert.runModal()
            completionHandler()
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Confirm"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        if let window = self.window {
            alert.beginSheetModal(for: window) { response in
                completionHandler(response == .alertFirstButtonReturn)
            }
        } else {
            let response = alert.runModal()
            completionHandler(response == .alertFirstButtonReturn)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Prompt"
        alert.informativeText = prompt
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = defaultText ?? ""
        alert.accessoryView = input

        if let window = self.window {
            alert.beginSheetModal(for: window) { response in
                completionHandler(response == .alertFirstButtonReturn ? input.stringValue : nil)
            }
        } else {
            let response = alert.runModal()
            completionHandler(response == .alertFirstButtonReturn ? input.stringValue : nil)
        }
    }

    // MARK: - WKUIDelegate — Popup Windows

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if !popupsAllowed {
            return nil
        }

        // Load in the SAME webView using the ORIGINAL request — not a new URLRequest.
        // The original request preserves the HTTP method (POST), headers, body/form data,
        // and auth tokens. Creating a new URLRequest(url:) would discard all of that,
        // which breaks flows like OnDemand → code-server where the click carries auth context.
        webView.load(navigationAction.request)
        return nil
    }

    // MARK: - Context Menu (Right-Click)

    /// Intercept and customize the webView's default context menu.
    /// WKWebView on macOS provides a default menu; we add our items to it.
    private func setupContextMenu() {
        // Inject JS that captures right-click target info and stores it
        let contextJS = WKUserScript(source: """
            document.addEventListener('contextmenu', function(e) {
                var el = e.target;
                var linkURL = null;
                var imgURL = null;
                // Walk up to find the nearest <a> or <img>
                while (el && el !== document) {
                    if (!linkURL && el.tagName === 'A' && el.href) linkURL = el.href;
                    if (!imgURL && el.tagName === 'IMG' && el.src) imgURL = el.src;
                    el = el.parentElement;
                }
                window.__clomeContextInfo = { linkURL: linkURL, imgURL: imgURL };
            }, true);
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        webView.configuration.userContentController.addUserScript(contextJS)
    }

    /// Called by the webView's menu system — we override willOpenMenu on the webView.
    func installContextMenuHandler() {
        // Swizzle is complex; instead, use a simpler approach:
        // Add a tracking area and intercept right-click via menuForEvent
    }

    /// Build a context menu with our custom items, called from the webView's menu.
    func buildContextMenu(linkURL: URL?) -> NSMenu {
        let menu = NSMenu()

        if let linkURL = linkURL {
            let openTab = NSMenuItem(title: "Open Link in New Tab", action: #selector(contextMenuOpenInNewTab(_:)), keyEquivalent: "")
            openTab.target = self
            openTab.representedObject = linkURL
            menu.addItem(openTab)

            let openSame = NSMenuItem(title: "Open Link", action: #selector(contextMenuOpenInSameTab(_:)), keyEquivalent: "")
            openSame.target = self
            openSame.representedObject = linkURL
            menu.addItem(openSame)

            menu.addItem(NSMenuItem.separator())

            let copyLink = NSMenuItem(title: "Copy Link", action: #selector(contextMenuCopyLink(_:)), keyEquivalent: "")
            copyLink.target = self
            copyLink.representedObject = linkURL
            menu.addItem(copyLink)

            let copyMD = NSMenuItem(title: "Copy Link as Markdown", action: #selector(contextMenuCopyMarkdownLink(_:)), keyEquivalent: "")
            copyMD.target = self
            copyMD.representedObject = linkURL
            menu.addItem(copyMD)

            menu.addItem(NSMenuItem.separator())

            let download = NSMenuItem(title: "Download Linked File", action: #selector(contextMenuDownloadLink(_:)), keyEquivalent: "")
            download.target = self
            download.representedObject = linkURL
            menu.addItem(download)

            menu.addItem(NSMenuItem.separator())
        }

        // Standard page actions
        let back = NSMenuItem(title: "Back", action: #selector(goBack), keyEquivalent: "")
        back.target = self
        back.isEnabled = webView.canGoBack
        menu.addItem(back)

        let forward = NSMenuItem(title: "Forward", action: #selector(goForward), keyEquivalent: "")
        forward.target = self
        forward.isEnabled = webView.canGoForward
        menu.addItem(forward)

        let reloadItem = NSMenuItem(title: "Reload", action: #selector(reload), keyEquivalent: "")
        reloadItem.target = self
        menu.addItem(reloadItem)

        menu.addItem(NSMenuItem.separator())

        let copyPage = NSMenuItem(title: "Copy Page URL", action: #selector(contextMenuCopyPageURL), keyEquivalent: "")
        copyPage.target = self
        menu.addItem(copyPage)

        menu.addItem(NSMenuItem.separator())

        let viewSourceItem = NSMenuItem(title: "View Page Source", action: #selector(contextMenuViewSource), keyEquivalent: "")
        viewSourceItem.target = self
        menu.addItem(viewSourceItem)

        let inspectItem = NSMenuItem(title: "Inspect Element", action: #selector(openWebInspector), keyEquivalent: "")
        inspectItem.target = self
        menu.addItem(inspectItem)

        return menu
    }

    @objc private func contextMenuViewSource() {
        viewPageSource()
    }

    @objc private func openWebInspector() {
        let sel = NSSelectorFromString("_inspector")
        guard webView.responds(to: sel),
              let inspector = webView.perform(sel)?.takeUnretainedValue() as? NSObject else { return }
        let showSel = NSSelectorFromString("show")
        if inspector.responds(to: showSel) {
            inspector.perform(showSel)
        }
    }

    @objc private func contextMenuOpenInNewTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        _ = delegate?.browserPanel(self, openNewTabWith: url)
    }

    @objc private func contextMenuOpenInSameTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        webView.load(URLRequest(url: url))
    }

    @objc private func contextMenuCopyLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc private func contextMenuCopyMarkdownLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let linkTitle = title.isEmpty ? url.absoluteString : title
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("[\(linkTitle)](\(url.absoluteString))", forType: .string)
    }

    @objc private func contextMenuDownloadLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destURL = panel.url else { return }
            URLSession.shared.downloadTask(with: url) { tempURL, _, error in
                guard let tempURL = tempURL, error == nil else { return }
                try? FileManager.default.moveItem(at: tempURL, to: destURL)
            }.resume()
        }
    }

    @objc private func contextMenuCopyPageURL() {
        guard let url = storedURL?.absoluteString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    // MARK: - WKScriptMessageHandler (Context Menu)

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "clomeContextMenu",
           let dict = message.body as? [String: Any],
           let linkStr = dict["linkURL"] as? String,
           !linkStr.isEmpty,
           let url = URL(string: linkStr) {
            (webView as? ClomeWebView)?.lastContextLinkURL = url
        }

    }

    // MARK: - Popup Toggle

    @objc private func togglePopups() {
        popupsAllowed.toggle()
    }

    private func updatePopupToggleIcon() {
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        if popupsAllowed {
            popupToggleButton.image = NSImage(systemSymbolName: "macwindow.badge.plus", accessibilityDescription: "Popups allowed")?.withSymbolConfiguration(cfg)
            popupToggleButton.contentTintColor = chromeTint
            popupToggleButton.toolTip = "Popups allowed — click to block"
        } else {
            popupToggleButton.image = NSImage(systemSymbolName: "xmark.rectangle", accessibilityDescription: "Popups blocked")?.withSymbolConfiguration(cfg)
            popupToggleButton.contentTintColor = NSColor.systemRed.withAlphaComponent(0.7)
            popupToggleButton.toolTip = "Popups blocked — click to allow"
        }
    }

    // MARK: - WKNavigationDelegate — Authentication Challenges

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let protectionSpace = challenge.protectionSpace
        let authMethod = protectionSpace.authenticationMethod

        if authMethod == NSURLAuthenticationMethodServerTrust {
            // Server trust evaluation — accept valid certificates
            guard let serverTrust = protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)

        } else if authMethod == NSURLAuthenticationMethodHTTPBasic
                    || authMethod == NSURLAuthenticationMethodHTTPDigest
                    || authMethod == NSURLAuthenticationMethodDefault {
            // Check for existing stored credentials first
            let stored = URLCredentialStorage.shared.defaultCredential(for: protectionSpace)
            if let stored = stored, challenge.previousFailureCount == 0 {
                completionHandler(.useCredential, stored)
                return
            }

            // Show credential prompt dialog
            showAuthenticationDialog(for: protectionSpace, failureCount: challenge.previousFailureCount) { username, password, shouldSave in
                guard let username = username, let password = password else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    return
                }
                let persistence: URLCredential.Persistence = shouldSave ? .permanent : .forSession
                let credential = URLCredential(user: username, password: password, persistence: persistence)
                if shouldSave {
                    URLCredentialStorage.shared.setDefaultCredential(credential, for: protectionSpace)
                }
                completionHandler(.useCredential, credential)
            }

        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: - Authentication Dialog

    private func showAuthenticationDialog(for protectionSpace: URLProtectionSpace, failureCount: Int, completion: @escaping (String?, String?, Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Authentication Required"

        let host = protectionSpace.host
        let realm = protectionSpace.realm ?? ""
        var info = "The server \"\(host)\" requires a username and password."
        if !realm.isEmpty {
            info += "\nRealm: \(realm)"
        }
        if failureCount > 0 {
            info += "\n\nThe previous credentials were incorrect. Please try again."
        }
        alert.informativeText = info

        alert.addButton(withTitle: "Log In")
        alert.addButton(withTitle: "Cancel")

        // Build accessory view with username, password, and save checkbox
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 90))

        let userLabel = NSTextField(labelWithString: "Username:")
        userLabel.frame = NSRect(x: 0, y: 64, width: 75, height: 20)
        userLabel.font = .systemFont(ofSize: 12)
        container.addSubview(userLabel)

        let userField = NSTextField(frame: NSRect(x: 80, y: 64, width: 200, height: 22))
        userField.font = .systemFont(ofSize: 12)
        container.addSubview(userField)

        let passLabel = NSTextField(labelWithString: "Password:")
        passLabel.frame = NSRect(x: 0, y: 36, width: 75, height: 20)
        passLabel.font = .systemFont(ofSize: 12)
        container.addSubview(passLabel)

        let passField = NSSecureTextField(frame: NSRect(x: 80, y: 36, width: 200, height: 22))
        passField.font = .systemFont(ofSize: 12)
        container.addSubview(passField)

        let saveCheck = NSButton(checkboxWithTitle: "Save to Keychain", target: nil, action: nil)
        saveCheck.frame = NSRect(x: 80, y: 6, width: 200, height: 20)
        saveCheck.state = .on
        saveCheck.font = .systemFont(ofSize: 11)
        container.addSubview(saveCheck)

        alert.accessoryView = container

        if let window = self.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    completion(userField.stringValue, passField.stringValue, saveCheck.state == .on)
                } else {
                    completion(nil, nil, false)
                }
            }
        } else {
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                completion(userField.stringValue, passField.stringValue, saveCheck.state == .on)
            } else {
                completion(nil, nil, false)
            }
        }
    }

    // MARK: - Password Key Indicator

    /// Update the key icon visibility — shown when saved credentials exist for current host.
    private func updateKeyIndicator() {
        guard let host = storedURL?.host else {
            keyButton.isHidden = true
            return
        }
        let credentials = CredentialStore.shared.credentialsForHost(host)
        keyButton.isHidden = credentials.isEmpty
    }

    /// Show a menu of saved credentials for this host, with option to autofill.
    @objc private func showPasswordMenu() {
        guard let host = storedURL?.host else { return }
        let credentials = CredentialStore.shared.credentialsForHost(host)
        guard !credentials.isEmpty else { return }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let headerAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor(white: 0.5, alpha: 1.0),
        ]
        let header = NSMenuItem(title: "SAVED PASSWORDS", action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.attributedTitle = NSAttributedString(string: "SAVED PASSWORDS", attributes: headerAttr)
        menu.addItem(header)

        for cred in credentials {
            let displayName = cred.username.isEmpty ? host : cred.username
            let item = NSMenuItem(title: displayName, action: #selector(autofillCredential(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = cred
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            item.image = NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let deleteHeader = NSMenuItem(title: "Manage", action: nil, keyEquivalent: "")
        deleteHeader.isEnabled = false
        deleteHeader.attributedTitle = NSAttributedString(string: "MANAGE", attributes: headerAttr)
        menu.addItem(deleteHeader)

        for cred in credentials {
            let displayName = "Delete \(cred.username.isEmpty ? "password" : cred.username)"
            let item = NSMenuItem(title: displayName, action: #selector(deleteCredential(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = cred
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            menu.addItem(item)
        }

        menu.popUp(positioning: nil, at: NSPoint(x: keyButton.frame.minX, y: keyButton.frame.minY), in: keyButton.superview)
    }

    @objc private func autofillCredential(_ sender: NSMenuItem) {
        guard let cred = sender.representedObject as? SavedCredential else { return }
        let safeUser = cred.username.replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\\", with: "\\\\")
        let safePass = cred.password.replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\\", with: "\\\\")
        let js = "if (window.__clomeFillCredentials) window.__clomeFillCredentials('\(safeUser)', '\(safePass)');"
        webView.evaluateJavaScript(js, completionHandler: nil)
        CredentialStore.shared.touchCredential(host: cred.host, username: cred.username)
    }

    @objc private func deleteCredential(_ sender: NSMenuItem) {
        guard let cred = sender.representedObject as? SavedCredential else { return }
        CredentialStore.shared.deleteCredential(host: cred.host, username: cred.username)
        updateKeyIndicator()
    }

    /// View page source — writes to temp file and opens in default editor
    func viewPageSource() {
        let js = "document.documentElement.outerHTML"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let html = result as? String else { return }
            let tmpDir = FileManager.default.temporaryDirectory
            let fileName = (self?.storedURL?.host ?? "page") + "_source.html"
            let tmpFile = tmpDir.appendingPathComponent(fileName)
            try? html.write(to: tmpFile, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(tmpFile)
        }
    }

    // MARK: - Keyboard Shortcuts

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleKeyEquivalent(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handleKeyEquivalent(event) {
            return
        }

        super.keyDown(with: event)
    }

    // MARK: - Cookie Indicator

    private func updateCookieIndicator() {
        guard let host = storedURL?.host else {
            cookieButton.isHidden = true
            currentDomainCookieCount = 0
            return
        }
        persistentDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self else { return }
            let count = cookies.filter { cookie in
                let cookieDomain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                return host == cookieDomain || host.hasSuffix(".\(cookieDomain)")
            }.count
            DispatchQueue.main.async {
                self.currentDomainCookieCount = count
                self.cookieButton.isHidden = count == 0
                // Tint indicates cookie presence: orange if cookies stored, dim otherwise
                self.cookieButton.contentTintColor = count > 0
                    ? NSColor.systemOrange.withAlphaComponent(0.7)
                    : NSColor(white: 0.35, alpha: 1.0)
            }
        }
    }

    @objc private func showCookiePopover() {
        guard let host = storedURL?.host else { return }
        persistentDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self else { return }
            let domainCookies = cookies.filter { cookie in
                let cookieDomain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                return host == cookieDomain || host.hasSuffix(".\(cookieDomain)")
            }
            DispatchQueue.main.async {
                self.presentCookiePopover(host: host, cookies: domainCookies)
            }
        }
    }

    private func presentCookiePopover(host: String, cookies: [HTTPCookie]) {
        let popover = NSPopover()
        popover.behavior = .transient

        let vc = NSViewController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 0))

        let titleLabel = NSTextField(labelWithString: "Cookies for \(host)")
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = NSColor(white: 0.9, alpha: 1.0)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        let countLabel = NSTextField(labelWithString: "\(cookies.count) cookie\(cookies.count == 1 ? "" : "s") stored")
        countLabel.font = .systemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = NSColor(white: 0.55, alpha: 1.0)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(countLabel)

        // Show first few cookie names as detail
        let maxDisplay = min(cookies.count, 5)
        var detailLines: [String] = []
        for i in 0..<maxDisplay {
            detailLines.append(cookies[i].name)
        }
        if cookies.count > maxDisplay {
            detailLines.append("... and \(cookies.count - maxDisplay) more")
        }
        let detailText = detailLines.joined(separator: "\n")
        let detailLabel = NSTextField(labelWithString: detailText)
        detailLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = NSColor(white: 0.45, alpha: 1.0)
        detailLabel.maximumNumberOfLines = 0
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(detailLabel)

        let extraLine: CGFloat = cookies.count > maxDisplay ? 14 : 0
        let contentHeight: CGFloat = CGFloat(20 + 16 + max(maxDisplay, 1) * 14) + extraLine + 24
        container.frame = NSRect(x: 0, y: 0, width: 240, height: contentHeight)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            countLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            countLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            countLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            detailLabel.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 6),
            detailLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            detailLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
        ])

        vc.view = container
        popover.contentViewController = vc
        popover.show(relativeTo: cookieButton.bounds, of: cookieButton, preferredEdge: .maxY)
    }

    // MARK: - WKHTTPCookieStoreObserver

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in
            self?.updateCookieIndicator()
        }
    }
}

// MARK: - URLBarTextField

@MainActor
final class BrowserChromeButton: NSButton {
    var baseBackgroundColor = NSColor(white: 1.0, alpha: 0.035) { didSet { updateAppearance() } }
    var hoverBackgroundColor = NSColor(white: 1.0, alpha: 0.08)
    var borderColor = NSColor(white: 1.0, alpha: 0.08) { didSet { updateAppearance() } }

    private var trackingAreaRef: NSTrackingArea?
    private var isHovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let newTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(newTrackingArea)
        trackingAreaRef = newTrackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.backgroundColor = (isHovering ? hoverBackgroundColor : baseBackgroundColor).cgColor
        layer?.borderColor = borderColor.cgColor
        layer?.borderWidth = 1
    }
}

@MainActor
final class BrowserStartCardButton: NSButton {
    var payloadURL: String?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var trackingAreaRef: NSTrackingArea?
    private var isHovering = false

    private let baseBackgroundColor = NSColor(white: 1.0, alpha: 0.035)
    private let hoverBackgroundColor = NSColor(white: 1.0, alpha: 0.075)
    private let borderColor = NSColor(white: 1.0, alpha: 0.08)

    init(title: String, subtitle: String, icon: String, compact: Bool = false) {
        super.init(frame: .zero)
        self.title = ""
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = compact ? 12 : 16
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        setButtonType(.momentaryPushIn)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        let config = NSImage.SymbolConfiguration(pointSize: compact ? 12 : 13, weight: .medium)
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        iconView.contentTintColor = NSColor(white: 1.0, alpha: 0.66)
        addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: compact ? 12 : 13, weight: .semibold)
        titleLabel.textColor = NSColor(white: 1.0, alpha: 0.92)
        titleLabel.stringValue = title
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: compact ? 11 : 12, weight: .regular)
        subtitleLabel.textColor = NSColor(white: 1.0, alpha: 0.46)
        subtitleLabel.stringValue = subtitle
        subtitleLabel.lineBreakMode = .byTruncatingTail
        addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: compact ? 14 : 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: compact ? 16 : 18),
            iconView.heightAnchor.constraint(equalToConstant: compact ? 16 : 18),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: compact ? 10 : 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: compact ? 11 : 15),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
        ])

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: compact ? 54 : 72),
        ])

        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let newTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(newTrackingArea)
        trackingAreaRef = newTrackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.backgroundColor = (isHovering ? hoverBackgroundColor : baseBackgroundColor).cgColor
        layer?.borderColor = borderColor.cgColor
    }
}

@MainActor
final class BrowserStartPageView: NSView {
    var onOpenURL: ((String) -> Void)?
    var onFocusAddressBar: (() -> Void)?
    var onImportBrowserData: (() -> Void)?
    var onClearHistory: (() -> Void)?

    private let scrollView = NSScrollView()
    private let contentView = NSView()
    private let stackView = NSStackView()
    private let savedSitesStack = NSStackView()
    private let recentSitesStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.075, green: 0.078, blue: 0.095, alpha: 1.0).cgColor

        let topGlow = NSView()
        topGlow.translatesAutoresizingMaskIntoConstraints = false
        topGlow.wantsLayer = true
        topGlow.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.12).cgColor
        topGlow.layer?.cornerRadius = 180
        addSubview(topGlow)

        let sideGlow = NSView()
        sideGlow.translatesAutoresizingMaskIntoConstraints = false
        sideGlow.wantsLayer = true
        sideGlow.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        sideGlow.layer?.cornerRadius = 140
        addSubview(sideGlow)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        addSubview(scrollView)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentView

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 28
        contentView.addSubview(stackView)

        let heroStack = NSStackView()
        heroStack.translatesAutoresizingMaskIntoConstraints = false
        heroStack.orientation = .vertical
        heroStack.alignment = .leading
        heroStack.spacing = 8

        let eyebrow = NSTextField(labelWithString: "START PAGE")
        eyebrow.font = .systemFont(ofSize: 11, weight: .semibold)
        eyebrow.textColor = NSColor(white: 1.0, alpha: 0.34)
        heroStack.addArrangedSubview(eyebrow)

        let titleLabel = NSTextField(labelWithString: "Minimal browsing, faster access.")
        titleLabel.font = .systemFont(ofSize: 30, weight: .semibold)
        titleLabel.textColor = NSColor(white: 1.0, alpha: 0.96)
        heroStack.addArrangedSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: "Saved sites and recently opened pages stay one click away.")
        subtitleLabel.font = .systemFont(ofSize: 14, weight: .regular)
        subtitleLabel.textColor = NSColor(white: 1.0, alpha: 0.52)
        heroStack.addArrangedSubview(subtitleLabel)

        let actionRow = NSStackView()
        actionRow.translatesAutoresizingMaskIntoConstraints = false
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 10

        let locationButton = makeActionButton(title: "Open Address Bar", icon: "command")
        locationButton.target = self
        locationButton.action = #selector(focusAddressBarAction)
        actionRow.addArrangedSubview(locationButton)

        let importButton = makeActionButton(title: "Import Browser Data", icon: "arrow.down.circle")
        importButton.target = self
        importButton.action = #selector(importBrowserDataAction)
        actionRow.addArrangedSubview(importButton)

        let clearButton = makeActionButton(title: "Clear History", icon: "clock.arrow.trianglehead.counterclockwise.rotate.90")
        clearButton.target = self
        clearButton.action = #selector(clearHistoryAction)
        actionRow.addArrangedSubview(clearButton)

        heroStack.addArrangedSubview(actionRow)
        stackView.addArrangedSubview(heroStack)

        let savedSection = makeSection(title: "Saved Sites", subtitle: "Pages you intentionally keep around.", contentStack: savedSitesStack)
        stackView.addArrangedSubview(savedSection)

        let recentSection = makeSection(title: "Recently Opened", subtitle: "Quickly jump back into pages you used last.", contentStack: recentSitesStack)
        stackView.addArrangedSubview(recentSection)

        NSLayoutConstraint.activate([
            topGlow.widthAnchor.constraint(equalToConstant: 360),
            topGlow.heightAnchor.constraint(equalToConstant: 360),
            topGlow.topAnchor.constraint(equalTo: topAnchor, constant: -180),
            topGlow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 140),

            sideGlow.widthAnchor.constraint(equalToConstant: 280),
            sideGlow.heightAnchor.constraint(equalToConstant: 280),
            sideGlow.topAnchor.constraint(equalTo: topAnchor, constant: 120),
            sideGlow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -120),

            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 34),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -28),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func reloadContent(bookmarks: [BookmarkManager.Bookmark], history: [BookmarkManager.HistoryEntry]) {
        rebuildSavedSites(bookmarks)
        rebuildRecentSites(history)
    }

    @objc private func focusAddressBarAction() {
        onFocusAddressBar?()
    }

    @objc private func importBrowserDataAction() {
        onImportBrowserData?()
    }

    @objc private func clearHistoryAction() {
        onClearHistory?()
    }

    @objc private func openURLFromButton(_ sender: NSButton) {
        guard let button = sender as? BrowserStartCardButton, let url = button.payloadURL else { return }
        onOpenURL?(url)
    }

    private func rebuildSavedSites(_ bookmarks: [BookmarkManager.Bookmark]) {
        clearArrangedSubviews(in: savedSitesStack)
        let items = Array(bookmarks.prefix(6))

        guard !items.isEmpty else {
            savedSitesStack.addArrangedSubview(makeEmptyState("Nothing saved yet. Use the star in the address bar to keep a site here."))
            return
        }

        for chunk in stride(from: 0, to: items.count, by: 2) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 12
            row.distribution = .fillEqually

            for bookmark in items[chunk..<min(chunk + 2, items.count)] {
                let button = BrowserStartCardButton(
                    title: bookmark.title.isEmpty ? simplifiedTitle(for: bookmark.url) : bookmark.title,
                    subtitle: simplifiedSubtitle(for: bookmark.url),
                    icon: "star.fill"
                )
                button.payloadURL = bookmark.url
                button.target = self
                button.action = #selector(openURLFromButton(_:))
                row.addArrangedSubview(button)
            }

            if row.arrangedSubviews.count == 1 {
                row.addArrangedSubview(NSView())
            }

            savedSitesStack.addArrangedSubview(row)
        }
    }

    private func rebuildRecentSites(_ history: [BookmarkManager.HistoryEntry]) {
        clearArrangedSubviews(in: recentSitesStack)

        guard !history.isEmpty else {
            recentSitesStack.addArrangedSubview(makeEmptyState("Your recent pages show up here once you start browsing."))
            return
        }

        for entry in history {
            let button = BrowserStartCardButton(
                title: entry.title.isEmpty ? simplifiedTitle(for: entry.url) : entry.title,
                subtitle: "\(simplifiedSubtitle(for: entry.url))  •  \(relativeTime(for: entry.date))",
                icon: "clock",
                compact: true
            )
            button.payloadURL = entry.url
            button.target = self
            button.action = #selector(openURLFromButton(_:))
            recentSitesStack.addArrangedSubview(button)
        }
    }

    private func makeSection(title: String, subtitle: String, contentStack: NSStackView) -> NSView {
        contentStack.orientation = .vertical
        contentStack.spacing = 12
        contentStack.alignment = .leading

        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 12

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = NSColor(white: 1.0, alpha: 0.92)
        section.addArrangedSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = NSColor(white: 1.0, alpha: 0.44)
        section.addArrangedSubview(subtitleLabel)
        section.addArrangedSubview(contentStack)

        return section
    }

    private func makeActionButton(title: String, icon: String) -> BrowserChromeButton {
        let button = BrowserChromeButton()
        button.title = title
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = NSColor(white: 1.0, alpha: 0.76)
        button.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }

    private func makeEmptyState(_ message: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = NSColor(white: 1.0, alpha: 0.42)
        return label
    }

    private func clearArrangedSubviews(in stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func simplifiedTitle(for urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host, !host.isEmpty else {
            return urlString
        }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    private func simplifiedSubtitle(for urlString: String) -> String {
        guard let url = URL(string: urlString) else { return urlString }
        var parts: [String] = []
        if let host = url.host {
            parts.append(host.replacingOccurrences(of: "www.", with: ""))
        }
        if !url.path.isEmpty, url.path != "/" {
            parts.append(url.path)
        }
        return parts.joined(separator: "")
    }

    private func relativeTime(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - ClomeWebView (Context Menu)

/// WKWebView subclass that provides a custom right-click context menu.
@MainActor
final class ClomeWebView: WKWebView {
    weak var browserPanel: BrowserPanel?

    /// The link URL from the most recent right-click, set by the JS contextmenu listener.
    var lastContextLinkURL: URL?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        guard let panel = browserPanel else {
            super.willOpenMenu(menu, with: event)
            return
        }

        // Use the link URL captured by the JS contextmenu event
        let linkURL = lastContextLinkURL
        lastContextLinkURL = nil

        // Build our custom items and prepend them before WebKit's default items
        let customMenu = panel.buildContextMenu(linkURL: linkURL)

        // Insert separator before WebKit's items
        menu.insertItem(NSMenuItem.separator(), at: 0)

        // Insert our custom items at the top
        var insertIdx = 0
        for item in customMenu.items {
            customMenu.removeItem(item)
            menu.insertItem(item, at: insertIdx)
            insertIdx += 1
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if browserPanel?.handleKeyEquivalent(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Custom NSTextField subclass that notifies when it becomes first responder (gains focus).
/// Standard NSTextField does not provide a delegate callback for focus — only for editing
/// (which requires a keystroke). This subclass fires `onBecomeFirstResponder` immediately
/// when the user clicks or tabs into the field, before any text selection.
@MainActor
final class URLBarTextField: NSTextField {
    weak var browserPanel: BrowserPanel?
    var onBecomeFirstResponder: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            // Fire on next run loop so the field editor is fully installed
            DispatchQueue.main.async { [weak self] in
                self?.onBecomeFirstResponder?()
            }
        }
        return result
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if browserPanel?.handleKeyEquivalent(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
