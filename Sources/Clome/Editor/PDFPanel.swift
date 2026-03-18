import AppKit
import PDFKit

// MARK: - Notification Names

extension Notification.Name {
    static let pdfShowFindBar = Notification.Name("clomePDFShowFindBar")
    static let pdfDismissFindBar = Notification.Name("clomePDFDismissFindBar")
}

// MARK: - PDFPanel

/// A fast, clean PDF viewer panel that can be placed in any split pane.
/// Features: toolbar with navigation/zoom, outline sidebar, find bar, status bar, keyboard shortcuts.
class PDFPanel: NSView {

    // MARK: - Subviews

    private let pdfView = PDFView()
    private var toolbarView: NSView!
    private var statusBarView: NSView!
    private var outlineSidebar: PDFOutlineSidebarView?
    private var findBar: PDFFindBarView?

    // Toolbar controls
    private var fileNameLabel: NSTextField!
    private var pageLabel: NSTextField!
    private var prevPageButton: NSButton!
    private var nextPageButton: NSButton!
    private var zoomOutButton: NSButton!
    private var zoomInButton: NSButton!
    private var zoomLabel: NSTextField!
    private var fitWidthButton: NSButton!
    private var fitPageButton: NSButton!
    private var displayModeButton: NSButton!
    private var outlineButton: NSButton!

    // Status bar
    private var statusPageLabel: NSTextField!
    private var statusZoomLabel: NSTextField!
    private var statusFileSizeLabel: NSTextField!
    private var statusPageCountLabel: NSTextField!

    // Layout
    private var pdfLeadingToSidebar: NSLayoutConstraint?
    private var pdfLeadingToSuperview: NSLayoutConstraint!
    private var findBarContainer: NSView?
    private var pdfTopToToolbar: NSLayoutConstraint!
    private var pdfTopToFindBar: NSLayoutConstraint?

    // State
    private(set) var filePath: String?
    private var isOutlineVisible = false

    var title: String = "PDF" {
        didSet {
            NotificationCenter.default.post(name: .terminalSurfaceTitleChanged, object: self)
        }
    }

    // MARK: - Colors

    private let bgColor = NSColor(red: 0.055, green: 0.055, blue: 0.07, alpha: 1.0)
    private let toolbarBg = NSColor(white: 0.08, alpha: 1.0)
    private let statusBg = NSColor(white: 0.08, alpha: 1.0)
    private let dimText = NSColor(white: 0.50, alpha: 1.0)
    private let brightText = NSColor(white: 0.80, alpha: 1.0)
    private let accentColor = NSColor(red: 0.4, green: 0.6, blue: 1.0, alpha: 1.0)

    // MARK: - Init

