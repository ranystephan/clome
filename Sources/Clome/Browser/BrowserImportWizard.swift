import AppKit
import WebKit

// MARK: - BrowserImportWindowController

/// A multi-step wizard window for importing browser data (cookies, bookmarks, history)
/// from installed browsers into Clome.
@MainActor
final class BrowserImportWindowController: NSWindowController {

    /// Retained reference so the controller stays alive while the window is open.
    private static var currentController: BrowserImportWindowController?

    private let contentView: BrowserImportContentView

    // MARK: - Lifecycle

    private init() {
        let content = BrowserImportContentView(frame: NSRect(x: 0, y: 0, width: 480, height: 520))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Import Browser Data"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.backgroundColor = NSColor(red: 0.055, green: 0.055, blue: 0.071, alpha: 1.0)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = content
        window.center()

        self.contentView = content
        super.init(window: window)

        content.onClose = { [weak self] in
            self?.close()
            BrowserImportWindowController.currentController = nil
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    // MARK: - Public API

    static func show() {
        if let existing = currentController {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = BrowserImportWindowController()
        currentController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Creates an NSMenuItem wired to show the import wizard.
    static func addToMenu(_ menu: NSMenu) {
        let item = NSMenuItem(
            title: "Import Browser Data...",
            action: #selector(showWizardFromMenu(_:)),
            keyEquivalent: ""
        )
        item.target = BrowserImportMenuTarget.shared
        menu.addItem(item)
    }

    @objc private static func showWizardFromMenu(_ sender: Any?) {
        show()
    }
}

// MARK: - Menu Target

/// Separate target object for the menu item so we don't require BrowserImportWindowController
/// to be instantiated just for menu validation.
@MainActor
private final class BrowserImportMenuTarget: NSObject {
    static let shared = BrowserImportMenuTarget()

    @objc func showWizardFromMenu(_ sender: Any?) {
        BrowserImportWindowController.show()
    }
}

// MARK: - BrowserImportContentView

/// Root content view that manages the three wizard steps.
@MainActor
private final class BrowserImportContentView: NSView {

    var onClose: (() -> Void)?

    private enum Step {
        case browserSelection
        case dataSelection
        case progress
    }

    private var currentStep: Step = .browserSelection

    // Shared state across steps
    private var detectedBrowsers: [BrowserProfile] = []
    private var selectedBrowser: BrowserProfile?
    private var importOptions = ImportOptions(cookies: true, bookmarks: true, history: true)

    // Step views
    private var browserSelectionView: BrowserSelectionStepView?
    private var dataSelectionView: DataSelectionStepView?
    private var progressView: ProgressStepView?

    private var currentStepView: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.055, green: 0.055, blue: 0.071, alpha: 1.0).cgColor
        detectBrowsers()
        showStep(.browserSelection, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func detectBrowsers() {
        detectedBrowsers = BrowserDetector.detectInstalledBrowsers()
    }

    // MARK: - Step Navigation

    private func showStep(_ step: Step, animated: Bool) {
        let oldView = currentStepView
        currentStep = step

        let newView: NSView
        switch step {
        case .browserSelection:
            let view = BrowserSelectionStepView(
                frame: bounds,
                browsers: detectedBrowsers,
                onContinue: { [weak self] browser in
                    self?.selectedBrowser = browser
                    self?.showStep(.dataSelection, animated: true)
                },
                onCancel: { [weak self] in
                    self?.onClose?()
                }
            )
            browserSelectionView = view
            newView = view

        case .dataSelection:
            guard let browser = selectedBrowser else { return }
            let view = DataSelectionStepView(
                frame: bounds,
                browser: browser,
                options: importOptions,
                onBack: { [weak self] in
                    self?.showStep(.browserSelection, animated: true)
                },
                onImport: { [weak self] options in
                    self?.importOptions = options
                    self?.showStep(.progress, animated: true)
                }
            )
            dataSelectionView = view
            newView = view

        case .progress:
            guard let browser = selectedBrowser else { return }
            let view = ProgressStepView(
                frame: bounds,
                browser: browser,
                options: importOptions,
                onDone: { [weak self] in
                    self?.onClose?()
                }
            )
            progressView = view
            newView = view
        }

        newView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(newView)
        NSLayoutConstraint.activate([
            newView.topAnchor.constraint(equalTo: topAnchor),
            newView.leadingAnchor.constraint(equalTo: leadingAnchor),
            newView.trailingAnchor.constraint(equalTo: trailingAnchor),
            newView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        if animated, let old = oldView {
            newView.alphaValue = 0
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                old.animator().alphaValue = 0
                newView.animator().alphaValue = 1
            }, completionHandler: {
                old.removeFromSuperview()
            })
        } else {
            oldView?.removeFromSuperview()
        }

        currentStepView = newView
    }
}

// MARK: - Brand Colors

@MainActor
private func brandColor(for profile: BrowserProfile) -> NSColor {
    let name = profile.name.lowercased()
    if name.contains("chrome") || name.contains("chromium") {
        return NSColor(red: 0.91, green: 0.26, blue: 0.21, alpha: 1.0)
    } else if name.contains("firefox") {
        return NSColor(red: 1.0, green: 0.45, blue: 0.0, alpha: 1.0)
    } else if name.contains("safari") {
        return NSColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
    } else if name.contains("arc") {
        return NSColor(red: 0.58, green: 0.29, blue: 0.96, alpha: 1.0)
    } else if name.contains("brave") {
        return NSColor(red: 1.0, green: 0.45, blue: 0.0, alpha: 1.0)
    } else if name.contains("edge") {
        return NSColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
    } else if name.contains("opera") {
        return NSColor(red: 1.0, green: 0.14, blue: 0.14, alpha: 1.0)
    } else if name.contains("vivaldi") {
        return NSColor(red: 0.93, green: 0.23, blue: 0.25, alpha: 1.0)
    }
    return NSColor(white: 0.6, alpha: 1.0)
}

// MARK: - Step 1: Browser Selection

@MainActor
private final class BrowserSelectionStepView: NSView {

    private let browsers: [BrowserProfile]
    private let onContinue: (BrowserProfile) -> Void
    private let onCancel: () -> Void
    private var selectedIndex: Int? {
        didSet { updateSelection() }
    }

    private var rowViews: [BrowserRowView] = []
    private var continueButton: NSButton!

    init(frame: NSRect, browsers: [BrowserProfile], onContinue: @escaping (BrowserProfile) -> Void, onCancel: @escaping () -> Void) {
        self.browsers = browsers
        self.onContinue = onContinue
        self.onCancel = onCancel
        super.init(frame: frame)
        wantsLayer = true
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setupUI() {
        // Header
        let header = NSTextField(labelWithString: "Import from another browser")
        header.font = .systemFont(ofSize: 18, weight: .semibold)
        header.textColor = .white
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        // Subtitle
        let subtitle = NSTextField(labelWithString: "Select a browser to import cookies, bookmarks, and history")
        subtitle.font = .systemFont(ofSize: 12, weight: .regular)
        subtitle.textColor = NSColor(white: 0.5, alpha: 1.0)
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitle)

        // Browser list scroll view
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        let listContainer = NSView()
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = listContainer

        // Build browser rows
        var lastBottom: NSLayoutYAxisAnchor = listContainer.topAnchor
        for (index, browser) in browsers.enumerated() {
            let row = BrowserRowView(browser: browser, index: index) { [weak self] idx in
                self?.selectedIndex = idx
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            listContainer.addSubview(row)
            rowViews.append(row)

            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: lastBottom, constant: index == 0 ? 0 : 4),
                row.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
                row.heightAnchor.constraint(equalToConstant: 56),
            ])
            lastBottom = row.bottomAnchor
        }

        if browsers.isEmpty {
            let emptyLabel = NSTextField(labelWithString: "No browsers detected")
            emptyLabel.font = .systemFont(ofSize: 13, weight: .regular)
            emptyLabel.textColor = NSColor(white: 0.4, alpha: 1.0)
            emptyLabel.alignment = .center
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false
            listContainer.addSubview(emptyLabel)
            NSLayoutConstraint.activate([
                emptyLabel.topAnchor.constraint(equalTo: listContainer.topAnchor, constant: 40),
                emptyLabel.centerXAnchor.constraint(equalTo: listContainer.centerXAnchor),
            ])
            lastBottom = emptyLabel.bottomAnchor
        }

        // Pin document view size
        NSLayoutConstraint.activate([
            listContainer.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            lastBottom.constraint(equalTo: listContainer.bottomAnchor, constant: -4),
        ])

        // Buttons
        let cancelButton = makeSecondaryButton(title: "Cancel")
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        addSubview(cancelButton)

        continueButton = makePrimaryButton(title: "Continue")
        continueButton.target = self
        continueButton.action = #selector(continueTapped)
        continueButton.isEnabled = false
        addSubview(continueButton)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 32),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),

            subtitle.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            subtitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            subtitle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),

