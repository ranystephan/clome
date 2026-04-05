import AppKit

// MARK: - FileShelfView

/// A sidebar panel for staging files to drag into the terminal.
/// Two tabs: Pinned (user-curated) and Downloads (auto-populated from ~/Downloads).
/// Supports multi-selection via ⌘-click (toggle) and ⇧-click (range).
@MainActor
class FileShelfView: NSView, NSTextFieldDelegate {

    enum ShelfTab { case pinned, downloads }

    private var activeTab: ShelfTab = .pinned

    private var pinnedFiles: [URL] = []
    private var downloadsFiles: [URL] = []

    /// Indices of currently selected rows
    private var selectedIndices: Set<Int> = []
    /// Last clicked index for shift-click range selection
    private var lastClickedIndex: Int?

    // Subviews
    private let tabBar = NSView()
    private let pinnedTabBtn = NSButton()
    private let downloadsTabBtn = NSButton()
    private let indicatorLine = NSView()

    private let listScrollView = NSScrollView()
    private let listStack = NSStackView()

    private let addButton = NSButton()
    private let searchButton = NSButton()
    private let searchField = NSTextField()
    private let emptyLabel = NSTextField(labelWithString: "Drop files here or click +")

    private var downloadsWatcher: DispatchSourceFileSystemObject?
    private var isSearchVisible = false
    private var searchText = ""
    private var listScrollViewBottomConstraint: NSLayoutConstraint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
        loadPinnedFiles()
        loadDownloads()
        reloadList()
        watchDownloads()
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    func cleanup() {
        downloadsWatcher?.cancel()
        downloadsWatcher = nil
    }

    /// The files in the active tab
    private var currentFiles: [URL] {
        if activeTab == .pinned {
            return pinnedFiles
        } else {
            // Filter downloads based on search text
            if searchText.isEmpty {
                return downloadsFiles
            } else {
                return downloadsFiles.filter { url in
                    url.lastPathComponent.localizedCaseInsensitiveContains(searchText)
                }
            }
        }
    }

    /// URLs for all selected rows
    var selectedURLs: [URL] {
        let files = currentFiles
        return selectedIndices.sorted().compactMap { $0 < files.count ? files[$0] : nil }
    }

