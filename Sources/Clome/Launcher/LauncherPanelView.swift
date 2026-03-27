import AppKit

/// The floating launcher panel containing search, results, live preview, and action bar.
@MainActor
class LauncherPanelView: NSView, LauncherSearchFieldDelegate, LauncherResultsDelegate {

    let searchField = LauncherSearchField()
    let resultsView = LauncherResultsView()
    let actionBar = LauncherActionBar()

    // MARK: - Preview Panel

    private let previewContainer = NSView()
    private let previewImageViewA = NSImageView()
    private let previewImageViewB = NSImageView()
    private var frontImageView: NSImageView!
    private var backImageView: NSImageView!
    private let previewPlaceholder = NSTextField(labelWithString: "")

    /// Overlay title strip at bottom of preview image.
    private let previewTitleStrip = NSView()
    private let previewTitleLabel = NSTextField(labelWithString: "")

    /// Terminal input for interactive preview.
    private let terminalInputContainer = NSView()
    private let terminalInputField = NSTextField()

    /// Focus button to jump to the previewed tab.
    private let focusButton = NSButton()

    /// Info panel for non-previewable items.
    private let infoPanel = NSView()
    private let infoIconView = NSImageView()
    private let infoTitleLabel = NSTextField(labelWithString: "")
    private let infoDetailLabel = NSTextField(labelWithString: "")
    private let infoShortcutLabel = NSTextField(labelWithString: "")

    /// Vertical separator between results and preview.
    private let verticalSeparator = NSView()

    // MARK: - Layout Constants

    private var panelWidthConstraint: NSLayoutConstraint!
    private var panelHeightConstraint: NSLayoutConstraint!
    private static let narrowWidth: CGFloat = 660
    private static let previewWidth: CGFloat = 520
    private static var wideWidth: CGFloat {
        let maxWidth = (NSScreen.main?.frame.width ?? 1440) * 0.75
        return min(narrowWidth + previewWidth + 1, maxWidth)
    }

    // MARK: - Live Preview Timer

    private var previewTimer: Timer?
    private var currentPreviewItem: LauncherItem?

    // MARK: - Providers

    private var providers: [LauncherProvider] = []

    /// Called when the user activates an item (primary action).
    var onItemActivated: ((LauncherItem) -> Void)?

    /// Called when the user presses Escape.
    var onDismiss: (() -> Void)?

