import AppKit

/// Protocol for data sources that feed items into the launcher.
@MainActor
protocol LauncherProvider {
    /// Section title displayed above this provider's results.
    var sectionTitle: String { get }

    /// SF Symbol icon for the section header.
    var sectionIcon: String { get }

    /// Search for items matching the query. Empty query returns top/recent items.
    func search(query: String) -> [LauncherItem]

    /// Return available actions for a given item from this provider.
    func actions(for item: LauncherItem) -> [LauncherAction]
}