    override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = bgColor.cgColor
        setupToolbar()
        setupPDFView()
        setupStatusBar()
        setupLayout()
        setupNotifications()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Accept First Responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        return true
    }

    // MARK: - Setup

    private func setupToolbar() {
        toolbarView = NSView()
        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.wantsLayer = true
        toolbarView.layer?.backgroundColor = toolbarBg.cgColor
        addSubview(toolbarView)

        // Outline toggle (left side)
        outlineButton = makeToolbarButton(symbol: "sidebar.left", tooltip: "Toggle Outline (⌘\\)")
        outlineButton.target = self
        outlineButton.action = #selector(toggleOutline)
        toolbarView.addSubview(outlineButton)

        // File name
        fileNameLabel = NSTextField(labelWithString: "PDF")
        fileNameLabel.translatesAutoresizingMaskIntoConstraints = false
        fileNameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        fileNameLabel.textColor = brightText
        fileNameLabel.lineBreakMode = .byTruncatingMiddle
        fileNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolbarView.addSubview(fileNameLabel)

        // Page navigation (center)
        prevPageButton = makeToolbarButton(symbol: "chevron.left", tooltip: "Previous Page (↑)")
        prevPageButton.target = self
        prevPageButton.action = #selector(goToPreviousPage)
        toolbarView.addSubview(prevPageButton)

        pageLabel = NSTextField(labelWithString: "Page 0 of 0")
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        pageLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pageLabel.textColor = dimText
        pageLabel.alignment = .center
        toolbarView.addSubview(pageLabel)

        nextPageButton = makeToolbarButton(symbol: "chevron.right", tooltip: "Next Page (↓)")
        nextPageButton.target = self
        nextPageButton.action = #selector(goToNextPage)
        toolbarView.addSubview(nextPageButton)

        // Zoom controls (right side)
        zoomOutButton = makeToolbarButton(symbol: "minus.magnifyingglass", tooltip: "Zoom Out (⌘-)")
        zoomOutButton.target = self
        zoomOutButton.action = #selector(zoomOut)
        toolbarView.addSubview(zoomOutButton)

        zoomLabel = NSTextField(labelWithString: "100%")
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        zoomLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        zoomLabel.textColor = dimText
        zoomLabel.alignment = .center
        toolbarView.addSubview(zoomLabel)

        zoomInButton = makeToolbarButton(symbol: "plus.magnifyingglass", tooltip: "Zoom In (⌘+)")
        zoomInButton.target = self
        zoomInButton.action = #selector(zoomIn)
        toolbarView.addSubview(zoomInButton)

        fitWidthButton = makeToolbarButton(symbol: "arrow.left.and.right", tooltip: "Fit Width")
        fitWidthButton.target = self
        fitWidthButton.action = #selector(fitWidth)
        toolbarView.addSubview(fitWidthButton)

        fitPageButton = makeToolbarButton(symbol: "arrow.up.left.and.arrow.down.right", tooltip: "Fit Page")
        fitPageButton.target = self
        fitPageButton.action = #selector(fitPage)
        toolbarView.addSubview(fitPageButton)

        displayModeButton = makeToolbarButton(symbol: "rectangle.split.1x2", tooltip: "Toggle Continuous Scroll")
        displayModeButton.target = self
        displayModeButton.action = #selector(toggleDisplayMode)
        toolbarView.addSubview(displayModeButton)
    }

    private func setupPDFView() {
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = bgColor
        pdfView.interpolationQuality = .high
        addSubview(pdfView)
    }

    private func setupStatusBar() {
        statusBarView = NSView()
        statusBarView.translatesAutoresizingMaskIntoConstraints = false
        statusBarView.wantsLayer = true
        statusBarView.layer?.backgroundColor = statusBg.cgColor
        addSubview(statusBarView)

        let statusFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        statusPageLabel = NSTextField(labelWithString: "")
        statusPageLabel.translatesAutoresizingMaskIntoConstraints = false
        statusPageLabel.font = statusFont
        statusPageLabel.textColor = dimText
        statusBarView.addSubview(statusPageLabel)

        statusZoomLabel = NSTextField(labelWithString: "")
        statusZoomLabel.translatesAutoresizingMaskIntoConstraints = false
        statusZoomLabel.font = statusFont
        statusZoomLabel.textColor = dimText
        statusBarView.addSubview(statusZoomLabel)

        statusFileSizeLabel = NSTextField(labelWithString: "")
        statusFileSizeLabel.translatesAutoresizingMaskIntoConstraints = false
        statusFileSizeLabel.font = statusFont
        statusFileSizeLabel.textColor = dimText
        statusBarView.addSubview(statusFileSizeLabel)

        statusPageCountLabel = NSTextField(labelWithString: "")
        statusPageCountLabel.translatesAutoresizingMaskIntoConstraints = false
        statusPageCountLabel.font = statusFont
        statusPageCountLabel.textColor = dimText
        statusBarView.addSubview(statusPageCountLabel)
    }

    private func setupLayout() {
        pdfLeadingToSuperview = pdfView.leadingAnchor.constraint(equalTo: leadingAnchor)
        pdfTopToToolbar = pdfView.topAnchor.constraint(equalTo: toolbarView.bottomAnchor)

        NSLayoutConstraint.activate([
            // Toolbar
            toolbarView.topAnchor.constraint(equalTo: topAnchor),
            toolbarView.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarView.heightAnchor.constraint(equalToConstant: 36),

            // Toolbar contents — left group
            outlineButton.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor, constant: 8),
            outlineButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            fileNameLabel.leadingAnchor.constraint(equalTo: outlineButton.trailingAnchor, constant: 8),
            fileNameLabel.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            fileNameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 200),

            // Toolbar contents — center (page nav)
            pageLabel.centerXAnchor.constraint(equalTo: toolbarView.centerXAnchor),
            pageLabel.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            pageLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),

            prevPageButton.trailingAnchor.constraint(equalTo: pageLabel.leadingAnchor, constant: -4),
            prevPageButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            nextPageButton.leadingAnchor.constraint(equalTo: pageLabel.trailingAnchor, constant: 4),
            nextPageButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            // Toolbar contents — right (zoom + display)
            displayModeButton.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor, constant: -8),
            displayModeButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            fitPageButton.trailingAnchor.constraint(equalTo: displayModeButton.leadingAnchor, constant: -4),
            fitPageButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            fitWidthButton.trailingAnchor.constraint(equalTo: fitPageButton.leadingAnchor, constant: -4),
            fitWidthButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            zoomInButton.trailingAnchor.constraint(equalTo: fitWidthButton.leadingAnchor, constant: -8),
            zoomInButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            zoomLabel.trailingAnchor.constraint(equalTo: zoomInButton.leadingAnchor, constant: -4),
            zoomLabel.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            zoomLabel.widthAnchor.constraint(equalToConstant: 44),

            zoomOutButton.trailingAnchor.constraint(equalTo: zoomLabel.leadingAnchor, constant: -4),
            zoomOutButton.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            // PDF View
            pdfTopToToolbar,
            pdfLeadingToSuperview,
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: statusBarView.topAnchor),

            // Status bar
            statusBarView.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBarView.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBarView.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusBarView.heightAnchor.constraint(equalToConstant: 22),

            // Status bar contents
            statusPageLabel.leadingAnchor.constraint(equalTo: statusBarView.leadingAnchor, constant: 10),
            statusPageLabel.centerYAnchor.constraint(equalTo: statusBarView.centerYAnchor),

            statusZoomLabel.leadingAnchor.constraint(equalTo: statusPageLabel.trailingAnchor, constant: 16),
            statusZoomLabel.centerYAnchor.constraint(equalTo: statusBarView.centerYAnchor),

            statusPageCountLabel.trailingAnchor.constraint(equalTo: statusBarView.trailingAnchor, constant: -10),
            statusPageCountLabel.centerYAnchor.constraint(equalTo: statusBarView.centerYAnchor),

            statusFileSizeLabel.trailingAnchor.constraint(equalTo: statusPageCountLabel.leadingAnchor, constant: -16),
            statusFileSizeLabel.centerYAnchor.constraint(equalTo: statusBarView.centerYAnchor),
        ])
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(pageChanged(_:)),
            name: .PDFViewPageChanged, object: pdfView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(scaleChanged(_:)),
            name: .PDFViewScaleChanged, object: pdfView
        )
    }

    // MARK: - Toolbar Button Factory

    private func makeToolbarButton(symbol: String, tooltip: String) -> NSButton {
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.contentTintColor = dimText
        button.toolTip = tooltip
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true

        // Hover effect
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: button, userInfo: nil
        )
        button.addTrackingArea(area)

        return button
    }

    // MARK: - Load PDF

    func loadPDF(at path: String) {
        let url = URL(fileURLWithPath: path)
        guard let document = PDFDocument(url: url) else { return }
        loadDocument(document, path: path)
    }

    func loadPDF(url: URL) {
        guard let document = PDFDocument(url: url) else { return }
        loadDocument(document, path: url.path)
    }

    private func loadDocument(_ document: PDFDocument, path: String) {
        pdfView.document = document
        filePath = path
        title = (path as NSString).lastPathComponent
        fileNameLabel.stringValue = title

        // File size
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? UInt64 {
            statusFileSizeLabel.stringValue = formatFileSize(size)
        }

        // Page count
        let count = document.pageCount
        statusPageCountLabel.stringValue = "\(count) page\(count == 1 ? "" : "s")"

        // Outline button state
        outlineButton.isEnabled = document.outlineRoot != nil &&
            (document.outlineRoot?.numberOfChildren ?? 0) > 0

        updatePageInfo()
        updateZoomInfo()
    }

    // MARK: - Page Navigation

    @objc private func goToPreviousPage() {
        pdfView.goToPreviousPage(nil)
    }

    @objc private func goToNextPage() {
        pdfView.goToNextPage(nil)
    }

    @objc private func pageChanged(_ notification: Notification) {
        updatePageInfo()
    }

    private func updatePageInfo() {
        guard let doc = pdfView.document, let page = pdfView.currentPage else {
            pageLabel.stringValue = "Page 0 of 0"
            statusPageLabel.stringValue = ""
            return
        }
        let current = doc.index(for: page) + 1
        let total = doc.pageCount
        pageLabel.stringValue = "Page \(current) of \(total)"
        statusPageLabel.stringValue = "Page \(current)/\(total)"

        prevPageButton.isEnabled = pdfView.canGoToPreviousPage
        nextPageButton.isEnabled = pdfView.canGoToNextPage
    }

    // MARK: - Zoom

    @objc private func zoomIn() {
        pdfView.zoomIn(nil)
        updateZoomInfo()
    }

    @objc private func zoomOut() {
        pdfView.zoomOut(nil)
        updateZoomInfo()
    }

    @objc private func fitWidth() {
        pdfView.autoScales = false
        pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit
        // Fit width: scale based on view width vs page width
        if let page = pdfView.currentPage {
            let pageWidth = page.bounds(for: pdfView.displayBox).width
            let viewWidth = pdfView.bounds.width - 20 // margin
            pdfView.scaleFactor = viewWidth / pageWidth
        }
        updateZoomInfo()
    }

    @objc private func fitPage() {
        pdfView.autoScales = true
        updateZoomInfo()
    }

    @objc private func scaleChanged(_ notification: Notification) {
        updateZoomInfo()
    }

    private func updateZoomInfo() {
        let percent = Int(pdfView.scaleFactor * 100)
        zoomLabel.stringValue = "\(percent)%"
        statusZoomLabel.stringValue = "Zoom \(percent)%"
    }

    // MARK: - Display Mode

    @objc private func toggleDisplayMode() {
        switch pdfView.displayMode {
        case .singlePageContinuous:
            pdfView.displayMode = .singlePage
            displayModeButton.image = NSImage(
                systemSymbolName: "rectangle.split.1x2",
                accessibilityDescription: "Continuous Scroll"
            )
            displayModeButton.toolTip = "Switch to Continuous Scroll"
        case .singlePage:
            pdfView.displayMode = .twoUpContinuous
            displayModeButton.image = NSImage(
                systemSymbolName: "rectangle.split.2x1",
                accessibilityDescription: "Two-Up"
            )
            displayModeButton.toolTip = "Switch to Single Page"
        case .twoUpContinuous:
            pdfView.displayMode = .singlePageContinuous
            displayModeButton.image = NSImage(
                systemSymbolName: "rectangle",
                accessibilityDescription: "Single Page"
            )
            displayModeButton.toolTip = "Switch to Continuous Scroll"
        default:
            pdfView.displayMode = .singlePageContinuous
        }
    }

    // MARK: - Outline Sidebar

    @objc private func toggleOutline() {
        if isOutlineVisible {
            hideOutline()
        } else {
            showOutline()
        }
    }

    private func showOutline() {
        guard let root = pdfView.document?.outlineRoot, root.numberOfChildren > 0 else { return }

        let sidebar = PDFOutlineSidebarView(outline: root) { [weak self] destination in
            if let destination = destination {
                self?.pdfView.go(to: destination)
            }
        }
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sidebar)

        pdfLeadingToSuperview.isActive = false
        pdfLeadingToSidebar = pdfView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: statusBarView.topAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 220),
            pdfLeadingToSidebar!,
        ])

        outlineSidebar = sidebar
        isOutlineVisible = true
        outlineButton.contentTintColor = accentColor
    }

    private func hideOutline() {
        outlineSidebar?.removeFromSuperview()
        outlineSidebar = nil
        pdfLeadingToSidebar?.isActive = false
        pdfLeadingToSidebar = nil
        pdfLeadingToSuperview.isActive = true
        isOutlineVisible = false
        outlineButton.contentTintColor = dimText
    }

    // MARK: - Find Bar

    private func showFindBar() {
        guard findBar == nil else {
            findBar?.focus()
            return
        }

        let bar = PDFFindBarView(pdfView: pdfView)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.onDismiss = { [weak self] in
            self?.hideFindBar()
        }
        addSubview(bar)

        pdfTopToToolbar.isActive = false
        pdfTopToFindBar = pdfView.topAnchor.constraint(equalTo: bar.bottomAnchor)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: pdfView.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 36),
            pdfTopToFindBar!,
        ])

        findBar = bar
        bar.focus()
    }

    private func hideFindBar() {
        findBar?.removeFromSuperview()
        findBar = nil
        pdfTopToFindBar?.isActive = false
        pdfTopToFindBar = nil
        pdfTopToToolbar.isActive = true
        window?.makeFirstResponder(self)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)

        switch event.keyCode {
        case 126: // Up arrow
            if !cmd { pdfView.goToPreviousPage(nil) }
        case 125: // Down arrow
            if !cmd { pdfView.goToNextPage(nil) }
        case 49: // Space
            if flags.contains(.shift) {
                pdfView.goToPreviousPage(nil)
            } else {
                pdfView.goToNextPage(nil)
            }
        case 24, 69: // ⌘+ (= key or numpad +)
            if cmd { zoomIn() }
        case 27, 78: // ⌘- (- key or numpad -)
            if cmd { zoomOut() }
        case 29: // ⌘0
            if cmd { fitPage() }
        case 3: // ⌘F
            if cmd { showFindBar() }
        case 42: // ⌘\ (backslash)
            if cmd { toggleOutline() }
        case 53: // Escape
            if findBar != nil { hideFindBar() }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Helpers

    private func formatFileSize(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 {
            return String(format: "%.0f KB", kb)
        }
        let mb = kb / 1024
        if mb < 1024 {
            return String(format: "%.1f MB", mb)
        }
        let gb = mb / 1024
        return String(format: "%.2f GB", gb)
    }
}

