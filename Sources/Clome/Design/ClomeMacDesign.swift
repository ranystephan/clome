import AppKit
import SwiftUI
import ClomeDesign

@MainActor
enum ClomeMacTheme {
    static func palette(for appearance: NSAppearance? = nil) -> ClomePalette {
        let resolved = appearance ?? NSApp.effectiveAppearance
        let isDark = resolved.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? .dark() : .light()
    }
}

@MainActor
enum ClomeMacColor {
    static let windowBackground = dynamic { $0.bg }
    static let sidebarSurface = dynamic { $0.bg }
    static let chromeSurface = dynamic { $0.surface }
    static let chromeSurfaceAlt = dynamic { $0.surfaceAlt }
    static let elevatedSurface = dynamic { palette in
        palette.isDark ? ClomeColor.surfaceElevated : ClomeColor.lightSurfaceAlt
    }
    static let border = dynamic { $0.dark }
    static let borderStrong = dynamic { palette in
        palette.isDark ? ClomeColor.borderStrong : ClomeColor.lightTextTertiary.opacity(0.2)
    }
    static let textPrimary = dynamic { $0.bright }
    static let textSecondary = dynamic { $0.text }
    static let textTertiary = dynamic { $0.dim }
    static let accent = dynamic { $0.accent }
    static let success = dynamic { $0.green }
    static let warning = dynamic { $0.yellow }
    static let error = dynamic { $0.red }

    private static func dynamic(_ transform: @escaping (ClomePalette) -> Color) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(transform(ClomeMacTheme.palette(for: appearance)))
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
