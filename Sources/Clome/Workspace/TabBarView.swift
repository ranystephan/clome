import AppKit

protocol TabBarDelegate: AnyObject {
    func tabBar(_ tabBar: TabBarView, didSelectTabAt index: Int)
    func tabBar(_ tabBar: TabBarView, didCloseTabAt index: Int)
    func tabBarDidRequestNewTab(_ tabBar: TabBarView)
}

/// A compact tab bar for switching between surfaces within a single pane.
class TabBarView: NSView {
    weak var delegate: TabBarDelegate?

    private let stackView = NSStackView()
    private let addButton: NSButton
    private var tabs: [TabItemView] = []
    private(set) var selectedIndex: Int = 0

    private let barHeight: CGFloat = 36
    private let bgColor = ClomeMacColor.chromeSurface
    private let borderColor = ClomeMacColor.border

    override init(frame: NSRect = .zero) {
        addButton = NSButton()
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = ClomeMacMetric.panelRadius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = bgColor.cgColor
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: barHeight)
    }

    private func setupUI() {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        stackView.orientation = .horizontal
        stackView.spacing = 4
        stackView.alignment = .centerY
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let clipView = NSClipView()
        clipView.drawsBackground = false
        clipView.documentView = stackView
        scrollView.contentView = clipView

        // Add tab button
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.bezelStyle = .texturedRounded
        addButton.isBordered = false
        addButton.title = ""
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")?.withSymbolConfiguration(cfg)
        addButton.contentTintColor = ClomeMacColor.textSecondary
        addButton.wantsLayer = true
        addButton.layer?.cornerRadius = ClomeMacMetric.compactRadius
        addButton.layer?.cornerCurve = .continuous
        addButton.layer?.backgroundColor = ClomeMacColor.chromeSurfaceAlt.cgColor
        addButton.target = self
        addButton.action = #selector(addTabTapped)
        addSubview(addButton)

        // Bottom border
        let border = NSView()
        border.translatesAutoresizingMaskIntoConstraints = false
        border.wantsLayer = true
        border.layer?.backgroundColor = borderColor.cgColor
        addSubview(border)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            scrollView.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -8),

            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),

            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 26),
            addButton.heightAnchor.constraint(equalToConstant: 26),

            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),

            heightAnchor.constraint(equalToConstant: barHeight),
        ])
    }

    func updateTabs(titles: [String], icons: [NSImage?] = [], selectedIndex: Int) {
        self.selectedIndex = selectedIndex
        stackView.arrangedSubviews.forEach { stackView.removeArrangedSubview($0); $0.removeFromSuperview() }
        tabs.removeAll()

        // Only show tab bar if there are multiple tabs
        isHidden = titles.count <= 1

        for (index, title) in titles.enumerated() {
            let icon = index < icons.count ? icons[index] : nil
            let tab = TabItemView(title: title, icon: icon, index: index, isSelected: index == selectedIndex)
            tab.target = self
            tab.action = #selector(tabTapped(_:))
            tab.closeAction = { [weak self] idx in
                self?.delegate?.tabBar(self!, didCloseTabAt: idx)
            }
            stackView.addArrangedSubview(tab)
            tabs.append(tab)
        }
    }

    /// Lightweight selection update — only changes visual state on existing tab views.
    func updateSelection(index: Int) {
        guard index >= 0, index < tabs.count else { return }
        let oldIndex = selectedIndex
        guard index != oldIndex else { return }
        selectedIndex = index

        if oldIndex >= 0, oldIndex < tabs.count {
            tabs[oldIndex].updateSelectionState(false)
        }
        tabs[index].updateSelectionState(true)
    }

    /// Update a single tab's title and icon without rebuilding all tabs.
    func updateTabTitle(at index: Int, title: String, icon: NSImage?) {
        guard index >= 0, index < tabs.count else { return }
        tabs[index].updateContent(title: title, icon: icon)
    }

    @objc private func tabTapped(_ sender: TabItemView) {
        delegate?.tabBar(self, didSelectTabAt: sender.index)
    }

    @objc private func addTabTapped() {
        delegate?.tabBarDidRequestNewTab(self)
    }
}

// MARK: - Tab Item

class TabItemView: NSControl {
    let index: Int
    private(set) var isSelected: Bool
    var closeAction: ((Int) -> Void)?
    private var closeButton: NSButton!
    private var label: NSTextField!
    private var iconView: NSImageView!
    private let hasCustomIcon: Bool

    private let activeColor = ClomeMacColor.elevatedSurface
    private let inactiveColor = NSColor.clear
    private let hoverColor = ClomeMacColor.chromeSurfaceAlt

    init(title: String, icon: NSImage? = nil, index: Int, isSelected: Bool) {
        self.index = index
        self.isSelected = isSelected
        self.hasCustomIcon = icon != nil
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = ClomeMacMetric.compactRadius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = isSelected ? activeColor.cgColor : inactiveColor.cgColor

        let textColor = isSelected ? ClomeMacColor.textPrimary : ClomeMacColor.textSecondary

        // Icon
        iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        if let icon = icon {
            iconView.image = icon
        } else {
            let iconCfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            iconView.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)?.withSymbolConfiguration(iconCfg)
            iconView.contentTintColor = textColor
        }
        addSubview(iconView)

        label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = ClomeMacFont.captionMedium
        label.textColor = textColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        closeButton = NSButton()
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .texturedRounded
        closeButton.isBordered = false
        closeButton.title = ""
        let closeCfg = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?.withSymbolConfiguration(closeCfg)
        closeButton.contentTintColor = ClomeMacColor.textTertiary
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.alphaValue = isSelected ? 0.8 : 0.0
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            heightAnchor.constraint(equalToConstant: 30),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    @objc private func closeTapped() {
        closeAction?(index)
    }

    /// Update visual state without rebuilding the view.
    func updateSelectionState(_ selected: Bool) {
        isSelected = selected
        let textColor = selected ? ClomeMacColor.textPrimary : ClomeMacColor.textSecondary
        layer?.backgroundColor = selected ? activeColor.cgColor : inactiveColor.cgColor
        label.textColor = textColor
        label.font = ClomeMacFont.captionMedium
        if !hasCustomIcon { iconView.contentTintColor = textColor }
        closeButton.alphaValue = selected ? 0.8 : 0.0
    }

    /// Update title and icon content without rebuilding the view.
    func updateContent(title: String, icon: NSImage?) {
        label.stringValue = title
        if let icon {
            iconView.image = icon
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        if !isSelected { layer?.backgroundColor = hoverColor.cgColor }
        closeButton.alphaValue = 0.8
    }

    override func mouseExited(with event: NSEvent) {
        if !isSelected { layer?.backgroundColor = inactiveColor.cgColor }
        if !isSelected { closeButton.alphaValue = 0.0 }
    }
}