// MARK: - PDFOutlineSidebarView

/// Sidebar showing the PDF's table of contents / outline.
private class PDFOutlineSidebarView: NSView {
    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private let root: PDFOutline
    private let onSelect: (PDFDestination?) -> Void

    init(outline: PDFOutline, onSelect: @escaping (PDFDestination?) -> Void) {
        self.root = outline
        self.onSelect = onSelect
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.06, alpha: 1.0).cgColor
        setupOutlineView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setupOutlineView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("outline"))
        column.title = ""
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.backgroundColor = .clear
        outlineView.rowHeight = 24
        outlineView.indentationPerLevel = 16
        outlineView.selectionHighlightStyle = .regular
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.target = self
        outlineView.action = #selector(outlineClicked)

        scrollView.documentView = outlineView

        // Separator line on the right edge
        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor(white: 0.15, alpha: 1.0).cgColor
        addSubview(separator)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
        ])

        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
    }

    @objc private func outlineClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? PDFOutline else { return }
        onSelect(item.destination)
    }
}

extension PDFOutlineSidebarView: NSOutlineViewDataSource, NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let node = (item as? PDFOutline) ?? root
        return node.numberOfChildren
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let node = (item as? PDFOutline) ?? root
        return node.child(at: index) as Any
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? PDFOutline else { return false }
        return node.numberOfChildren > 0
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? PDFOutline else { return nil }

        let cell = NSTextField(labelWithString: node.label ?? "Untitled")
        cell.font = .systemFont(ofSize: 12)
        cell.textColor = NSColor(white: 0.75, alpha: 1.0)
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = PDFOutlineRowView()
        return row
    }
}

