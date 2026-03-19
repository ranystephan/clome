import AppKit

protocol WorkspaceTabBarDelegate: AnyObject {
    func tabBar(_ tabBar: WorkspaceTabBar, didSelectTabAt index: Int)
    func tabBar(_ tabBar: WorkspaceTabBar, didCloseTabAt index: Int)
    func tabBar(_ tabBar: WorkspaceTabBar, didMoveTabFrom from: Int, to: Int)
    func tabBar(_ tabBar: WorkspaceTabBar, didRenameTabAt index: Int, to name: String)
    func tabBarDidRequestNewTab(_ tabBar: WorkspaceTabBar)
    func tabBarDidRequestNewTerminal(_ tabBar: WorkspaceTabBar)
    func tabBarDidRequestNewBrowser(_ tabBar: WorkspaceTabBar)
    func tabBarDidRequestNewProject(_ tabBar: WorkspaceTabBar)
    func tabBarDidRequestNewFile(_ tabBar: WorkspaceTabBar)
    func tabBarDidRequestSplit(_ tabBar: WorkspaceTabBar, direction: SplitDirection)
    func tabBarDidRequestQuadSplit(_ tabBar: WorkspaceTabBar)
    func tabBar(_ tabBar: WorkspaceTabBar, didBeginDragTabAt index: Int)
    func tabBar(_ tabBar: WorkspaceTabBar, didDragTabAt index: Int, to windowPoint: NSPoint)
    func tabBar(_ tabBar: WorkspaceTabBar, didEndDragTabAt index: Int, at windowPoint: NSPoint)
}

