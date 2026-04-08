import AppKit

/// Minimal sidebar header. Holds the sidebar toggle button on the left.
///
/// We deliberately do **not** show the active workspace name here: the user can
/// already see which workspace they are in (active row in the workspace list,
/// titlebar, ⌘1–9 indicators). Repeating it would be redundant chrome.
@MainActor
class WorkspaceSwitcherView: NSView {
    private let workspaceManager: WorkspaceManager
    private let sidebarBtn = NSButton()

    var onToggleSidebar: (() -> Void)?

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        // Slim header — just enough to host the toggle button.
        heightAnchor.constraint(equalToConstant: 40).isActive = true

        sidebarBtn.translatesAutoresizingMaskIntoConstraints = false
        sidebarBtn.bezelStyle = .texturedRounded
        sidebarBtn.isBordered = false
        sidebarBtn.title = ""
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        sidebarBtn.image = NSImage(systemSymbolName: "sidebar.left",
                                    accessibilityDescription: "Toggle Sidebar")?
            .withSymbolConfiguration(cfg)
        sidebarBtn.contentTintColor = ClomeMacColor.textSecondary
        sidebarBtn.wantsLayer = true
        sidebarBtn.layer?.cornerRadius = ClomeMacMetric.compactRadius
        sidebarBtn.layer?.cornerCurve = .continuous
        sidebarBtn.target = self
        sidebarBtn.action = #selector(sidebarToggleTapped)
        sidebarBtn.toolTip = "Toggle Sidebar"
        addSubview(sidebarBtn)

        NSLayoutConstraint.activate([
            // Pinned to the trailing edge so it never collides with the macOS
            // traffic-light buttons that sit at the top-left of the window.
            sidebarBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            sidebarBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            sidebarBtn.widthAnchor.constraint(equalToConstant: 28),
            sidebarBtn.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    /// Kept for source-compatibility with callers; nothing to refresh now that
    /// the active workspace name is no longer displayed here.
    func update() {}

    @objc private func sidebarToggleTapped() {
        onToggleSidebar?()
    }
}
