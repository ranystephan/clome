import AppKit

// MARK: - NotebookPanel

/// A notebook panel that renders .ipynb files with a scrollable list of cells.
/// Each cell has a source editor, execution count, and output area.
/// Supports kernel execution via KernelManager (Python bridge to jupyter_client).
@MainActor
class NotebookPanel: NSView {
    private(set) var store: NotebookStore
    private var cellViews: [NotebookCellView] = []
    private(set) var focusedCellIndex: Int = 0

    // Kernel
    private var kernelManager = KernelManager()
    private var runAllQueue: [UUID] = []  // cell IDs queued for Run All
    private var isRunningAll = false

    // Environment
    private var discoveredEnvironments: [PythonEnvironment] = []
    private let projectDirectory: String?

    // Output refresh debouncing
    private var pendingRefreshCells: Set<Int> = []
    private var refreshDebounceWorkItem: DispatchWorkItem?

    // UI
    private var toolbarView: NSView!
    private var titleLabel: NSTextField!
    private var kernelLabel: NSTextField!
    private var cellCountLabel: NSTextField!
    private var scrollView: NSScrollView!
    private var stackView: NSStackView!
    private var statusBarView: NSView!
    private var statusLabel: NSTextField!
    private var kernelStatusLabel: NSTextField!
    private var envButton: NSButton!
    private var kernelPicker: NSPopUpButton!

    var title: String = "Notebook" {
        didSet {
            NotificationCenter.default.post(name: .terminalSurfaceTitleChanged, object: self)
        }
    }

    /// The file path of the loaded notebook (nil if none loaded).
    var filePath: String? { store.filePath }

    // MARK: - Design System Colors

    private var baseBg: NSColor { ClomeSettings.shared.backgroundWithOpacity }
    private var surface2: NSColor {
        ClomeMacTheme.surfaceColor(.chromeAlt)
    }
    private let borderSubtle = ClomeMacColor.border

