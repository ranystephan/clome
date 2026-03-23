import AppKit

/// Welcome screen shown when no project roots are open.
/// Provides folder drop zone, "Open Folder" button, and recent projects list.
@MainActor
class WelcomeView: NSView {

    /// Called when user selects a folder (via button, drop, or recent project click).
    var onOpenFolder: ((String) -> Void)?

    private let containerStack = NSStackView()
    private var recentProjectsStack: NSStackView?

    override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        wantsLayer = true
        setupUI()
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        // Center container
        containerStack.orientation = .vertical
        containerStack.alignment = .centerX
        containerStack.spacing = 24
        containerStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(containerStack)

        NSLayoutConstraint.activate([
            containerStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            containerStack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            containerStack.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])

        // Icon
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let iconCfg = NSImage.SymbolConfiguration(pointSize: 40, weight: .light)
        iconView.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "Open Folder")?.withSymbolConfiguration(iconCfg)
        iconView.contentTintColor = NSColor(white: 0.30, alpha: 1.0)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 56),
            iconView.heightAnchor.constraint(equalToConstant: 56),
        ])
        containerStack.addArrangedSubview(iconView)

        // Title
        let title = NSTextField(labelWithString: "Open a Project Folder")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textColor = NSColor(white: 0.80, alpha: 1.0)
        title.alignment = .center
        containerStack.addArrangedSubview(title)

        // Subtitle
        let subtitle = NSTextField(labelWithString: "Drop a folder here, or click Open Folder")
        subtitle.font = .systemFont(ofSize: 13, weight: .regular)
        subtitle.textColor = NSColor(white: 0.40, alpha: 1.0)
        subtitle.alignment = .center
        containerStack.addArrangedSubview(subtitle)

        // Open Folder button
        let openBtn = WelcomeButton(title: "Open Folder", shortcut: "⌘O")
        openBtn.target = self
        openBtn.action = #selector(openFolderClicked)
        containerStack.addArrangedSubview(openBtn)

        // Spacer
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 8).isActive = true
        containerStack.addArrangedSubview(spacer)

        // Recent projects section
        let recentsStack = NSStackView()
        recentsStack.orientation = .vertical
        recentsStack.alignment = .leading
        recentsStack.spacing = 4
        recentsStack.translatesAutoresizingMaskIntoConstraints = false
        self.recentProjectsStack = recentsStack
        containerStack.addArrangedSubview(recentsStack)

        loadRecentProjects()
    }

    private func loadRecentProjects() {
        guard let stack = recentProjectsStack else { return }
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }

        // Get recent projects from user defaults
        let recentPaths = UserDefaults.standard.stringArray(forKey: "clome.recentProjectPaths") ?? []
        let validPaths = recentPaths.filter { FileManager.default.fileExists(atPath: $0) }

        guard !validPaths.isEmpty else { return }

        // Section header
        let header = NSTextField(labelWithString: "RECENT")
        header.font = .systemFont(ofSize: 10, weight: .semibold)
        header.textColor = NSColor(white: 0.40, alpha: 1.0)
        let headerAttr = NSMutableAttributedString(string: "RECENT", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor(white: 0.40, alpha: 1.0),
            .kern: 1.2,
        ])
        header.attributedStringValue = headerAttr
        stack.addArrangedSubview(header)

        for path in validPaths.prefix(6) {
            let row = RecentProjectRow(path: path)
            row.onClick = { [weak self] in
                self?.onOpenFolder?(path)
            }
            stack.addArrangedSubview(row)
        }
    }

    /// Save a project path to recent projects list.
    static func addRecentProject(_ path: String) {
        var recents = UserDefaults.standard.stringArray(forKey: "clome.recentProjectPaths") ?? []
        recents.removeAll { $0 == path }
        recents.insert(path, at: 0)
        if recents.count > 10 { recents = Array(recents.prefix(10)) }
        UserDefaults.standard.set(recents, forKey: "clome.recentProjectPaths")
    }

    @objc private func openFolderClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project folder"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.onOpenFolder?(url.path)
        }
    }

    // MARK: - Drag and Drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard hasDirectoryURL(sender) else { return [] }
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.4).cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = 12
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        layer?.borderWidth = 0
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        layer?.borderWidth = 0
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        layer?.borderWidth = 0
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL] else { return false }

        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                onOpenFolder?(url.path)
                return true
            }
        }
        return false
    }

    private func hasDirectoryURL(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL] else { return false }

        return urls.contains { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
    }
}

// MARK: - Welcome Button

private class WelcomeButton: NSButton {
    private var isHovered = false

    init(title: String, shortcut: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor

        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor(white: 0.90, alpha: 1.0),
        ]))
        attr.append(NSAttributedString(string: "  \(shortcut)", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor(white: 0.40, alpha: 1.0),
        ]))
        attributedTitle = attr

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 200),
            heightAnchor.constraint(equalToConstant: 44),
        ])

        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.10).cgColor
        CATransaction.commit()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        CATransaction.commit()
    }
}

// MARK: - Recent Project Row

private class RecentProjectRow: NSView {
    var onClick: (() -> Void)?
    private var isHovered = false

    init(path: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        iconView.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        iconView.contentTintColor = NSColor(white: 0.45, alpha: 1.0)
        addSubview(iconView)

        let folderName = (path as NSString).lastPathComponent
        let nameLabel = NSTextField(labelWithString: folderName)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = NSColor(white: 0.80, alpha: 1.0)
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        // Abbreviate the path for display
        let displayPath = abbreviatePath(path)
        let pathLabel = NSTextField(labelWithString: displayPath)
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = .systemFont(ofSize: 11, weight: .regular)
        pathLabel.textColor = NSColor(white: 0.40, alpha: 1.0)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(pathLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            widthAnchor.constraint(equalToConstant: 280),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 100),

            pathLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.04).cgColor
        CATransaction.commit()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        layer?.backgroundColor = NSColor.clear.cgColor
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = isHovered ? NSColor(white: 1.0, alpha: 0.04).cgColor : NSColor.clear.cgColor
        onClick?()
    }
}
