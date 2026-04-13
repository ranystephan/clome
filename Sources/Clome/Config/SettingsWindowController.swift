import AppKit
import ClomeDesign

@MainActor
class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    private static var shared: SettingsWindowController?

    static func show() {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let ctrl = SettingsWindowController()
        shared = ctrl
        ctrl.window?.makeKeyAndOrderFront(nil)
    }

    private let settings = ClomeSettings.shared

    private var contentArea: NSView!
    private var activePage: ToolbarPage = .general

    private enum ToolbarPage: String, CaseIterable {
        case general = "General"
        case editor = "Editor"
        case terminal = "Terminal"
        case languages = "Languages"

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .editor: return "doc.text"
            case .terminal: return "terminal"
            case .languages: return "chevron.left.forwardslash.chevron.right"
            }
        }

        var identifier: NSToolbarItem.Identifier {
            NSToolbarItem.Identifier("settings.\(rawValue)")
        }
    }

    // MARK: - Init

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.titlebarAppearsTransparent = false
        self.init(window: window)
        setupToolbar()
        setupContentArea()
        showPage(.general)
    }

    // MARK: - Toolbar

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = ToolbarPage.general.identifier
        window?.toolbar = toolbar
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ToolbarPage.allCases.map(\.identifier)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ToolbarPage.allCases.map(\.identifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ToolbarPage.allCases.map(\.identifier)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let page = ToolbarPage.allCases.first(where: { $0.identifier == itemIdentifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = page.rawValue
        item.image = NSImage(systemSymbolName: page.icon, accessibilityDescription: page.rawValue)
        item.target = self
        item.action = #selector(toolbarItemClicked(_:))
        return item
    }

    @objc private func toolbarItemClicked(_ sender: NSToolbarItem) {
        guard let page = ToolbarPage.allCases.first(where: { $0.identifier == sender.itemIdentifier }) else { return }
        showPage(page)
    }

    // MARK: - Content Area

    private func setupContentArea() {
        guard let contentView = window?.contentView else { return }
        contentArea = NSView()
        contentArea.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(contentArea)
        NSLayoutConstraint.activate([
            contentArea.topAnchor.constraint(equalTo: contentView.topAnchor),
            contentArea.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contentArea.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    private func showPage(_ page: ToolbarPage) {
        activePage = page
        window?.toolbar?.selectedItemIdentifier = page.identifier
        contentArea.subviews.forEach { $0.removeFromSuperview() }

        let pageView: NSView
        switch page {
        case .general: pageView = buildGeneralPage()
        case .editor: pageView = buildEditorPage()
        case .terminal: pageView = buildTerminalPage()
        case .languages: pageView = buildLanguagesPage()
        }

        contentArea.addSubview(pageView)
        NSLayoutConstraint.activate([
            pageView.topAnchor.constraint(equalTo: contentArea.topAnchor),
            pageView.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            pageView.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
        ])
    }

    // MARK: - General Page

    private func buildGeneralPage() -> NSView {
        let stack = makePageStack()

        // Theme
        stack.addArrangedSubview(makeSectionHeader("Theme"))
        let themeSegment = NSSegmentedControl(labels: ThemeMode.allCases.map(\.displayName), trackingMode: .selectOne, target: self, action: #selector(themeModeChanged(_:)))
        themeSegment.segmentStyle = .automatic
        themeSegment.selectedSegment = ThemeMode.allCases.firstIndex(of: settings.themeMode) ?? 2
        themeSegment.translatesAutoresizingMaskIntoConstraints = false
        themeSegment.widthAnchor.constraint(equalToConstant: 240).isActive = true
        stack.addArrangedSubview(wrapInRow(label: "Appearance", control: themeSegment))

        // Accent Color
        stack.addArrangedSubview(makeSectionHeader("Accent Color"))
        let accentRow = makeAccentColorRow()
        stack.addArrangedSubview(wrapInRow(label: "Color", control: accentRow))

        // Window
        stack.addArrangedSubview(makeSectionHeader("Window"))

        let opacitySlider = NSSlider(value: Double(settings.windowOpacity), minValue: 0.2, maxValue: 1.0, target: self, action: #selector(opacityChanged(_:)))
        opacitySlider.translatesAutoresizingMaskIntoConstraints = false
        opacitySlider.widthAnchor.constraint(equalToConstant: 160).isActive = true

        let opacityLabel = NSTextField(labelWithString: String(format: "%.0f%%", settings.windowOpacity * 100))
        opacityLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        opacityLabel.textColor = .secondaryLabelColor
        opacityLabel.tag = 100 // for lookup
        opacityLabel.translatesAutoresizingMaskIntoConstraints = false
        opacityLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let opacityStack = NSStackView(views: [opacitySlider, opacityLabel])
        opacityStack.orientation = .horizontal
        opacityStack.spacing = 8
        stack.addArrangedSubview(wrapInRow(label: "Opacity", control: opacityStack))

        let sessionCheck = makeCheckbox("Restore session on launch", checked: settings.restoreSessionOnLaunch, action: #selector(restoreSessionChanged(_:)))
        stack.addArrangedSubview(wrapInRow(label: "", control: sessionCheck))

        let autoHideTabCheck = makeCheckbox("Auto-hide tab bar", checked: settings.autoHideTabBar, action: #selector(autoHideTabBarChanged(_:)))
        stack.addArrangedSubview(wrapInRow(label: "", control: autoHideTabCheck))

        // Behavior
        stack.addArrangedSubview(makeSectionHeader("Behavior"))

        let linksPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        linksPopup.addItems(withTitles: ["Clome Browser", "System Browser"])
        linksPopup.selectItem(at: settings.openLinksInClomeBrowser ? 0 : 1)
        linksPopup.target = self
        linksPopup.action = #selector(openLinksChanged(_:))
        linksPopup.translatesAutoresizingMaskIntoConstraints = false
        linksPopup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        stack.addArrangedSubview(wrapInRow(label: "Open links in", control: linksPopup))

        let iconsCheck = makeCheckbox("Colorful file icons", checked: settings.colorfulFileIcons, action: #selector(colorfulIconsChanged(_:)))
        stack.addArrangedSubview(wrapInRow(label: "", control: iconsCheck))

        // Reset
        stack.addArrangedSubview(makeSpacer(20))
        let resetBtn = NSButton(title: "Reset All to Defaults", target: self, action: #selector(resetDefaults(_:)))
        resetBtn.bezelStyle = .rounded
        stack.addArrangedSubview(wrapInRow(label: "", control: resetBtn))

        return wrapInScroll(stack)
    }

    // MARK: - Editor Page

    private func buildEditorPage() -> NSView {
        let stack = makePageStack()

        // Font
        stack.addArrangedSubview(makeSectionHeader("Font"))

        let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        fontPopup.addItem(withTitle: "System Mono (SF Mono)")
        let monoFamilies = NSFontManager.shared.availableFontFamilies.filter { family in
            if let font = NSFont(name: family, size: 13) {
                return font.isFixedPitch || family.lowercased().contains("mono") || family.lowercased().contains("code")
            }
            return false
        }.sorted()
        for family in monoFamilies {
            fontPopup.addItem(withTitle: family)
        }
        if !settings.editorFontFamily.isEmpty {
            fontPopup.selectItem(withTitle: settings.editorFontFamily)
        } else {
            fontPopup.selectItem(at: 0)
        }
        fontPopup.target = self
        fontPopup.action = #selector(fontFamilyChanged(_:))
        fontPopup.translatesAutoresizingMaskIntoConstraints = false
        fontPopup.widthAnchor.constraint(equalToConstant: 200).isActive = true
        stack.addArrangedSubview(wrapInRow(label: "Family", control: fontPopup))

        let sizeStepper = NSStepper(frame: .zero)
        sizeStepper.minValue = 8
        sizeStepper.maxValue = 32
        sizeStepper.increment = 1
        sizeStepper.doubleValue = Double(settings.editorFontSize)
        sizeStepper.target = self
        sizeStepper.action = #selector(fontSizeStepperChanged(_:))
        sizeStepper.translatesAutoresizingMaskIntoConstraints = false

        let sizeField = NSTextField(string: String(format: "%.0f", settings.editorFontSize))
        sizeField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        sizeField.alignment = .center
        sizeField.translatesAutoresizingMaskIntoConstraints = false
        sizeField.widthAnchor.constraint(equalToConstant: 40).isActive = true
        sizeField.tag = 200
        sizeField.target = self
        sizeField.action = #selector(fontSizeFieldChanged(_:))

        let sizeLabel = NSTextField(labelWithString: "pt")
        sizeLabel.textColor = .secondaryLabelColor

        let sizeStack = NSStackView(views: [sizeField, sizeLabel, sizeStepper])
        sizeStack.orientation = .horizontal
        sizeStack.spacing = 4
        stack.addArrangedSubview(wrapInRow(label: "Size", control: sizeStack))

        // Display
        stack.addArrangedSubview(makeSectionHeader("Display"))

        let lineHeightSlider = NSSlider(value: Double(settings.lineHeightMultiplier), minValue: 1.0, maxValue: 2.0, target: self, action: #selector(lineHeightChanged(_:)))
        lineHeightSlider.translatesAutoresizingMaskIntoConstraints = false
        lineHeightSlider.widthAnchor.constraint(equalToConstant: 140).isActive = true

        let lineHeightLabel = NSTextField(labelWithString: String(format: "%.1fx", settings.lineHeightMultiplier))
        lineHeightLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        lineHeightLabel.textColor = .secondaryLabelColor
        lineHeightLabel.tag = 300
        lineHeightLabel.translatesAutoresizingMaskIntoConstraints = false
        lineHeightLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let lhStack = NSStackView(views: [lineHeightSlider, lineHeightLabel])
        lhStack.orientation = .horizontal
        lhStack.spacing = 8
        stack.addArrangedSubview(wrapInRow(label: "Line height", control: lhStack))

        stack.addArrangedSubview(wrapInRow(label: "", control: makeCheckbox("Show line numbers", checked: settings.showLineNumbers, action: #selector(showLineNumbersChanged(_:)))))
        stack.addArrangedSubview(wrapInRow(label: "", control: makeCheckbox("Highlight current line", checked: settings.highlightCurrentLine, action: #selector(highlightCurrentLineChanged(_:)))))
        stack.addArrangedSubview(wrapInRow(label: "", control: makeCheckbox("Show minimap", checked: settings.showMinimap, action: #selector(showMinimapChanged(_:)))))
        stack.addArrangedSubview(wrapInRow(label: "", control: makeCheckbox("Cursor blink", checked: settings.cursorBlink, action: #selector(cursorBlinkChanged(_:)))))
        stack.addArrangedSubview(wrapInRow(label: "", control: makeCheckbox("Word wrap", checked: settings.wordWrap, action: #selector(wordWrapChanged(_:)))))

        // Indentation
        stack.addArrangedSubview(makeSectionHeader("Indentation"))

        let tabPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        tabPopup.addItems(withTitles: ["2", "4", "8"])
        switch settings.tabSize {
        case 2: tabPopup.selectItem(at: 0)
        case 8: tabPopup.selectItem(at: 2)
        default: tabPopup.selectItem(at: 1)
        }
        tabPopup.target = self
        tabPopup.action = #selector(tabSizeChanged(_:))
        tabPopup.translatesAutoresizingMaskIntoConstraints = false
        tabPopup.widthAnchor.constraint(equalToConstant: 80).isActive = true
        stack.addArrangedSubview(wrapInRow(label: "Tab size", control: tabPopup))

        stack.addArrangedSubview(wrapInRow(label: "", control: makeCheckbox("Insert spaces for tabs", checked: settings.insertSpacesForTabs, action: #selector(insertSpacesChanged(_:)))))

        return wrapInScroll(stack)
    }

    // MARK: - Terminal Page

    private func buildTerminalPage() -> NSView {
        let stack = makePageStack()

        stack.addArrangedSubview(makeSectionHeader("Terminal Engine"))

        let infoLabel = NSTextField(wrappingLabelWithString: "Clome's terminal is powered by Ghostty, a GPU-accelerated terminal emulator. Terminal settings (font, colors, keybindings) are configured through Ghostty's config file.")
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = .systemFont(ofSize: 13)
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(infoLabel)

        stack.addArrangedSubview(makeSpacer(8))

        let pathLabel = NSTextField(labelWithString: "~/.config/ghostty/config")
        pathLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        pathLabel.textColor = .labelColor
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(wrapInRow(label: "Config file", control: pathLabel))

        stack.addArrangedSubview(makeSpacer(8))

        let openBtn = NSButton(title: "Open Config in Editor", target: self, action: #selector(openGhosttyConfig(_:)))
        openBtn.bezelStyle = .rounded
        stack.addArrangedSubview(wrapInRow(label: "", control: openBtn))

        stack.addArrangedSubview(makeSpacer(16))

        let hintLabel = NSTextField(wrappingLabelWithString: "Common settings: font-family, font-size, theme, cursor-style, window-padding, keybind. See Ghostty documentation for all options.")
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(hintLabel)

        return wrapInScroll(stack)
    }

    // MARK: - Languages Page

    private func buildLanguagesPage() -> NSView {
        let lv = LanguageSupportView(frame: .zero)
        lv.translatesAutoresizingMaskIntoConstraints = false
        return lv
    }

    // MARK: - Accent Color Row

    private func makeAccentColorRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        for theme in ClomeAccentTheme.allCases {
            let btn = AccentColorButton(theme: theme, isSelected: theme == settings.accentTheme)
            btn.target = self
            btn.action = #selector(accentColorClicked(_:))
            row.addArrangedSubview(btn)
        }

        return row
    }

    // MARK: - Actions

    @objc private func themeModeChanged(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment < ThemeMode.allCases.count else { return }
        settings.themeMode = ThemeMode.allCases[sender.selectedSegment]
    }

    @objc private func accentColorClicked(_ sender: AccentColorButton) {
        settings.accentTheme = sender.theme
        // Update selection state on all accent buttons
        if let stack = sender.superview as? NSStackView {
            for case let btn as AccentColorButton in stack.arrangedSubviews {
                btn.isSelected = btn.theme == sender.theme
            }
        }
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        settings.windowOpacity = CGFloat(sender.doubleValue)
        if let label = sender.superview?.subviews.first(where: { $0.tag == 100 }) as? NSTextField {
            label.stringValue = String(format: "%.0f%%", sender.doubleValue * 100)
        }
    }

    @objc private func restoreSessionChanged(_ sender: NSButton) {
        settings.restoreSessionOnLaunch = sender.state == .on
    }

    @objc private func openLinksChanged(_ sender: NSPopUpButton) {
        settings.openLinksInClomeBrowser = sender.indexOfSelectedItem == 0
    }

    @objc private func colorfulIconsChanged(_ sender: NSButton) {
        settings.colorfulFileIcons = sender.state == .on
    }

    @objc private func autoHideTabBarChanged(_ sender: NSButton) {
        settings.autoHideTabBar = sender.state == .on
    }

    @objc private func fontFamilyChanged(_ sender: NSPopUpButton) {
        if sender.indexOfSelectedItem == 0 {
            settings.editorFontFamily = ""
        } else {
            settings.editorFontFamily = sender.titleOfSelectedItem ?? ""
        }
    }

    @objc private func fontSizeStepperChanged(_ sender: NSStepper) {
        settings.editorFontSize = CGFloat(sender.doubleValue)
        if let field = sender.superview?.subviews.first(where: { $0.tag == 200 }) as? NSTextField {
            field.stringValue = String(format: "%.0f", sender.doubleValue)
        }
    }

    @objc private func fontSizeFieldChanged(_ sender: NSTextField) {
        let val = CGFloat(sender.doubleValue)
        if val >= 8 && val <= 32 {
            settings.editorFontSize = val
        }
    }

    @objc private func lineHeightChanged(_ sender: NSSlider) {
        let rounded = (sender.doubleValue * 10).rounded() / 10 // round to 0.1
        settings.lineHeightMultiplier = CGFloat(rounded)
        if let label = sender.superview?.subviews.first(where: { $0.tag == 300 }) as? NSTextField {
            label.stringValue = String(format: "%.1fx", rounded)
        }
    }

    @objc private func showLineNumbersChanged(_ sender: NSButton) {
        settings.showLineNumbers = sender.state == .on
    }

    @objc private func highlightCurrentLineChanged(_ sender: NSButton) {
        settings.highlightCurrentLine = sender.state == .on
    }

    @objc private func showMinimapChanged(_ sender: NSButton) {
        settings.showMinimap = sender.state == .on
    }

    @objc private func cursorBlinkChanged(_ sender: NSButton) {
        settings.cursorBlink = sender.state == .on
    }

    @objc private func wordWrapChanged(_ sender: NSButton) {
        settings.wordWrap = sender.state == .on
    }

    @objc private func tabSizeChanged(_ sender: NSPopUpButton) {
        let sizes = [2, 4, 8]
        settings.tabSize = sizes[sender.indexOfSelectedItem]
    }

    @objc private func insertSpacesChanged(_ sender: NSButton) {
        settings.insertSpacesForTabs = sender.state == .on
    }

    @objc private func openGhosttyConfig(_ sender: Any?) {
        let configPath = NSString("~/.config/ghostty/config").expandingTildeInPath
        // Create directory + file if they don't exist
        let dir = (configPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: configPath) {
            FileManager.default.createFile(atPath: configPath, contents: "# Ghostty Configuration\n# See: https://ghostty.org/docs/config\n\n".data(using: .utf8))
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
    }

    @objc private func resetDefaults(_ sender: Any?) {
        settings.resetToDefaults()
        // Refresh the current page
        showPage(activePage)
    }

    // MARK: - Layout Helpers

    private func makePageStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 32, bottom: 20, right: 32)
        return stack
    }

    private func wrapInScroll(_ stack: NSStackView) -> NSView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.documentView = stack

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])

        return scroll
    }

    private func makeSectionHeader(_ text: String) -> NSView {
        let spacer = makeSpacer(12)
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSStackView(views: [spacer, label])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 4
        return container
    }

    private func wrapInRow(label labelText: String, control: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        if !labelText.isEmpty {
            let label = NSTextField(labelWithString: labelText)
            label.font = .systemFont(ofSize: 13)
            label.textColor = .labelColor
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 100).isActive = true
            row.addArrangedSubview(label)
        } else {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.widthAnchor.constraint(equalToConstant: 100).isActive = true
            row.addArrangedSubview(spacer)
        }

        control.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(control)

        return row
    }

    private func makeCheckbox(_ title: String, checked: Bool, action: Selector) -> NSButton {
        let btn = NSButton(checkboxWithTitle: title, target: self, action: action)
        btn.state = checked ? .on : .off
        btn.font = .systemFont(ofSize: 13)
        return btn
    }

    private func makeSpacer(_ height: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        return v
    }
}

// MARK: - Accent Color Button

private class AccentColorButton: NSButton {
    let theme: ClomeAccentTheme
    var isSelected: Bool {
        didSet { needsDisplay = true }
    }

    init(theme: ClomeAccentTheme, isSelected: Bool) {
        self.theme = theme
        self.isSelected = isSelected
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        self.isBordered = false
        self.title = ""
        self.setButtonType(.momentaryChange)
        self.toolTip = theme.displayName
        self.translatesAutoresizingMaskIntoConstraints = false
        self.widthAnchor.constraint(equalToConstant: 24).isActive = true
        self.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let accentColor = isDark ? NSColor(theme.darkAccent) : NSColor(theme.lightAccent)

        let circleRect = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(ovalIn: circleRect)

        accentColor.setFill()
        path.fill()

        if isSelected {
            let ringRect = bounds.insetBy(dx: 0.5, dy: 0.5)
            let ring = NSBezierPath(ovalIn: ringRect)
            ring.lineWidth = 2.0
            NSColor.labelColor.withAlphaComponent(0.6).setStroke()
            ring.stroke()
        }
    }
}