            scrollView.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 20),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            scrollView.bottomAnchor.constraint(equalTo: continueButton.topAnchor, constant: -20),

            cancelButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            cancelButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            cancelButton.heightAnchor.constraint(equalToConstant: 32),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),

            continueButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            continueButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            continueButton.heightAnchor.constraint(equalToConstant: 32),
            continueButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
        ])
    }

    private func updateSelection() {
        for (index, row) in rowViews.enumerated() {
            row.setSelected(index == selectedIndex)
        }
        continueButton.isEnabled = selectedIndex != nil
    }

    @objc private func cancelTapped() {
        onCancel()
    }

    @objc private func continueTapped() {
        guard let index = selectedIndex, index < browsers.count else { return }
        onContinue(browsers[index])
    }
}

// MARK: - Browser Row View

@MainActor
private final class BrowserRowView: NSView {

    private let browser: BrowserProfile
    private let index: Int
    private let onSelect: (Int) -> Void
    private var isSelected = false
    private var highlightLayer: CALayer?

    init(browser: BrowserProfile, index: Int, onSelect: @escaping (Int) -> Void) {
        self.browser = browser
        self.index = index
        self.onSelect = onSelect
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        setupUI()
        setupTracking()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setupUI() {
        let color = brandColor(for: browser)

        // Icon
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let cfg = NSImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        iconView.image = NSImage(systemSymbolName: browser.icon, accessibilityDescription: browser.name)?.withSymbolConfiguration(cfg)
        iconView.contentTintColor = color
        addSubview(iconView)

        // Name
        let nameLabel = NSTextField(labelWithString: browser.name)
        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        // Profile path
        let pathLabel = NSTextField(labelWithString: browser.profilePath.path)
        pathLabel.font = .systemFont(ofSize: 11, weight: .regular)
        pathLabel.textColor = NSColor(white: 0.4, alpha: 1.0)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pathLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            pathLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            pathLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            pathLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
    }

    private func setupTracking() {
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseDown(with event: NSEvent) {
        onSelect(index)
    }

    override func mouseEntered(with event: NSEvent) {
        if !isSelected {
            layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.05).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        if !isSelected {
            layer?.backgroundColor = nil
        }
    }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        layer?.backgroundColor = selected
            ? NSColor(white: 1.0, alpha: 0.10).cgColor
            : nil
    }
}

// MARK: - Step 2: Data Selection

@MainActor
private final class DataSelectionStepView: NSView {