    /// Weak reference to workspace manager for snapshotting.
    weak var workspaceManager: WorkspaceManager?

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        frontImageView = previewImageViewA
        backImageView = previewImageViewB
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    // MARK: - View Setup

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.085, alpha: 0.96).cgColor
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        layer?.borderWidth = 0.5

        let topSeparator = NSView()
        topSeparator.translatesAutoresizingMaskIntoConstraints = false
        topSeparator.wantsLayer = true
        topSeparator.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor

        let bottomSeparator = NSView()
        bottomSeparator.translatesAutoresizingMaskIntoConstraints = false
        bottomSeparator.wantsLayer = true
        bottomSeparator.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.searchDelegate = self

        resultsView.translatesAutoresizingMaskIntoConstraints = false
        resultsView.resultsDelegate = self

        actionBar.translatesAutoresizingMaskIntoConstraints = false
        actionBar.onActionExecuted = { [weak self] in
            self?.onDismiss?()
        }

        setupTerminalInput()
        setupPreviewPanel()
        setupInfoPanel()

        verticalSeparator.translatesAutoresizingMaskIntoConstraints = false
        verticalSeparator.wantsLayer = true
        verticalSeparator.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        verticalSeparator.isHidden = true

        addSubview(searchField)
        addSubview(topSeparator)
        addSubview(resultsView)
        addSubview(bottomSeparator)
        addSubview(actionBar)
        addSubview(verticalSeparator)
        addSubview(previewContainer)

        panelWidthConstraint = widthAnchor.constraint(equalToConstant: Self.narrowWidth)
        panelHeightConstraint = heightAnchor.constraint(equalToConstant: 500)

        let resultsTrailing = resultsView.trailingAnchor.constraint(equalTo: verticalSeparator.leadingAnchor)
        let resultsTrailingFallback = resultsView.trailingAnchor.constraint(equalTo: trailingAnchor)
        resultsTrailingFallback.priority = .defaultLow
        resultsTrailing.priority = .defaultHigh

        NSLayoutConstraint.activate([
            panelWidthConstraint,
            panelHeightConstraint,

            searchField.topAnchor.constraint(equalTo: topAnchor),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor),

            topSeparator.topAnchor.constraint(equalTo: searchField.bottomAnchor),
            topSeparator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            topSeparator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            topSeparator.heightAnchor.constraint(equalToConstant: 1),

            resultsView.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            resultsView.leadingAnchor.constraint(equalTo: leadingAnchor),
            resultsTrailing,
            resultsTrailingFallback,
            resultsView.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),

            verticalSeparator.topAnchor.constraint(equalTo: topSeparator.bottomAnchor, constant: 8),
            verticalSeparator.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor, constant: -8),
            verticalSeparator.widthAnchor.constraint(equalToConstant: 1),
            verticalSeparator.trailingAnchor.constraint(equalTo: previewContainer.leadingAnchor),

            previewContainer.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            previewContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            previewContainer.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),
            previewContainer.widthAnchor.constraint(equalToConstant: Self.previewWidth),

            bottomSeparator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            bottomSeparator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            bottomSeparator.heightAnchor.constraint(equalToConstant: 1),
            bottomSeparator.bottomAnchor.constraint(equalTo: actionBar.topAnchor),

            actionBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionBar.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        previewContainer.isHidden = true
    }

    // MARK: - Preview Image Views (Dual for Crossfade)

    private func setupPreviewPanel() {
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.wantsLayer = true

        // Configure both image views identically
        for imageView in [previewImageViewA, previewImageViewB] {
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 4
            imageView.layer?.cornerCurve = .continuous
            imageView.layer?.masksToBounds = true
            imageView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.04).cgColor
            imageView.layer?.borderWidth = 0.5
            previewContainer.addSubview(imageView)
        }
        backImageView.alphaValue = 0

        // Overlay title strip (semi-transparent, at bottom of image)
        previewTitleStrip.translatesAutoresizingMaskIntoConstraints = false
        previewTitleStrip.wantsLayer = true
        previewTitleStrip.layer?.backgroundColor = NSColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 0.85).cgColor
        previewContainer.addSubview(previewTitleStrip)

        previewTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        previewTitleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        previewTitleLabel.textColor = NSColor(white: 0.75, alpha: 1.0)
        previewTitleLabel.lineBreakMode = .byTruncatingTail
        previewTitleLabel.maximumNumberOfLines = 1
        previewTitleStrip.addSubview(previewTitleLabel)

        // Focus button (inside title strip)
        focusButton.translatesAutoresizingMaskIntoConstraints = false
        focusButton.bezelStyle = .texturedRounded
        focusButton.isBordered = false
        focusButton.title = ""
        focusButton.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: "Focus")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        focusButton.contentTintColor = NSColor(white: 0.5, alpha: 1.0)
        focusButton.target = self
        focusButton.action = #selector(focusButtonClicked)
        focusButton.toolTip = "Switch to this tab (Enter)"
        previewTitleStrip.addSubview(focusButton)

        // Placeholder
        previewPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        previewPlaceholder.font = .systemFont(ofSize: 12, weight: .regular)
        previewPlaceholder.textColor = NSColor(white: 0.20, alpha: 1.0)
        previewPlaceholder.alignment = .center
        previewPlaceholder.stringValue = "No preview"
        previewPlaceholder.isHidden = true
        previewContainer.addSubview(previewPlaceholder)

        NSLayoutConstraint.activate([
            // Image views fill the preview area with minimal padding
            previewImageViewA.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 6),
            previewImageViewA.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 6),
            previewImageViewA.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -6),
            previewImageViewA.bottomAnchor.constraint(equalTo: terminalInputContainer.topAnchor, constant: -4),

            previewImageViewB.topAnchor.constraint(equalTo: previewImageViewA.topAnchor),
            previewImageViewB.leadingAnchor.constraint(equalTo: previewImageViewA.leadingAnchor),
            previewImageViewB.trailingAnchor.constraint(equalTo: previewImageViewA.trailingAnchor),
            previewImageViewB.bottomAnchor.constraint(equalTo: previewImageViewA.bottomAnchor),

            // Title strip overlays the bottom of the image
            previewTitleStrip.leadingAnchor.constraint(equalTo: previewImageViewA.leadingAnchor),
            previewTitleStrip.trailingAnchor.constraint(equalTo: previewImageViewA.trailingAnchor),
            previewTitleStrip.bottomAnchor.constraint(equalTo: previewImageViewA.bottomAnchor),
            previewTitleStrip.heightAnchor.constraint(equalToConstant: 28),

            previewTitleLabel.leadingAnchor.constraint(equalTo: previewTitleStrip.leadingAnchor, constant: 8),
            previewTitleLabel.centerYAnchor.constraint(equalTo: previewTitleStrip.centerYAnchor),
            previewTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: focusButton.leadingAnchor, constant: -6),

            focusButton.trailingAnchor.constraint(equalTo: previewTitleStrip.trailingAnchor, constant: -6),
            focusButton.centerYAnchor.constraint(equalTo: previewTitleStrip.centerYAnchor),
            focusButton.widthAnchor.constraint(equalToConstant: 22),
            focusButton.heightAnchor.constraint(equalToConstant: 22),

            previewPlaceholder.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            previewPlaceholder.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
        ])
    }

    // MARK: - Terminal Input

    private func setupTerminalInput() {
        terminalInputContainer.translatesAutoresizingMaskIntoConstraints = false
        terminalInputContainer.wantsLayer = true
        terminalInputContainer.isHidden = true
        previewContainer.addSubview(terminalInputContainer)

        terminalInputField.translatesAutoresizingMaskIntoConstraints = false
        terminalInputField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        terminalInputField.textColor = NSColor(white: 0.85, alpha: 1.0)
        terminalInputField.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)
        terminalInputField.drawsBackground = true
        terminalInputField.isBordered = false
        terminalInputField.isBezeled = false
        terminalInputField.focusRingType = .none
        terminalInputField.placeholderAttributedString = NSAttributedString(
            string: "Send to terminal... (\u{2318}\u{21A9})",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor(white: 0.3, alpha: 1.0),
            ]
        )
        terminalInputField.wantsLayer = true
        terminalInputField.layer?.cornerRadius = 4
        terminalInputField.target = self
        terminalInputField.action = #selector(terminalInputSubmitted)
        terminalInputContainer.addSubview(terminalInputField)

        NSLayoutConstraint.activate([
            terminalInputContainer.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 6),
            terminalInputContainer.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -6),
            terminalInputContainer.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -6),
            terminalInputContainer.heightAnchor.constraint(equalToConstant: 30),

            terminalInputField.topAnchor.constraint(equalTo: terminalInputContainer.topAnchor),
            terminalInputField.leadingAnchor.constraint(equalTo: terminalInputContainer.leadingAnchor, constant: 6),
            terminalInputField.trailingAnchor.constraint(equalTo: terminalInputContainer.trailingAnchor, constant: -6),
            terminalInputField.bottomAnchor.constraint(equalTo: terminalInputContainer.bottomAnchor),
        ])
    }

    // MARK: - Info Panel (Non-Previewable Items)

    private func setupInfoPanel() {
        infoPanel.translatesAutoresizingMaskIntoConstraints = false
        infoPanel.wantsLayer = true
        infoPanel.isHidden = true
        previewContainer.addSubview(infoPanel)

        infoIconView.translatesAutoresizingMaskIntoConstraints = false
        infoIconView.imageScaling = .scaleProportionallyDown
        infoPanel.addSubview(infoIconView)

        infoTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        infoTitleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        infoTitleLabel.textColor = NSColor(white: 0.80, alpha: 1.0)
        infoTitleLabel.alignment = .center
        infoTitleLabel.lineBreakMode = .byTruncatingTail
        infoTitleLabel.maximumNumberOfLines = 2
        infoPanel.addSubview(infoTitleLabel)

        infoDetailLabel.translatesAutoresizingMaskIntoConstraints = false
        infoDetailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        infoDetailLabel.textColor = NSColor(white: 0.45, alpha: 1.0)
        infoDetailLabel.alignment = .center
        infoDetailLabel.lineBreakMode = .byWordWrapping
        infoDetailLabel.maximumNumberOfLines = 4
        infoPanel.addSubview(infoDetailLabel)

        infoShortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        infoShortcutLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        infoShortcutLabel.textColor = NSColor(white: 0.35, alpha: 1.0)
        infoShortcutLabel.alignment = .center
        infoShortcutLabel.wantsLayer = true
        infoShortcutLabel.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.04).cgColor
        infoShortcutLabel.layer?.cornerRadius = 4
        infoPanel.addSubview(infoShortcutLabel)

        NSLayoutConstraint.activate([
            infoPanel.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            infoPanel.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            infoPanel.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            infoPanel.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),

            infoIconView.centerXAnchor.constraint(equalTo: infoPanel.centerXAnchor),
            infoIconView.bottomAnchor.constraint(equalTo: infoTitleLabel.topAnchor, constant: -12),
            infoIconView.widthAnchor.constraint(equalToConstant: 36),
            infoIconView.heightAnchor.constraint(equalToConstant: 36),

            infoTitleLabel.centerXAnchor.constraint(equalTo: infoPanel.centerXAnchor),
            infoTitleLabel.centerYAnchor.constraint(equalTo: infoPanel.centerYAnchor, constant: -8),
            infoTitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: infoPanel.leadingAnchor, constant: 20),
            infoTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: infoPanel.trailingAnchor, constant: -20),

            infoDetailLabel.topAnchor.constraint(equalTo: infoTitleLabel.bottomAnchor, constant: 6),
            infoDetailLabel.leadingAnchor.constraint(equalTo: infoPanel.leadingAnchor, constant: 20),
            infoDetailLabel.trailingAnchor.constraint(equalTo: infoPanel.trailingAnchor, constant: -20),

            infoShortcutLabel.topAnchor.constraint(equalTo: infoDetailLabel.bottomAnchor, constant: 10),
            infoShortcutLabel.centerXAnchor.constraint(equalTo: infoPanel.centerXAnchor),
            infoShortcutLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
            infoShortcutLabel.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    // MARK: - Preview Update Logic

    private func updatePreview(for item: LauncherItem) {
        let view = resolveView(for: item)
        let isNewItem = currentPreviewItem?.id != item.id
        currentPreviewItem = item

        if let view {
            showPreviewPanel()
            infoPanel.isHidden = true
            previewImageViewA.isHidden = false
            previewImageViewB.isHidden = false

            let snapshot = captureSnapshot(of: view)

            if isNewItem {
                crossfadeToSnapshot(snapshot)
                let isTerminal = item.payload is TerminalPayload
                terminalInputContainer.isHidden = !isTerminal
            } else {
                frontImageView.image = snapshot
            }

            previewTitleLabel.stringValue = item.title
            previewTitleStrip.isHidden = false
            previewPlaceholder.isHidden = (snapshot != nil)
        } else {
            showPreviewPanel()
            showInfoForItem(item)
        }
    }

    private func crossfadeToSnapshot(_ snapshot: NSImage?) {
        // Cancel any in-flight animation
        backImageView.animator().alphaValue = 0
        frontImageView.animator().alphaValue = 1

        // Swap front/back
        let temp = frontImageView!
        frontImageView = backImageView
        backImageView = temp

        frontImageView.image = snapshot

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            frontImageView.animator().alphaValue = 1
            backImageView.animator().alphaValue = 0
        }
    }

    private func showInfoForItem(_ item: LauncherItem) {
        previewImageViewA.isHidden = true
        previewImageViewB.isHidden = true
        previewTitleStrip.isHidden = true
        terminalInputContainer.isHidden = true
        previewPlaceholder.isHidden = true
        infoPanel.isHidden = false

        let iconCfg = NSImage.SymbolConfiguration(pointSize: 28, weight: .light)
        infoIconView.image = NSImage(systemSymbolName: item.icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(iconCfg)
        infoIconView.contentTintColor = item.iconColor ?? NSColor(white: 0.4, alpha: 1.0)

        infoTitleLabel.stringValue = item.title

        if let meta = item.metadata, !meta.isEmpty {
            infoShortcutLabel.stringValue = "  \(meta)  "
            infoShortcutLabel.isHidden = false
        } else {
            infoShortcutLabel.isHidden = true
        }

        if let subtitle = item.subtitle, !subtitle.isEmpty {
            infoDetailLabel.stringValue = subtitle
        } else {
            infoDetailLabel.stringValue = item.provider == "command"
                ? "Press Enter to run"
                : ""
        }
    }

    private func resolveView(for item: LauncherItem) -> NSView? {
        guard let wm = workspaceManager else { return nil }

        if let navPayload = item.payload as? NavigationPayload {
            let wsIndex = navPayload.workspaceIndex
            let tabIndex = navPayload.tabIndex
            guard wsIndex < wm.workspaces.count else { return nil }
            let workspace = wm.workspaces[wsIndex]
            guard tabIndex < workspace.tabs.count else { return nil }
            return navPayload.paneView ?? workspace.tabs[tabIndex].view
        }

        if let termPayload = item.payload as? TerminalPayload {
            return termPayload.terminal
        }

        return nil
    }

    private func captureSnapshot(of view: NSView) -> NSImage? {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        guard let bitmapRep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmapRep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmapRep)
        return image
    }

    // MARK: - Show / Hide Preview

    private func showPreviewPanel() {
        guard previewContainer.isHidden else { return }
        previewContainer.isHidden = false
        verticalSeparator.isHidden = false
        panelWidthConstraint.constant = Self.wideWidth

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            superview?.layoutSubtreeIfNeeded()
        }
    }

    private func hidePreviewPanel() {
        guard !previewContainer.isHidden else { return }
        previewContainer.isHidden = true
        verticalSeparator.isHidden = true
        panelWidthConstraint.constant = Self.narrowWidth

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            superview?.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - Live Preview Timer

    func startLivePreview() {
        guard previewTimer == nil else { return }
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshCurrentPreview()
            }
        }
    }

    func stopLivePreview() {
        previewTimer?.invalidate()
        previewTimer = nil
        currentPreviewItem = nil
    }

    private func refreshCurrentPreview() {
        guard let item = currentPreviewItem else { return }
        guard let view = resolveView(for: item) else { return }

        // Skip refresh if terminal is idle (optimization)
        if let terminal = view as? TerminalSurface,
           terminal.activityState == .idle && terminal.claudeCodeState == nil {
            return
        }

        let snapshot = captureSnapshot(of: view)
        frontImageView.image = snapshot
    }

    // MARK: - Terminal Input

    @objc private func terminalInputSubmitted() {
        let text = terminalInputField.stringValue
        guard !text.isEmpty else { return }
        guard let item = currentPreviewItem,
              let payload = item.payload as? TerminalPayload,
              let terminal = payload.terminal else { return }

        terminal.injectText(text)
        terminal.injectReturn()
        terminalInputField.stringValue = ""

        // Refresh preview after a short delay to show the result
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.refreshCurrentPreview()
        }
    }

    /// Focus the terminal input field (called via Cmd+Enter).
    func focusTerminalInput() {
        guard !terminalInputContainer.isHidden else { return }
        window?.makeFirstResponder(terminalInputField)
    }

    @objc private func focusButtonClicked() {
        guard let item = currentPreviewItem else { return }
        onItemActivated?(item)
    }

    // MARK: - Provider Management

    func registerProvider(_ provider: LauncherProvider) {
        providers.append(provider)
    }

    func refreshResults() {
        let mode = searchField.activeMode
        let query = searchField.queryText

        let activeProviders: [LauncherProvider]
        switch mode {
        case .all: activeProviders = providers
        case .commands: activeProviders = providers.filter { $0.sectionTitle == "Commands" }
        case .sessions: activeProviders = providers.filter { $0.sectionTitle == "Sessions" }
        case .files: activeProviders = providers.filter { $0.sectionTitle == "Files" }
        case .terminals: activeProviders = providers.filter { $0.sectionTitle == "Terminals" }
        }

        var sections: [(title: String, items: [LauncherItem])] = []
        var attentionItems: [LauncherItem] = []
        var normalSections: [(title: String, items: [LauncherItem])] = []

        for provider in activeProviders {
            let items = provider.search(query: query)
            let attention = items.filter { $0.priority >= 1000 }
            let normal = items.filter { $0.priority < 1000 }
            attentionItems.append(contentsOf: attention)
            if !normal.isEmpty {
                normalSections.append((provider.sectionTitle, normal))
            }
        }

        if !attentionItems.isEmpty {
            attentionItems.sort { $0.priority > $1.priority }
            sections.append(("Needs Attention", attentionItems))
        }
        sections.append(contentsOf: normalSections)

        resultsView.updateResults(sections, query: query)

        if let selected = resultsView.selectedItem {
            updateActionsForItem(selected)
            updatePreview(for: selected)
        } else {
            hidePreviewPanel()
        }
    }

    private func updateActionsForItem(_ item: LauncherItem) {
        for provider in providers {
            let actions = provider.actions(for: item)
            if !actions.isEmpty {
                actionBar.updateActions(actions)
                return
            }
        }
        actionBar.updateActions([])
    }

    // MARK: - LauncherSearchFieldDelegate

    func searchFieldDidChange(_ text: String) {
        actionBar.collapse()
        refreshResults()
    }

    func searchFieldDidPressArrowDown() {
        resultsView.moveSelectionDown()
    }

    func searchFieldDidPressArrowUp() {
        resultsView.moveSelectionUp()
    }

    func searchFieldDidPressEnter() {
        resultsView.activateSelection()
    }

    func searchFieldDidPressTab() {
        actionBar.toggleExpanded()
    }

    func searchFieldDidPressEscape() {
        // If terminal input is focused, return to search
        if window?.firstResponder === terminalInputField.currentEditor() {
            searchField.focus()
            return
        }
        if actionBar.isExpanded {
            actionBar.collapse()
        } else {
            onDismiss?()
        }
    }

    // MARK: - LauncherResultsDelegate

    func resultsView(_ view: LauncherResultsView, didSelectItem item: LauncherItem) {
        updateActionsForItem(item)
        updatePreview(for: item)
    }

    func resultsView(_ view: LauncherResultsView, didActivateItem item: LauncherItem) {
        onItemActivated?(item)
    }
}
