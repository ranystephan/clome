import AppKit

extension Notification.Name {
    static let appearanceSettingsChanged = Notification.Name("clomeAppearanceSettingsChanged")
}

/// Manages appearance settings, persisted via SessionState.
@MainActor
class AppearanceSettings {
    static let shared = AppearanceSettings()

    // Background (unified for entire window)
    var backgroundColor: NSColor {
        didSet { save(); notify() }
    }
    var backgroundOpacity: CGFloat {
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
    static let defaultBackgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)
    static let defaultBackgroundOpacity: CGFloat = 0.92

    private init() {
        backgroundColor = Self.defaultBackgroundColor
        backgroundOpacity = Self.defaultBackgroundOpacity
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
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity
        )
    }

    private func load() {
        if let restored = SessionState.shared.restoreAppearance() {
            backgroundColor = restored.backgroundColor
            backgroundOpacity = restored.backgroundOpacity
        }
    }

    /// Returns the background color with the configured opacity applied.
    var backgroundBgColor: NSColor {
        backgroundColor.withAlphaComponent(backgroundOpacity)
    }
}