    private let browser: BrowserProfile
    private var options: ImportOptions
    private let onBack: () -> Void
    private let onImport: (ImportOptions) -> Void

    private var cookiesCheckbox: NSButton!
    private var bookmarksCheckbox: NSButton!
    private var historyCheckbox: NSButton!
    private var importButton: NSButton!

    init(frame: NSRect, browser: BrowserProfile, options: ImportOptions, onBack: @escaping () -> Void, onImport: @escaping (ImportOptions) -> Void) {
        self.browser = browser
        self.options = options
        self.onBack = onBack
        self.onImport = onImport
        super.init(frame: frame)
        wantsLayer = true
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setupUI() {
        let isSafari = browser.browserType == .safari

        // Header with browser icon + name
        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.spacing = 10
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerStack)

        let iconView = NSImageView()
        let cfg = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        iconView.image = NSImage(systemSymbolName: browser.icon, accessibilityDescription: browser.name)?.withSymbolConfiguration(cfg)
        iconView.contentTintColor = brandColor(for: browser)
        headerStack.addArrangedSubview(iconView)

        let headerLabel = NSTextField(labelWithString: "Choose what to import")
        headerLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        headerLabel.textColor = .white
        headerStack.addArrangedSubview(headerLabel)

        let browserNameLabel = NSTextField(labelWithString: "from \(browser.name)")
        browserNameLabel.font = .systemFont(ofSize: 12, weight: .regular)
        browserNameLabel.textColor = NSColor(white: 0.5, alpha: 1.0)
        browserNameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(browserNameLabel)

        // Data type rows
        let optionsStack = NSStackView()
        optionsStack.orientation = .vertical
        optionsStack.spacing = 12
        optionsStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(optionsStack)

        // Cookies row
        let cookiesRow = makeOptionRow(
            iconSymbol: "shield.fill",
            iconColor: NSColor.systemOrange,
            title: "Cookies",
            subtitle: isSafari ? "Safari cookies are system-managed" : "Stay logged in to your websites",
            isEnabled: !isSafari,
            defaultState: isSafari ? false : options.cookies
        )
        cookiesCheckbox = cookiesRow.checkbox
        optionsStack.addArrangedSubview(cookiesRow.view)

        // Bookmarks row
        let bookmarksRow = makeOptionRow(
            iconSymbol: "star.fill",
            iconColor: NSColor.systemYellow,
            title: "Bookmarks",
            subtitle: "Your saved bookmarks",
            isEnabled: true,
            defaultState: options.bookmarks
        )
        bookmarksCheckbox = bookmarksRow.checkbox
        optionsStack.addArrangedSubview(bookmarksRow.view)

        // History row
        let historyRow = makeOptionRow(
            iconSymbol: "clock.fill",
            iconColor: NSColor.systemBlue,
            title: "History",
            subtitle: "Your browsing history",
            isEnabled: true,
            defaultState: options.history
        )
        historyCheckbox = historyRow.checkbox
        optionsStack.addArrangedSubview(historyRow.view)

        // Buttons
        let backButton = makeSecondaryButton(title: "Back")
        backButton.target = self
        backButton.action = #selector(backTapped)
        addSubview(backButton)

        importButton = makePrimaryButton(title: "Import")
        importButton.target = self
        importButton.action = #selector(importTapped)
        addSubview(importButton)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: topAnchor, constant: 32),
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),

