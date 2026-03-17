import AppKit

@MainActor
class SettingsWindowController: NSWindowController {
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

    private let settings = AppearanceSettings.shared

    // Sidebar
    private var sidebarView: NSView!
    private var contentArea: NSView!
    private var appearanceRow: NSButton!
    private var languagesRow: NSButton!
    private var activePage: Int = 0

    // Appearance controls
    private var sidebarColorWell: NSColorWell!
    private var sidebarOpacitySlider: NSSlider!
    private var sidebarOpacityLabel: NSTextField!
    private var mainColorWell: NSColorWell!
    private var mainOpacitySlider: NSSlider!
    private var mainOpacityLabel: NSTextField!
    private var colorfulIconsToggle: NSButton!

    // Language view
    private var languageView: LanguageSupportView?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
        setupUI()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true

        // Sidebar
        sidebarView = NSView()
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.wantsLayer = true
        sidebarView.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.05).cgColor
        contentView.addSubview(sidebarView)

        // Content area
        contentArea = NSView()
        contentArea.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(contentArea)

        // Divider
        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        contentView.addSubview(divider)

        NSLayoutConstraint.activate([
            sidebarView.topAnchor.constraint(equalTo: contentView.topAnchor),
            sidebarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            sidebarView.widthAnchor.constraint(equalToConstant: 140),

            divider.topAnchor.constraint(equalTo: contentView.topAnchor),
            divider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            contentArea.topAnchor.constraint(equalTo: contentView.topAnchor),
            contentArea.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contentArea.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        // Sidebar rows
        appearanceRow = makeSidebarButton(title: "Appearance", icon: "paintbrush", tag: 0)
        languagesRow = makeSidebarButton(title: "Languages", icon: "chevron.left.forwardslash.chevron.right", tag: 1)

        sidebarView.addSubview(appearanceRow)
        sidebarView.addSubview(languagesRow)

        appearanceRow.translatesAutoresizingMaskIntoConstraints = false
        languagesRow.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            appearanceRow.topAnchor.constraint(equalTo: sidebarView.topAnchor, constant: 8),
            appearanceRow.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 6),
            appearanceRow.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -6),
            appearanceRow.heightAnchor.constraint(equalToConstant: 28),

            languagesRow.topAnchor.constraint(equalTo: appearanceRow.bottomAnchor, constant: 2),
            languagesRow.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 6),
            languagesRow.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -6),
            languagesRow.heightAnchor.constraint(equalToConstant: 28),
        ])

        showPage(0)
    }

    private func makeSidebarButton(title: String, icon: String, tag: Int) -> NSButton {
        let btn = NSButton(title: title, target: self, action: #selector(sidebarClicked(_:)))
        btn.tag = tag
        btn.bezelStyle = .recessed
        btn.setButtonType(.pushOnPushOff)
        btn.isBordered = false
        btn.alignment = .left
        btn.font = .systemFont(ofSize: 13)
        if let img = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
            btn.image = img
            btn.imagePosition = .imageLeading
        }
        return btn
    }

    @objc private func sidebarClicked(_ sender: NSButton) {
        showPage(sender.tag)
    }

    private func showPage(_ page: Int) {
        activePage = page

        // Update sidebar highlight
        appearanceRow.state = page == 0 ? .on : .off
        languagesRow.state = page == 1 ? .on : .off

        // Clear content area
        contentArea.subviews.forEach { $0.removeFromSuperview() }
        languageView = nil

        if page == 0 {
            buildAppearanceContent()
        } else {
            buildLanguagesContent()
        }
    }

    private func buildAppearanceContent() {
        let padding: CGFloat = 24
        let labelWidth: CGFloat = 110
        let controlX: CGFloat = padding + labelWidth + 8

        var y: CGFloat = contentArea.frame.height > 0 ? contentArea.frame.height - 40 : 440

        // Sidebar section
        let sidebarHeader = makeHeader("Sidebar")
        sidebarHeader.frame.origin = NSPoint(x: padding, y: y)
        contentArea.addSubview(sidebarHeader)
        y -= 36

        let sidebarColorLabel = makeLabel("Color")
        sidebarColorLabel.frame.origin = NSPoint(x: padding + 12, y: y + 2)
        contentArea.addSubview(sidebarColorLabel)

        sidebarColorWell = NSColorWell(frame: NSRect(x: controlX, y: y, width: 44, height: 28))
        sidebarColorWell.color = settings.sidebarColor
        sidebarColorWell.target = self
        sidebarColorWell.action = #selector(sidebarColorChanged(_:))
        contentArea.addSubview(sidebarColorWell)
        y -= 36

        let sidebarOpLabel = makeLabel("Opacity")
        sidebarOpLabel.frame.origin = NSPoint(x: padding + 12, y: y + 2)
        contentArea.addSubview(sidebarOpLabel)

        sidebarOpacitySlider = NSSlider(value: Double(settings.sidebarOpacity), minValue: 0.0, maxValue: 1.0, target: self, action: #selector(sidebarOpacityChanged(_:)))
        sidebarOpacitySlider.frame = NSRect(x: controlX, y: y + 2, width: 160, height: 20)
        contentArea.addSubview(sidebarOpacitySlider)

        sidebarOpacityLabel = makeValueLabel(String(format: "%.0f%%", settings.sidebarOpacity * 100))
        sidebarOpacityLabel.frame.origin = NSPoint(x: controlX + 168, y: y + 2)
        contentArea.addSubview(sidebarOpacityLabel)
        y -= 44

        // Main Window section
        let mainHeader = makeHeader("Main Window")
        mainHeader.frame.origin = NSPoint(x: padding, y: y)
        contentArea.addSubview(mainHeader)
        y -= 36

        let mainColorLabel = makeLabel("Color")
        mainColorLabel.frame.origin = NSPoint(x: padding + 12, y: y + 2)
        contentArea.addSubview(mainColorLabel)

        mainColorWell = NSColorWell(frame: NSRect(x: controlX, y: y, width: 44, height: 28))
        mainColorWell.color = settings.mainPanelColor
        mainColorWell.target = self
        mainColorWell.action = #selector(mainColorChanged(_:))
        contentArea.addSubview(mainColorWell)
        y -= 36

        let mainOpLabel = makeLabel("Opacity")
        mainOpLabel.frame.origin = NSPoint(x: padding + 12, y: y + 2)
        contentArea.addSubview(mainOpLabel)

        mainOpacitySlider = NSSlider(value: Double(settings.mainPanelOpacity), minValue: 0.0, maxValue: 1.0, target: self, action: #selector(mainOpacityChanged(_:)))
        mainOpacitySlider.frame = NSRect(x: controlX, y: y + 2, width: 160, height: 20)
        contentArea.addSubview(mainOpacitySlider)

        mainOpacityLabel = makeValueLabel(String(format: "%.0f%%", settings.mainPanelOpacity * 100))
        mainOpacityLabel.frame.origin = NSPoint(x: controlX + 168, y: y + 2)
        contentArea.addSubview(mainOpacityLabel)
        y -= 44

        // File Explorer section
        let explorerHeader = makeHeader("File Explorer")
        explorerHeader.frame.origin = NSPoint(x: padding, y: y)
        contentArea.addSubview(explorerHeader)
        y -= 36

        colorfulIconsToggle = NSButton(checkboxWithTitle: "Colorful file icons", target: self, action: #selector(colorfulIconsChanged(_:)))
        colorfulIconsToggle.state = settings.colorfulFileIcons ? .on : .off
        colorfulIconsToggle.font = .systemFont(ofSize: 13)
        colorfulIconsToggle.sizeToFit()
        colorfulIconsToggle.frame.origin = NSPoint(x: padding + 12, y: y)
        contentArea.addSubview(colorfulIconsToggle)
        y -= 44

        // Reset button
        let resetBtn = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetDefaults(_:)))
        resetBtn.bezelStyle = .rounded
        resetBtn.frame = NSRect(x: padding, y: y, width: 140, height: 28)
        contentArea.addSubview(resetBtn)
    }

    private func buildLanguagesContent() {
        let lv = LanguageSupportView(frame: contentArea.bounds)
        lv.translatesAutoresizingMaskIntoConstraints = false
        contentArea.addSubview(lv)
        NSLayoutConstraint.activate([
            lv.topAnchor.constraint(equalTo: contentArea.topAnchor),
            lv.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            lv.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            lv.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
        ])
        languageView = lv
    }

    // MARK: - Actions

    @objc private func sidebarColorChanged(_ sender: NSColorWell) {
        settings.sidebarColor = sender.color
    }

    @objc private func sidebarOpacityChanged(_ sender: NSSlider) {
        settings.sidebarOpacity = CGFloat(sender.doubleValue)
        sidebarOpacityLabel.stringValue = String(format: "%.0f%%", sender.doubleValue * 100)
    }

    @objc private func mainColorChanged(_ sender: NSColorWell) {
        settings.mainPanelColor = sender.color
    }

    @objc private func mainOpacityChanged(_ sender: NSSlider) {
        settings.mainPanelOpacity = CGFloat(sender.doubleValue)
        mainOpacityLabel.stringValue = String(format: "%.0f%%", sender.doubleValue * 100)
    }

    @objc private func colorfulIconsChanged(_ sender: NSButton) {
        settings.colorfulFileIcons = sender.state == .on
    }

    @objc private func resetDefaults(_ sender: Any?) {
        settings.sidebarColor = AppearanceSettings.defaultSidebarColor
        settings.sidebarOpacity = AppearanceSettings.defaultSidebarOpacity
        settings.mainPanelColor = AppearanceSettings.defaultMainPanelColor
        settings.mainPanelOpacity = AppearanceSettings.defaultMainPanelOpacity
        settings.colorfulFileIcons = true

        sidebarColorWell.color = settings.sidebarColor
        sidebarOpacitySlider.doubleValue = Double(settings.sidebarOpacity)
        sidebarOpacityLabel.stringValue = String(format: "%.0f%%", settings.sidebarOpacity * 100)
        mainColorWell.color = settings.mainPanelColor
        mainOpacitySlider.doubleValue = Double(settings.mainPanelOpacity)
        mainOpacityLabel.stringValue = String(format: "%.0f%%", settings.mainPanelOpacity * 100)
        colorfulIconsToggle.state = .on
    }

    // MARK: - Helpers

    private func makeHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.sizeToFit()
        return label
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.sizeToFit()
        return label
    }

    private func makeValueLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.frame.size = NSSize(width: 44, height: 18)
        return label
    }
}
