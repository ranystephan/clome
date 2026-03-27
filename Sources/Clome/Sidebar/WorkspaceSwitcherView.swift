import AppKit

/// Compact workspace selector at the top of the sidebar.
/// Shows sidebar toggle + current workspace name with color dot.
/// Click workspace name to show picker dropdown.
@MainActor
class WorkspaceSwitcherView: NSView, NSGestureRecognizerDelegate {
    private let workspaceManager: WorkspaceManager
    private let colorDot = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private var sidebarBtn: NSButton!

    var onToggleSidebar: (() -> Void)?

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setupUI()
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        heightAnchor.constraint(equalToConstant: 40).isActive = true

        // Sidebar toggle
        sidebarBtn = NSButton()
        sidebarBtn.translatesAutoresizingMaskIntoConstraints = false
        sidebarBtn.bezelStyle = .texturedRounded
        sidebarBtn.isBordered = false
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        sidebarBtn.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar")?.withSymbolConfiguration(cfg)
        sidebarBtn.contentTintColor = NSColor(white: 0.50, alpha: 1.0)
        sidebarBtn.target = self
        sidebarBtn.action = #selector(sidebarToggleTapped)
        addSubview(sidebarBtn)

        // Color dot
        colorDot.translatesAutoresizingMaskIntoConstraints = false
        colorDot.wantsLayer = true
        colorDot.layer?.cornerRadius = 4
        addSubview(colorDot)

        // Name label (clickable)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = NSColor(white: 0.80, alpha: 1.0)
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            sidebarBtn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 76),
            sidebarBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            sidebarBtn.widthAnchor.constraint(equalToConstant: 24),
            sidebarBtn.heightAnchor.constraint(equalToConstant: 24),

            colorDot.leadingAnchor.constraint(equalTo: sidebarBtn.trailingAnchor, constant: 8),
            colorDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            colorDot.widthAnchor.constraint(equalToConstant: 8),
            colorDot.heightAnchor.constraint(equalToConstant: 8),

            nameLabel.leadingAnchor.constraint(equalTo: colorDot.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])

        // Click on workspace name to show picker
        let click = NSClickGestureRecognizer(target: self, action: #selector(switcherClicked))
        click.delegate = self
        addGestureRecognizer(click)
    }

    func update() {
        guard let workspace = workspaceManager.activeWorkspace else { return }
        nameLabel.stringValue = workspace.name
        colorDot.layer?.backgroundColor = workspace.color.nsColor.cgColor
    }

    @objc private func sidebarToggleTapped() {
        onToggleSidebar?()
    }

    // MARK: - NSGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        // Don't let the gesture recognizer intercept clicks on the sidebar button
        let loc = event.locationInWindow
        let btnLoc = sidebarBtn.convert(loc, from: nil)
        return !sidebarBtn.bounds.contains(btnLoc)
    }

    @objc private func switcherClicked(_ gesture: NSGestureRecognizer) {
        showWorkspacePicker()
    }

    private func showWorkspacePicker() {
        let menu = NSMenu()

        for (i, workspace) in workspaceManager.workspaces.enumerated() {
            let item = NSMenuItem()
            item.title = workspace.name
            item.tag = i
            item.target = self
            item.action = #selector(workspaceSelected(_:))
            if i == workspaceManager.activeWorkspaceIndex {
                item.state = .on
            }
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let newWs = NSMenuItem(title: "New Workspace", action: #selector(newWorkspace), keyEquivalent: "")
        newWs.target = self
        menu.addItem(newWs)

        let point = NSPoint(x: colorDot.frame.minX, y: bounds.minY)
        menu.popUp(positioning: nil, at: point, in: self)
    }

    @objc private func workspaceSelected(_ sender: NSMenuItem) {
        workspaceManager.switchTo(index: sender.tag)
        update()
    }

    @objc private func newWorkspace() {
        workspaceManager.addWorkspace()
        update()
    }
}
