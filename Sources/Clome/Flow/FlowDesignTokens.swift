import SwiftUI

// MARK: - Flow Design Tokens

/// Centralized design constants for all Flow panel views.
/// Usage: `FlowTokens.bg0`, `FlowTokens.textPrimary`, etc.
enum FlowTokens {

    // MARK: - Backgrounds

    /// Base background (#0E0E12)
    static let bg0 = Color(red: 0.055, green: 0.055, blue: 0.071)
    /// Subtle surface (headers, input fields)
    static let bg1 = Color.white.opacity(0.03)
    /// Cards, elevated surfaces
    static let bg2 = Color.white.opacity(0.05)
    /// Active/hover states, code blocks
    static let bg3 = Color.white.opacity(0.08)

    // MARK: - Text

    static let textPrimary = Color.white.opacity(0.90)
    static let textSecondary = Color.white.opacity(0.70)
    static let textTertiary = Color.white.opacity(0.40)
    static let textHint = Color.white.opacity(0.30)
    static let textMuted = Color.white.opacity(0.20)
    static let textDisabled = Color.white.opacity(0.15)

    // MARK: - Accent

    static let accent = Color(red: 0.38, green: 0.56, blue: 1.0)
    static let accentSubtle = Color(red: 0.38, green: 0.56, blue: 1.0).opacity(0.12)

    // MARK: - Semantic

    static let success = Color(red: 0.3, green: 0.75, blue: 0.4)
    static let error = Color(red: 0.9, green: 0.4, blue: 0.4)
    static let warning = Color(red: 0.9, green: 0.75, blue: 0.3)

    // MARK: - Priority

    static let priorityHigh = Color(red: 0.9, green: 0.4, blue: 0.4)
    static let priorityMedium = Color(red: 0.9, green: 0.75, blue: 0.3)
    static let priorityLow = Color(red: 0.4, green: 0.6, blue: 0.9)

    // MARK: - Urgency

    static let urgencyOverdue = Color(red: 0.9, green: 0.3, blue: 0.3)
    static let urgencyCritical = Color(red: 0.9, green: 0.6, blue: 0.2)
    static let urgencyWarning = Color(red: 0.9, green: 0.75, blue: 0.3)
    static let urgencyNormal = Color(red: 0.4, green: 0.6, blue: 0.9)

    // MARK: - Borders

    static let border = Color.white.opacity(0.06)
    static let borderFocused = Color.white.opacity(0.10)

    // MARK: - Spacing

    static let spacingXS: CGFloat = 2
    static let spacingSM: CGFloat = 4
    static let spacingMD: CGFloat = 8
    static let spacingLG: CGFloat = 12
    static let spacingXL: CGFloat = 16

    // MARK: - Corner Radii

    static let radiusSmall: CGFloat = 4
    static let radiusMedium: CGFloat = 6
    static let radiusLarge: CGFloat = 8

    // MARK: - Sizing

    static let modeBarHeight: CGFloat = 32
    static let contextBarHeight: CGFloat = 18
    static let rowHeight: CGFloat = 28
    static let inputHeight: CGFloat = 32
    static let iconSize: CGFloat = 13

    // MARK: - Calendar Item Types

    static let calendarTodo = Color(red: 0.4, green: 0.75, blue: 0.5)
    static let calendarDeadline = Color(red: 0.9, green: 0.5, blue: 0.3)
    static let calendarReminder = Color(red: 0.7, green: 0.5, blue: 0.9)
    static let hourGridLine = Color.white.opacity(0.04)
    static let hourGridLineAccent = Color.white.opacity(0.08)

    // MARK: - Calendar Layout

    static let dayHourHeight: CGFloat = 28
    static let weekHourHeight: CGFloat = 14
    static let gutterWidth: CGFloat = 36
    static let weekGutterWidth: CGFloat = 30

    // MARK: - Category Colors

    static func categoryColor(_ category: String) -> Color {
        switch category {
        case "idea": return .yellow.opacity(0.7)
        case "task": return accent.opacity(0.7)
        case "reminder": return .orange.opacity(0.7)
        case "goal": return success.opacity(0.8)
        case "journal": return .purple.opacity(0.7)
        case "reference": return .gray.opacity(0.7)
        default: return textHint
        }
    }
}

// MARK: - Animation Tokens

extension Animation {
    /// Standard spring for interactive elements (expand/collapse, reorder)
    static let flowSpring = Animation.spring(response: 0.3, dampingFraction: 0.8)

    /// Quick state change (tab switch, hover)
    static let flowQuick = Animation.easeInOut(duration: 0.15)

    /// Smooth content transition
    static let flowSmooth = Animation.easeInOut(duration: 0.2)
}

// MARK: - View Modifiers

extension View {
    /// Standard Flow card styling
    func flowCard(isSelected: Bool = false) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: FlowTokens.radiusMedium, style: .continuous)
                    .fill(isSelected ? FlowTokens.bg3 : FlowTokens.bg2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FlowTokens.radiusMedium, style: .continuous)
                    .stroke(isSelected ? FlowTokens.borderFocused : FlowTokens.border, lineWidth: 0.5)
            )
    }

    /// Standard Flow section header styling
    func flowSectionHeader() -> some View {
        self
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(FlowTokens.textMuted)
            .tracking(1.5)
    }

    /// Standard header bar styling
    func flowHeaderBar() -> some View {
        self
            .padding(.horizontal, 10)
            .padding(.vertical, FlowTokens.spacingSM)
            .background(FlowTokens.bg1)
    }
}
