import AppKit

/// Manages split pane layout within a workspace.
/// Supports recursive horizontal and vertical splits.
class PaneContainerView: NSView {
    private var splitTree: SplitNode?
    private weak var _focusedPane: NSView?
    private var focusBorderLayer: CALayer?
    private var paneHeaders: [NSView: PaneHeaderBar] = [:]

    /// Called when the user clicks the close button on a pane.
    var onClosePane: ((NSView) -> Void)?

    /// Called when a pane header is dragged. Provides the pane view and window point.
    var onPaneDragBegan: ((NSView) -> Void)?
    var onPaneDragMoved: ((NSView, NSPoint) -> Void)?
    var onPaneDragEnded: ((NSView, NSPoint) -> Void)?

    var focusedPane: NSView? {
        get { _focusedPane }
        set {
            _focusedPane = newValue
            updateFocusIndicator()
            updateHeaderStates()
        }
    }

    override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func setRoot(_ view: NSView) {
        subviews.forEach { $0.removeFromSuperview() }
        paneHeaders.removeAll()
        splitTree = .leaf(view)
        _focusedPane = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func split(view existing: NSView, with newView: NSView, direction: SplitDirection) {
        guard let tree = splitTree else { return }
        splitTree = tree.split(target: existing, newView: newView, direction: direction)
        rebuildLayout()
    }

    /// Split at the root level — wraps the entire existing split tree with a new pane.
    /// The new pane is placed in the given direction relative to the existing content.
    func splitRoot(with newView: NSView, direction: SplitDirection) {
        guard let oldTree = splitTree else { return }
        switch direction {
        case .right, .down:
            splitTree = .split(first: oldTree, second: .leaf(newView), direction: direction, ratio: 0.5)
        case .left, .up:
            splitTree = .split(first: .leaf(newView), second: oldTree, direction: direction, ratio: 0.5)
        }
        rebuildLayout()
    }

    /// Remove a pane from the split tree. Its sibling takes over.
    func removePaneAndCollapse(_ view: NSView) {
        guard let tree = splitTree else { return }
        if let newTree = tree.remove(target: view) {
            splitTree = newTree
        }
        view.removeFromSuperview()
        rebuildLayout()
    }

    /// Returns all leaf views in the split tree.
    var allLeafViews: [NSView] {
        guard let tree = splitTree else { return [] }
        return tree.allViews
    }

    /// Returns all TerminalSurface views in the split tree.
    func allTerminalSurfaces() -> [TerminalSurface] {
        guard let tree = splitTree else { return [] }
        return tree.allViews.compactMap { $0 as? TerminalSurface }
    }

    /// Number of leaf panes.
    var leafCount: Int {
        guard let tree = splitTree else { return 0 }
        return tree.leafCount
    }

    /// Navigate to the next/previous pane in the given direction.
    func navigateFocus(_ direction: SplitDirection) -> NSView? {
        let leaves = allLeafViews
        guard leaves.count > 1, let current = _focusedPane,
              let idx = leaves.firstIndex(where: { $0 === current }) else { return nil }

        let newIndex: Int
        switch direction {
        case .right, .down:
            newIndex = (idx + 1) % leaves.count
        case .left, .up:
            newIndex = (idx - 1 + leaves.count) % leaves.count
        }
        let target = leaves[newIndex]
        focusedPane = target
        return target
    }

    /// Find which leaf pane contains the given window point, and return its frame in our coordinate space.
    func paneAt(windowPoint: NSPoint) -> (pane: NSView, frame: NSRect)? {
        let localPoint = convert(windowPoint, from: nil)
        for leaf in allLeafViews {
            // The leaf is inside a wrapper (header + pane) when split
            let wrapper = paneHeaders[leaf]?.superview ?? leaf
            guard let wrapperFrame = wrapper.superview?.convert(wrapper.frame, to: self) else { continue }
            if wrapperFrame.contains(localPoint) {
                return (leaf, wrapperFrame)
            }
        }
        return nil
    }

    // MARK: - Pane Headers

    private func updateHeaderStates() {
        for (pane, header) in paneHeaders {
            header.isFocused = pane === _focusedPane
        }
    }

    // MARK: - Focus Indicator

    private func updateFocusIndicator() {
        focusBorderLayer?.removeFromSuperlayer()
        focusBorderLayer = nil

        guard leafCount > 1, let focused = _focusedPane else { return }

        // Find the header's wrapper view for the focused pane
        guard let header = paneHeaders[focused] else { return }
        guard let wrapper = header.superview else { return }

        wrapper.wantsLayer = true
        let border = CALayer()
        border.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor
        border.borderWidth = 1.5
        border.cornerRadius = 2
        border.frame = wrapper.bounds
        border.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        wrapper.layer?.addSublayer(border)
        focusBorderLayer = border
    }

    override func layout() {
        super.layout()
        updateFocusIndicator()
    }

    // MARK: - Layout

    private func rebuildLayout() {
        subviews.forEach { $0.removeFromSuperview() }
        paneHeaders.removeAll()
        guard let tree = splitTree else { return }

        let showHeaders = tree.leafCount > 1
        let container = tree.buildView(showHeaders: showHeaders, onClose: { [weak self] pane in
            self?.onClosePane?(pane)
        }, headerRegistry: &paneHeaders)

        // Wire drag callbacks on all headers
        for (pane, header) in paneHeaders {
            let capturedPane = pane
            header.onDragBegan = { [weak self] in
                self?.onPaneDragBegan?(capturedPane)
            }
            header.onDragMoved = { [weak self] point in
                self?.onPaneDragMoved?(capturedPane, point)
            }
            header.onDragEnded = { [weak self] point in
                self?.onPaneDragEnded?(capturedPane, point)
            }
        }

        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateHeaderStates()
        updateFocusIndicator()
    }
}

// MARK: - Pane Header Bar

/// Small header strip at the top of each split pane with a label and close button.
class PaneHeaderBar: NSView {
    private let label = NSTextField(labelWithString: "")
    private let closeBtn = NSButton()
    private let iconView = NSImageView()
    let paneView: NSView

