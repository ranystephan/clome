import AppKit

/// An action that can be performed on a launcher item.
@MainActor
struct LauncherAction {
    let title: String
    let icon: String           // SF Symbol name
    let shortcut: String?      // Display string (e.g. "Enter", "Cmd+Y")
    let handler: () -> Void
}
