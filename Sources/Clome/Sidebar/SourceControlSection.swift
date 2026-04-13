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

    func refreshAppearance() {
        headerView.refreshAppearance()
        rebuildList()
    }

    private func setupUI() {
        wantsLayer = true
        addSubview(headerView)

        headerView.onToggle = { [weak self] expanded in
            self?.setExpanded(expanded)
        }

        // List container
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 4
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

            listStack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            listStack.bottomAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.bottomAnchor),
            listStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

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

        guard !changedFiles.isEmpty else {
            let emptyLabel = NSTextField(labelWithString: "Working tree is clean")
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false
            emptyLabel.font = ClomeMacFont.caption
            emptyLabel.textColor = ClomeMacColor.textTertiary
            emptyLabel.alignment = .center

            let card = NSView()
            card.translatesAutoresizingMaskIntoConstraints = false
            card.wantsLayer = true
            card.layer?.cornerRadius = ClomeMacMetric.panelRadius
            card.layer?.cornerCurve = .continuous
            card.layer?.backgroundColor = ClomeMacTheme.surfaceColor(.chrome).cgColor
            card.layer?.borderWidth = 1
            card.layer?.borderColor = ClomeMacColor.border.cgColor
            card.addSubview(emptyLabel)

            listStack.addArrangedSubview(card)

            NSLayoutConstraint.activate([
                emptyLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
                emptyLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
                emptyLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
                emptyLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
                card.widthAnchor.constraint(equalTo: listStack.widthAnchor),
            ])
            listHeightConstraint?.constant = isExpanded ? 48 : 0
            return
        }

        for file in changedFiles.prefix(50) {
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

        let rowHeight: CGFloat = 36
        let totalHeight = CGFloat(min(changedFiles.count, 50)) * rowHeight
        listHeightConstraint?.constant = isExpanded ? min(totalHeight, 200) : 0
    }

    private func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            let rowHeight: CGFloat = 36
            let totalHeight = CGFloat(min(changedFiles.count, 50)) * rowHeight
            listHeightConstraint?.constant = expanded ? min(totalHeight, 200) : 0
            layoutSubtreeIfNeeded()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }
}

// MARK: - Source Control Row

private class SourceControlRow: NSView {
    var onClick: (() -> Void)?
    private var isHovered = false
    private let status: GitFileStatus
    private let statusLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")

    init(filename: String, relativePath: String, status: GitFileStatus) {
        self.status = status
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = ClomeMacMetric.compactRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = ClomeMacColor.border.cgColor
        layer?.backgroundColor = baseBackgroundColor.cgColor

        // Status letter
        statusLabel.stringValue = statusLetter(status)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        statusLabel.alignment = .center
        addSubview(statusLabel)

        // Filename
        nameLabel.stringValue = filename
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = ClomeMacFont.bodyMedium
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        // Relative path
        pathLabel.stringValue = relativePath
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = ClomeMacFont.caption
        pathLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(pathLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),

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
        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var baseBackgroundColor: NSColor { ClomeMacTheme.surfaceColor(.chrome) }
    private var hoverBackgroundColor: NSColor { ClomeMacTheme.surfaceColor(.chromeAlt) }
    private var pressedBackgroundColor: NSColor { ClomeMacTheme.surfaceColor(.elevated) }

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
        layer?.backgroundColor = hoverBackgroundColor.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.backgroundColor = baseBackgroundColor.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = pressedBackgroundColor.cgColor
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = isHovered ? hoverBackgroundColor.cgColor : baseBackgroundColor.cgColor
        onClick?()
    }

    private func applyAppearance() {
        layer?.borderColor = ClomeMacColor.border.cgColor
        layer?.backgroundColor = (isHovered ? hoverBackgroundColor : baseBackgroundColor).cgColor
        statusLabel.textColor = statusColor(status)
        nameLabel.textColor = ClomeMacColor.textPrimary
        pathLabel.textColor = ClomeMacColor.textTertiary
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }
}
