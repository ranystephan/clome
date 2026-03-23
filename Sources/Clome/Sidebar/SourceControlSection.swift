import AppKit

/// Collapsible source control section showing git changed files.
@MainActor
class SourceControlSection: NSView {
    var onFileSelected: ((String) -> Void)?
    private var changedFiles: [(path: String, status: GitFileStatus, relativePath: String)] = []

    private let headerView: SidebarSectionHeader
    private let listStack = NSStackView()
    private let scrollView = NSScrollView()
    private var listHeightConstraint: NSLayoutConstraint?
    private var isExpanded = true

    override init(frame: NSRect = .zero) {
        headerView = SidebarSectionHeader(title: "Source Control")
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        addSubview(headerView)

        headerView.onToggle = { [weak self] expanded in
            self?.setExpanded(expanded)
        }

        // List container
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = listStack
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        listHeightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            listStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: scrollView.topAnchor),

            listHeightConstraint!,
        ])
    }

    /// Update the section with changed files from all project roots.
    func update(roots: [ProjectRoot]) {
        changedFiles = []

        for root in roots {
            for (path, status) in root.gitTracker.fileStatuses {
                // Only show files, not directories
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    continue
                }
                if status == .ignored { continue }

                // Get relative path from root
                let relative: String
                if path.hasPrefix(root.path + "/") {
                    relative = String(path.dropFirst(root.path.count + 1))
                } else {
                    relative = (path as NSString).lastPathComponent
                }

                changedFiles.append((path: path, status: status, relativePath: relative))
            }
        }

        // Sort: staged first, then modified, then untracked
        changedFiles.sort { a, b in
            let ap = statusSortPriority(a.status)
            let bp = statusSortPriority(b.status)
            if ap != bp { return ap < bp }
            return a.relativePath < b.relativePath
        }

        headerView.updateBadge(changedFiles.isEmpty ? nil : changedFiles.count)
        rebuildList()
    }

    private func statusSortPriority(_ status: GitFileStatus) -> Int {
        switch status {
        case .staged, .stagedModified: return 0
        case .modified: return 1
        case .conflict: return 2
        case .untracked: return 3
        case .deleted: return 4
        case .renamed: return 5
        case .ignored: return 6
        }
    }

    private func rebuildList() {
        listStack.arrangedSubviews.forEach { listStack.removeArrangedSubview($0); $0.removeFromSuperview() }

        for (i, file) in changedFiles.prefix(50).enumerated() {
            let row = SourceControlRow(
                filename: (file.path as NSString).lastPathComponent,
                relativePath: file.relativePath,
                status: file.status
            )
            row.onClick = { [weak self] in
                self?.onFileSelected?(file.path)
            }
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }

        let rowHeight: CGFloat = 26
        let totalHeight = CGFloat(min(changedFiles.count, 50)) * rowHeight
        listHeightConstraint?.constant = isExpanded ? min(totalHeight, 200) : 0
    }

    private func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            let rowHeight: CGFloat = 26
            let totalHeight = CGFloat(min(changedFiles.count, 50)) * rowHeight
            listHeightConstraint?.constant = expanded ? min(totalHeight, 200) : 0
            layoutSubtreeIfNeeded()
        }
    }
}

// MARK: - Source Control Row

private class SourceControlRow: NSView {
    var onClick: (() -> Void)?
    private var isHovered = false

    init(filename: String, relativePath: String, status: GitFileStatus) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 4

        // Status letter
        let statusLabel = NSTextField(labelWithString: statusLetter(status))
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        statusLabel.textColor = statusColor(status)
        statusLabel.alignment = .center
        addSubview(statusLabel)

        // Filename
        let nameLabel = NSTextField(labelWithString: filename)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = NSColor(white: 0.80, alpha: 1.0)
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        // Relative path
        let pathLabel = NSTextField(labelWithString: relativePath)
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = NSColor(white: 0.40, alpha: 1.0)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(pathLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),

            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.widthAnchor.constraint(equalToConstant: 14),

            nameLabel.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 120),

            pathLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func statusLetter(_ status: GitFileStatus) -> String {
        switch status {
        case .modified, .stagedModified: return "M"
        case .staged: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "U"
        case .conflict: return "!"
        case .ignored: return ""
        }
    }

    private func statusColor(_ status: GitFileStatus) -> NSColor {
        switch status {
        case .staged, .renamed: return NSColor(red: 0.40, green: 0.72, blue: 0.40, alpha: 0.9)
        case .modified, .stagedModified: return NSColor(red: 0.88, green: 0.70, blue: 0.30, alpha: 0.9)
        case .untracked: return NSColor(red: 0.40, green: 0.72, blue: 0.40, alpha: 0.75)
        case .deleted: return NSColor(red: 0.82, green: 0.38, blue: 0.38, alpha: 0.9)
        case .conflict: return NSColor(red: 0.88, green: 0.42, blue: 0.42, alpha: 0.95)
        case .ignored: return NSColor(white: 0.35, alpha: 1.0)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.04).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = isHovered ? NSColor(white: 1.0, alpha: 0.04).cgColor : NSColor.clear.cgColor
        onClick?()
    }
}