/// Custom row view with dark hover/selection styling.
private class PDFOutlineRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor(white: 0.2, alpha: 1.0).setFill()
        bounds.fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .emphasized }
}

// MARK: - PDFFindBarView

/// Find bar for searching within a PDF document.
private class PDFFindBarView: NSView, NSSearchFieldDelegate {
    private let pdfView: PDFView
    private let searchField = NSSearchField()
    private let matchLabel = NSTextField(labelWithString: "")
    private let prevButton: NSButton
    private let nextButton: NSButton
    private var matches: [PDFSelection] = []
    private var currentMatchIndex = -1

    var onDismiss: (() -> Void)?

    init(pdfView: PDFView) {
        self.pdfView = pdfView
        self.prevButton = NSButton()
        self.nextButton = NSButton()
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.10, alpha: 1.0).cgColor
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setup() {
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Find in PDF..."
        searchField.font = .systemFont(ofSize: 12)
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged)
        addSubview(searchField)

        matchLabel.translatesAutoresizingMaskIntoConstraints = false
        matchLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        matchLabel.textColor = NSColor(white: 0.5, alpha: 1.0)
        addSubview(matchLabel)

        prevButton.translatesAutoresizingMaskIntoConstraints = false
        prevButton.bezelStyle = .accessoryBarAction
        prevButton.isBordered = false
        prevButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous")
        prevButton.contentTintColor = NSColor(white: 0.6, alpha: 1.0)
        prevButton.target = self
        prevButton.action = #selector(prevMatch)
        addSubview(prevButton)