    private let bgColor = NSColor(red: 0.1, green: 0.1, blue: 0.115, alpha: 1.0)
    private let focusBgColor = NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0)

    var isFocused: Bool = false {
        didSet {
            layer?.backgroundColor = isFocused ? focusBgColor.cgColor : bgColor.cgColor
            label.textColor = isFocused ? NSColor(white: 0.8, alpha: 1.0) : NSColor(white: 0.5, alpha: 1.0)
            iconView.contentTintColor = label.textColor
        }
    }

    var onClose: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?

    private var dragStartPoint: NSPoint = .zero
    private var isDragging = false

    init(paneView: NSView) {
        self.paneView = paneView
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = bgColor.cgColor

        // Icon
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let (symbolName, titleText) = PaneHeaderBar.info(for: paneView)
        let iconCfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(iconCfg)
        iconView.contentTintColor = NSColor(white: 0.5, alpha: 1.0)
        addSubview(iconView)

        // Label
        label.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = titleText
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = NSColor(white: 0.5, alpha: 1.0)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        // Close button
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.bezelStyle = .texturedRounded
        closeBtn.isBordered = false
        closeBtn.title = ""
        let closeCfg = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        closeBtn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Pane")?.withSymbolConfiguration(closeCfg)
        closeBtn.contentTintColor = NSColor(white: 0.4, alpha: 1.0)
        closeBtn.target = self
        closeBtn.action = #selector(closeTapped)
        addSubview(closeBtn)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 12),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: closeBtn.leadingAnchor, constant: -4),

            closeBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeBtn.widthAnchor.constraint(equalToConstant: 16),
            closeBtn.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    @objc private func closeTapped() {
        onClose?()
    }

    // MARK: - Drag to re-split / unsplit

    override func mouseDown(with event: NSEvent) {
        dragStartPoint = event.locationInWindow
        isDragging = false
        // Check if click is on close button — if so, let it handle it
        let local = convert(event.locationInWindow, from: nil)
        if closeBtn.frame.contains(local) {
            super.mouseDown(with: event)
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let dx = abs(event.locationInWindow.x - dragStartPoint.x)
        let dy = abs(event.locationInWindow.y - dragStartPoint.y)
        if dx > 4 || dy > 4 {
            if !isDragging {
                isDragging = true
                superview?.layer?.opacity = 0.5
                onDragBegan?()
            }
            onDragMoved?(event.locationInWindow)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            superview?.layer?.opacity = 1.0
            isDragging = false
            onDragEnded?(event.locationInWindow)
        }
    }

    static func info(for view: NSView) -> (icon: String, title: String) {
        if let terminal = view as? TerminalSurface {
            return ("terminal", terminal.title.isEmpty ? "Terminal" : terminal.title)
        } else if let browser = view as? BrowserPanel {
            return ("globe", browser.title.isEmpty ? "Browser" : browser.title)
        } else if let editor = view as? EditorPanel {
            return ("doc.text", editor.title)
        } else if let pdf = view as? PDFPanel {
            return ("doc.richtext", pdf.title.isEmpty ? "PDF" : pdf.title)
        }
        return ("square", "Pane")
    }
}

