import AppKit
import ClomeDesign

// MARK: - Theme Mode

enum ThemeMode: String, CaseIterable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    static let clomeSettingsChanged = Notification.Name("clomeSettingsChanged")
}

// MARK: - Settings Keys

private enum SettingsKey {
    static let themeMode = "clome.themeMode"
    static let accentTheme = "clome.accentTheme"
    static let windowOpacity = "clome.windowOpacity"
    static let openLinksInClomeBrowser = "clome.openLinksInClomeBrowser"
    static let restoreSessionOnLaunch = "clome.restoreSessionOnLaunch"

    static let editorFontSize = "clome.editorFontSize"
    static let editorFontFamily = "clome.editorFontFamily"
    static let lineHeightMultiplier = "clome.lineHeightMultiplier"
    static let tabSize = "clome.tabSize"
    static let insertSpacesForTabs = "clome.insertSpacesForTabs"
    static let wordWrap = "clome.wordWrap"
    static let showMinimap = "clome.showMinimap"
    static let showLineNumbers = "clome.showLineNumbers"
    static let cursorBlink = "clome.cursorBlink"
    static let highlightCurrentLine = "clome.highlightCurrentLine"

    static let colorfulFileIcons = "clome.colorfulFileIcons"
    static let autoHideTabBar = "clome.autoHideTabBar"
}

// MARK: - ClomeSettings

@MainActor
final class ClomeSettings {
    static let shared = ClomeSettings()

    private let defaults = UserDefaults.standard

    // MARK: - General

    /// Called before .clomeSettingsChanged is posted when theme/accent changes.
    /// Set by ClomeMacTheme to apply NSApp.appearance before views re-resolve colors.
    var onThemeWillChange: (() -> Void)?

    var themeMode: ThemeMode {
        didSet { defaults.set(themeMode.rawValue, forKey: SettingsKey.themeMode); onThemeWillChange?(); notify() }
    }

    var accentTheme: ClomeAccentTheme {
        didSet { defaults.set(accentTheme.rawValue, forKey: SettingsKey.accentTheme); onThemeWillChange?(); notify() }
    }

    var windowOpacity: CGFloat {
        didSet {
            let clamped = min(1.0, max(0.2, windowOpacity))
            if clamped != windowOpacity { windowOpacity = clamped; return }
            defaults.set(Double(windowOpacity), forKey: SettingsKey.windowOpacity); notify()
        }
    }

    var openLinksInClomeBrowser: Bool {
        didSet { defaults.set(openLinksInClomeBrowser, forKey: SettingsKey.openLinksInClomeBrowser); notify() }
    }

    var restoreSessionOnLaunch: Bool {
        didSet { defaults.set(restoreSessionOnLaunch, forKey: SettingsKey.restoreSessionOnLaunch); notify() }
    }

    // MARK: - Editor

    var editorFontSize: CGFloat {
        didSet {
            let clamped = min(32, max(8, editorFontSize))
            if clamped != editorFontSize { editorFontSize = clamped; return }
            defaults.set(Double(editorFontSize), forKey: SettingsKey.editorFontSize)
            _resolvedFont = nil
            _resolvedBoldFont = nil
            notify()
        }
    }

    var editorFontFamily: String {
        didSet {
            defaults.set(editorFontFamily, forKey: SettingsKey.editorFontFamily)
            _resolvedFont = nil
            _resolvedBoldFont = nil
            notify()
        }
    }

    var lineHeightMultiplier: CGFloat {
        didSet {
            let clamped = min(2.0, max(1.0, lineHeightMultiplier))
            if clamped != lineHeightMultiplier { lineHeightMultiplier = clamped; return }
            defaults.set(Double(lineHeightMultiplier), forKey: SettingsKey.lineHeightMultiplier); notify()
        }
    }

    var tabSize: Int {
        didSet { defaults.set(tabSize, forKey: SettingsKey.tabSize); notify() }
    }

    var insertSpacesForTabs: Bool {
        didSet { defaults.set(insertSpacesForTabs, forKey: SettingsKey.insertSpacesForTabs); notify() }
    }

    var wordWrap: Bool {
        didSet { defaults.set(wordWrap, forKey: SettingsKey.wordWrap); notify() }
    }

    var showMinimap: Bool {
        didSet { defaults.set(showMinimap, forKey: SettingsKey.showMinimap); notify() }
    }

    var showLineNumbers: Bool {
        didSet { defaults.set(showLineNumbers, forKey: SettingsKey.showLineNumbers); notify() }
    }

    var cursorBlink: Bool {
        didSet { defaults.set(cursorBlink, forKey: SettingsKey.cursorBlink); notify() }
    }

    var highlightCurrentLine: Bool {
        didSet { defaults.set(highlightCurrentLine, forKey: SettingsKey.highlightCurrentLine); notify() }
    }

    // MARK: - File Explorer

    var colorfulFileIcons: Bool {
        didSet { defaults.set(colorfulFileIcons, forKey: SettingsKey.colorfulFileIcons); notify() }
    }

    // MARK: - Tab Bar

    var autoHideTabBar: Bool {
        didSet { defaults.set(autoHideTabBar, forKey: SettingsKey.autoHideTabBar); notify() }
    }

    // MARK: - Computed Helpers

    private var _resolvedFont: NSFont?
    private var _resolvedBoldFont: NSFont?

    var resolvedFont: NSFont {
        if let cached = _resolvedFont { return cached }
        let font: NSFont
        if editorFontFamily.isEmpty {
            font = NSFont.monospacedSystemFont(ofSize: editorFontSize, weight: .regular)
        } else if let custom = NSFont(name: editorFontFamily, size: editorFontSize) {
            font = custom
        } else {
            font = NSFont.monospacedSystemFont(ofSize: editorFontSize, weight: .regular)
        }
        _resolvedFont = font
        return font
    }