/// Horizontal tab bar at the top of the content area.
class WorkspaceTabBar: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    weak var delegate: WorkspaceTabBarDelegate?

    private let stackView = NSStackView()
    private let addMenuContainer: AddTabMenuView
    private let splitHButton: NSButton
    private let splitVButton: NSButton
    private let splitQuadButton: NSButton

    private let barHeight: CGFloat = 34
    private let bgColor = NSColor(red: 0.13, green: 0.13, blue: 0.145, alpha: 0.6)
    private let borderColor = NSColor(white: 1.0, alpha: 0.06)

    // Leading inset (adjusted when sidebar hides to clear traffic lights)
    private var stackLeadingConstraint: NSLayoutConstraint!
    private let defaultLeadingInset: CGFloat = 10
    private let trafficLightLeadingInset: CGFloat = 74

    // Drag state
    private var draggedIndex: Int?
    private var dragStartX: CGFloat = 0
    private var dragPlaceholderIndex: Int?

    override init(frame: NSRect = .zero) {
        addMenuContainer = AddTabMenuView()
        splitHButton = NSButton()
        splitVButton = NSButton()
        splitQuadButton = NSButton()
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = bgColor.cgColor
        addMenuContainer.onNewTerminal = { [weak self] in
            guard let self else { return }
            self.delegate?.tabBarDidRequestNewTerminal(self)
        }
        addMenuContainer.onNewBrowser = { [weak self] in
            guard let self else { return }
            self.delegate?.tabBarDidRequestNewBrowser(self)
        }
        addMenuContainer.onNewProject = { [weak self] in
            guard let self else { return }
            self.delegate?.tabBarDidRequestNewProject(self)
        }
        addMenuContainer.onNewFile = { [weak self] in
            guard let self else { return }
            self.delegate?.tabBarDidRequestNewFile(self)
        }
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: barHeight)
    }

    private func setupUI() {
        stackView.orientation = .horizontal
        stackView.spacing = 1
        stackView.alignment = .centerY
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        // Split buttons
        configureSplitButton(splitHButton, symbol: "rectangle.split.2x1", tooltip: "Split Right (⌘D)", action: #selector(splitHTapped))
        configureSplitButton(splitVButton, symbol: "rectangle.split.1x2", tooltip: "Split Down (⌘⇧D)", action: #selector(splitVTapped))
        configureSplitButton(splitQuadButton, symbol: "rectangle.split.2x2", tooltip: "Split into 4 Panes", action: #selector(splitQuadTapped))

        // Add tab menu (hover-expandable)
        addMenuContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(addMenuContainer)

        // Right-side button group: [splitH] [splitV] [quad] | [+]
        let buttonGroup = NSStackView(views: [splitHButton, splitVButton, splitQuadButton])
        buttonGroup.translatesAutoresizingMaskIntoConstraints = false
        buttonGroup.orientation = .horizontal
        buttonGroup.spacing = 2
        buttonGroup.alignment = .centerY
        addSubview(buttonGroup)

        let border = NSView()
        border.translatesAutoresizingMaskIntoConstraints = false
        border.wantsLayer = true
        border.layer?.backgroundColor = borderColor.cgColor
        addSubview(border)

        // Thin separator between split buttons and +
        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        addSubview(separator)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: barHeight),

            {
                stackLeadingConstraint = stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: defaultLeadingInset)
                return stackLeadingConstraint
            }(),
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: buttonGroup.leadingAnchor, constant: -8),

            // Split button group
            buttonGroup.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttonGroup.trailingAnchor.constraint(equalTo: separator.leadingAnchor, constant: -6),

            // Separator
            separator.trailingAnchor.constraint(equalTo: addMenuContainer.leadingAnchor, constant: -6),
            separator.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.heightAnchor.constraint(equalToConstant: 16),

            // Add tab menu (rightmost)
            addMenuContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            addMenuContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            addMenuContainer.heightAnchor.constraint(equalToConstant: 22),

            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func configureSplitButton(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.title = ""
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?.withSymbolConfiguration(cfg)
        button.contentTintColor = NSColor(white: 0.35, alpha: 1.0)
        button.target = self
        button.action = action
        button.toolTip = tooltip
        addSubview(button)

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 22),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    /// Adjust leading inset to avoid traffic light buttons when sidebar is hidden.
    func setSidebarVisible(_ visible: Bool, animated: Bool = true) {
        let inset = visible ? defaultLeadingInset : trafficLightLeadingInset
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                stackLeadingConstraint.animator().constant = inset
            }
        } else {
            stackLeadingConstraint.constant = inset
        }
    }

    /// Lightweight update — only changes which tab appears selected, no view hierarchy changes
    func updateSelection(activeIndex: Int) {
        for (i, view) in stackView.arrangedSubviews.enumerated() {
            guard let item = view as? WorkspaceTabItem else { continue }
            item.index = i
            item.setSelected(i == activeIndex)
        }
    }

    /// Lightweight update — only changes a single tab's title and icon without rebuilding.
    func updateTabTitle(at index: Int, title: String, icon: String?, isSplit: Bool, splitDescription: String?) {
        guard index >= 0, index < stackView.arrangedSubviews.count,
              let item = stackView.arrangedSubviews[index] as? WorkspaceTabItem else { return }
        item.updateContent(title: isSplit ? (splitDescription ?? title) : title, icon: icon)
    }

    func updateTabs(workspace: Workspace) {
        stackView.arrangedSubviews.forEach { stackView.removeArrangedSubview($0); $0.removeFromSuperview() }

        for (index, tab) in workspace.tabs.enumerated() {
            let isSelected = index == workspace.activeTabIndex
            let tabView = WorkspaceTabItem(tab: tab, index: index, isSelected: isSelected)
            tabView.onSelect = { [weak self] idx in
                guard let self else { return }
                self.delegate?.tabBar(self, didSelectTabAt: idx)
            }
            tabView.onClose = { [weak self] idx in
                guard let self else { return }
                self.delegate?.tabBar(self, didCloseTabAt: idx)
            }
            tabView.onStartRename = { [weak self] idx in
                self?.startRename(at: idx)
            }
            tabView.onDragBegan = { [weak self] idx, point in
                self?.draggedIndex = idx
                self?.dragStartX = point.x
                self?.delegate?.tabBar(self!, didBeginDragTabAt: idx)
            }
            tabView.onDragMoved = { [weak self] idx, point in
                guard let self else { return }
                let localPoint = self.convert(point, from: nil)
                let insideTabBar = localPoint.y >= 0 && localPoint.y <= self.bounds.height
                if insideTabBar {
                    self.handleDragMove(from: idx, globalX: point.x)
                }
                // Always notify delegate so it can show/hide drop zones
                self.delegate?.tabBar(self, didDragTabAt: idx, to: point)
            }
            tabView.onDragEnded = { [weak self] idx, point in
                guard let self else { return }
                let localPoint = self.convert(point, from: nil)
                let insideTabBar = localPoint.y >= 0 && localPoint.y <= self.bounds.height
                if insideTabBar {
                    self.handleDragEnd(from: idx)
                } else {
                    self.delegate?.tabBar(self, didEndDragTabAt: idx, at: point)
                }
            }
            tabView.contextMenuProvider = { [weak self] idx in
                self?.makeContextMenu(for: idx) ?? NSMenu()
            }
            stackView.addArrangedSubview(tabView)
        }
    }

    // MARK: - Split Actions

    @objc private func splitHTapped() {
        delegate?.tabBarDidRequestSplit(self, direction: .right)
    }

    @objc private func splitVTapped() {
        delegate?.tabBarDidRequestSplit(self, direction: .down)
    }

    @objc private func splitQuadTapped() {
        delegate?.tabBarDidRequestQuadSplit(self)
    }

    // MARK: - Drag Reorder

    private func handleDragMove(from sourceIndex: Int, globalX: CGFloat) {
        let views = stackView.arrangedSubviews
        for (i, view) in views.enumerated() where i != sourceIndex {
            let midX = view.convert(CGPoint(x: view.bounds.midX, y: 0), to: nil).x
            if globalX < midX && i < sourceIndex {
                moveDraggedView(from: sourceIndex, to: i)
                return
            } else if globalX > midX && i > sourceIndex {
                moveDraggedView(from: sourceIndex, to: i)
                return
            }
        }
    }

    private func moveDraggedView(from: Int, to: Int) {
        let views = stackView.arrangedSubviews
        guard from >= 0, from < views.count, to >= 0, to < views.count, from != to else { return }
        let view = views[from]
        stackView.removeArrangedSubview(view)
        stackView.insertArrangedSubview(view, at: to)

        // Update indices on all tab items
        for (i, v) in stackView.arrangedSubviews.enumerated() {
            (v as? WorkspaceTabItem)?.index = i
        }
        draggedIndex = to
    }

    private func handleDragEnd(from originalIndex: Int) {
        guard let finalIndex = draggedIndex else { return }
        if originalIndex != finalIndex {
            delegate?.tabBar(self, didMoveTabFrom: originalIndex, to: finalIndex)
        }
        draggedIndex = nil
    }

    // MARK: - Rename

    private func startRename(at index: Int) {
        guard index < stackView.arrangedSubviews.count,
              let tabItem = stackView.arrangedSubviews[index] as? WorkspaceTabItem else { return }

        let field = NSTextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.stringValue = tabItem.currentTitle
        field.font = .systemFont(ofSize: 11, weight: .medium)
        field.textColor = NSColor(white: 0.92, alpha: 1.0)
        field.backgroundColor = NSColor(red: 0.17, green: 0.17, blue: 0.19, alpha: 1.0)
        field.isBordered = false
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.cornerRadius = 3

        let renameIndex = index
        let finishRename: (NSTextField) -> Void = { [weak self] tf in
            let newName = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newName.isEmpty {
                self?.delegate?.tabBar(self!, didRenameTabAt: renameIndex, to: newName)
            }
            tf.removeFromSuperview()
        }

        field.target = nil
        field.action = nil

        tabItem.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: tabItem.leadingAnchor, constant: 28),
            field.trailingAnchor.constraint(equalTo: tabItem.trailingAnchor, constant: -22),
            field.centerYAnchor.constraint(equalTo: tabItem.centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 18),
        ])

        field.window?.makeFirstResponder(field)
        field.selectText(nil)

        // End editing on enter or focus loss
        NotificationCenter.default.addObserver(forName: NSTextField.textDidEndEditingNotification, object: field, queue: .main) { _ in
            finishRename(field)
        }
    }

    // MARK: - Context Menu

    private func makeContextMenu(for index: Int) -> NSMenu {
        let menu = NSMenu()

        let renameItem = NSMenuItem(title: "Rename", action: nil, keyEquivalent: "")
        renameItem.target = self
        renameItem.representedObject = index
        renameItem.action = #selector(contextRename(_:))
        menu.addItem(renameItem)

        menu.addItem(NSMenuItem.separator())

        // Split options in context menu
        let splitRightItem = NSMenuItem(title: "Split Right", action: nil, keyEquivalent: "")
        splitRightItem.target = self
        splitRightItem.representedObject = index
        splitRightItem.action = #selector(contextSplitRight(_:))
        menu.addItem(splitRightItem)

        let splitDownItem = NSMenuItem(title: "Split Down", action: nil, keyEquivalent: "")
        splitDownItem.target = self
        splitDownItem.representedObject = index
        splitDownItem.action = #selector(contextSplitDown(_:))
        menu.addItem(splitDownItem)

        menu.addItem(NSMenuItem.separator())

        let closeItem = NSMenuItem(title: "Close Tab", action: nil, keyEquivalent: "")
        closeItem.target = self
        closeItem.representedObject = index
        closeItem.action = #selector(contextClose(_:))
        menu.addItem(closeItem)

        return menu
    }

    @objc private func contextRename(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        startRename(at: index)
    }

    @objc private func contextSplitRight(_ sender: NSMenuItem) {
        delegate?.tabBarDidRequestSplit(self, direction: .right)
    }

    @objc private func contextSplitDown(_ sender: NSMenuItem) {
        delegate?.tabBarDidRequestSplit(self, direction: .down)
    }

    @objc private func contextClose(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        delegate?.tabBar(self, didCloseTabAt: index)
    }

}