            browserNameLabel.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 6),
            browserNameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),

            optionsStack.topAnchor.constraint(equalTo: browserNameLabel.bottomAnchor, constant: 28),
            optionsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            optionsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),

            backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            backButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            backButton.heightAnchor.constraint(equalToConstant: 32),
            backButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),

            importButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            importButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            importButton.heightAnchor.constraint(equalToConstant: 32),
            importButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
        ])
    }

    private struct OptionRow {
        let view: NSView
        let checkbox: NSButton
    }

    private func makeOptionRow(
        iconSymbol: String,
        iconColor: NSColor,
        title: String,
        subtitle: String,
        isEnabled: Bool,
        defaultState: Bool
    ) -> OptionRow {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.cornerCurve = .continuous
        container.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.04).cgColor

        // Icon
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        iconView.image = NSImage(systemSymbolName: iconSymbol, accessibilityDescription: title)?.withSymbolConfiguration(cfg)
        iconView.contentTintColor = isEnabled ? iconColor : iconColor.withAlphaComponent(0.3)
        container.addSubview(iconView)

        // Title
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = isEnabled ? .white : NSColor(white: 0.4, alpha: 1.0)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        // Subtitle
        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = NSColor(white: isEnabled ? 0.45 : 0.3, alpha: 1.0)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subtitleLabel)

        // Checkbox
        let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.state = defaultState ? .on : .off
        checkbox.isEnabled = isEnabled
        container.addSubview(checkbox)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 64),

            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            checkbox.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            checkbox.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        return OptionRow(view: container, checkbox: checkbox)
    }

    @objc private func backTapped() {
        onBack()
    }

    @objc private func importTapped() {
        let opts = ImportOptions(
            cookies: cookiesCheckbox.state == .on,
            bookmarks: bookmarksCheckbox.state == .on,
            history: historyCheckbox.state == .on
        )
        onImport(opts)
    }
}