    // MARK: - Setup

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.97).cgColor
        layer?.cornerRadius = 8
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]

        // Top separator
        let sep = NSView()
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        addSubview(sep)

        // Tab bar
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabBar)

        configureTabButton(pinnedTabBtn, title: "Pinned", action: #selector(pinnedTabTapped))
        configureTabButton(downloadsTabBtn, title: "Downloads", action: #selector(downloadsTabTapped))
        tabBar.addSubview(pinnedTabBtn)
        tabBar.addSubview(downloadsTabBtn)

        indicatorLine.translatesAutoresizingMaskIntoConstraints = false
        indicatorLine.wantsLayer = true
        indicatorLine.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        indicatorLine.layer?.cornerRadius = 1
        tabBar.addSubview(indicatorLine)

        // Scroll view for file list
        listScrollView.translatesAutoresizingMaskIntoConstraints = false
        listScrollView.drawsBackground = false
        listScrollView.hasVerticalScroller = true
        listScrollView.autohidesScrollers = true
        listScrollView.borderType = .noBorder
        addSubview(listScrollView)

        listStack.orientation = .vertical
        listStack.spacing = 1
        listStack.alignment = .leading
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let clipView = NSClipView()
        clipView.drawsBackground = false
        clipView.documentView = listStack
        listScrollView.contentView = clipView

        // Add button (pinned tab only)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.bezelStyle = .texturedRounded
        addButton.isBordered = false
        addButton.title = ""
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        addButton.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "Add files")?.withSymbolConfiguration(cfg)
        addButton.contentTintColor = NSColor(white: 1.0, alpha: 0.6)
        addButton.target = self
        addButton.action = #selector(addPinnedFilesTapped)
        addSubview(addButton)

        // Search button (downloads tab only)
        searchButton.translatesAutoresizingMaskIntoConstraints = false
        searchButton.bezelStyle = .texturedRounded
        searchButton.isBordered = false
        searchButton.title = ""
        let searchCfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        searchButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search files")?.withSymbolConfiguration(searchCfg)
        searchButton.contentTintColor = NSColor(white: 1.0, alpha: 0.6)
        searchButton.target = self
        searchButton.action = #selector(searchButtonTapped)
        searchButton.isHidden = true
        addSubview(searchButton)

        // Search field
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search downloads..."
        searchField.font = .systemFont(ofSize: 11)
        searchField.textColor = NSColor(white: 1.0, alpha: 0.85)
        searchField.backgroundColor = NSColor(white: 0.12, alpha: 0.8)
        searchField.drawsBackground = true
        searchField.isBezeled = true
        searchField.bezelStyle = .roundedBezel
        searchField.target = self
        searchField.action = #selector(searchFieldChanged)
        searchField.delegate = self
        searchField.isHidden = true
        addSubview(searchField)

        // Empty label
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = NSColor(white: 1.0, alpha: 0.3)
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        // Layout - initially set for pinned tab (showing add button)
        listScrollViewBottomConstraint = listScrollView.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -2)
        
        NSLayoutConstraint.activate([
            sep.topAnchor.constraint(equalTo: topAnchor),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),

            tabBar.topAnchor.constraint(equalTo: sep.bottomAnchor),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 32),

            pinnedTabBtn.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor, constant: 12),
            pinnedTabBtn.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),

            downloadsTabBtn.leadingAnchor.constraint(equalTo: pinnedTabBtn.trailingAnchor, constant: 16),
            downloadsTabBtn.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),

            indicatorLine.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor),
            indicatorLine.heightAnchor.constraint(equalToConstant: 2),

            listScrollView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            listScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            listScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            listScrollViewBottomConstraint!,

            listStack.leadingAnchor.constraint(equalTo: listScrollView.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: listScrollView.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: listScrollView.contentView.topAnchor),

            addButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            addButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            addButton.widthAnchor.constraint(equalToConstant: 24),
            addButton.heightAnchor.constraint(equalToConstant: 24),

            searchButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            searchButton.widthAnchor.constraint(equalToConstant: 24),
            searchButton.heightAnchor.constraint(equalToConstant: 24),

            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            searchField.bottomAnchor.constraint(equalTo: searchButton.topAnchor, constant: -4),
            searchField.heightAnchor.constraint(equalToConstant: 22),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: listScrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
        ])

        updateTabAppearance()
    }

    private func configureTabButton(_ btn: NSButton, title: String, action: Selector) {
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.bezelStyle = .texturedRounded
        btn.isBordered = false
        btn.title = title
        btn.font = .systemFont(ofSize: 11, weight: .medium)
        btn.contentTintColor = NSColor(white: 1.0, alpha: 0.5)
        btn.target = self
        btn.action = action
    }

    // MARK: - Tab Switching

    @objc private func pinnedTabTapped() { switchTab(.pinned) }
    @objc private func downloadsTabTapped() { switchTab(.downloads) }

    private func switchTab(_ tab: ShelfTab) {
        guard tab != activeTab else { return }
        activeTab = tab
        selectedIndices.removeAll()
        lastClickedIndex = nil
        
        // Hide search when switching away from downloads
        if tab != .downloads && isSearchVisible {
            hideSearchField()
        }
        
        updateTabAppearance()
        reloadList()
    }

    private func updateTabAppearance() {
        let activeColor = NSColor(white: 1.0, alpha: 0.85)
        let inactiveColor = NSColor(white: 1.0, alpha: 0.4)

        pinnedTabBtn.contentTintColor = activeTab == .pinned ? activeColor : inactiveColor
        downloadsTabBtn.contentTintColor = activeTab == .downloads ? activeColor : inactiveColor

        addButton.isHidden = activeTab != .pinned
        searchButton.isHidden = activeTab != .downloads
        
        // Update scroll view bottom constraint based on active tab (if search is not visible)
        if !isSearchVisible {
            listScrollViewBottomConstraint?.isActive = false
            if activeTab == .pinned {
                listScrollViewBottomConstraint = listScrollView.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -2)
            } else {
                listScrollViewBottomConstraint = listScrollView.bottomAnchor.constraint(equalTo: searchButton.topAnchor, constant: -2)
            }
            listScrollViewBottomConstraint?.isActive = true
        }

        // Move indicator line under active tab
        let targetBtn = activeTab == .pinned ? pinnedTabBtn : downloadsTabBtn
        for c in indicatorLine.constraints where c.firstAttribute == .width {
            indicatorLine.removeConstraint(c)
        }
        for c in tabBar.constraints where c.firstItem === indicatorLine && (c.firstAttribute == .leading || c.firstAttribute == .centerX) {
            tabBar.removeConstraint(c)
        }
        NSLayoutConstraint.activate([
            indicatorLine.centerXAnchor.constraint(equalTo: targetBtn.centerXAnchor),
            indicatorLine.widthAnchor.constraint(equalTo: targetBtn.widthAnchor),
        ])
        needsLayout = true
    }

    // MARK: - Selection

    /// Called by row views when clicked. Handles plain, ⌘, and ⇧ click.
    func rowClicked(index: Int, event: NSEvent) {
        let count = currentFiles.count
        guard index >= 0, index < count else { return }

        if event.modifierFlags.contains(.command) {
            // ⌘-click: toggle individual row
            if selectedIndices.contains(index) {
                selectedIndices.remove(index)
            } else {
                selectedIndices.insert(index)
            }
            lastClickedIndex = index
        } else if event.modifierFlags.contains(.shift), let anchor = lastClickedIndex {
            // ⇧-click: select range from last clicked to this one
            let lo = min(anchor, index)
            let hi = max(anchor, index)
            for i in lo...hi {
                selectedIndices.insert(i)
            }
            // Don't update lastClickedIndex on shift-click so further shifts extend from same anchor
        } else {
            // Plain click: select only this row
            selectedIndices = [index]
            lastClickedIndex = index
        }

        updateRowSelectionVisuals()
    }

    private func updateRowSelectionVisuals() {
        for (i, view) in listStack.arrangedSubviews.enumerated() {
            guard let row = view as? FileShelfRowView else { continue }
            row.setSelected(selectedIndices.contains(i))
        }
    }

    // MARK: - Data

    private func loadPinnedFiles() {
        let paths = SessionState.shared.restorePinnedFiles()
        pinnedFiles = paths.compactMap { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func loadDownloads() {
        let downloadsPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
        // Only access Downloads if we already have permission — avoid triggering TCC prompts
        guard FileAccessManager.shared.accessDirectory(downloadsPath) else {
            downloadsFiles = []
            return
        }
        let downloadsURL = URL(fileURLWithPath: downloadsPath)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: downloadsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            downloadsFiles = []
            return
        }
        downloadsFiles = contents.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return da > db
        }
        if downloadsFiles.count > 50 {
            downloadsFiles = Array(downloadsFiles.prefix(50))
        }
    }

    private func savePinnedFiles() {
        SessionState.shared.savePinnedFiles(pinnedFiles.map(\.path))
    }

    // MARK: - Downloads Watcher

    private func watchDownloads() {
        let downloadsPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
        // Only watch if we already have access — avoid triggering TCC
        guard FileAccessManager.shared.accessDirectory(downloadsPath) else { return }
        let fd = open(downloadsPath, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            self?.loadDownloads()
            if self?.activeTab == .downloads {
                self?.reloadList()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        downloadsWatcher = source
    }

    // MARK: - List

    func reloadList() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let files = currentFiles
        let showRemove = activeTab == .pinned

        // Update empty label based on context
        if activeTab == .downloads && !searchText.isEmpty && files.isEmpty {
            emptyLabel.stringValue = "No files match your search"
        } else if activeTab == .downloads && files.isEmpty {
            emptyLabel.stringValue = "No files in Downloads folder"
        } else {
            emptyLabel.stringValue = "Drop files here or click +"
        }
        
        emptyLabel.isHidden = !files.isEmpty

        // Prune stale selection indices
        selectedIndices = selectedIndices.filter { $0 < files.count }

        for (index, url) in files.enumerated() {
            let row = FileShelfRowView(fileURL: url, showRemove: showRemove, index: index, shelf: self)
            row.onRemove = { [weak self] idx in
                self?.removePinnedFile(at: idx)
            }
            row.setSelected(selectedIndices.contains(index))
            row.translatesAutoresizingMaskIntoConstraints = false
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }
    }

    // MARK: - Actions

    @objc private func addPinnedFilesTapped() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] result in
            guard result == .OK, let self else { return }
            for url in panel.urls where !self.pinnedFiles.contains(url) {
                self.pinnedFiles.append(url)
            }
            self.savePinnedFiles()
            self.reloadList()
        }
    }

    private func removePinnedFile(at index: Int) {
        guard index < pinnedFiles.count else { return }
        pinnedFiles.remove(at: index)
        selectedIndices.remove(index)
        // Shift down any selected indices above the removed one
        selectedIndices = Set(selectedIndices.map { $0 > index ? $0 - 1 : $0 })
        savePinnedFiles()
        reloadList()
    }

    @objc private func searchButtonTapped() {
        if isSearchVisible {
            hideSearchField()
        } else {
            showSearchField()
        }
    }

    @objc private func searchFieldChanged() {
        searchText = searchField.stringValue
        selectedIndices.removeAll()
        lastClickedIndex = nil
        reloadList()
    }

    private func showSearchField() {
        guard !isSearchVisible else { return }
        isSearchVisible = true
        searchField.isHidden = false
        searchField.alphaValue = 0.0
        searchButton.contentTintColor = NSColor.controlAccentColor
        
        // Update scroll view constraint to make room for search field
        listScrollViewBottomConstraint?.isActive = false
        listScrollViewBottomConstraint = listScrollView.bottomAnchor.constraint(equalTo: searchField.topAnchor, constant: -2)
        listScrollViewBottomConstraint?.isActive = true
        
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            searchField.animator().alphaValue = 1.0
            self.layoutSubtreeIfNeeded()
        }
        
        // Focus the search field
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self?.searchField)
        }
    }

    private func hideSearchField() {
        guard isSearchVisible else { return }
        isSearchVisible = false
        searchButton.contentTintColor = NSColor(white: 1.0, alpha: 0.6)
        
        // Restore scroll view constraint
        listScrollViewBottomConstraint?.isActive = false
        listScrollViewBottomConstraint = listScrollView.bottomAnchor.constraint(equalTo: searchButton.topAnchor, constant: -2)
        listScrollViewBottomConstraint?.isActive = true
        
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            searchField.animator().alphaValue = 0.0
            self.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            self?.searchField.isHidden = true
            self?.searchField.stringValue = ""
            self?.searchText = ""
            self?.selectedIndices.removeAll()
            self?.lastClickedIndex = nil
            self?.reloadList()
        })
    }

    // MARK: - Drag Destination (pinned tab accepts file drops)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard activeTab == .pinned else { return [] }
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard activeTab == .pinned else { return false }
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        var changed = false
        for url in urls where !pinnedFiles.contains(url) {
            pinnedFiles.append(url)
            changed = true
        }
        if changed {
            savePinnedFiles()
            reloadList()
        }
        return changed
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSTextField === searchField else { return }
        searchText = searchField.stringValue
        selectedIndices.removeAll()
        lastClickedIndex = nil
        reloadList()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { // Escape key
            hideSearchField()
            return true
        }
        return false
    }
}