// MARK: - Add Tab Menu (hover-expandable)

class AddTabMenuView: NSView {
    var onNewTerminal: (() -> Void)?
    var onNewBrowser: (() -> Void)?
    var onNewProject: (() -> Void)?
    var onNewFile: (() -> Void)?

    private let plusIcon: NSImageView
    private let expandedStack: NSStackView
    private var widthConstraint: NSLayoutConstraint!
    private var isExpanded = false
    private var collapseTimer: Timer?

    private let collapsedWidth: CGFloat = 22
    private let expandedWidth: CGFloat = 102 // 4 buttons * 22 + 3 gaps * 2 + padding

    override init(frame: NSRect = .zero) {
        plusIcon = NSImageView()
        expandedStack = NSStackView()
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        // Plus icon (shown when collapsed)
        plusIcon.translatesAutoresizingMaskIntoConstraints = false
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        plusIcon.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")?.withSymbolConfiguration(cfg)
        plusIcon.contentTintColor = NSColor(white: 0.4, alpha: 1.0)
        addSubview(plusIcon)

        // Expanded button stack
        expandedStack.translatesAutoresizingMaskIntoConstraints = false
        expandedStack.orientation = .horizontal
        expandedStack.spacing = 2
        expandedStack.alignment = .centerY
        expandedStack.alphaValue = 0

        let items: [(symbol: String, tooltip: String, action: Selector)] = [
            ("terminal", "New Terminal", #selector(terminalTapped)),
            ("globe", "New Browser", #selector(browserTapped)),
            ("folder", "New Project", #selector(projectTapped)),
            ("doc.text", "New File", #selector(fileTapped)),
        ]

        for item in items {
            let btn = NSButton()
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.bezelStyle = .texturedRounded
            btn.isBordered = false
            btn.title = ""
            let btnCfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            btn.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.tooltip)?.withSymbolConfiguration(btnCfg)
            btn.contentTintColor = NSColor(white: 0.45, alpha: 1.0)
            btn.target = self
            btn.action = item.action
            btn.toolTip = item.tooltip
            let btnWidth = btn.widthAnchor.constraint(equalToConstant: 22)
            btnWidth.priority = .defaultHigh
            NSLayoutConstraint.activate([
                btnWidth,
                btn.heightAnchor.constraint(equalToConstant: 22),
            ])
            // Hover highlight per button
            let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: btn)
            btn.addTrackingArea(area)
            expandedStack.addArrangedSubview(btn)
        }

        addSubview(expandedStack)

        widthConstraint = widthAnchor.constraint(equalToConstant: collapsedWidth)

        let stackCenterX = expandedStack.centerXAnchor.constraint(equalTo: centerXAnchor)
        stackCenterX.priority = .defaultHigh

        let stackLeading = expandedStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2)
        stackLeading.priority = .defaultHigh

        let stackTrailing = expandedStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2)
        stackTrailing.priority = .defaultHigh

        NSLayoutConstraint.activate([
            widthConstraint,

            plusIcon.centerXAnchor.constraint(equalTo: centerXAnchor),
            plusIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            plusIcon.widthAnchor.constraint(equalToConstant: 14),
            plusIcon.heightAnchor.constraint(equalToConstant: 14),

            stackLeading,
            stackTrailing,
            stackCenterX,
            expandedStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // MARK: - Hover

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
        collapseTimer?.invalidate()
        collapseTimer = nil
        guard !isExpanded else { return }
        isExpanded = true

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            self.widthConstraint.animator().constant = self.expandedWidth
            self.plusIcon.animator().alphaValue = 0
            self.expandedStack.animator().alphaValue = 1
            self.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        // Delay collapse so moving between buttons doesn't flicker
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.collapse()
        }
    }

    private func collapse() {
        guard isExpanded else { return }
        isExpanded = false

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            self.widthConstraint.animator().constant = self.collapsedWidth
            self.plusIcon.animator().alphaValue = 1
            self.expandedStack.animator().alphaValue = 0
            self.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    // MARK: - Actions

    @objc private func terminalTapped() { onNewTerminal?() }
    @objc private func browserTapped() { onNewBrowser?() }
    @objc private func projectTapped() { onNewProject?() }
    @objc private func fileTapped() { onNewFile?() }
}

// MARK: - Tab Item

class WorkspaceTabItem: NSView {
    var index: Int
    private(set) var isSelected: Bool
    let currentTitle: String

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onStartRename: ((Int) -> Void)?
    var onDragBegan: ((Int, NSPoint) -> Void)?
    var onDragMoved: ((Int, NSPoint) -> Void)?
    var onDragEnded: ((Int, NSPoint) -> Void)?
    var contextMenuProvider: ((Int) -> NSMenu)?

    private let activeColor = NSColor(red: 0.16, green: 0.16, blue: 0.175, alpha: 1.0)
    private let hoverColor = NSColor(red: 0.14, green: 0.14, blue: 0.155, alpha: 1.0)
    private let selectedTextColor = NSColor(white: 0.92, alpha: 1.0)
    private let unselectedTextColor = NSColor(white: 0.5, alpha: 1.0)
    private var closeButton: NSButton!
    private var iconView: NSImageView!
    private var titleLabel: NSTextField!
    private var indicatorView: NSView?
    private var hasFavicon: Bool = false
    private var isDragging = false
    private var didSelect = false
    private var dragStartLocation: NSPoint = .zero
    private var originalIndex: Int

    init(tab: WorkspaceTab, index: Int, isSelected: Bool) {
        self.index = index
        self.originalIndex = index
        self.isSelected = isSelected
        self.currentTitle = tab.title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = isSelected ? activeColor.cgColor : NSColor.clear.cgColor

        let textColor = isSelected ? selectedTextColor : unselectedTextColor

        // Type icon — use favicon for browser tabs when available
        iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        if let favicon = tab.favicon {
            iconView.image = favicon
            iconView.imageScaling = .scaleProportionallyDown
            hasFavicon = true
        } else {
            let iconCfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            let iconName = (tab.view as? TerminalSurface)?.programIcon ?? tab.type.icon
            iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?.withSymbolConfiguration(iconCfg)
            iconView.contentTintColor = textColor
        }
        addSubview(iconView)

        // Split icon (shown when tab has multiple panes)
        var splitIconView: NSImageView?
        if tab.isSplit {
            let sIcon = NSImageView()
            sIcon.translatesAutoresizingMaskIntoConstraints = false
            let sCfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
            sIcon.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Split")?.withSymbolConfiguration(sCfg)
            sIcon.contentTintColor = NSColor.controlAccentColor.withAlphaComponent(0.7)
            addSubview(sIcon)
            splitIconView = sIcon

            NSLayoutConstraint.activate([
                sIcon.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 3),
                sIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
                sIcon.widthAnchor.constraint(equalToConstant: 12),
                sIcon.heightAnchor.constraint(equalToConstant: 12),
            ])
        }

        // Title — show split description when tab is split
        let displayTitle = tab.isSplit ? tab.splitDescription : tab.title
        titleLabel = NSTextField(labelWithString: displayTitle)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 11, weight: isSelected ? .medium : .regular)
        titleLabel.textColor = textColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        // Close button
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

        // Blue indicator line (always created, hidden when not selected)
        let indicator = NSView()
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        indicator.layer?.cornerRadius = 1
        indicator.isHidden = !isSelected
        addSubview(indicator)
        indicatorView = indicator

        let titleLeading: NSLayoutConstraint
        if let sIcon = splitIconView {
            titleLeading = titleLabel.leadingAnchor.constraint(equalTo: sIcon.trailingAnchor, constant: 3)
        } else {
            titleLeading = titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5)
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            heightAnchor.constraint(equalToConstant: 28),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            titleLeading,
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14),

