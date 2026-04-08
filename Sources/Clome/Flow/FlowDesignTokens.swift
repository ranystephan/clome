import SwiftUI
import ClomeDesign

// MARK: - Flow Design Tokens
//
// Dark-mode design system for the Clome macOS Flow tab.
// Aligned with the ClomeFlow iOS app (PreefloColorSystem) so the two
// surfaces feel like the same product. Values are deliberately literal
// (not derived from ClomeColor) so the Flow tab can evolve independently
// of the rest of the Clome chrome.
//
// Usage: `FlowTokens.bg0`, `FlowTokens.textPrimary`, `.flowFont(.title2)`, etc.

enum FlowTokens {

    // MARK: - Backgrounds (Warm Neutral Dark Scale)

    /// App / panel base — warm950
    static let bg0 = Color(red: 0.059, green: 0.067, blue: 0.090)
    /// Section surface — warm900
    static let bg1 = Color(red: 0.102, green: 0.114, blue: 0.153)
    /// Card surface — warm850
    static let bg2 = Color(red: 0.142, green: 0.157, blue: 0.200)
    /// Elevated / hover / active — warm800
    static let bg3 = Color(red: 0.176, green: 0.192, blue: 0.235)
    /// Hairline / divider — warm700 @ low alpha
    static let bg4 = Color(red: 0.239, green: 0.255, blue: 0.333)

    // MARK: - Text