    init(store: NotebookStore? = nil, projectDirectory: String? = nil) {
        let resolvedStore = store ?? NotebookStore()
        self.store = resolvedStore
        self.projectDirectory = projectDirectory
        super.init(frame: .zero)
        wantsLayer = true
        // No layer bg — the scroll view paints the background to avoid double-layering
        kernelManager.delegate = self
        setupUI()
        rebuildCells()
        discoverEnvironmentsAsync()
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceDidChange), name: .appearanceSettingsChanged, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        // Note: deinit can't be @MainActor isolated in all Swift versions,
        // but KernelManager.shutdown() is @MainActor. We rely on willClose()
        // being called from Workspace.closeTab() and the process
        // terminationHandler to clean up if the panel is deallocated.
    }

    /// Called by Workspace when this notebook's tab is being closed.
    /// Shuts down the kernel bridge subprocess to prevent orphaned processes.
    func willClose() {
        kernelManager.shutdown()
        // Release all cell views and their potentially heavy output images
        for cellView in cellViews {
            cellView.releaseResources()
        }
        cellViews.removeAll()
        stackView?.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    @objc private func appearanceDidChange() {
        layer?.backgroundColor = baseBg.cgColor
        toolbarView.layer?.backgroundColor = surface2.cgColor
        scrollView.backgroundColor = baseBg
    }

    func loadNotebook(at path: String) throws {
        store = try NotebookStore(contentsOfFile: path)
        title = (path as NSString).lastPathComponent
        rebuildCells()
        updateStatusBar()
    }

    // MARK: - UI Setup

    private func setupUI() {
        setupToolbar()
        setupScrollView()
        setupStatusBar()

        NSLayoutConstraint.activate([
            toolbarView.topAnchor.constraint(equalTo: topAnchor),
            toolbarView.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarView.heightAnchor.constraint(equalToConstant: 36),

            scrollView.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBarView.topAnchor),

            statusBarView.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBarView.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBarView.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusBarView.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    // MARK: - Toolbar

    private func setupToolbar() {
        toolbarView = NSView()
        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        toolbarView.wantsLayer = true
        toolbarView.layer?.backgroundColor = surface2.cgColor
        addSubview(toolbarView)

        // Bottom border line
        let borderLine = NSView()
        borderLine.translatesAutoresizingMaskIntoConstraints = false
        borderLine.wantsLayer = true
        borderLine.layer?.backgroundColor = NotebookColors.borderSubtle.cgColor
        toolbarView.addSubview(borderLine)
        NSLayoutConstraint.activate([
            borderLine.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor),
            borderLine.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor),
            borderLine.bottomAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            borderLine.heightAnchor.constraint(equalToConstant: 1),
        ])

        // Title (Text Primary, 12pt medium)
        titleLabel = NSTextField(labelWithString: "Notebook")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = NotebookColors.textPrimary
        toolbarView.addSubview(titleLabel)

        // Kernel name (Text Muted, 11pt)
        kernelLabel = NSTextField(labelWithString: "")
        kernelLabel.translatesAutoresizingMaskIntoConstraints = false
        kernelLabel.font = .systemFont(ofSize: 11, weight: .regular)
        kernelLabel.textColor = NotebookColors.textMuted
        toolbarView.addSubview(kernelLabel)

        // Execution buttons: Run, Run All, Stop, Restart
        let runCellBtn = makeToolbarIconButton(
            systemImage: "play.fill",
            action: #selector(runFocusedCell),
            tint: NotebookColors.accentGreen,
            tooltip: "Run focused cell (Cmd+Enter)"
        )
        let runAllBtn = makeToolbarIconButton(
            systemImage: "forward.fill",
            action: #selector(runAllCells),
            tint: NotebookColors.accentGreen,
            tooltip: "Run all cells (Cmd+Shift+Enter)"
        )
        let interruptBtn = makeToolbarIconButton(
            systemImage: "stop.fill",
            action: #selector(interruptKernel),
            tint: NotebookColors.accentRed,
            tooltip: "Interrupt kernel"
        )
        let restartBtn = makeToolbarIconButton(
            systemImage: "arrow.counterclockwise",
            action: #selector(restartKernel),
            tint: NotebookColors.accentAmber,
            tooltip: "Restart kernel"
        )

        // Separator 1
        let sep1 = makeToolbarSeparator()

        // Cell buttons: + Code, + Markdown
        let addCodeBtn = makeToolbarIconButton(
            systemImage: "plus.rectangle",
            action: #selector(addCodeCell),
            tint: NotebookColors.textSecondary,
            tooltip: "Add code cell (B)"
        )
        let addMdBtn = makeToolbarIconButton(
            systemImage: "text.badge.plus",
            action: #selector(addMarkdownCell),
            tint: NotebookColors.textSecondary,
            tooltip: "Add markdown cell"
        )

        // Separator 2
        let sep2 = makeToolbarSeparator()

        // Utility buttons: Clear Outputs, Package
        let clearOutputsBtn = makeToolbarIconButton(
            systemImage: "xmark.circle",
            action: #selector(clearAllOutputs),
            tint: NotebookColors.textSecondary,
            tooltip: "Clear all outputs"
        )
        let packageBtn = makeToolbarIconButton(
            systemImage: "shippingbox",
            action: #selector(showPackageInstall),
            tint: NotebookColors.textSecondary,
            tooltip: "Install Python package"
        )

        // Kernel picker (right side)
        kernelPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        kernelPicker.translatesAutoresizingMaskIntoConstraints = false
        kernelPicker.font = .systemFont(ofSize: 10, weight: .medium)
        kernelPicker.bezelStyle = .accessoryBarAction
        kernelPicker.isBordered = false
        kernelPicker.target = self
        kernelPicker.action = #selector(kernelPickerChanged)
        kernelPicker.addItem(withTitle: "No Kernel")
        toolbarView.addSubview(kernelPicker)

        // Cell count (Text Muted)
        cellCountLabel = NSTextField(labelWithString: "")
        cellCountLabel.translatesAutoresizingMaskIntoConstraints = false
        cellCountLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        cellCountLabel.textColor = NotebookColors.textMuted
        toolbarView.addSubview(cellCountLabel)

        // Layout: Left side
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            kernelLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            kernelLabel.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
        ])

        // Layout: Center button group (anchored after kernel label with flexible space effect)
        // We use a guide approach: buttons float in the middle area
        NSLayoutConstraint.activate([
            runCellBtn.leadingAnchor.constraint(equalTo: kernelLabel.trailingAnchor, constant: 16),
            runCellBtn.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            runCellBtn.widthAnchor.constraint(equalToConstant: 22),
            runCellBtn.heightAnchor.constraint(equalToConstant: 22),

            runAllBtn.leadingAnchor.constraint(equalTo: runCellBtn.trailingAnchor, constant: 6),
            runAllBtn.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            runAllBtn.widthAnchor.constraint(equalToConstant: 22),
            runAllBtn.heightAnchor.constraint(equalToConstant: 22),

            interruptBtn.leadingAnchor.constraint(equalTo: runAllBtn.trailingAnchor, constant: 6),
            interruptBtn.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            interruptBtn.widthAnchor.constraint(equalToConstant: 22),
            interruptBtn.heightAnchor.constraint(equalToConstant: 22),

            restartBtn.leadingAnchor.constraint(equalTo: interruptBtn.trailingAnchor, constant: 6),
            restartBtn.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            restartBtn.widthAnchor.constraint(equalToConstant: 22),
            restartBtn.heightAnchor.constraint(equalToConstant: 22),

            // Separator 1
            sep1.leadingAnchor.constraint(equalTo: restartBtn.trailingAnchor, constant: 12),
            sep1.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            addCodeBtn.leadingAnchor.constraint(equalTo: sep1.trailingAnchor, constant: 12),
            addCodeBtn.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            addCodeBtn.widthAnchor.constraint(equalToConstant: 22),
            addCodeBtn.heightAnchor.constraint(equalToConstant: 22),

            addMdBtn.leadingAnchor.constraint(equalTo: addCodeBtn.trailingAnchor, constant: 6),
            addMdBtn.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            addMdBtn.widthAnchor.constraint(equalToConstant: 22),
            addMdBtn.heightAnchor.constraint(equalToConstant: 22),

            // Separator 2
            sep2.leadingAnchor.constraint(equalTo: addMdBtn.trailingAnchor, constant: 12),
            sep2.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            clearOutputsBtn.leadingAnchor.constraint(equalTo: sep2.trailingAnchor, constant: 12),
            clearOutputsBtn.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            clearOutputsBtn.widthAnchor.constraint(equalToConstant: 22),
            clearOutputsBtn.heightAnchor.constraint(equalToConstant: 22),

            packageBtn.leadingAnchor.constraint(equalTo: clearOutputsBtn.trailingAnchor, constant: 6),
            packageBtn.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            packageBtn.widthAnchor.constraint(equalToConstant: 22),
            packageBtn.heightAnchor.constraint(equalToConstant: 22),
        ])

        // Layout: Right side (from right edge inward)
        NSLayoutConstraint.activate([
            cellCountLabel.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor, constant: -14),
            cellCountLabel.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),

            kernelPicker.trailingAnchor.constraint(equalTo: cellCountLabel.leadingAnchor, constant: -8),
            kernelPicker.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            kernelPicker.widthAnchor.constraint(lessThanOrEqualToConstant: 130),
        ])
    }

    private func makeToolbarIconButton(systemImage: String, action: Selector, tint: NSColor, tooltip: String = "") -> NSButton {
        let img = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)!
        let btn = HoverButton(image: img, target: self, action: action)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.bezelStyle = .accessoryBarAction
        btn.isBordered = false
        btn.contentTintColor = tint
        btn.toolTip = tooltip
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 5
        btn.layer?.cornerCurve = .continuous
        toolbarView.addSubview(btn)
        return btn
    }

    /// Creates a thin 1px vertical separator line for the toolbar.
    private func makeToolbarSeparator() -> NSView {
        let sep = NSView()
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        toolbarView.addSubview(sep)
        NSLayoutConstraint.activate([
            sep.widthAnchor.constraint(equalToConstant: 1),
            sep.heightAnchor.constraint(equalToConstant: 16),
        ])
        return sep
    }

    // MARK: - Scroll View

    private func setupScrollView() {
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = baseBg
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        addSubview(scrollView)

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.wantsLayer = true
        scrollView.documentView = documentView

        stackView = NSStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 6
        stackView.edgeInsets = NSEdgeInsets(top: 20, left: 0, bottom: 48, right: 0)
        documentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),

            stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusBarView = NSView()
        statusBarView.translatesAutoresizingMaskIntoConstraints = false
        statusBarView.wantsLayer = true
        statusBarView.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1.0).cgColor
        addSubview(statusBarView)

        // Top border line (matches tab bar border style)
        let statusTopBorder = NSView()
        statusTopBorder.translatesAutoresizingMaskIntoConstraints = false
        statusTopBorder.wantsLayer = true
        statusTopBorder.layer?.backgroundColor = NotebookColors.borderSubtle.cgColor
        statusBarView.addSubview(statusTopBorder)
        NSLayoutConstraint.activate([
            statusTopBorder.leadingAnchor.constraint(equalTo: statusBarView.leadingAnchor),
            statusTopBorder.trailingAnchor.constraint(equalTo: statusBarView.trailingAnchor),
            statusTopBorder.topAnchor.constraint(equalTo: statusBarView.topAnchor),
            statusTopBorder.heightAnchor.constraint(equalToConstant: 1),
        ])

        // Left: info label (matching editor status bar style)
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = NSColor(white: 0.50, alpha: 1.0)
        statusBarView.addSubview(statusLabel)

        // Center: clickable environment button (Accent Blue)
        envButton = NSButton(title: "Environment", target: self, action: #selector(showEnvironmentPicker))
        envButton.translatesAutoresizingMaskIntoConstraints = false
        envButton.bezelStyle = .accessoryBarAction
        envButton.isBordered = false
        envButton.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        envButton.contentTintColor = NotebookColors.accentBlue
        statusBarView.addSubview(envButton)

        // Right: kernel state with colored dot
        kernelStatusLabel = NSTextField(labelWithString: "No Kernel")
        kernelStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        kernelStatusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        kernelStatusLabel.textColor = NSColor(white: 0.50, alpha: 1.0)
        statusBarView.addSubview(kernelStatusLabel)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: statusBarView.leadingAnchor, constant: 10),
            statusLabel.centerYAnchor.constraint(equalTo: statusBarView.centerYAnchor),

            envButton.centerXAnchor.constraint(equalTo: statusBarView.centerXAnchor),
            envButton.centerYAnchor.constraint(equalTo: statusBarView.centerYAnchor),

            kernelStatusLabel.trailingAnchor.constraint(equalTo: statusBarView.trailingAnchor, constant: -10),
            kernelStatusLabel.centerYAnchor.constraint(equalTo: statusBarView.centerYAnchor),
        ])
    }

    // MARK: - Cell Management

    private func rebuildCells() {
        // Clean up and remove all existing views from stack
        for view in cellViews {
            view.prepareForRemoval()
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        cellViews.removeAll()

        for (i, cell) in store.document.cells.enumerated() {
            let execState = store.cellExecutionStates[cell.id] ?? .idle
            let cellView = NotebookCellView(cell: cell, index: i, language: store.language)
            cellView.update(cell: cell, index: i, executionState: execState)
            cellView.delegate = self

            // Auto-render markdown cells that have content
            if cell.cell_type == .markdown,
               !cell.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cellView.enterMarkdownRendered()
            }

            stackView.addArrangedSubview(cellView)
            cellView.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            cellViews.append(cellView)
        }

        if !cellViews.isEmpty {
            focusedCellIndex = min(focusedCellIndex, cellViews.count - 1)
            cellViews[focusedCellIndex].setFocused(true)
        }

        updateToolbarInfo()
    }

    /// Refresh a single cell view without rebuilding everything.
    private func refreshCell(at index: Int) {
        guard index >= 0, index < cellViews.count, index < store.document.cells.count else { return }
        let cell = store.document.cells[index]
        let execState = store.cellExecutionStates[cell.id] ?? .idle
        cellViews[index].update(cell: cell, index: index, executionState: execState)
    }

    /// Insert a new cell view at the given index without rebuilding all cells.
    private func insertCellView(at index: Int) {
        let cell = store.document.cells[index]
        let execState = store.cellExecutionStates[cell.id] ?? .idle
        let cellView = NotebookCellView(cell: cell, index: index, language: store.language)
        cellView.update(cell: cell, index: index, executionState: execState)
        cellView.delegate = self

        if cell.cell_type == .markdown,
           !cell.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cellView.enterMarkdownRendered()
        }

        stackView.insertArrangedSubview(cellView, at: index)
        cellView.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        cellViews.insert(cellView, at: index)

        // Update indices for cells after the insertion point
        for i in (index + 1)..<cellViews.count {
            cellViews[i].update(cell: store.document.cells[i], index: i,
                               executionState: store.cellExecutionStates[store.document.cells[i].id] ?? .idle)
        }
        updateToolbarInfo()
    }

    /// Remove the cell view at the given index without rebuilding all cells.
    private func removeCellView(at index: Int) {
        let view = cellViews[index]
        view.prepareForRemoval()
        stackView.removeArrangedSubview(view)
        view.removeFromSuperview()
        cellViews.remove(at: index)

        // Update indices for remaining cells
        for i in index..<cellViews.count {
            cellViews[i].update(cell: store.document.cells[i], index: i,
                               executionState: store.cellExecutionStates[store.document.cells[i].id] ?? .idle)
        }
        updateToolbarInfo()
    }

    /// Move a cell view from one index to another without rebuilding all cells.
    private func moveCellView(from sourceIndex: Int, to destIndex: Int) {
        let view = cellViews.remove(at: sourceIndex)
        stackView.removeArrangedSubview(view)

        cellViews.insert(view, at: destIndex)
        stackView.insertArrangedSubview(view, at: destIndex)

        // Update indices for all affected cells
        let minIdx = min(sourceIndex, destIndex)
        let maxIdx = max(sourceIndex, destIndex)
        for i in minIdx...maxIdx {
            cellViews[i].update(cell: store.document.cells[i], index: i,
                               executionState: store.cellExecutionStates[store.document.cells[i].id] ?? .idle)
        }
        updateToolbarInfo()
    }

    /// Schedule a debounced refresh for a cell (used during streaming output).
    private func scheduleRefresh(for index: Int) {
        pendingRefreshCells.insert(index)
        refreshDebounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let indices = self.pendingRefreshCells
            self.pendingRefreshCells.removeAll()
            for idx in indices {
                self.refreshCell(at: idx)
            }
        }
        refreshDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    /// Find the cell view index for a given cell UUID.
    private func cellIndex(for cellId: UUID) -> Int? {
        store.document.cells.firstIndex(where: { $0.id == cellId })
    }

    private func updateToolbarInfo() {
        titleLabel.stringValue = title
        kernelLabel.stringValue = store.kernelDisplayName
        cellCountLabel.stringValue = "\(store.document.cells.count) cells"
    }

    private func updateStatusBar() {
        let codeCount = store.document.cells.filter { $0.cell_type == .code }.count
        let mdCount = store.document.cells.filter { $0.cell_type == .markdown }.count
        statusLabel.stringValue = "\(store.language) \u{00B7} \(codeCount) code, \(mdCount) md \u{00B7} \(store.isDirty ? "Modified" : "Saved")"

        // Kernel state with colored dot
        let stateStr: String
        let stateColor: NSColor
        switch kernelManager.state {
        case .idle:
            stateStr = "\u{25CF} Idle"
            stateColor = NotebookColors.accentGreen
        case .busy:
            stateStr = "\u{25CF} Busy"
            stateColor = NotebookColors.accentAmber
        case .error(let msg):
            stateStr = "\u{25CF} \(msg)"
            stateColor = NotebookColors.accentRed
        case .starting:
            stateStr = "Starting..."
            stateColor = NotebookColors.textMuted
        case .settingUp(let msg):
            stateStr = msg
            stateColor = NotebookColors.textMuted
        case .disconnected:
            stateStr = "No Kernel"
            stateColor = NotebookColors.textMuted
        }
        kernelStatusLabel.stringValue = stateStr
        kernelStatusLabel.textColor = stateColor

        // Update environment button label
        if let activeKernel = kernelManager.activeKernelName {
            let displayName = kernelManager.availableKernels.first(where: { $0.name == activeKernel })?.displayName ?? activeKernel
            envButton.title = displayName
        } else {
            envButton.title = "Select Environment"
        }
    }

    private func updateKernelPicker() {
        kernelPicker.removeAllItems()
        if kernelManager.availableKernels.isEmpty {
            kernelPicker.addItem(withTitle: "No Kernel")
        } else {
            for spec in kernelManager.availableKernels {
                kernelPicker.addItem(withTitle: spec.displayName)
            }
            // Select the active kernel or one matching notebook metadata
            if let active = kernelManager.activeKernelName,
               let idx = kernelManager.availableKernels.firstIndex(where: { $0.name == active }) {
                kernelPicker.selectItem(at: idx)
            } else if let metaName = store.document.metadata.kernelspec?.name,
                      let idx = kernelManager.availableKernels.firstIndex(where: { $0.name == metaName }) {
                kernelPicker.selectItem(at: idx)
            }
        }
    }

    // MARK: - Scroll Helpers

    /// Smoothly scroll a cell at the given index into the visible area.
    /// Only scrolls if the cell is not already fully visible.
    private func scrollCellIntoView(at index: Int) {
        guard index >= 0, index < cellViews.count else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, index < self.cellViews.count else { return }
            let cellView = self.cellViews[index]
            let cellFrame = cellView.convert(cellView.bounds, to: self.scrollView.documentView)
            let visibleRect = self.scrollView.contentView.documentVisibleRect
            // Skip scroll if cell is already fully visible
            if visibleRect.contains(cellFrame) { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.allowsImplicitAnimation = true
                self.scrollView.contentView.scrollToVisible(cellFrame)
            }
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        }
    }

    // MARK: - Focus Management

    /// Update focus highlight only — no scrolling, no editor activation.
    private func setFocus(to index: Int) {
        guard index >= 0, index < cellViews.count else { return }
        let changingCell = focusedCellIndex != index
        if focusedCellIndex < cellViews.count {
            let oldCell = cellViews[focusedCellIndex]
            oldCell.setFocused(false)
            if changingCell,
               focusedCellIndex < store.document.cells.count,
               store.document.cells[focusedCellIndex].cell_type == .markdown,
               !oldCell.isMarkdownRendered,
               !store.document.cells[focusedCellIndex].sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                oldCell.enterMarkdownRendered()
            }
        }
        focusedCellIndex = index
        cellViews[focusedCellIndex].setFocused(true)
    }

    /// Move focus to next cell, scroll into view, and activate its editor.
    private func advanceFocusAndActivate() {
        let next = focusedCellIndex + 1
        guard next < cellViews.count else { return }
        setFocus(to: next)
        let cell = cellViews[focusedCellIndex]
        if !cell.isMarkdownRendered {
            cell.activateSourceEditor()
        }
        scrollCellIntoView(at: focusedCellIndex)
    }

    /// Move focus to next cell and scroll into view.
    private func advanceFocus() {
        let next = focusedCellIndex + 1
        guard next < cellViews.count else { return }
        setFocus(to: next)
        scrollCellIntoView(at: focusedCellIndex)
    }

    /// Move focus to previous cell and scroll into view.
    private func retreatFocus() {
        let prev = focusedCellIndex - 1
        guard prev >= 0 else { return }
        setFocus(to: prev)
        scrollCellIntoView(at: focusedCellIndex)
    }

    // MARK: - Public Insert

    /// Insert a cell at a given index, used by keyboard shortcuts and toolbar.
    func insertCell(at index: Int, type: NotebookCell.CellType) {
        let clampedIndex = min(max(index, 0), store.document.cells.count)
        store.insertCell(at: clampedIndex, type: type)
        focusedCellIndex = clampedIndex
        insertCellView(at: clampedIndex)
        cellViews[clampedIndex].setFocused(true)
        updateStatusBar()
        scrollCellIntoView(at: clampedIndex)
    }

    // MARK: - Environment Discovery

    private func discoverEnvironmentsAsync() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let projectDir = self?.projectDirectory
            let envs = PythonEnvironmentManager.discoverEnvironments(projectDirectory: projectDir)
            DispatchQueue.main.async {
                self?.discoveredEnvironments = envs
            }
        }
    }

    // MARK: - Environment Picker

    @objc private func showEnvironmentPicker() {
        let menu = NSMenu()

        // Section: Available kernels (already registered)
        if !kernelManager.availableKernels.isEmpty {
            menu.addItem(NSMenuItem.sectionHeader(title: "Kernels"))
            for (i, spec) in kernelManager.availableKernels.enumerated() {
                let item = NSMenuItem(title: spec.displayName, action: #selector(envMenuKernelSelected(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                if spec.name == kernelManager.activeKernelName {
                    item.state = .on
                }
                menu.addItem(item)
            }
        }

        // Section: Discovered environments (not yet registered as kernels)
        let unregistered = discoveredEnvironments.filter { !$0.isKernelRegistered }
        if !unregistered.isEmpty {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "Register Environment as Kernel"))
            for env in unregistered {
                let item = NSMenuItem(title: env.name, action: #selector(envMenuRegisterSelected(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = env
                item.toolTip = env.pythonPath
                menu.addItem(item)
            }
        }

        // Section: Actions
        menu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(title: "Refresh Environments", action: #selector(envMenuRefresh), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let browseItem = NSMenuItem(title: "Use Custom Python...", action: #selector(envMenuBrowse), keyEquivalent: "")
        browseItem.target = self
        menu.addItem(browseItem)

        // Show below the button
        let point = envButton.convert(NSPoint(x: 0, y: envButton.bounds.height), to: nil)
        menu.popUp(positioning: nil, at: point, in: envButton.window?.contentView)
    }

    @objc private func envMenuKernelSelected(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx >= 0, idx < kernelManager.availableKernels.count else { return }
        let spec = kernelManager.availableKernels[idx]
        kernelManager.startKernel(name: spec.name)
    }

    @objc private func envMenuRegisterSelected(_ sender: NSMenuItem) {
        guard let env = sender.representedObject as? PythonEnvironment else { return }
        kernelStatusLabel.stringValue = "Registering \(env.name)..."

        PythonEnvironmentManager.registerKernel(for: env) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let kernelName):
                self.kernelManager.discoverKernels()
                self.discoverEnvironmentsAsync()
                self.kernelStatusLabel.stringValue = "Registered \(env.name)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.kernelManager.startKernel(name: kernelName)
                }
            case .failure(let error):
                self.kernelStatusLabel.stringValue = "Registration failed"
                self.showAlert(title: "Failed to Register Environment",
                             message: error.localizedDescription)
            }
        }
    }

    @objc private func envMenuRefresh() {
        discoverEnvironmentsAsync()
        kernelManager.discoverKernels()
        kernelStatusLabel.stringValue = "Refreshing..."
    }

    @objc private func envMenuBrowse() {
        let panel = NSOpenPanel()
        panel.title = "Select Python Executable"
        panel.allowedContentTypes = [.unixExecutable, .item]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        panel.message = "Select a Python 3 executable (e.g. python3, python)"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let pythonPath = url.path
            let env = PythonEnvironment(
                id: "custom:\(pythonPath)",
                name: url.lastPathComponent,
                pythonPath: pythonPath,
                type: .system,
                isKernelRegistered: false
            )
            self?.registerAndStartEnv(env)
        }
    }

    private func registerAndStartEnv(_ env: PythonEnvironment) {
        kernelStatusLabel.stringValue = "Registering \(env.name)..."
        PythonEnvironmentManager.registerKernel(for: env) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let kernelName):
                self.kernelManager.discoverKernels()
                self.discoverEnvironmentsAsync()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.kernelManager.startKernel(name: kernelName)
                }
            case .failure(let error):
                self.showAlert(title: "Failed to Register Environment",
                             message: error.localizedDescription)
            }
        }
    }

    // MARK: - Package Install

    @objc private func showPackageInstall() {
        let alert = NSAlert()
        alert.messageText = "Install Python Package"
        alert.informativeText = "Enter a package name (or multiple separated by spaces).\nInstalls into the active kernel's environment."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "e.g. numpy pandas matplotlib"
        input.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        guard let win = self.window else { return }
        alert.beginSheetModal(for: win) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let packages = input.stringValue.trimmingCharacters(in: .whitespaces)
            guard !packages.isEmpty else { return }
            self?.installPackagesViaKernel(packages)
        }
    }

    /// Install packages by executing `!pip install ...` through the running kernel.
    /// This way packages install into the kernel's actual environment.
    private func installPackagesViaKernel(_ packages: String) {
        let code = "import subprocess, sys\nsubprocess.check_call([sys.executable, '-m', 'pip', 'install'] + \(packageList(packages)))\nprint('Installed successfully: \(packages)')"

        // Insert a temporary cell, execute it, then the output shows the result
        let insertAt = store.document.cells.count
        store.insertCell(at: insertAt, type: .code)
        store.updateCellSource(at: insertAt, text: code)
        focusedCellIndex = insertAt
        insertCellView(at: insertAt)
        executeCell(at: insertAt)
        scrollCellIntoView(at: insertAt)
    }

    /// Convert "numpy pandas matplotlib" -> "['numpy', 'pandas', 'matplotlib']"
    private func packageList(_ input: String) -> String {
        let names = input.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let quoted = names.map { "'\($0)'" }.joined(separator: ", ")
        return "[\(quoted)]"
    }

    // MARK: - Kernel Lifecycle

    private func connectKernel() {
        guard case .disconnected = kernelManager.state else { return }
        kernelManager.startBridge()
    }

    private func ensureKernelRunning(then action: @escaping @MainActor () -> Void) {
        switch kernelManager.state {
        case .idle, .busy:
            action()
        case .disconnected, .error:
            connectKernel()
            pendingKernelAction = action
        case .starting, .settingUp:
            pendingKernelAction = action
        }
    }

    private var pendingKernelAction: (@MainActor () -> Void)?

    // MARK: - Cell Execution

    private func executeCell(at index: Int) {
        guard index >= 0, index < store.document.cells.count else { return }
        let cell = store.document.cells[index]

        // Markdown cells: toggle rendered mode
        if cell.cell_type == .markdown {
            if index < cellViews.count {
                cellViews[index].enterMarkdownRendered()
            }
            return
        }

        guard cell.cell_type == .code else { return }

        let cellId = cell.id
        let code = cell.sourceText

        // Scroll the executing cell into view
        scrollCellIntoView(at: index)

        ensureKernelRunning { [weak self] in
            self?.doExecuteCell(cellId: cellId, code: code)
        }
    }

    private func doExecuteCell(cellId: UUID, code: String) {
        // Clear old outputs
        store.clearCellOutputs(cellId: cellId)
        store.setCellExecutionState(cellId, state: .running)
        if let idx = cellIndex(for: cellId) {
            refreshCell(at: idx)
        }

        kernelManager.execute(code: code, cellId: cellId, onOutput: { [weak self] output in
            guard let self else { return }
            self.store.appendCellOutput(cellId: cellId, output: output)
            if let idx = self.cellIndex(for: cellId) {
                self.scheduleRefresh(for: idx)
            }
        }, onComplete: { [weak self] execCount, status in
            guard let self else { return }
            self.store.setCellExecutionCount(cellId: cellId, executionCount: execCount)
            self.store.setCellExecutionState(cellId, state: .idle)
            if let idx = self.cellIndex(for: cellId) {
                // Flush any pending debounced refresh and do a final direct refresh
                self.pendingRefreshCells.remove(idx)
                self.refreshCell(at: idx)
            }
            self.updateStatusBar()
            // Continue Run All queue if active
            self.continueRunAll()
        })

        updateStatusBar()
    }

    private func executeAllCells() {
        isRunningAll = true
        runAllQueue = store.document.cells
            .filter { $0.cell_type == .code }
            .map { $0.id }

        // Mark all as queued
        for cellId in runAllQueue {
            store.setCellExecutionState(cellId, state: .queued)
        }
        // Refresh all queued cells to show queued state
        for i in 0..<cellViews.count {
            refreshCell(at: i)
        }

        continueRunAll()
    }

    private func continueRunAll() {
        guard isRunningAll, !runAllQueue.isEmpty else {
            isRunningAll = false
            return
        }
        let nextId = runAllQueue.removeFirst()
        guard let idx = cellIndex(for: nextId) else {
            continueRunAll()
            return
        }
        let cell = store.document.cells[idx]
        scrollCellIntoView(at: idx)
        doExecuteCell(cellId: cell.id, code: cell.sourceText)
    }

    // MARK: - Actions

    @objc private func addCodeCell() {
        let insertAt = focusedCellIndex + 1
        insertCell(at: insertAt, type: .code)
    }

    @objc private func addMarkdownCell() {
        let insertAt = focusedCellIndex + 1
        insertCell(at: insertAt, type: .markdown)
    }

    @objc private func clearAllOutputs() {
        store.clearAllOutputs()
        for i in 0..<cellViews.count { refreshCell(at: i) }
        updateStatusBar()
    }

    @objc private func runFocusedCell() {
        executeCell(at: focusedCellIndex)
    }

    @objc private func runAllCells() {
        ensureKernelRunning { [weak self] in
            self?.executeAllCells()
        }
    }

    @objc private func interruptKernel() {
        kernelManager.interrupt()
        isRunningAll = false
        runAllQueue.removeAll()
        // Clear queued states and refresh affected cells
        for (i, cell) in store.document.cells.enumerated() {
            if store.cellExecutionStates[cell.id] == .queued {
                store.setCellExecutionState(cell.id, state: .idle)
                refreshCell(at: i)
            }
        }
    }

    @objc private func restartKernel() {
        isRunningAll = false
        runAllQueue.removeAll()
        // Clear all execution states and refresh
        for cell in store.document.cells {
            store.setCellExecutionState(cell.id, state: .idle)
        }
        kernelManager.restart()
        for i in 0..<cellViews.count { refreshCell(at: i) }
        updateStatusBar()
    }

    @objc private func kernelPickerChanged() {
        let idx = kernelPicker.indexOfSelectedItem
        guard idx >= 0, idx < kernelManager.availableKernels.count else { return }
        let spec = kernelManager.availableKernels[idx]
        kernelManager.startKernel(name: spec.name)
    }

    // MARK: - Keyboard Navigation

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 36: // Return/Enter
            if flags == .command {
                // Cmd+Enter: run cell, stay
                executeCell(at: focusedCellIndex)
                return true
            } else if flags == [.command, .shift] {
                // Cmd+Shift+Enter: run all
                runAllCells()
                return true
            }
        case 1: // S
            if flags == .command {
                do {
                    try store.save()
                    updateStatusBar()
                } catch {
                    print("Failed to save notebook: \(error)")
                }
                return true
            }
        case 2: // D
            if flags == [.command, .shift] {
                // Cmd+Shift+D: delete focused cell
                deleteFocusedCell()
                return true
            }
        case 126: // Up arrow
            if flags == [.command, .shift] {
                // Cmd+Shift+Up: move cell up
                moveFocusedCellUp()
                return true
            }
        case 125: // Down arrow
            if flags == [.command, .shift] {
                // Cmd+Shift+Down: move cell down
                moveFocusedCellDown()
                return true
            }
        default:
            break
        }

        return super.performKeyEquivalent(with: event)
    }

    /// Handle key events that performKeyEquivalent doesn't catch (non-modifier keys).
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Only handle these when no text view is first responder (cell focused, not editing)
        let textViewIsFirstResponder = window?.firstResponder is NotebookTextView

        if !textViewIsFirstResponder {
            switch event.keyCode {
            case 126: // Up arrow (no modifiers) -- move focus to previous cell
                if flags.isEmpty {
                    retreatFocus()
                    return
                }
            case 125: // Down arrow (no modifiers) -- move focus to next cell
                if flags.isEmpty {
                    advanceFocus()
                    return
                }
            case 0: // A -- insert code cell above
                if flags.isEmpty {
                    insertCell(at: focusedCellIndex, type: .code)
                    return
                }
            case 11: // B -- insert code cell below
                if flags.isEmpty {
                    insertCell(at: focusedCellIndex + 1, type: .code)
                    return
                }
            case 7: // X -- delete focused cell
                if flags.isEmpty {
                    deleteFocusedCell()
                    return
                }
            case 53: // Escape -- just keep focus, no-op if not editing
                return
            default:
                break
            }
        } else {
            // Text view has focus -- handle Escape to exit edit mode
            if event.keyCode == 53 && flags.isEmpty {
                // Escape: resign text view first responder, keep cell focused
                window?.makeFirstResponder(self)
                return
            }
            // Up arrow at top of cell text -> move to previous cell
            if event.keyCode == 126 && flags.isEmpty {
                if isCursorAtFirstLine() {
                    retreatFocus()
                    return
                }
            }
            // Down arrow at bottom of cell text -> move to next cell
            if event.keyCode == 125 && flags.isEmpty {
                if isCursorAtLastLine() {
                    advanceFocus()
                    return
                }
            }
        }

        super.keyDown(with: event)
    }

    /// Check if the current first-responder text view's cursor is on the first line.
    private func isCursorAtFirstLine() -> Bool {
        guard let textView = window?.firstResponder as? NSTextView,
              let layoutManager = textView.layoutManager,
              layoutManager.numberOfGlyphs > 0 else { return true }
        let selectedRange = textView.selectedRange()
        if selectedRange.length > 0 { return false }
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: selectedRange.location)
        let firstLineRect = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let currentLineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        return currentLineRect.origin.y == firstLineRect.origin.y
    }

    /// Check if the current first-responder text view's cursor is on the last line.
    private func isCursorAtLastLine() -> Bool {
        guard let textView = window?.firstResponder as? NSTextView,
              let layoutManager = textView.layoutManager,
              layoutManager.numberOfGlyphs > 0 else { return true }
        let selectedRange = textView.selectedRange()
        if selectedRange.length > 0 { return false }
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: selectedRange.location)
        let lastGlyphIndex = max(0, layoutManager.numberOfGlyphs - 1)
        let currentLineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let lastLineRect = layoutManager.lineFragmentRect(forGlyphAt: lastGlyphIndex, effectiveRange: nil)
        return currentLineRect.origin.y == lastLineRect.origin.y
    }

    // MARK: - Cell Operations (keyboard-triggered)

    private func deleteFocusedCell() {
        guard store.document.cells.count > 1 else {
            NSSound.beep()
            return
        }
        let idx = focusedCellIndex
        store.deleteCell(at: idx)
        removeCellView(at: idx)
        if focusedCellIndex >= store.document.cells.count {
            focusedCellIndex = max(0, store.document.cells.count - 1)
        }
        if !cellViews.isEmpty { cellViews[focusedCellIndex].setFocused(true) }
        updateStatusBar()
        scrollCellIntoView(at: focusedCellIndex)
    }

    private func moveFocusedCellUp() {
        let idx = focusedCellIndex
        guard idx > 0 else { return }
        store.moveCell(from: idx, to: idx - 1)
        moveCellView(from: idx, to: idx - 1)
        focusedCellIndex = idx - 1
        cellViews[focusedCellIndex].setFocused(true)
        updateStatusBar()
        scrollCellIntoView(at: focusedCellIndex)
    }

    private func moveFocusedCellDown() {
        let idx = focusedCellIndex
        guard idx < store.document.cells.count - 1 else { return }
        store.moveCell(from: idx, to: idx + 1)
        moveCellView(from: idx, to: idx + 1)
        focusedCellIndex = idx + 1
        cellViews[focusedCellIndex].setFocused(true)
        updateStatusBar()
        scrollCellIntoView(at: focusedCellIndex)
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Helpers

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        if let win = self.window {
            alert.beginSheetModal(for: win)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - KernelManagerDelegate

extension NotebookPanel: KernelManagerDelegate {
    func kernelManager(_ manager: KernelManager, didChangeState state: KernelManager.State) {
        updateStatusBar()
        updateKernelPicker()

        // When kernels are first discovered and no kernel is running, auto-start
        if case .idle = state, manager.activeKernelName == nil, !manager.availableKernels.isEmpty {
            // Pick kernel matching notebook metadata, or first available
            let metaName = store.document.metadata.kernelspec?.name
            let kernelName = metaName.flatMap { name in
                manager.availableKernels.first(where: { $0.name == name })?.name
            } ?? manager.availableKernels[0].name
            manager.startKernel(name: kernelName)
            return
        }

        // Execute pending action when kernel becomes idle
        if case .idle = state, let action = pendingKernelAction {
            pendingKernelAction = nil
            action()
        }
    }
}

// MARK: - NotebookCellViewDelegate

extension NotebookPanel: NotebookCellViewDelegate {
    func cellDidUpdateSource(_ cellView: NotebookCellView, text: String) {
        store.updateCellSource(at: cellView.cellIndex, text: text)
        updateStatusBar()
    }

    func cellDidRequestDelete(_ cellView: NotebookCellView) {
        guard store.document.cells.count > 1 else {
            NSSound.beep()
            return
        }
        let idx = cellView.cellIndex
        store.deleteCell(at: idx)
        removeCellView(at: idx)
        if focusedCellIndex >= store.document.cells.count {
            focusedCellIndex = max(0, store.document.cells.count - 1)
        }
        if !cellViews.isEmpty { cellViews[focusedCellIndex].setFocused(true) }
        updateStatusBar()
        scrollCellIntoView(at: focusedCellIndex)
    }

    func cellDidRequestInsertBelow(_ cellView: NotebookCellView, type: NotebookCell.CellType) {
        let insertAt = cellView.cellIndex + 1
        insertCell(at: insertAt, type: type)
    }

    func cellDidRequestMoveUp(_ cellView: NotebookCellView) {
        let idx = cellView.cellIndex
        guard idx > 0 else { return }
        store.moveCell(from: idx, to: idx - 1)
        moveCellView(from: idx, to: idx - 1)
        focusedCellIndex = idx - 1
        cellViews[focusedCellIndex].setFocused(true)
        updateStatusBar()
        scrollCellIntoView(at: focusedCellIndex)
    }

    func cellDidRequestMoveDown(_ cellView: NotebookCellView) {
        let idx = cellView.cellIndex
        guard idx < store.document.cells.count - 1 else { return }
        store.moveCell(from: idx, to: idx + 1)
        moveCellView(from: idx, to: idx + 1)
        focusedCellIndex = idx + 1
        cellViews[focusedCellIndex].setFocused(true)
        updateStatusBar()
        scrollCellIntoView(at: focusedCellIndex)
    }

    func cellDidRequestChangeType(_ cellView: NotebookCellView, to type: NotebookCell.CellType) {
        store.changeCellType(at: cellView.cellIndex, to: type)
        refreshCell(at: cellView.cellIndex)
        updateStatusBar()
    }

    func cellDidRequestFocus(_ cellView: NotebookCellView) {
        setFocus(to: cellView.cellIndex)
    }

    func cellDidRequestRun(_ cellView: NotebookCellView) {
        executeCell(at: cellView.cellIndex)
    }

    func cellDidRequestRunAndAdvance(_ cellView: NotebookCellView) {
        executeCell(at: cellView.cellIndex)
        advanceFocusAndActivate()
    }

    func cellDidRequestClearOutput(_ cellView: NotebookCellView) {
        let idx = cellView.cellIndex
        guard idx >= 0, idx < store.document.cells.count else { return }
        let cellId = store.document.cells[idx].id
        store.clearCellOutputs(cellId: cellId)
        refreshCell(at: idx)
        updateStatusBar()
    }

}

// MARK: - HoverButton (toolbar button with hover background)

@MainActor
class HoverButton: NSButton {
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }
}

// MARK: - Flipped View (for top-to-bottom scrolling)

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
