import AppKit

/// A panel that shows a file diff with accept/reject controls.
/// Can be opened as a tab in ProjectPanel alongside EditorPanel, NotebookPanel, PDFPanel.
class DiffReviewPanel: NSView {
    private let diffView = DiffView()
    private let headerBar = NSView()
    private let fileLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private let acceptAllButton: NSButton
    private let rejectAllButton: NSButton

    /// The file path this diff is for.
    private(set) var filePath: String

    /// Called after accept/reject so the parent can close or update the tab.
    var onReviewComplete: ((String, Bool) -> Void)?  // (path, wasAccepted)

    init(filePath: String, oldContent: String?, newContent: String?) {
        self.filePath = filePath
        self.acceptAllButton = NSButton()
        self.rejectAllButton = NSButton()
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.055, green: 0.055, blue: 0.07, alpha: 1.0).cgColor
        setupUI()
        loadDiff(oldContent: oldContent, newContent: newContent)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        // Header bar
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        headerBar.wantsLayer = true
        headerBar.layer?.backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1.0).cgColor
        addSubview(headerBar)

        // File icon
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: "Diff")
        iconView.contentTintColor = NSColor(red: 0.45, green: 0.65, blue: 0.90, alpha: 1.0)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        headerBar.addSubview(iconView)

        // File name
        fileLabel.translatesAutoresizingMaskIntoConstraints = false
        fileLabel.font = .systemFont(ofSize: 13, weight: .medium)
        fileLabel.textColor = NSColor(white: 0.9, alpha: 1.0)
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.stringValue = (filePath as NSString).lastPathComponent
        headerBar.addSubview(fileLabel)

        // Stats (e.g. "+12 -3")
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        statsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statsLabel.textColor = NSColor(white: 0.5, alpha: 1.0)
        headerBar.addSubview(statsLabel)

        // Reject All button
        configureButton(rejectAllButton, title: "Reject", color: NSColor(red: 0.9, green: 0.4, blue: 0.4, alpha: 1.0), action: #selector(rejectTapped))
        headerBar.addSubview(rejectAllButton)

        // Accept button
        configureButton(acceptAllButton, title: "Accept", color: NSColor(red: 0.4, green: 0.85, blue: 0.5, alpha: 1.0), action: #selector(acceptTapped))
        headerBar.addSubview(acceptAllButton)

        // Diff view
        diffView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(diffView)

        // Hide DiffView's own toolbar — we have our own Accept/Reject in the header
        if let diffToolbar = diffView.subviews.first {
            diffToolbar.isHidden = true
        }
        diffView.onAccept = nil
        diffView.onReject = nil

        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: 40),

            iconView.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            fileLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            fileLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            statsLabel.leadingAnchor.constraint(equalTo: fileLabel.trailingAnchor, constant: 12),
            statsLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            acceptAllButton.trailingAnchor.constraint(equalTo: rejectAllButton.leadingAnchor, constant: -8),
            acceptAllButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            acceptAllButton.heightAnchor.constraint(equalToConstant: 26),

            rejectAllButton.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -12),
            rejectAllButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            rejectAllButton.heightAnchor.constraint(equalToConstant: 26),

            diffView.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            diffView.leadingAnchor.constraint(equalTo: leadingAnchor),
            diffView.trailingAnchor.constraint(equalTo: trailingAnchor),
            diffView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func configureButton(_ button: NSButton, title: String, color: NSColor, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = title
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 4
        button.layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = color
        button.target = self
        button.action = action
    }

    private func loadDiff(oldContent: String?, newContent: String?) {
        let old = oldContent ?? ""
        let new = newContent ?? ""
        diffView.showDiff(oldText: old, newText: new)

        // Compute stats
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let oldSet = Set(oldLines)
        let newSet = Set(newLines)
        let added = newLines.filter { !oldSet.contains($0) }.count
        let removed = oldLines.filter { !newSet.contains($0) }.count
        statsLabel.stringValue = "+\(added) -\(removed)"
        statsLabel.textColor = added > removed
            ? NSColor(red: 0.4, green: 0.8, blue: 0.4, alpha: 0.7)
            : NSColor(red: 0.8, green: 0.4, blue: 0.4, alpha: 0.7)
    }

    // MARK: - Actions

    @objc private func acceptTapped() {
        AgentFileTracker.shared.acceptChange(at: filePath)
        showReviewResult(accepted: true)
        onReviewComplete?(filePath, true)
    }

    @objc private func rejectTapped() {
        AgentFileTracker.shared.rejectChange(at: filePath)
        showReviewResult(accepted: false)
        onReviewComplete?(filePath, false)
    }

    private func showReviewResult(accepted: Bool) {
        let label = NSTextField(labelWithString: accepted ? "Changes Accepted" : "Changes Rejected")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = accepted
            ? NSColor(red: 0.4, green: 0.85, blue: 0.5, alpha: 1.0)
            : NSColor(red: 0.9, green: 0.4, blue: 0.4, alpha: 1.0)
        label.alignment = .center
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: headerBar.bottomAnchor, constant: 20),
        ])

        acceptAllButton.isEnabled = false
        rejectAllButton.isEnabled = false
    }
}
