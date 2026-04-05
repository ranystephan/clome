import AppKit
import SwiftUI

/// The Flow panel embeds Clome Flow productivity features (todos, calendar, chat, deadlines)
/// inside the Clome dev environment as a workspace tab.
@MainActor
class FlowPanel: NSView {

    /// Project directory context from the workspace (used to scope todos/deadlines).
    var projectContext: String? {
        didSet { rebuildHostView() }
    }

    /// Workspace ID for scoping conversations.
    var workspaceID: UUID? {
        didSet { rebuildHostView() }
    }

    var title: String = "Flow"

    private var hostView: NSHostingView<FlowPanelHostView>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.055, green: 0.055, blue: 0.071, alpha: 1.0).cgColor

        let host = NSHostingView(rootView: FlowPanelHostView(projectContext: projectContext, workspaceID: workspaceID))
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        hostView = host

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceChanged),
            name: .appearanceSettingsChanged,
            object: nil
        )
    }

    private func rebuildHostView() {
        hostView?.rootView = FlowPanelHostView(projectContext: projectContext, workspaceID: workspaceID)
    }

    @objc private func appearanceChanged() {
        layer?.backgroundColor = NSColor(red: 0.055, green: 0.055, blue: 0.071, alpha: 1.0).cgColor
    }
}
