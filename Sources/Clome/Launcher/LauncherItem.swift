import AppKit

/// A single result item in the launcher.
@MainActor
struct LauncherItem: Identifiable {
    let id: String
    let icon: String          // SF Symbol name
    let iconColor: NSColor?   // Optional tint for the icon
    let title: String
    let subtitle: String?
    let metadata: String?     // Right-aligned secondary text (e.g. "2h ago")
    let provider: String      // Which provider created this item
    let payload: AnyObject?   // Provider-specific data (workspace, terminal, etc.)
    let priority: Int         // Higher = appears first (attention items get 1000+)

    init(
        id: String,
        icon: String,
        iconColor: NSColor? = nil,
        title: String,
        subtitle: String? = nil,
        metadata: String? = nil,
        provider: String,
        payload: AnyObject? = nil,
        priority: Int = 0
    ) {
        self.id = id
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.metadata = metadata
        self.provider = provider
        self.payload = payload
        self.priority = priority
    }
}