// MARK: - FileShelfRowView

/// A single row in the file shelf: icon + filename + detail, draggable.
@MainActor
class FileShelfRowView: NSView, NSDraggingSource {

    let fileURL: URL
    let index: Int
    var onRemove: ((Int) -> Void)?
    private weak var shelf: FileShelfView?

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let removeBtn = NSButton()
    private var trackingArea: NSTrackingArea?
    private let showRemove: Bool
    private var isRowSelected = false

    init(fileURL: URL, showRemove: Bool, index: Int, shelf: FileShelfView) {
        self.fileURL = fileURL
        self.showRemove = showRemove
        self.index = index
        self.shelf = shelf
        super.init(frame: .zero)
        setupRow()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSelected(_ selected: Bool) {
        isRowSelected = selected
        layer?.backgroundColor = selected
            ? NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.8, alpha: 0.25).cgColor
            : nil
    }

    private func setupRow() {
        wantsLayer = true

        // Icon
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSWorkspace.shared.icon(forFile: fileURL.path)
        iconView.image?.size = NSSize(width: 16, height: 16)
        addSubview(iconView)

        // Filename
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = NSColor(white: 1.0, alpha: 0.85)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.stringValue = fileURL.lastPathComponent
        addSubview(nameLabel)

        // Detail (parent folder)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = NSColor(white: 1.0, alpha: 0.4)
        detailLabel.lineBreakMode = .byTruncatingHead
        detailLabel.stringValue = fileURL.deletingLastPathComponent().lastPathComponent
        addSubview(detailLabel)

        // Remove button
        removeBtn.translatesAutoresizingMaskIntoConstraints = false
        removeBtn.bezelStyle = .texturedRounded
        removeBtn.isBordered = false
        removeBtn.title = ""
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        removeBtn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove")?.withSymbolConfiguration(cfg)
        removeBtn.contentTintColor = NSColor(white: 1.0, alpha: 0.4)
        removeBtn.target = self
        removeBtn.action = #selector(removeTapped)
        removeBtn.isHidden = true
        if showRemove {
            addSubview(removeBtn)
        }

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -6),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: showRemove ? -28 : -10),

            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 6),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: showRemove ? -28 : -10),
        ])

        if showRemove {
            NSLayoutConstraint.activate([
                removeBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                removeBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
                removeBtn.widthAnchor.constraint(equalToConstant: 18),
                removeBtn.heightAnchor.constraint(equalToConstant: 18),
            ])
        }
    }

    @objc private func removeTapped() {
        onRemove?(index)
    }

    // MARK: - Click handling (selection)

    override func mouseDown(with event: NSEvent) {
        shelf?.rowClicked(index: index, event: event)
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        if !isRowSelected {
            layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        }
        if showRemove { removeBtn.isHidden = false }
    }

    override func mouseExited(with event: NSEvent) {
        if !isRowSelected {
            layer?.backgroundColor = nil
        }
        if showRemove { removeBtn.isHidden = true }
    }

    // MARK: - Drag Source

    override func mouseDragged(with event: NSEvent) {
        // If this row is selected and there are multiple selections, drag all selected files
        // Otherwise drag just this file
        let urlsToDrag: [URL]
        if let shelf, isRowSelected, shelf.selectedURLs.count > 1 {
            urlsToDrag = shelf.selectedURLs
        } else {
            urlsToDrag = [fileURL]
        }

        var items: [NSDraggingItem] = []
        for url in urlsToDrag {
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let iconImage = NSWorkspace.shared.icon(forFile: url.path)
            iconImage.size = NSSize(width: 32, height: 32)
            item.setDraggingFrame(NSRect(x: 0, y: 0, width: 32, height: 32), contents: iconImage)
            items.append(item)
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .copy
    }
}