// MARK: - Step 3: Progress & Results

@MainActor
private final class ProgressStepView: NSView {

    private let browser: BrowserProfile
    private let options: ImportOptions
    private let onDone: () -> Void

    private var progressCard: NSView!
    private var badgeView: NSView!
    private var spinner: NSProgressIndicator!
    private var progressBar: NSProgressIndicator!
    private var statusLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var selectedDataLabel: NSTextField!
    private var resultsStack: NSStackView!
    private var doneButton: NSButton!

    init(frame: NSRect, browser: BrowserProfile, options: ImportOptions, onDone: @escaping () -> Void) {
        self.browser = browser
        self.options = options
        self.onDone = onDone
        super.init(frame: frame)
        wantsLayer = true
        setupUI()
        startImport()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setupUI() {
        let accent = NSColor(red: 0.38, green: 0.56, blue: 1.0, alpha: 1.0)

        let sectionLabel = NSTextField(labelWithString: "IMPORT")
        sectionLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        sectionLabel.textColor = accent.withAlphaComponent(0.9)
        sectionLabel.alignment = .center
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sectionLabel)

        let header = NSTextField(labelWithString: "Importing from \(browser.name)")
        header.font = .systemFont(ofSize: 18, weight: .semibold)
        header.textColor = .white
        header.alignment = .center
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        let subtitle = NSTextField(labelWithString: "Transferring selected data into Clome's secure store")
        subtitle.font = .systemFont(ofSize: 12, weight: .regular)
        subtitle.textColor = NSColor(white: 0.62, alpha: 1.0)
        subtitle.alignment = .center
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitle)

