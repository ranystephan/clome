import AppKit

/// Reusable collapsible section header for the sidebar.
/// Shows title (tracked caps), optional badge count, and optional action buttons.
@MainActor
class SidebarSectionHeader: NSView {
    private let title: String
    var isExpanded: Bool = true {
        didSet { updateDisclosure() }
    }

    var onToggle: ((Bool) -> Void)?

    private let disclosureIcon = NSImageView()
    private let chevronConfig = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let actionStack = NSStackView()

    init(title: String, badge: Int? = nil) {
        self.title = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = ClomeMacMetric.compactRadius
        layer?.cornerCurve = .continuous

        // Disclosure triangle
        disclosureIcon.translatesAutoresizingMaskIntoConstraints = false
        disclosureIcon.contentTintColor = ClomeMacColor.textTertiary
        disclosureIcon.imageScaling = .scaleProportionallyDown
        addSubview(disclosureIcon)

        // Title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        // Badge
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        badgeLabel.textColor = ClomeMacColor.textSecondary
        badgeLabel.isHidden = badge == nil
        if let badge { badgeLabel.stringValue = "(\(badge))" }
        addSubview(badgeLabel)

        // Action buttons stack
        actionStack.orientation = .horizontal
        actionStack.spacing = 4
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actionStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),

            disclosureIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
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

        // Set initial chevron image
        updateDisclosure()
        refreshAppearance()

        // Click to toggle
        let click = NSClickGestureRecognizer(target: self, action: #selector(headerClicked))
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError() }

    func refreshAppearance() {
        titleLabel.attributedStringValue = NSAttributedString(string: title.uppercased(), attributes: [
            .font: ClomeMacFont.sectionLabel,
            .foregroundColor: ClomeMacColor.textTertiary,
            .kern: 1.8,
        ])
        disclosureIcon.contentTintColor = ClomeMacColor.textTertiary
        badgeLabel.textColor = ClomeMacColor.textSecondary
        for case let button as NSButton in actionStack.arrangedSubviews {
            button.contentTintColor = ClomeMacColor.textTertiary
        }
    }

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
        btn.contentTintColor = ClomeMacColor.textTertiary
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
        let name = isExpanded ? "chevron.down" : "chevron.right"
        disclosureIcon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(chevronConfig)
    }

    @objc private func headerClicked() {
        isExpanded.toggle()
        layer?.backgroundColor = ClomeMacColor.hoverFill.cgColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.layer?.backgroundColor = NSColor.clear.cgColor
        }
        onToggle?(isExpanded)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }
}