    static let textPrimary   = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.66)
    static let textTertiary  = Color.white.opacity(0.42)
    static let textHint      = Color.white.opacity(0.32)
    static let textMuted     = Color.white.opacity(0.24)
    static let textDisabled  = Color.white.opacity(0.16)

    // MARK: - Accent (Signal Teal)

    /// Primary accent — coral500
    static let accent        = Color(red: 0.247, green: 0.667, blue: 0.616)
    /// Hover / secondary — coral400
    static let accentHover   = Color(red: 0.365, green: 0.741, blue: 0.690)
    /// Pressed — coral600
    static let accentPressed = Color(red: 0.165, green: 0.580, blue: 0.529)
    /// Soft tint background
    static let accentSubtle  = Color(red: 0.247, green: 0.667, blue: 0.616).opacity(0.16)
    static let accentWash    = Color(red: 0.247, green: 0.667, blue: 0.616).opacity(0.08)

    // MARK: - Editorial (SAI-inspired highlights)

    /// "NOW" indicator, progress bars, urgent
    static let editorialRed    = Color(red: 0.831, green: 0.220, blue: 0.173)
    /// "You Have a Meeting" hero card
    static let editorialYellow = Color(red: 0.961, green: 0.835, blue: 0.278)
    /// Dark chip / dock background
    static let editorialDark   = Color(red: 0.106, green: 0.114, blue: 0.145)
    /// Hairline separator on light surfaces
    static let editorialSep    = Color(red: 0.850, green: 0.830, blue: 0.800)
    /// Gold for rewards / XP
    static let gold            = Color(red: 0.914, green: 0.769, blue: 0.416)

    // MARK: - Semantic

    static let success = Color(red: 0.322, green: 0.729, blue: 0.588)
    static let warning = Color(red: 0.922, green: 0.722, blue: 0.420)
    static let error   = Color(red: 0.902, green: 0.490, blue: 0.490)
    static let info    = Color(red: 0.490, green: 0.678, blue: 0.882)

    // MARK: - Priority

    static let priorityHigh   = Color(red: 0.902, green: 0.490, blue: 0.490)
    static let priorityMedium = Color(red: 0.922, green: 0.722, blue: 0.420)
    static let priorityLow    = Color(red: 0.490, green: 0.678, blue: 0.882)

    // MARK: - Urgency

    static let urgencyOverdue  = editorialRed
    static let urgencyCritical = Color(red: 0.961, green: 0.553, blue: 0.243)
    static let urgencyWarning  = warning
    static let urgencyNormal   = info

    // MARK: - Borders

    static let border         = Color.white.opacity(0.06)
    static let borderStrong   = Color.white.opacity(0.10)
    static let borderFocused  = accent.opacity(0.55)

    // MARK: - Spacing (8pt base)

    static let spacingXS:  CGFloat = 4
    static let spacingSM:  CGFloat = 8
    static let spacingMD:  CGFloat = 12
    static let spacingLG:  CGFloat = 16
    static let spacingXL:  CGFloat = 20
    static let spacingXXL: CGFloat = 24
    static let spacingXXXL: CGFloat = 32

    // MARK: - Corner Radii

    static let radiusXS:     CGFloat = 6
    static let radiusSmall:  CGFloat = 8
    static let radiusMedium: CGFloat = 12
    static let radiusLarge:  CGFloat = 14
    static let radiusXL:     CGFloat = 16
    static let radiusPill:   CGFloat = 999

    /// Semantic aliases — prefer these in new code.
    static let radiusControl: CGFloat = 6   // small chips, event cards, pills
    static let radiusButton:  CGFloat = 8   // toolbar buttons, segmented items
    static let radiusCard:    CGFloat = 12  // cards, sections
    static let radiusSheet:   CGFloat = 16  // hero cards, popovers

    // MARK: - Strokes & Accent Bars

    static let hairline:        CGFloat = 0.5
    static let hairlineStrong:  CGFloat = 1.0
    static let accentBarWidth:  CGFloat = 2

    // MARK: - Event / Tint Fills

    static let eventFillActive:  Double = 0.22
    static let eventFillSubtle:  Double = 0.16
    static let eventFillPast:    Double = 0.10
    static let eventStrokeAlpha: Double = 0.55

    // MARK: - Fixed widths

    static let sidebarWidth:  CGFloat = 280
    static let popoverWidth:  CGFloat = 260

    // MARK: - Sizing

    static let modeBarHeight: CGFloat = 52
    static let contextBarHeight: CGFloat = 28
    static let rowHeight: CGFloat = 40
    static let inputHeight: CGFloat = 40
    static let iconSize: CGFloat = 14

    // MARK: - Calendar Item Type Colors

    static let calendarEvent    = accent
    static let calendarTodo     = Color(red: 0.490, green: 0.741, blue: 0.557)
    static let calendarDeadline = editorialRed
    static let calendarReminder = Color(red: 0.706, green: 0.541, blue: 0.918)
    static let hourGridLine       = Color.white.opacity(0.04)
    static let hourGridLineAccent = Color.white.opacity(0.08)

    // MARK: - Calendar Layout

    static let dayHourHeight:  CGFloat = 44
    static let weekHourHeight: CGFloat = 22
    static let gutterWidth:    CGFloat = 56
    static let weekGutterWidth: CGFloat = 44

    // MARK: - Category Colors

    static func categoryColor(_ category: String) -> Color {
        switch category.lowercased() {
        case "idea":      return Color(red: 0.820, green: 0.680, blue: 0.310)
        case "task":      return Color(red: 0.320, green: 0.490, blue: 0.700)
        case "reminder":  return Color(red: 0.800, green: 0.530, blue: 0.250)
        case "goal":      return Color(red: 0.240, green: 0.580, blue: 0.420)
        case "journal":   return Color(red: 0.500, green: 0.410, blue: 0.660)
        case "reference": return Color(red: 0.220, green: 0.560, blue: 0.560)
        case "meeting":   return Color(red: 0.145, green: 0.555, blue: 0.540)
        case "work":      return Color(red: 0.290, green: 0.410, blue: 0.590)
        case "study":     return Color(red: 0.235, green: 0.450, blue: 0.720)
        case "exercise":  return Color(red: 0.180, green: 0.560, blue: 0.380)
        case "sleep":     return Color(red: 0.420, green: 0.380, blue: 0.700)
        case "meal":      return Color(red: 0.760, green: 0.500, blue: 0.190)
        default:          return textHint
        }
    }
}

// MARK: - Typography Tokens (mirrors ClomeFlow iOS)

enum FlowFont {
    case displayLarge, displayMedium
    case title1, title2, title3
    case body, bodyMedium, bodyBold
    case callout, caption, micro
    case timeDisplay, timestamp, sectionLabel
    case greetingLight, greetingBold, dateMuted

    var size: CGFloat {
        switch self {
        case .displayLarge:  return 40
        case .displayMedium: return 32
        case .title1:        return 22
        case .title2:        return 18
        case .title3:        return 15
        case .body, .bodyMedium, .bodyBold: return 13
        case .callout:       return 12
        case .caption:       return 11
        case .micro:         return 9
        case .timeDisplay:   return 14
        case .timestamp:     return 10
        case .sectionLabel:  return 10
        case .greetingLight, .greetingBold: return 26
        case .dateMuted:     return 12
        }
    }

    var weight: Font.Weight {
        switch self {
        case .displayLarge, .displayMedium, .bodyBold, .greetingBold: return .bold
        case .title1, .title2: return .semibold
        case .title3, .bodyMedium, .callout, .micro, .timeDisplay, .timestamp: return .medium
        case .sectionLabel: return .bold
        case .greetingLight: return .light
        default: return .regular
        }
    }