    var resolvedBoldFont: NSFont {
        if let cached = _resolvedBoldFont { return cached }
        let font: NSFont
        if editorFontFamily.isEmpty {
            font = NSFont.monospacedSystemFont(ofSize: editorFontSize, weight: .bold)
        } else if let custom = NSFont(name: editorFontFamily, size: editorFontSize),
                  let bold = NSFontManager.shared.convert(custom, toHaveTrait: .boldFontMask) as NSFont? {
            font = bold
        } else {
            font = NSFont.monospacedSystemFont(ofSize: editorFontSize, weight: .bold)
        }
        _resolvedBoldFont = font
        return font
    }

    var resolvedLineHeight: CGFloat {
        editorFontSize * lineHeightMultiplier
    }

    var tabString: String {
        insertSpacesForTabs ? String(repeating: " ", count: tabSize) : "\t"
    }

    /// Window background with user's opacity applied.
    var backgroundWithOpacity: NSColor {
        ClomeMacTheme.windowTint(opacity: windowOpacity)
    }

    // MARK: - Backward Compat (transitional — remove once all consumers migrate)

    var backgroundColor: NSColor { ClomeMacColor.windowBackground }
    var backgroundOpacity: CGFloat { windowOpacity }
    var backgroundBgColor: NSColor { backgroundWithOpacity }

    // MARK: - Init

    private init() {
        let d = UserDefaults.standard

        // General
        themeMode = ThemeMode(rawValue: d.string(forKey: SettingsKey.themeMode) ?? "") ?? .system
        accentTheme = ClomeAccentTheme(rawValue: d.string(forKey: SettingsKey.accentTheme) ?? "") ?? .graphite
        windowOpacity = d.object(forKey: SettingsKey.windowOpacity) != nil
            ? CGFloat(d.double(forKey: SettingsKey.windowOpacity)) : 0.92
        openLinksInClomeBrowser = d.object(forKey: SettingsKey.openLinksInClomeBrowser) as? Bool ?? true
        restoreSessionOnLaunch = d.object(forKey: SettingsKey.restoreSessionOnLaunch) as? Bool ?? true

        // Editor
        editorFontSize = d.object(forKey: SettingsKey.editorFontSize) != nil
            ? CGFloat(d.double(forKey: SettingsKey.editorFontSize)) : 13
        editorFontFamily = d.string(forKey: SettingsKey.editorFontFamily) ?? ""
        lineHeightMultiplier = d.object(forKey: SettingsKey.lineHeightMultiplier) != nil
            ? CGFloat(d.double(forKey: SettingsKey.lineHeightMultiplier)) : 1.4
        tabSize = d.object(forKey: SettingsKey.tabSize) != nil ? d.integer(forKey: SettingsKey.tabSize) : 4
        insertSpacesForTabs = d.object(forKey: SettingsKey.insertSpacesForTabs) as? Bool ?? true
        wordWrap = d.object(forKey: SettingsKey.wordWrap) as? Bool ?? false
        showMinimap = d.object(forKey: SettingsKey.showMinimap) as? Bool ?? false
        showLineNumbers = d.object(forKey: SettingsKey.showLineNumbers) as? Bool ?? true
        cursorBlink = d.object(forKey: SettingsKey.cursorBlink) as? Bool ?? true
        highlightCurrentLine = d.object(forKey: SettingsKey.highlightCurrentLine) as? Bool ?? true

        // File Explorer
        colorfulFileIcons = d.object(forKey: SettingsKey.colorfulFileIcons) as? Bool ?? true

        // Tab Bar
        autoHideTabBar = d.object(forKey: SettingsKey.autoHideTabBar) as? Bool ?? false

        // Migrate from old AppearanceSettings keys
        migrateOldSettings()
    }

    private func migrateOldSettings() {
        // Migrate old boolean keys if they exist and new keys don't
        let oldIconsKey = "clome.colorfulFileIcons"
        let oldLinksKey = "clome.openLinksInClomeBrowser"
        // These keys are the same, so they're already migrated by virtue of the same key names.
        // The SQLite-stored bg color/opacity are no longer used — the design system handles colors.
        _ = oldIconsKey
        _ = oldLinksKey
    }

    // MARK: - Reset

    func resetToDefaults() {
        themeMode = .system
        accentTheme = .graphite
        windowOpacity = 0.92
        openLinksInClomeBrowser = true
        restoreSessionOnLaunch = true

        editorFontSize = 13
        editorFontFamily = ""
        lineHeightMultiplier = 1.4
        tabSize = 4
        insertSpacesForTabs = true
        wordWrap = false
        showMinimap = false
        showLineNumbers = true
        cursorBlink = true
        highlightCurrentLine = true

        colorfulFileIcons = true

        autoHideTabBar = false
    }

    // MARK: - Notification

    private func notify() {
        NotificationCenter.default.post(name: .clomeSettingsChanged, object: nil)
    }
}

// MARK: - Legacy Alias

/// Backward compatibility — consumers can still reference AppearanceSettings.shared
/// during migration. Remove this once all references are updated.
@MainActor
enum AppearanceSettings {
    static var shared: ClomeSettings { ClomeSettings.shared }
    static var defaultBackgroundColor: NSColor { ClomeMacColor.windowBackground }
    static var defaultBackgroundOpacity: CGFloat { 0.92 }
}

extension Notification.Name {
    /// Legacy notification name — observers should migrate to .clomeSettingsChanged
    static var appearanceSettingsChanged: Notification.Name { .clomeSettingsChanged }
}
