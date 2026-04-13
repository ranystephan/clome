import AppKit
import SwiftUI
import ClomeDesign

/// Cached accent — updated whenever settings change.
/// Avoids accessing @MainActor ClomeSettings from inside NSColor(name:nil) closures.
nonisolated(unsafe) private var _cachedDarkAccent: Color = ClomeAccentTheme.graphite.darkAccent
nonisolated(unsafe) private var _cachedLightAccent: Color = ClomeAccentTheme.graphite.lightAccent

@MainActor
enum ClomeMacTheme {
    enum SurfaceRole {
        case window
        case sidebar
        case chrome
        case chromeAlt
        case elevated

        fileprivate var opacityOffset: CGFloat {
            switch self {
            case .window, .sidebar, .chrome:
                0
            case .chromeAlt:
                0.04
            case .elevated:
                0.08
            }
        }

        /// Pick the matching surface color from a resolved palette.
        fileprivate func base(from pal: ClomePalette) -> Color {
            switch self {
            case .window:   pal.windowBackground
            case .sidebar:  pal.sidebarSurface
            case .chrome:   pal.chromeSurface
            case .chromeAlt: pal.chromeSurfaceAlt
            case .elevated: pal.elevated
            }
        }
    }

    static func palette(for appearance: NSAppearance? = nil) -> ClomePalette {
        let resolved = appearance ?? NSApp.effectiveAppearance
        let isDark = resolved.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let accent = ClomeSettings.shared.accentTheme
        return isDark
            ? .dark(accent: accent.darkAccent)
            : .light(accent: accent.lightAccent)
    }

    /// Returns a concrete (non-dynamic) NSColor for the given surface role,
    /// resolved against the specified or current appearance.  Safe to use for
    /// `layer?.backgroundColor` outside drawing contexts.
    static func surfaceColor(
        _ role: SurfaceRole,
        opacity requestedOpacity: CGFloat? = nil,
        appearance: NSAppearance? = nil
    ) -> NSColor {
        let resolvedOpacity = min(1.0, max(0.0, (requestedOpacity ?? ClomeSettings.shared.windowOpacity) + role.opacityOffset))
        let pal = palette(for: appearance)
        return NSColor(role.base(from: pal)).withAlphaComponent(resolvedOpacity)
    }

    static func windowTint(opacity requestedOpacity: CGFloat, appearance: NSAppearance? = nil) -> NSColor {
        surfaceColor(.window, opacity: requestedOpacity, appearance: appearance)
    }

    static func windowMaterial(for appearance: NSAppearance? = nil) -> NSVisualEffectView.Material {
        // When the user reduces opacity, use .hudWindow for a lighter, more
        // glass-like blur that lets the desktop show through clearly.
        // At full opacity, use the standard heavy materials.
        if ClomeSettings.shared.windowOpacity < 0.98 {
            return .hudWindow
        }
        let palette = palette(for: appearance)
        return palette.isDark ? .windowBackground : .contentBackground
    }

    /// Apply the user's selected theme to NSApp.appearance and update cached accent.
    /// Call on launch and whenever themeMode or accentTheme changes.
    static func applyTheme() {
        let settings = ClomeSettings.shared
        switch settings.themeMode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        // Update cached accent for dynamic color closures
        _cachedDarkAccent = settings.accentTheme.darkAccent
        _cachedLightAccent = settings.accentTheme.lightAccent
    }
}

@MainActor
enum ClomeMacColor {
    static let windowBackground = dynamic { $0.windowBackground }
    static let sidebarSurface = dynamic { $0.sidebarSurface }
    static let chromeSurface = dynamic { $0.chromeSurface }
    static let chromeSurfaceAlt = dynamic { $0.chromeSurfaceAlt }
    static let elevatedSurface = dynamic { $0.elevated }
    static let buttonSurface = dynamic { palette in
        palette.isDark ? ClomeColor.surfaceHighest.opacity(0.38) : Color.white.opacity(0.80)
    }
    static let buttonSurfaceHover = dynamic { palette in
        palette.isDark ? ClomeColor.surfaceHighest.opacity(0.60) : Color.white.opacity(0.96)
    }
    static let buttonSurfacePressed = dynamic { palette in
        palette.isDark ? ClomeColor.surfaceHighest.opacity(0.82) : ClomeColor.paperWarm
    }
    static let hoverFill = dynamic { palette in
        palette.isDark ? ClomeColor.borderStrong.opacity(0.18) : ClomeColor.accentSoft
    }
    static let currentLineFill = dynamic { palette in
        palette.isDark ? ClomeColor.textPrimary.opacity(0.03) : ClomeColor.ink.opacity(0.035)
    }
    static let inputBackground = dynamic { palette in
        palette.isDark ? ClomeColor.surfaceHighest.opacity(0.72) : Color.white.opacity(0.92)
    }
    static let border = dynamic { $0.dark }
    static let borderStrong = dynamic { palette in
        palette.isDark ? ClomeColor.borderStrong : ClomeColor.ruleStrong
    }
    static let textPrimary = dynamic { $0.bright }
    static let textSecondary = dynamic { $0.text }
    static let textTertiary = dynamic { $0.dim }
    static let accent = dynamic { $0.accent }
    static let info = dynamic { palette in
        ClomeColor.info(dark: palette.isDark)
    }
    static let infoWash = dynamic { palette in
        ClomeColor.info(dark: palette.isDark).opacity(palette.isDark ? 0.18 : 0.10)
    }
    static let success = dynamic { $0.green }
    static let warning = dynamic { $0.yellow }
    static let error = dynamic { $0.red }
    static let diffContextText = dynamic { palette in
        palette.isDark ? ClomeColor.textSecondary : ClomeColor.inkSecondary
    }
    static let diffAdditionText = dynamic { palette in
        palette.isDark ? ClomeColor.success(dark: true) : Color(red: 0.149, green: 0.431, blue: 0.306)
    }
    static let diffDeletionText = dynamic { palette in
        palette.isDark ? ClomeColor.error(dark: true) : Color(red: 0.624, green: 0.235, blue: 0.227)
    }
    static let diffAdditionBackground = dynamic { palette in
        palette.isDark
            ? ClomeColor.success(dark: true).opacity(0.16)
            : ClomeColor.success(dark: false).opacity(0.12)
    }
    static let diffDeletionBackground = dynamic { palette in
        palette.isDark
            ? ClomeColor.error(dark: true).opacity(0.16)
            : ClomeColor.error(dark: false).opacity(0.12)
    }

    /// Creates a dynamic NSColor that resolves based on current appearance.
    /// Uses cached accent to avoid @MainActor access from the color closure.
    private static func dynamic(_ transform: @escaping (ClomePalette) -> Color) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let palette = isDark
                ? ClomePalette.dark(accent: _cachedDarkAccent)
                : ClomePalette.light(accent: _cachedLightAccent)
            return NSColor(transform(palette))
        }
    }
}

enum ClomeMacMetric {
    static let windowRadius = ClomeCornerRadius.window
    static let panelRadius = ClomeCornerRadius.card
    static let compactRadius = ClomeCornerRadius.button
    static let sidebarWidth: CGFloat = 248
    static let contentInset: CGFloat = 14
    static let sectionGap = ClomeSpacing.sectionGap
    static let cardPadding = ClomeSpacing.cardPadding
    static let toolbarHeight = ClomeSpacing.toolbarHeight
}

@MainActor
enum ClomeMacFont {
    static let title = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let body = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let bodyMedium = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let caption = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let captionMedium = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let micro = NSFont.systemFont(ofSize: 10, weight: .medium)
    static let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    static let sectionLabel = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
}
