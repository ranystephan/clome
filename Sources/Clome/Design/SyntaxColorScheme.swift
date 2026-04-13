import AppKit

/// Theme-aware syntax highlighting colors for the code editor.
/// Dark mode preserves the existing color scheme; light mode uses the same hues
/// with adjusted luminance for readability on light backgrounds.
@MainActor
struct SyntaxColorScheme {
    let keyword: NSColor
    let string: NSColor
    let comment: NSColor
    let number: NSColor
    let type: NSColor
    let function: NSColor
    let decorator: NSColor

    // MARK: - Dark (original Clome colors)

    static let dark = SyntaxColorScheme(
        keyword:   NSColor(red: 0.78, green: 0.46, blue: 0.83, alpha: 1.0),   // purple
        string:    NSColor(red: 0.87, green: 0.56, blue: 0.40, alpha: 1.0),   // orange
        comment:   NSColor(white: 0.45, alpha: 1.0),                            // gray
        number:    NSColor(red: 0.82, green: 0.77, blue: 0.50, alpha: 1.0),   // yellow
        type:      NSColor(red: 0.47, green: 0.75, blue: 0.87, alpha: 1.0),   // cyan
        function:  NSColor(red: 0.40, green: 0.73, blue: 0.42, alpha: 1.0),   // green
        decorator: NSColor(red: 0.82, green: 0.77, blue: 0.50, alpha: 1.0)    // yellow
    )

    // MARK: - Light (same hues, darkened for light backgrounds)

    static let light = SyntaxColorScheme(
        keyword:   NSColor(red: 0.56, green: 0.22, blue: 0.62, alpha: 1.0),   // deep purple
        string:    NSColor(red: 0.76, green: 0.36, blue: 0.18, alpha: 1.0),   // burnt orange
        comment:   NSColor(white: 0.50, alpha: 1.0),                            // mid gray
        number:    NSColor(red: 0.60, green: 0.54, blue: 0.16, alpha: 1.0),   // dark gold
        type:      NSColor(red: 0.14, green: 0.48, blue: 0.62, alpha: 1.0),   // deep teal
        function:  NSColor(red: 0.18, green: 0.52, blue: 0.20, alpha: 1.0),   // forest green
        decorator: NSColor(red: 0.60, green: 0.54, blue: 0.16, alpha: 1.0)    // dark gold
    )

    // MARK: - Current

    /// Returns the syntax color scheme for the current effective appearance.
    static var current: SyntaxColorScheme {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? .dark : .light
    }
}