    var design: Font.Design {
        switch self {
        case .timeDisplay, .timestamp, .sectionLabel: return .monospaced
        default: return .default
        }
    }

    var tracking: CGFloat {
        switch self {
        case .displayLarge:  return -0.5
        case .displayMedium: return -0.3
        case .title1:        return -0.2
        case .title2:        return -0.1
        case .callout:       return 0.1
        case .caption:       return 0.2
        case .micro:         return 0.5
        case .timeDisplay:   return 0.8
        case .timestamp:     return 0.6
        case .sectionLabel:  return 2.0
        case .greetingLight, .greetingBold: return -0.56
        case .dateMuted:     return 0.1
        default: return 0
        }
    }
}

extension View {
    func flowFont(_ token: FlowFont) -> some View {
        self.font(.system(size: token.size, weight: token.weight, design: token.design))
            .tracking(token.tracking)
    }
}

// MARK: - Animation Tokens

extension Animation {
    static let flowSpring = Animation.spring(response: 0.32, dampingFraction: 0.84)
    static let flowQuick  = Animation.easeInOut(duration: 0.18)
    static let flowSmooth = Animation.easeInOut(duration: 0.24)
    static let flowBounce = Animation.spring(response: 0.42, dampingFraction: 0.72)
}

// MARK: - View Modifiers

extension View {
    /// Standard Flow card: warm850 fill, hairline border, 12pt radius.
    func flowCard(isSelected: Bool = false, radius: CGFloat = FlowTokens.radiusMedium) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(isSelected ? FlowTokens.bg3 : FlowTokens.bg2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(isSelected ? FlowTokens.borderFocused : FlowTokens.border, lineWidth: 0.5)
            )
    }

    /// Editorial section header — small, mono, tracked, muted.
    func flowSectionHeader() -> some View {
        self
            .flowFont(.sectionLabel)
            .foregroundColor(FlowTokens.textTertiary)
    }

    /// Standard top-bar background.
    func flowHeaderBar() -> some View {
        self
            .padding(.horizontal, FlowTokens.spacingLG)
            .padding(.vertical, FlowTokens.spacingMD)
            .background(FlowTokens.bg0)
            .overlay(alignment: .bottom) {
                Rectangle().fill(FlowTokens.border).frame(height: FlowTokens.hairline)
            }
    }

    /// Toolbar button / chip chrome — hoverable, 8pt radius, hairline border.
    func flowControl(isActive: Bool = false,
                     isHovered: Bool = false,
                     radius: CGFloat = FlowTokens.radiusButton) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(isActive ? FlowTokens.bg3 : (isHovered ? FlowTokens.bg2 : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(isActive ? FlowTokens.borderStrong : FlowTokens.border,
                                  lineWidth: FlowTokens.hairline)
            )
    }

    /// Text input styling — bg1 fill, hairline border, focus ring.
    func flowInput(isFocused: Bool = false) -> some View {
        self
            .padding(.horizontal, FlowTokens.spacingMD)
            .padding(.vertical, FlowTokens.spacingSM + 2)
            .background(
                RoundedRectangle(cornerRadius: FlowTokens.radiusButton, style: .continuous)
                    .fill(FlowTokens.bg1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FlowTokens.radiusButton, style: .continuous)
                    .strokeBorder(isFocused ? FlowTokens.borderFocused : FlowTokens.border,
                                  lineWidth: FlowTokens.hairline)
            )
    }
}

// MARK: - Event Card Styling

enum FlowEventState {
    case upcoming, now, past
}

extension View {
    /// Calendar event card — consistent fill/stroke driven by tint color and state.
    func flowEventCard(tint: Color, state: FlowEventState) -> some View {
        let fillAlpha: Double = {
            switch state {
            case .upcoming: return FlowTokens.eventFillActive
            case .now:      return FlowTokens.eventFillActive
            case .past:     return FlowTokens.eventFillPast
            }
        }()
        let strokeWidth: CGFloat = state == .now ? FlowTokens.hairlineStrong : FlowTokens.hairline
        return self
            .background(
                RoundedRectangle(cornerRadius: FlowTokens.radiusControl, style: .continuous)
                    .fill(tint.opacity(fillAlpha))
            )
            .overlay(
                RoundedRectangle(cornerRadius: FlowTokens.radiusControl, style: .continuous)
                    .strokeBorder(tint.opacity(FlowTokens.eventStrokeAlpha), lineWidth: strokeWidth)
            )
    }
}