        progressCard = NSView()
        progressCard.wantsLayer = true
        progressCard.translatesAutoresizingMaskIntoConstraints = false
        progressCard.layer?.cornerRadius = 14
        progressCard.layer?.cornerCurve = .continuous
        progressCard.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.045).cgColor
        progressCard.layer?.borderWidth = 1
        progressCard.layer?.borderColor = NSColor(white: 1.0, alpha: 0.09).cgColor
        progressCard.layer?.shadowColor = NSColor.black.cgColor
        progressCard.layer?.shadowOpacity = 0.24
        progressCard.layer?.shadowRadius = 14
        progressCard.layer?.shadowOffset = NSSize(width: 0, height: -2)
        addSubview(progressCard)

        badgeView = NSView()
        badgeView.wantsLayer = true
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeView.layer?.cornerRadius = 16
        badgeView.layer?.cornerCurve = .continuous
        badgeView.layer?.backgroundColor = accent.withAlphaComponent(0.16).cgColor
        badgeView.layer?.borderWidth = 1
        badgeView.layer?.borderColor = accent.withAlphaComponent(0.45).cgColor
        progressCard.addSubview(badgeView)

        let browserIcon = NSImageView()
        browserIcon.translatesAutoresizingMaskIntoConstraints = false
        let iconCfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        browserIcon.image = NSImage(systemSymbolName: browser.icon, accessibilityDescription: browser.name)?.withSymbolConfiguration(iconCfg)
        browserIcon.contentTintColor = brandColor(for: browser)
        badgeView.addSubview(browserIcon)

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.appearance = NSAppearance(named: .darkAqua)
        progressCard.addSubview(spinner)
        spinner.startAnimation(nil)

        statusLabel = NSTextField(labelWithString: "Preparing import...")
        statusLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        statusLabel.textColor = NSColor(white: 0.92, alpha: 1.0)
        statusLabel.alignment = .left
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        progressCard.addSubview(statusLabel)

        detailLabel = NSTextField(labelWithString: "Validating browser profile and preparing destination")
        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = NSColor(white: 0.62, alpha: 1.0)
        detailLabel.alignment = .left
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        progressCard.addSubview(detailLabel)

        progressBar = NSProgressIndicator()
        progressBar.style = .bar
        progressBar.isIndeterminate = true
        progressBar.usesThreadedAnimation = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressCard.addSubview(progressBar)
        progressBar.startAnimation(nil)

        selectedDataLabel = NSTextField(labelWithString: selectedDataSummary())
        selectedDataLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        selectedDataLabel.textColor = NSColor(white: 0.55, alpha: 1.0)
        selectedDataLabel.alignment = .left
        selectedDataLabel.translatesAutoresizingMaskIntoConstraints = false
        progressCard.addSubview(selectedDataLabel)

        resultsStack = NSStackView()
        resultsStack.orientation = .vertical
        resultsStack.spacing = 10
        resultsStack.alignment = .leading
        resultsStack.translatesAutoresizingMaskIntoConstraints = false
        resultsStack.isHidden = true
        progressCard.addSubview(resultsStack)

        doneButton = makePrimaryButton(title: "Done")
        doneButton.target = self
        doneButton.action = #selector(doneTapped)
        doneButton.isHidden = true
        addSubview(doneButton)

        NSLayoutConstraint.activate([
            sectionLabel.topAnchor.constraint(equalTo: topAnchor, constant: 34),
            sectionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),

            header.topAnchor.constraint(equalTo: sectionLabel.bottomAnchor, constant: 10),
            header.centerXAnchor.constraint(equalTo: centerXAnchor),
            header.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),

            subtitle.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            subtitle.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtitle.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),

            progressCard.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 24),
            progressCard.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            progressCard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            progressCard.bottomAnchor.constraint(lessThanOrEqualTo: doneButton.topAnchor, constant: -20),

            badgeView.topAnchor.constraint(equalTo: progressCard.topAnchor, constant: 18),
            badgeView.leadingAnchor.constraint(equalTo: progressCard.leadingAnchor, constant: 18),
            badgeView.widthAnchor.constraint(equalToConstant: 32),
            badgeView.heightAnchor.constraint(equalToConstant: 32),

            browserIcon.centerXAnchor.constraint(equalTo: badgeView.centerXAnchor),
            browserIcon.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),
            browserIcon.widthAnchor.constraint(equalToConstant: 16),
            browserIcon.heightAnchor.constraint(equalToConstant: 16),

            statusLabel.topAnchor.constraint(equalTo: progressCard.topAnchor, constant: 18),
            statusLabel.leadingAnchor.constraint(equalTo: badgeView.trailingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: progressCard.trailingAnchor, constant: -18),

            detailLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            detailLabel.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: progressCard.trailingAnchor, constant: -18),

            spinner.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 14),
            spinner.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),

            progressBar.centerYAnchor.constraint(equalTo: spinner.centerYAnchor),
            progressBar.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
            progressBar.trailingAnchor.constraint(equalTo: progressCard.trailingAnchor, constant: -18),
            progressBar.heightAnchor.constraint(equalToConstant: 8),

            selectedDataLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 12),
            selectedDataLabel.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            selectedDataLabel.trailingAnchor.constraint(equalTo: progressCard.trailingAnchor, constant: -18),

            resultsStack.topAnchor.constraint(equalTo: selectedDataLabel.bottomAnchor, constant: 16),
            resultsStack.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            resultsStack.trailingAnchor.constraint(lessThanOrEqualTo: progressCard.trailingAnchor, constant: -18),
            resultsStack.bottomAnchor.constraint(equalTo: progressCard.bottomAnchor, constant: -18),

            doneButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            doneButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            doneButton.heightAnchor.constraint(equalToConstant: 32),
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
        ])
    }

    private func startImport() {
        statusLabel.stringValue = "Importing selected data"
        detailLabel.stringValue = "Syncing into Clome's shared data store"
        selectedDataLabel.stringValue = selectedDataSummary()

        let cookieStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "4E5F6A7B-8C9D-0E1F-2A3B-4C5D6E7F8A9B")!).httpCookieStore

        BrowserImportCoordinator.performImport(from: browser, options: options, cookieStore: cookieStore) { [weak self] result in
            DispatchQueue.main.async {
                self?.showResults(result)
            }
        }
    }

    private func showResults(_ result: ImportResult) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        progressBar.stopAnimation(nil)
        progressBar.isHidden = true
        statusLabel.stringValue = "Import complete"
        statusLabel.textColor = NSColor(white: 0.96, alpha: 1.0)
        detailLabel.stringValue = result.errors.isEmpty
            ? "Everything selected was imported successfully."
            : "Import completed with some recoverable issues."
        detailLabel.textColor = result.errors.isEmpty
            ? NSColor.systemGreen.withAlphaComponent(0.9)
            : NSColor.systemYellow.withAlphaComponent(0.9)
        selectedDataLabel.isHidden = true

        resultsStack.isHidden = false

        if options.cookies {
            addResultRow(
                symbol: "checkmark.circle.fill",
                color: NSColor.systemGreen,
                text: "\(result.cookiesImported) cookies imported"
            )
        }
        if options.bookmarks {
            addResultRow(
                symbol: "checkmark.circle.fill",
                color: NSColor.systemGreen,
                text: "\(result.bookmarksImported) bookmarks imported"
            )
        }
        if options.history {
            addResultRow(
                symbol: "checkmark.circle.fill",
                color: NSColor.systemGreen,
                text: "\(result.historyImported) history entries imported"
            )
        }
        if !result.errors.isEmpty {
            addResultRow(
                symbol: "exclamationmark.triangle.fill",
                color: NSColor.systemYellow,
                text: "\(result.errors.count) item\(result.errors.count == 1 ? "" : "s") could not be imported"
            )
        }

        doneButton.isHidden = false
    }

    private func addResultRow(symbol: String, color: NSColor, text: String) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8

        let iconView = NSImageView()
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        iconView.contentTintColor = color
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
        ])
        row.addArrangedSubview(iconView)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(white: 0.85, alpha: 1.0)
        row.addArrangedSubview(label)

        resultsStack.addArrangedSubview(row)
    }

    private func selectedDataSummary() -> String {
        var parts: [String] = []
        if options.cookies { parts.append("cookies") }
        if options.bookmarks { parts.append("bookmarks") }
        if options.history { parts.append("history") }
        if parts.isEmpty { return "Selected: nothing" }
        return "Selected: " + parts.joined(separator: " • ")
    }

    @objc private func doneTapped() {
        onDone()
    }
}

// MARK: - Shared Button Helpers

@MainActor
private func makePrimaryButton(title: String) -> NSButton {
    let button = NSButton(title: title, target: nil, action: nil)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.bezelStyle = .rounded
    button.controlSize = .regular
    button.keyEquivalent = "\r"
    button.contentTintColor = .white
    button.bezelColor = NSColor.controlAccentColor
    return button
}

@MainActor
private func makeSecondaryButton(title: String) -> NSButton {
    let button = NSButton(title: title, target: nil, action: nil)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.bezelStyle = .rounded
    button.controlSize = .regular
    button.contentTintColor = NSColor(white: 0.7, alpha: 1.0)
    return button
}