            indicator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            indicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 16),
            indicator.heightAnchor.constraint(equalToConstant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func closeTapped() { onClose?(index) }

    /// Update all visual state to reflect selection change.
    func setSelected(_ selected: Bool) {
        guard selected != isSelected else { return }
        isSelected = selected
        applySelectionStyle()
    }

    /// Apply all visual properties based on current isSelected state.
    private func applySelectionStyle() {
        let textColor = isSelected ? selectedTextColor : unselectedTextColor
        layer?.backgroundColor = isSelected ? activeColor.cgColor : NSColor.clear.cgColor
        titleLabel.textColor = textColor
        titleLabel.font = .systemFont(ofSize: 11, weight: isSelected ? .medium : .regular)
        if !hasFavicon {
            iconView.contentTintColor = textColor
        }
        closeButton.alphaValue = isSelected ? 0.8 : 0.0
        indicatorView?.isHidden = !isSelected
    }

    /// Update icon when terminal program changes (e.g. Claude Code detected)
    func updateIcon(for tab: WorkspaceTab) {
        let iconName = (tab.view as? TerminalSurface)?.programIcon ?? tab.type.icon
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }

    /// Update title and optionally icon without rebuilding the view.
    func updateContent(title: String, icon: String?) {
        titleLabel.stringValue = title
        if let icon {
            let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Mouse handling

    override func mouseDown(with event: NSEvent) {
        dragStartLocation = event.locationInWindow
        isDragging = false
        didSelect = false
        originalIndex = index

        // Check close button
        let point = convert(event.locationInWindow, from: nil)
        if closeButton.frame.contains(point) { return }

        // Double-click = rename
        if event.clickCount == 2 {
            onStartRename?(index)
            return
        }

        // Don't select immediately — wait for mouseUp so dragging doesn't
        // make this tab active (which would break drag-to-split)
    }

    override func mouseDragged(with event: NSEvent) {
        let dx = abs(event.locationInWindow.x - dragStartLocation.x)
        let dy = abs(event.locationInWindow.y - dragStartLocation.y)
        // Lower threshold (3px) for easier drag initiation, especially vertical drags for splitting
        if dx > 3 || dy > 3 {
            if !isDragging {
                isDragging = true
                onDragBegan?(originalIndex, event.locationInWindow)
                layer?.opacity = 0.7
            }
            onDragMoved?(index, event.locationInWindow)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            layer?.opacity = 1.0
            isDragging = false
            onDragEnded?(originalIndex, event.locationInWindow)
        } else if !didSelect {
            // Simple click (no drag) — select the tab now
            onSelect?(index)
        }
        didSelect = false
    }

    // MARK: - Right-click

    override func rightMouseDown(with event: NSEvent) {
        if let menu = contextMenuProvider?(index) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        if !isSelected { layer?.backgroundColor = hoverColor.cgColor }
        closeButton.alphaValue = 0.8
    }

    override func mouseExited(with event: NSEvent) {
        if !isSelected { layer?.backgroundColor = NSColor.clear.cgColor }
        if !isSelected { closeButton.alphaValue = 0.0 }
    }
}
