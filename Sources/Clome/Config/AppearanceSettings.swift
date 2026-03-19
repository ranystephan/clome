import AppKit

extension Notification.Name {
    static let appearanceSettingsChanged = Notification.Name("clomeAppearanceSettingsChanged")
}

/// Manages sidebar and main panel appearance (color + opacity), persisted via SessionState.
@MainActor
class AppearanceSettings {
    static let shared = AppearanceSettings()

    // Sidebar
    var sidebarColor: NSColor {
        didSet { save(); notify() }
    }
    var sidebarOpacity: CGFloat {
        didSet { save(); notify() }
    }

    // Main panel
    var mainPanelColor: NSColor {
        didSet { save(); notify() }
    }
    var mainPanelOpacity: CGFloat {
        didSet { save(); notify() }
    }

    // File explorer
    var colorfulFileIcons: Bool {
        didSet { UserDefaults.standard.set(colorfulFileIcons, forKey: "clome.colorfulFileIcons"); notify() }
    }

    // Browser
    var openLinksInClomeBrowser: Bool {
        didSet { UserDefaults.standard.set(openLinksInClomeBrowser, forKey: "clome.openLinksInClomeBrowser"); notify() }
    }

    // Defaults
    static let defaultSidebarColor = NSColor(red: 0.145, green: 0.588, blue: 0.745, alpha: 1.0) // #2596be
    static let defaultSidebarOpacity: CGFloat = 0.15
    static let defaultMainPanelColor = NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)
    static let defaultMainPanelOpacity: CGFloat = 0.92

    private init() {
        sidebarColor = Self.defaultSidebarColor
        sidebarOpacity = Self.defaultSidebarOpacity
        mainPanelColor = Self.defaultMainPanelColor
        mainPanelOpacity = Self.defaultMainPanelOpacity
        colorfulFileIcons = UserDefaults.standard.object(forKey: "clome.colorfulFileIcons") as? Bool ?? true
        openLinksInClomeBrowser = UserDefaults.standard.object(forKey: "clome.openLinksInClomeBrowser") as? Bool ?? true
        load()
    }

    private func notify() {
        NotificationCenter.default.post(name: .appearanceSettingsChanged, object: nil)
    }

    // MARK: - Persistence

    private func save() {
        SessionState.shared.saveAppearance(
            sidebarColor: sidebarColor,
            sidebarOpacity: sidebarOpacity,
            mainPanelColor: mainPanelColor,
            mainPanelOpacity: mainPanelOpacity
        )
    }

    private func load() {
        if let restored = SessionState.shared.restoreAppearance() {
            sidebarColor = restored.sidebarColor
            sidebarOpacity = restored.sidebarOpacity
            mainPanelColor = restored.mainPanelColor
            mainPanelOpacity = restored.mainPanelOpacity
        }
    }

    /// Returns the sidebar tint color with the configured opacity applied.
    var sidebarTintColor: NSColor {
        sidebarColor.withAlphaComponent(sidebarOpacity)
    }

    /// Returns the main panel color with the configured opacity applied.
    var mainPanelBgColor: NSColor {
        mainPanelColor.withAlphaComponent(mainPanelOpacity)
    }
}
