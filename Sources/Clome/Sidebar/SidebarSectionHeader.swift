import AppKit

/// Reusable collapsible section header for the sidebar.
/// Shows title (tracked caps), optional badge count, and optional action buttons.
@MainActor
class SidebarSectionHeader: NSView {
    var isExpanded: Bool = true {
        didSet { updateDisclosure() }
    }

    var onToggle: ((Bool) -> Void)?

    private let disclosureIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let actionStack = NSStackView()

    init(title: String, badge: Int? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // Disclosure triangle
        disclosureIcon.translatesAutoresizingMaskIntoConstraints = false
        let cfg = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        disclosureIcon.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        disclosureIcon.contentTintColor = NSColor(white: 0.40, alpha: 1.0)
        addSubview(disclosureIcon)

        // Title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.attributedStringValue = NSAttributedString(string: title.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor(white: 1.0, alpha: 0.45),
            .kern: 1.2,
        ])
        addSubview(titleLabel)

        // Badge
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        badgeLabel.textColor = NSColor(white: 0.55, alpha: 1.0)
        badgeLabel.isHidden = badge == nil
        if let badge { badgeLabel.stringValue = "(\(badge))" }
        addSubview(badgeLabel)

        // Action buttons stack
        actionStack.orientation = .horizontal
        actionStack.spacing = 4
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actionStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),

            disclosureIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            disclosureIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosureIcon.widthAnchor.constraint(equalToConstant: 12),
            disclosureIcon.heightAnchor.constraint(equalToConstant: 12),

            titleLabel.leadingAnchor.constraint(equalTo: disclosureIcon.trailingAnchor, constant: 4),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            badgeLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            actionStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actionStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Set initial chevron state immediately (no animation)
        let initialAngle: CGFloat = isExpanded ? .pi / 2 : 0
        disclosureIcon.wantsLayer = true
        disclosureIcon.layer?.setAffineTransform(CGAffineTransform(rotationAngle: initialAngle))

        // Click to toggle
        let click = NSClickGestureRecognizer(target: self, action: #selector(headerClicked))
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateBadge(_ count: Int?) {
        if let count {
            badgeLabel.stringValue = "(\(count))"
            badgeLabel.isHidden = false
        } else {
            badgeLabel.isHidden = true
        }
    }

    func addActionButton(symbol: String, tooltip: String, target: AnyObject, action: Selector) {
        let btn = NSButton()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.bezelStyle = .texturedRounded
        btn.isBordered = false
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?.withSymbolConfiguration(cfg)
        btn.contentTintColor = NSColor(white: 0.50, alpha: 1.0)
        btn.target = target
        btn.action = action
        btn.toolTip = tooltip
        NSLayoutConstraint.activate([
            btn.widthAnchor.constraint(equalToConstant: 20),
            btn.heightAnchor.constraint(equalToConstant: 20),
        ])
        actionStack.addArrangedSubview(btn)
    }

    private func updateDisclosure() {
        let angle: CGFloat = isExpanded ? .pi / 2 : 0
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        disclosureIcon.layer?.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        CATransaction.commit()
    }

    @objc private func headerClicked() {
        isExpanded.toggle()
        onToggle?(isExpanded)
    }
}
