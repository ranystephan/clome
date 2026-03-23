import AppKit

/// A single row in the launcher results list.
@MainActor
class LauncherResultRowView: NSView {

    let iconView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")
    let metadataLabel = NSTextField(labelWithString: "")
    let shortcutLabel = NSTextField(labelWithString: "")
    private let accentBar = NSView()

    /// Container for title + subtitle to enable vertical centering as a group.
    private let textContainer = NSView()

    /// Constraint for centering title when subtitle is hidden.
    private var titleCenterYConstraint: NSLayoutConstraint!
    /// Constraint for pinning title to top of textContainer when subtitle is visible.
    private var titleTopConstraint: NSLayoutConstraint!

    /// Whether this row represents an attention item (e.g. Claude awaiting permission).
    var isAttention: Bool = false {
        didSet { updateAccentBar() }
    }

    /// Manually controlled selection state (replaces NSTableRowView.isSelected).
    var isItemSelected: Bool = false {
        didSet { updateAppearance() }
    }

    /// Fixed SF Symbol configuration for consistent icon sizing.
    private static let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setupViews() {
        wantsLayer = true
        // Accent bar (left edge indicator)
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        accentBar.wantsLayer = true
        accentBar.layer?.cornerRadius = 1.5
        accentBar.isHidden = true
        addSubview(accentBar)

        // Icon
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        // Text container (holds title + subtitle, centered vertically)
        textContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textContainer)

        // Title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = NSColor(white: 0.88, alpha: 1.0)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.maximumNumberOfLines = 1
        textContainer.addSubview(titleLabel)

        // Subtitle
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = NSColor(white: 0.45, alpha: 1.0)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.cell?.truncatesLastVisibleLine = true
        subtitleLabel.maximumNumberOfLines = 1
        textContainer.addSubview(subtitleLabel)

        // Metadata (right side)
        metadataLabel.translatesAutoresizingMaskIntoConstraints = false
        metadataLabel.font = .systemFont(ofSize: 11, weight: .regular)
        metadataLabel.textColor = NSColor(white: 0.4, alpha: 1.0)
        metadataLabel.alignment = .right
        metadataLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.cell?.truncatesLastVisibleLine = true
        metadataLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(metadataLabel)

        // Shortcut hint
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        shortcutLabel.textColor = NSColor(white: 0.35, alpha: 1.0)
        shortcutLabel.wantsLayer = true
        shortcutLabel.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        shortcutLabel.layer?.cornerRadius = 3
        shortcutLabel.alignment = .center
        shortcutLabel.isHidden = true
        addSubview(shortcutLabel)

        // Title vertical positioning constraints (toggled based on subtitle visibility)
        titleTopConstraint = titleLabel.topAnchor.constraint(equalTo: textContainer.topAnchor)
        titleCenterYConstraint = titleLabel.centerYAnchor.constraint(equalTo: textContainer.centerYAnchor)

        NSLayoutConstraint.activate([
            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            accentBar.centerYAnchor.constraint(equalTo: centerYAnchor),
            accentBar.widthAnchor.constraint(equalToConstant: 3),
            accentBar.heightAnchor.constraint(equalToConstant: 28),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            // Text container: vertically centered, spans between icon and metadata
            textContainer.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            textContainer.trailingAnchor.constraint(lessThanOrEqualTo: metadataLabel.leadingAnchor, constant: -8),

            // Title inside container
            titleLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: textContainer.trailingAnchor),

            // Subtitle inside container (2px gap below title)
            subtitleLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: textContainer.trailingAnchor),
            subtitleLabel.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor),

            metadataLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            metadataLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])

        // Default: no subtitle, title centered
        titleCenterYConstraint.isActive = true
        titleTopConstraint.isActive = false
    }

    func configure(with item: LauncherItem) {
        // Icon with consistent SF Symbol sizing
        if let img = NSImage(systemSymbolName: item.icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(Self.symbolConfig) {
            iconView.image = img
            iconView.contentTintColor = item.iconColor ?? NSColor(white: 0.55, alpha: 1.0)
        }

        titleLabel.stringValue = item.title

        // Subtitle
        let hasSubtitle = item.subtitle != nil && !item.subtitle!.isEmpty
        if hasSubtitle {
            subtitleLabel.stringValue = item.subtitle!
            subtitleLabel.isHidden = false
            // Title+subtitle pair: pin title to top, subtitle defines bottom
            titleCenterYConstraint.isActive = false
            titleTopConstraint.isActive = true
        } else {
            subtitleLabel.isHidden = true
            // No subtitle: center title vertically
            titleTopConstraint.isActive = false
            titleCenterYConstraint.isActive = true
        }

        // Metadata
        if let meta = item.metadata, !meta.isEmpty {
            metadataLabel.stringValue = meta
            metadataLabel.isHidden = false
            shortcutLabel.isHidden = true
        } else {
            metadataLabel.isHidden = true
        }

        isAttention = item.priority >= 1000
    }

    private func updateAppearance() {
        if isItemSelected {
            layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
            accentBar.isHidden = false
            if !isAttention {
                accentBar.layer?.backgroundColor = NSColor(red: 0.40, green: 0.62, blue: 1.00, alpha: 1.0).cgColor
            }
        } else {
            layer?.backgroundColor = .clear
            accentBar.isHidden = !isAttention
        }
    }

    private func updateAccentBar() {
        if isAttention {
            accentBar.isHidden = false
            accentBar.layer?.backgroundColor = NSColor(red: 1.0, green: 0.75, blue: 0.25, alpha: 1.0).cgColor
        } else if !isItemSelected {
            accentBar.isHidden = true
        }
    }
}