// MARK: - Split Tree

/// A binary tree representing the split layout.
indirect enum SplitNode {
    case leaf(NSView)
    case split(first: SplitNode, second: SplitNode, direction: SplitDirection, ratio: CGFloat)

    func split(target: NSView, newView: NSView, direction: SplitDirection) -> SplitNode {
        switch self {
        case .leaf(let view) where view === target:
            return .split(first: .leaf(view), second: .leaf(newView), direction: direction, ratio: 0.5)
        case .leaf:
            return self
        case .split(let first, let second, let dir, let ratio):
            return .split(
                first: first.split(target: target, newView: newView, direction: direction),
                second: second.split(target: target, newView: newView, direction: direction),
                direction: dir,
                ratio: ratio
            )
        }
    }

    /// Remove a leaf from the tree. Returns nil if this node is the target leaf.
    func remove(target: NSView) -> SplitNode? {
        switch self {
        case .leaf(let view) where view === target:
            return nil
        case .leaf:
            return self
        case .split(let first, let second, let dir, let ratio):
            let newFirst = first.remove(target: target)
            let newSecond = second.remove(target: target)
            if newFirst == nil { return second }
            if newSecond == nil { return first }
            return .split(first: newFirst!, second: newSecond!, direction: dir, ratio: ratio)
        }
    }

    func buildView(showHeaders: Bool = false, onClose: ((NSView) -> Void)? = nil, headerRegistry: inout [NSView: PaneHeaderBar]) -> NSView {
        switch self {
        case .leaf(let view):
            if showHeaders {
                // Wrap the pane in a container with a header bar
                let wrapper = NSView()
                wrapper.translatesAutoresizingMaskIntoConstraints = false
                wrapper.wantsLayer = true

                let header = PaneHeaderBar(paneView: view)
                header.onClose = { onClose?(view) }
                headerRegistry[view] = header

                view.translatesAutoresizingMaskIntoConstraints = false
                wrapper.addSubview(header)
                wrapper.addSubview(view)

                NSLayoutConstraint.activate([
                    header.topAnchor.constraint(equalTo: wrapper.topAnchor),
                    header.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
                    header.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),

                    view.topAnchor.constraint(equalTo: header.bottomAnchor),
                    view.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
                    view.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
                    view.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
                ])

                return wrapper
            } else {
                view.translatesAutoresizingMaskIntoConstraints = false
                return view
            }

        case .split(let first, let second, let direction, let ratio):
            let container = NSSplitView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.dividerStyle = .thin
            container.isVertical = direction.isHorizontal
            container.wantsLayer = true

            let firstView = first.buildView(showHeaders: showHeaders, onClose: onClose, headerRegistry: &headerRegistry)
            let secondView = second.buildView(showHeaders: showHeaders, onClose: onClose, headerRegistry: &headerRegistry)
            container.addSubview(firstView)
            container.addSubview(secondView)

            DispatchQueue.main.async {
                let totalSize = direction.isHorizontal ? container.bounds.width : container.bounds.height
                if totalSize > 0 {
                    container.setPosition(totalSize * ratio, ofDividerAt: 0)
                }
            }

            return container
        }
    }

    var allViews: [NSView] {
        switch self {
        case .leaf(let view):
            return [view]
        case .split(let first, let second, _, _):
            return first.allViews + second.allViews
        }
    }

    var leafCount: Int {
        switch self {
        case .leaf: return 1
        case .split(let first, let second, _, _): return first.leafCount + second.leafCount
        }
    }
}
