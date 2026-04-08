import AppKit

/// Side effects for starting a block. Opens attachments and — where
/// possible — switches Clome context to the block's bound workspace.
enum BlockRunner {

    @MainActor
    static func fireStartSideEffects(for block: Block) {
        for att in block.attachments {
            switch att {
            case .file(let path), .image(let path):
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            case .url(let url):
                NSWorkspace.shared.open(url)
            case .workspace(let idString, _):
                switchWorkspace(idString: idString)
            default:
                break
            }
        }
    }

    // MARK: - Workspace switching

    /// Posts a notification that the app shell listens for to switch
    /// workspaces. Wiring the shell-side listener lands in a later
    /// milestone; for now the notification is a no-op sink.
    @MainActor
    private static func switchWorkspace(idString: String) {
        NotificationCenter.default.post(
            name: .blockRunnerSwitchWorkspace,
            object: nil,
            userInfo: ["workspaceID": idString]
        )
    }
}

extension Notification.Name {
    static let blockRunnerSwitchWorkspace = Notification.Name("BlockRunner.switchWorkspace")
}