        nextButton.translatesAutoresizingMaskIntoConstraints = false
        nextButton.bezelStyle = .accessoryBarAction
        nextButton.isBordered = false
        nextButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next")
        nextButton.contentTintColor = NSColor(white: 0.6, alpha: 1.0)
        nextButton.target = self
        nextButton.action = #selector(nextMatch)
        addSubview(nextButton)

        let closeButton = NSButton()
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.contentTintColor = NSColor(white: 0.5, alpha: 1.0)
        closeButton.target = self
        closeButton.action = #selector(dismiss)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 220),

            matchLabel.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 8),
            matchLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            prevButton.leadingAnchor.constraint(equalTo: matchLabel.trailingAnchor, constant: 8),
            prevButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            nextButton.leadingAnchor.constraint(equalTo: prevButton.trailingAnchor, constant: 2),
            nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func focus() {
        window?.makeFirstResponder(searchField)
    }

    @objc private func searchChanged() {
        let query = searchField.stringValue
        guard !query.isEmpty, let doc = pdfView.document else {
            matches = []
            currentMatchIndex = -1
            matchLabel.stringValue = ""
            pdfView.highlightedSelections = nil
            return
        }

        matches = doc.findString(query, withOptions: .caseInsensitive)
        if matches.isEmpty {
            matchLabel.stringValue = "No matches"
            currentMatchIndex = -1
            pdfView.highlightedSelections = nil
        } else {
            currentMatchIndex = 0
            highlightCurrent()
        }
    }

    @objc private func prevMatch() {
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + matches.count) % matches.count
        highlightCurrent()
    }

    @objc private func nextMatch() {
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % matches.count
        highlightCurrent()
    }

    @objc private func dismiss() {
        pdfView.highlightedSelections = nil
        onDismiss?()
    }

    private func highlightCurrent() {
        guard currentMatchIndex >= 0, currentMatchIndex < matches.count else { return }
        matchLabel.stringValue = "\(currentMatchIndex + 1) of \(matches.count)"

        // Highlight all matches
        matches.forEach { $0.color = NSColor.systemYellow.withAlphaComponent(0.3) }
        // Current match brighter
        let current = matches[currentMatchIndex]
        current.color = NSColor.systemYellow.withAlphaComponent(0.6)
        pdfView.highlightedSelections = matches
        pdfView.go(to: current)
        pdfView.setCurrentSelection(current, animate: true)
    }

    // Handle Escape in search field
    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }

    func controlTextDidChange(_ obj: Notification) {
        searchChanged()
    }
}
