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

    private let barHeight: CGFloat = 34
    private let bgColor = NSColor(red: 0.06, green: 0.06, blue: 0.075, alpha: 1.0)
    private let borderColor = NSColor(white: 1.0, alpha: 0.06)

    override init(frame: NSRect = .zero) {
        addButton = NSButton()
        super.init(frame: frame)
        wantsLayer = true
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
        stackView.spacing = 1
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
        addButton.contentTintColor = NSColor(white: 0.4, alpha: 1.0)
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
            addButton.widthAnchor.constraint(equalToConstant: 22),
            addButton.heightAnchor.constraint(equalToConstant: 22),

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
    let isSelected: Bool
    var closeAction: ((Int) -> Void)?
    private var closeButton: NSButton!

    private let activeColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)
    private let inactiveColor = NSColor.clear
    private let hoverColor = NSColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1.0)

    init(title: String, icon: NSImage? = nil, index: Int, isSelected: Bool) {
        self.index = index
        self.isSelected = isSelected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = isSelected ? activeColor.cgColor : inactiveColor.cgColor

        let textColor = isSelected ? NSColor(white: 0.92, alpha: 1.0) : NSColor(white: 0.5, alpha: 1.0)

        // Icon
        let iconView = NSImageView()
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

        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: isSelected ? .medium : .regular)
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
        closeButton.contentTintColor = NSColor(white: 0.35, alpha: 1.0)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.alphaValue = isSelected ? 0.8 : 0.0
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            heightAnchor.constraint(equalToConstant: 28),

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

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
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
