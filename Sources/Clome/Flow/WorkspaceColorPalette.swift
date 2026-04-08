import SwiftUI
import ClomeModels

// MARK: - Workspace Color Palette (Mac)
//
// Maps the cross-platform `WorkspaceColorKey` enum (defined in
// ClomeEcosystemKit) into Mac-flavored Color values that live in the same
// editorial vocabulary as FlowTokens.
//
// Each color has three roles:
//   - `tint`: the saturated brand color used for the chip strip and the
//     workspace icon background.
//   - `wash`: a low-opacity tint used for hover states and the header strip.
//   - `text`: the on-tint label color (white for dark tints, near-black for
//     amber/gold).

extension WorkspaceColorKey {

    var tint: Color {
        switch self {
        case .teal:     return Color(red: 0.247, green: 0.667, blue: 0.616)
        case .coral:    return Color(red: 0.831, green: 0.420, blue: 0.355)
        case .indigo:   return Color(red: 0.380, green: 0.450, blue: 0.820)
        case .sage:     return Color(red: 0.498, green: 0.680, blue: 0.510)
        case .amber:    return Color(red: 0.961, green: 0.760, blue: 0.318)
        case .rose:     return Color(red: 0.880, green: 0.450, blue: 0.580)
        case .graphite: return Color(red: 0.580, green: 0.600, blue: 0.660)
        }
    }

    var wash: Color {
        tint.opacity(0.18)
    }

    var onTintTextColor: Color {
        switch self {
        case .amber: return Color(red: 0.106, green: 0.114, blue: 0.145)
        default:     return .white
        }
    }

    var displayName: String {
        switch self {
        case .teal:     return "Teal"
        case .coral:    return "Coral"
        case .indigo:   return "Indigo"
        case .sage:     return "Sage"
        case .amber:    return "Amber"
        case .rose:     return "Rose"
        case .graphite: return "Graphite"
        }
    }
}
