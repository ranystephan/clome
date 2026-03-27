import AppKit

/// A project panel manages a directory with multiple open editor sub-tabs.
/// This is the main content view for a `.project` workspace tab.
class ProjectPanel: NSView {
    let rootDirectory: String
    private(set) var openFiles: [OpenFile] = []
    private(set) var activeFileIndex: Int = -1

    /// The file explorer for the sidebar (owned here, displayed in sidebar)
    let fileExplorer: FileExplorerView

    private var tabBar: NSView!
    private var tabScrollView: NSScrollView!
    private var tabStackView: NSStackView!
    private var splitContainer: PaneContainerView!
    private var primarySlot: EditorSlot!
    private weak var activeSlot: EditorSlot?
    private var splitDropZone: SplitDropZoneView!
    private var welcomeLabel: NSTextField?
    private var dragSourceTabIndex: Int = -1

    struct OpenFile {
        let path: String
        let panel: NSView  // EditorPanel, NotebookPanel, PDFPanel, or DiffReviewPanel
        var editor: EditorPanel? { panel as? EditorPanel }
        var notebook: NotebookPanel? { panel as? NotebookPanel }
        var pdf: PDFPanel? { panel as? PDFPanel }
        var diffReview: DiffReviewPanel? { panel as? DiffReviewPanel }
        var name: String { (path as NSString).lastPathComponent }
        var isNotebook: Bool { panel is NotebookPanel }
        var isPDF: Bool { panel is PDFPanel }
        var isDiffReview: Bool { panel is DiffReviewPanel }
    }

    init(rootDirectory: String) {
        self.rootDirectory = rootDirectory
        self.fileExplorer = FileExplorerView()
        super.init(frame: .zero)
        wantsLayer = true
        fileExplorer.rootPath = rootDirectory
        fileExplorer.delegate = self
        setupUI()

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleDirtyStateChanged(_:)),
            name: .bufferDirtyStateChanged, object: nil
        )

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleOpenDiffReview(_:)),
            name: .openDiffReview, object: nil
        )
    }

    @objc private func handleDirtyStateChanged(_ notification: Notification) {
        guard let buffer = notification.object as? TextBuffer else { return }
        // Find the tab whose editor owns this buffer and update its dot
        for view in tabStackView.arrangedSubviews {
            guard let tab = view as? ProjectFileTab else { continue }
            let idx = tab.tabIndex
            guard idx < openFiles.count,
                  let editor = openFiles[idx].editor,
                  editor.editorView.buffer === buffer else { continue }
            tab.updateDirtyState(buffer.isDirty)
            break
        }
    }

    @objc private func handleOpenDiffReview(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let path = userInfo["path"] as? String,
              let oldContent = userInfo["oldContent"] as? String,
              let newContent = userInfo["newContent"] as? String else { return }
        // Only handle if the editor belongs to our project
        guard path.hasPrefix(rootDirectory) else { return }
        openDiffReview(path: path, oldContent: oldContent, newContent: newContent)
    }

    /// Open a diff review tab for a file changed by an agent.
    func openDiffReview(path: String, oldContent: String?, newContent: String?) {
        // If a diff review tab for this path is already open, switch to it
        if let existingIndex = openFiles.firstIndex(where: { $0.path == path && $0.isDiffReview }) {
            selectFile(existingIndex)
            return
        }

        let diffPanel = DiffReviewPanel(filePath: path, oldContent: oldContent, newContent: newContent)
        diffPanel.onReviewComplete = { [weak self] reviewedPath, wasAccepted in
            guard let self else { return }
            // Close the diff tab
            if let idx = self.openFiles.firstIndex(where: { $0.path == reviewedPath && $0.isDiffReview }) {
                self.closeFile(idx)
            }
            // Reload the editor tab (suppress file watcher to avoid re-triggering banner)
            if let editorIdx = self.openFiles.firstIndex(where: { $0.path == reviewedPath && $0.editor != nil }) {
                let editorView = self.openFiles[editorIdx].editor?.editorView
                editorView?.suppressNextExternalChange = true
                try? editorView?.buffer.reload()
                editorView?.dismissAgentBanner()
                editorView?.needsDisplay = true
            }
        }

        let file = OpenFile(path: path, panel: diffPanel)
        openFiles.append(file)
        selectFile(openFiles.count - 1)
        rebuildTabBar()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        // Sub-tab bar for open files
        tabBar = NSView()
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.wantsLayer = true
        tabBar.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(tabBar)

        tabScrollView = NSScrollView()
        tabScrollView.translatesAutoresizingMaskIntoConstraints = false
        tabScrollView.drawsBackground = false
        tabScrollView.hasHorizontalScroller = false
        tabScrollView.hasVerticalScroller = false
        tabScrollView.borderType = .noBorder
        tabBar.addSubview(tabScrollView)

        tabStackView = NSStackView()
        tabStackView.orientation = .horizontal
        tabStackView.spacing = 1
        tabStackView.alignment = .centerY
        tabStackView.translatesAutoresizingMaskIntoConstraints = false
        tabScrollView.documentView = tabStackView

        // Bottom border
        let bottomBorder = NSView()
        bottomBorder.translatesAutoresizingMaskIntoConstraints = false
        bottomBorder.wantsLayer = true
        bottomBorder.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        tabBar.addSubview(bottomBorder)

        // Split container with primary editor slot
        primarySlot = EditorSlot()
        activeSlot = primarySlot
        splitContainer = PaneContainerView()
        splitContainer.translatesAutoresizingMaskIntoConstraints = false
        splitContainer.setRoot(primarySlot)
        splitContainer.onClosePane = { [weak self] pane in
            self?.handleSplitPaneClosed(pane)
        }
        addSubview(splitContainer)

        // Drop zone overlay for drag-to-split (frame-based positioning)
        splitDropZone = SplitDropZoneView()
        splitDropZone.translatesAutoresizingMaskIntoConstraints = true
        addSubview(splitDropZone)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 36),

            tabScrollView.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor, constant: 8),
            tabScrollView.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor, constant: -8),
            tabScrollView.topAnchor.constraint(equalTo: tabBar.topAnchor, constant: 4),
            tabScrollView.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: -4),

            tabStackView.leadingAnchor.constraint(equalTo: tabScrollView.leadingAnchor),
            tabStackView.topAnchor.constraint(equalTo: tabScrollView.topAnchor),
            tabStackView.bottomAnchor.constraint(equalTo: tabScrollView.bottomAnchor),
            tabStackView.heightAnchor.constraint(equalTo: tabScrollView.heightAnchor),

            bottomBorder.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor),
            bottomBorder.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor),
            bottomBorder.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor),
            bottomBorder.heightAnchor.constraint(equalToConstant: 1),

            splitContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            splitContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        showWelcome()
    }

    private func showWelcome() {
        let label = NSTextField(labelWithString: "Open a file from the sidebar")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 14)
        label.textColor = NSColor(white: 0.4, alpha: 1.0)
        label.alignment = .center
        primarySlot.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: primarySlot.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: primarySlot.centerYAnchor),
        ])
        welcomeLabel = label
    }

    // MARK: - File Management

    func openFile(_ path: String) {
        // Check if already open
        if let existingIndex = openFiles.firstIndex(where: { $0.path == path }) {
            selectFile(existingIndex)
            return
        }

        let panel: NSView
        let lowerPath = path.lowercased()
        if lowerPath.hasSuffix(".pdf") {
            let pdfPanel = PDFPanel()
            pdfPanel.loadPDF(at: path)
            panel = pdfPanel
        } else if lowerPath.hasSuffix(".ipynb") {
            let notebookPanel = NotebookPanel(projectDirectory: rootDirectory)
            do {
                try notebookPanel.loadNotebook(at: path)
            } catch {
                NSLog("Failed to open notebook: \(error)")
                return
            }
            panel = notebookPanel
        } else {
            let editor = EditorPanel()
            do {
                try editor.openFile(path)
            } catch {
                NSLog("Failed to open file: \(error)")
                return
            }
            editor.editorView.navigationDelegate = self
            editor.compileDelegate = self
            panel = editor
        }

        let file = OpenFile(path: path, panel: panel)
        openFiles.append(file)
        selectFile(openFiles.count - 1)
        rebuildTabBar()
    }

    func createNewFile() {
        let editor = EditorPanel()
        // Untitled file with no path — will prompt on save
        let file = OpenFile(path: "", panel: editor)
        openFiles.append(file)
        selectFile(openFiles.count - 1)
        rebuildTabBar()
    }

    func selectFile(_ index: Int) {
        guard index >= 0, index < openFiles.count else { return }
        activeFileIndex = index
        welcomeLabel?.removeFromSuperview()
        welcomeLabel = nil

        let panel = openFiles[index].panel

        // Check if this panel is already visible in a split slot
        if let slot = slotContaining(panel) {
            activeSlot = slot
            splitContainer.focusedPane = slot
        } else {
            // Show in the currently active slot
            let slot = activeSlot ?? primarySlot!
            slot.showPanel(panel)
        }

        // Make the content the first responder
        DispatchQueue.main.async {
            if let editor = panel as? EditorPanel {
                editor.window?.makeFirstResponder(editor.editorView)
            } else {
                panel.window?.makeFirstResponder(panel)
            }
        }

        // Update file explorer active highlight
        fileExplorer.activeFilePath = openFiles[index].path

        updateTabHighlights()
    }

    /// Find which EditorSlot (if any) currently displays the given panel.
    private func slotContaining(_ panel: NSView) -> EditorSlot? {
        for leaf in splitContainer.allLeafViews {
            if let slot = leaf as? EditorSlot, slot.currentPanel === panel {
                return slot
            }
        }
        return nil
    }

    func closeFile(_ index: Int) {
        guard index >= 0, index < openFiles.count else { return }

        let file = openFiles[index]
        // Check if dirty — prompt save
        let isDirty: Bool
        if let editor = file.editor {
            isDirty = editor.editorView.buffer.isDirty
        } else if let notebook = file.notebook {
            isDirty = notebook.store.isDirty
        } else {
            isDirty = false
        }

        if isDirty {
            let alert = NSAlert()
            alert.messageText = "Save \(file.name.isEmpty ? "Untitled" : file.name)?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let editor = file.editor {
                    if file.path.isEmpty {
                        saveFileAs(index)
                    } else {
                        try? editor.editorView.buffer.save()
                    }
                } else if let notebook = file.notebook {
                    try? notebook.store.save()
                }
            } else if response == .alertThirdButtonReturn {
                return // Cancel
            }
        }

        // Remove panel from any split slot
        if let slot = slotContaining(file.panel) {
            if slot !== primarySlot && splitContainer.leafCount > 1 {
                slot.clear()
                splitContainer.removePaneAndCollapse(slot)
                if activeSlot === slot {
                    activeSlot = primarySlot
                    splitContainer.focusedPane = primarySlot
                }
            } else {
                slot.clear()
            }
        }

        file.editor?.editorView.cleanup()
        openFiles.remove(at: index)

        if openFiles.isEmpty {
            activeFileIndex = -1
            fileExplorer.activeFilePath = nil
            showWelcome()
        } else {
            selectFile(min(activeFileIndex, openFiles.count - 1))
        }
        rebuildTabBar()
    }

    func saveFileAs(_ index: Int) {
        guard index >= 0, index < openFiles.count else { return }
        let savePanel = NSSavePanel()
        savePanel.directoryURL = URL(fileURLWithPath: rootDirectory)
        savePanel.nameFieldStringValue = openFiles[index].name.isEmpty ? "Untitled" : openFiles[index].name
        savePanel.begin { [weak self] response in
            guard response == .OK, let url = savePanel.url else { return }
            if let editor = self?.openFiles[index].editor {
                try? editor.editorView.buffer.saveAs(url.path)
                editor.updateFileInfo()
            } else if let notebook = self?.openFiles[index].notebook {
                try? notebook.store.saveAs(url.path)
            }
            self?.rebuildTabBar()
        }
    }

    // MARK: - Tab Bar

    private func rebuildTabBar() {
        tabStackView.arrangedSubviews.forEach {
            tabStackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        for (i, file) in openFiles.enumerated() {
            // Add separator before tab (except first)
            if i > 0 {
                let sep = TabSeparatorView()
                let prevActive = (i - 1) == activeFileIndex
                let curActive = i == activeFileIndex
                sep.isHidden = prevActive || curActive
                tabStackView.addArrangedSubview(sep)
            }

            let fileDirty = file.editor?.editorView.buffer.isDirty ?? file.notebook?.store.isDirty ?? false
            let tab = ProjectFileTab(
                title: file.name.isEmpty ? "Untitled" : file.name,
                filePath: file.path,
                isActive: i == activeFileIndex,
                isDirty: fileDirty,
                tabIndex: i
            )
            let capturedIndex = i
            tab.onSelect = { [weak self] in self?.selectFile(capturedIndex) }
            tab.onClose = { [weak self] in self?.closeFile(capturedIndex) }
            tab.onCloseOthers = { [weak self] in self?.closeOtherFiles(capturedIndex) }
            tab.onCloseAll = { [weak self] in self?.closeAllFiles() }
            tab.onCloseToRight = { [weak self] in self?.closeFilesToRight(capturedIndex) }
            tab.onRevealInFinder = { [weak self] in
                guard let path = self?.openFiles[capturedIndex].path, !path.isEmpty else { return }
                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
            }
            tab.onCopyPath = { [weak self] in
                guard let path = self?.openFiles[capturedIndex].path, !path.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
            tab.onHoverChanged = { [weak self] hovered in
                self?.updateSeparatorVisibility(hoveredIndex: hovered ? capturedIndex : nil)
            }
            tab.onTabDragBegan = { [weak self] in self?.handleTabDragBegan(capturedIndex) }
            tab.onTabDragMoved = { [weak self] point in self?.handleTabDragMoved(capturedIndex, windowPoint: point) }
            tab.onTabDragEnded = { [weak self] point in self?.handleTabDragEnded(capturedIndex, windowPoint: point) }
            tabStackView.addArrangedSubview(tab)
        }
    }

    private func updateSeparatorVisibility(hoveredIndex: Int?) {
        // Separators are at even indices (0, 2, 4...) between tabs
        // Tabs are at odd-ish indices — actually separators are inserted before each tab except first
        // Layout: [tab0, sep, tab1, sep, tab2, ...]
        // sep at arranged index (2*i - 1) for i >= 1
        for (viewIndex, view) in tabStackView.arrangedSubviews.enumerated() {
            guard let sep = view as? TabSeparatorView else { continue }
            // Find neighboring tab indices
            let tabBefore = viewIndex / 2 - (viewIndex % 2 == 0 ? 1 : 0)
            let tabAfter = tabBefore + 1
            let nearActive = tabBefore == activeFileIndex || tabAfter == activeFileIndex
            let nearHovered = hoveredIndex != nil && (tabBefore == hoveredIndex || tabAfter == hoveredIndex)
            sep.setVisible(!(nearActive || nearHovered))
        }
    }

    private func closeOtherFiles(_ keepIndex: Int) {
        for i in stride(from: openFiles.count - 1, through: 0, by: -1) where i != keepIndex {
            openFiles[i].editor?.editorView.cleanup()
            openFiles.remove(at: i)
        }
        collapseAllSplits()
        activeFileIndex = 0
        if openFiles.isEmpty {
            activeFileIndex = -1
            showWelcome()
        } else {
            selectFile(0)
        }
        rebuildTabBar()
    }

    private func closeAllFiles() {
        for file in openFiles { file.editor?.editorView.cleanup() }
        openFiles.removeAll()
        collapseAllSplits()
        activeFileIndex = -1
        fileExplorer.activeFilePath = nil
        primarySlot.clear()
        showWelcome()
        rebuildTabBar()
    }

    private func closeFilesToRight(_ fromIndex: Int) {
        for i in stride(from: openFiles.count - 1, through: fromIndex + 1, by: -1) {
            if let slot = slotContaining(openFiles[i].panel), slot !== primarySlot, splitContainer.leafCount > 1 {
                slot.clear()
                splitContainer.removePaneAndCollapse(slot)
            }
            openFiles[i].editor?.editorView.cleanup()
            openFiles.remove(at: i)
        }
        if activeFileIndex > fromIndex {
            selectFile(fromIndex)
        }
        rebuildTabBar()
    }

    /// Collapse all split panes back to a single primary slot.
    private func collapseAllSplits() {
        let allLeaves = splitContainer.allLeafViews.compactMap { $0 as? EditorSlot }
        for slot in allLeaves where slot !== primarySlot {
            slot.clear()
            if splitContainer.leafCount > 1 {
                splitContainer.removePaneAndCollapse(slot)
            }
        }
        activeSlot = primarySlot
        splitContainer.focusedPane = primarySlot
    }

    /// Handle a split pane being closed via its header close button.
    private func handleSplitPaneClosed(_ pane: NSView) {
        guard let slot = pane as? EditorSlot else { return }
        if splitContainer.leafCount <= 1 {
            // Only one pane left, don't close — just clear it
            return
        }
        slot.clear()
        splitContainer.removePaneAndCollapse(slot)
        if activeSlot === slot {
            activeSlot = splitContainer.allLeafViews.first as? EditorSlot ?? primarySlot
            splitContainer.focusedPane = activeSlot
        }
        // Update active file based on what the new active slot shows
        if let slot = activeSlot, let panel = slot.currentPanel,
           let idx = openFiles.firstIndex(where: { $0.panel === panel }) {
            activeFileIndex = idx
        }
        updateTabHighlights()
    }

    private func updateTabHighlights() {
        var tabIdx = 0
        for view in tabStackView.arrangedSubviews {
            if let tab = view as? ProjectFileTab {
                tab.setActive(tabIdx == activeFileIndex)
                tabIdx += 1
            }
        }
        updateSeparatorVisibility(hoveredIndex: nil)
    }

    /// The display title for the workspace tab bar
    var directoryName: String {
        (rootDirectory as NSString).lastPathComponent
    }

    /// Returns the file paths of all currently open files in this project panel.
    var openFilePaths: [String] {
        openFiles.compactMap { $0.path.isEmpty ? nil : $0.path }
    }

    /// Opens the given files (used during session restore).
    func restoreOpenFiles(_ paths: [String]) {
        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            openFile(path)
        }
    }

    // MARK: - Tab Drag to Split

    private func handleTabDragBegan(_ tabIndex: Int) {
        dragSourceTabIndex = tabIndex
        // Position drop zone over the split container area
        let containerFrame = splitContainer.convert(splitContainer.bounds, to: self)
        splitDropZone.frame = containerFrame
        splitDropZone.positionOverArea(frame: NSRect(origin: .zero, size: containerFrame.size))
        splitDropZone.show()
    }

    private func handleTabDragMoved(_ tabIndex: Int, windowPoint: NSPoint) {
        let containerFrame = splitContainer.convert(splitContainer.bounds, to: self)
        let container = splitContainer!

        // Check if hovering over a specific pane (when there are multiple)
        if container.leafCount > 1 {
            if let (pane, paneFrame) = container.paneAt(windowPoint: windowPoint) {
                let frameInSelf = container.convert(paneFrame, to: self)
                splitDropZone.frame = frameInSelf
                splitDropZone.positionOverPane(pane, paneFrame: NSRect(origin: .zero, size: frameInSelf.size))
                splitDropZone.updateHover(at: windowPoint)
                return
            }
        }

        // Single pane or outside any pane — show over entire area
        splitDropZone.frame = containerFrame
        splitDropZone.positionOverArea(frame: NSRect(origin: .zero, size: containerFrame.size))
        splitDropZone.updateHover(at: windowPoint)
    }

    private func handleTabDragEnded(_ tabIndex: Int, windowPoint: NSPoint) {
        let result = splitDropZone.dropResult
        splitDropZone.hide()
        dragSourceTabIndex = -1

        guard let result = result,
              let direction = result.zone.splitDirection else { return }

        splitFileToNewPane(fileIndex: tabIndex, direction: direction, targetPane: result.targetPane)
    }

    /// Move a file into a new split pane.
    private func splitFileToNewPane(fileIndex: Int, direction: SplitDirection, targetPane: NSView?) {
        guard fileIndex >= 0, fileIndex < openFiles.count else { return }
        let panel = openFiles[fileIndex].panel

        // If this panel is already in a slot, remove it from that slot first
        if let existingSlot = slotContaining(panel) {
            existingSlot.clear()
            // If the existing slot is empty and not the only pane, collapse it
            if splitContainer.leafCount > 1 {
                splitContainer.removePaneAndCollapse(existingSlot)
                if activeSlot === existingSlot {
                    activeSlot = primarySlot
                }
            }
        }

        let newSlot = EditorSlot()
        newSlot.showPanel(panel)

        if let target = targetPane {
            splitContainer.split(view: target, with: newSlot, direction: direction)
        } else {
            let targetSlot = activeSlot ?? primarySlot!
            splitContainer.split(view: targetSlot, with: newSlot, direction: direction)
        }

        activeSlot = newSlot
        splitContainer.focusedPane = newSlot
        activeFileIndex = fileIndex
        updateTabHighlights()
    }

    // MARK: - Open File in Split

    /// Open a file in a new split pane (used for LaTeX PDF preview, etc.)
    func openFileInSplit(_ path: String, direction: SplitDirection) {
        // Check if already open
        if let existingIndex = openFiles.firstIndex(where: { $0.path == path }) {
            // If already in a split pane, just focus it
            if let slot = slotContaining(openFiles[existingIndex].panel) {
                activeSlot = slot
                activeFileIndex = existingIndex
                splitContainer.focusedPane = slot
                updateTabHighlights()
                rebuildTabBar()
                return
            }
            // Otherwise split it out
            splitFileToNewPane(fileIndex: existingIndex, direction: direction, targetPane: activeSlot ?? primarySlot)
            rebuildTabBar()
            return
        }

        // Open the file
        let panel: NSView
        let lowerPath = path.lowercased()
        if lowerPath.hasSuffix(".pdf") {
            let pdfPanel = PDFPanel()
            pdfPanel.loadPDF(at: path)
            panel = pdfPanel
        } else if lowerPath.hasSuffix(".ipynb") {
            let notebookPanel = NotebookPanel(projectDirectory: rootDirectory)
            do {
                try notebookPanel.loadNotebook(at: path)
            } catch {
                NSLog("Failed to open notebook: \(error)")
                return
            }
            panel = notebookPanel
        } else {
            let editor = EditorPanel()
            do {
                try editor.openFile(path)
            } catch {
                NSLog("Failed to open file: \(error)")
                return
            }
            editor.editorView.navigationDelegate = self
            editor.compileDelegate = self
            panel = editor
        }

        let file = OpenFile(path: path, panel: panel)
        openFiles.append(file)
        rebuildTabBar()

        splitFileToNewPane(fileIndex: openFiles.count - 1, direction: direction, targetPane: activeSlot ?? primarySlot)
    }
}

// MARK: - FileExplorerDelegate

extension ProjectPanel: FileExplorerDelegate {
    func fileExplorer(_ explorer: FileExplorerView, didSelectFile path: String) {
        openFile(path)
    }

    func fileExplorer(_ explorer: FileExplorerView, didRequestNewFileIn directory: String) {
        createNewFile()
    }
}

// MARK: - EditorViewNavigationDelegate

extension ProjectPanel: EditorViewNavigationDelegate {
    func editorView(_ editorView: EditorView, openFileAtPath path: String, line: Int, column: Int) {
        openFile(path)
        // After opening, navigate to the target position (only for editor files)
        if let idx = openFiles.firstIndex(where: { $0.path == path }),
           let editor = openFiles[idx].editor {
            editor.editorView.navigateTo(line: line, column: column)
        }
    }
}

// MARK: - LatexCompileDelegate

extension ProjectPanel: LatexCompileDelegate {
    func editorPanel(_ panel: EditorPanel, didCompileLatexToPDF pdfPath: String) {
        openFileInSplit(pdfPath, direction: .right)
    }
}

// MARK: - Tab Separator

class TabSeparatorView: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 1),
            heightAnchor.constraint(equalToConstant: 14),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.allowsImplicitAnimation = true
            self.animator().alphaValue = visible ? 1.0 : 0.0
        }
    }
}

// MARK: - File Icon Helper

private func fileIconName(for path: String) -> String {
    let ext = (path.lowercased() as NSString).pathExtension
    switch ext {
    case "swift": return "swift"
    case "js", "mjs", "cjs": return "j.square.fill"
    case "ts", "tsx": return "t.square.fill"
    case "jsx": return "j.square.fill"
    case "py": return "p.square.fill"
    case "rs": return "r.square.fill"
    case "go": return "g.square.fill"
    case "c", "h": return "c.square.fill"
    case "cpp", "cc", "hpp", "cxx": return "c.square.fill"
    case "zig": return "z.square.fill"
    case "json": return "curlybraces.square.fill"
    case "yaml", "yml": return "list.bullet.indent"
    case "md", "markdown": return "m.square.fill"
    case "html", "htm": return "chevron.left.forwardslash.chevron.right"
    case "css", "scss": return "paintbrush.fill"
    case "sh", "zsh", "bash": return "terminal.fill"
    case "toml": return "gearshape"
    case "ipynb": return "book.fill"
    case "pdf": return "doc.richtext.fill"
    case "tex", "sty", "cls": return "doc.text.fill"
    case "bib": return "books.vertical.fill"
    default: return "doc.text"
    }
}

private func fileIconColor(for path: String) -> NSColor {
    let ext = (path.lowercased() as NSString).pathExtension
    switch ext {
    case "swift": return .systemOrange
    case "js", "mjs", "cjs": return .systemYellow
    case "ts", "tsx": return .systemBlue
    case "jsx": return .systemCyan
    case "py": return NSColor(red: 0.3, green: 0.75, blue: 0.35, alpha: 1.0)
    case "rs": return NSColor(red: 0.87, green: 0.37, blue: 0.2, alpha: 1.0)
    case "go": return .systemCyan
    case "c", "h": return .systemBlue
    case "cpp", "cc", "hpp", "cxx": return .systemPurple
    case "zig": return NSColor(red: 0.95, green: 0.65, blue: 0.15, alpha: 1.0)
    case "json": return .systemYellow
    case "yaml", "yml": return .systemPink
    case "md", "markdown": return NSColor(white: 0.6, alpha: 1.0)
    case "html", "htm": return .systemOrange
    case "css", "scss": return .systemBlue
    case "sh", "zsh", "bash": return NSColor(white: 0.6, alpha: 1.0)
    case "toml": return NSColor(white: 0.5, alpha: 1.0)
    case "ipynb": return .systemOrange
    case "pdf": return .systemRed
    case "tex", "sty", "cls": return NSColor(red: 0.0, green: 0.514, blue: 0.494, alpha: 1.0)
    case "bib": return NSColor(red: 0.671, green: 0.557, blue: 0.180, alpha: 1.0)
    default: return NSColor(white: 0.5, alpha: 1.0)
    }
}

// MARK: - Project File Sub-Tab

class ProjectFileTab: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onCloseOthers: (() -> Void)?
    var onCloseAll: (() -> Void)?
    var onCloseToRight: (() -> Void)?
    var onRevealInFinder: (() -> Void)?
    var onCopyPath: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onTabDragBegan: (() -> Void)?
    var onTabDragMoved: ((NSPoint) -> Void)?
    var onTabDragEnded: ((NSPoint) -> Void)?

    private var isActiveTab: Bool
    private var isDirtyFile: Bool
    private var isHovered: Bool = false
    private let filePath: String
    let tabIndex: Int
    private var dragStartPoint: NSPoint = .zero
    private var isTabDragging: Bool = false

    private let iconView: NSImageView
    private let titleLabel: NSTextField
    private let closeBtn: NSButton
    private let dirtyDot: NSView
    private let activeDot: NSView

    private let activeBg = NSColor(white: 1.0, alpha: 0.08)
    private let hoverBg = NSColor(white: 1.0, alpha: 0.04)
    private let pressedBg = NSColor(white: 1.0, alpha: 0.12)

    init(title: String, filePath: String, isActive: Bool, isDirty: Bool, tabIndex: Int) {
        self.isActiveTab = isActive
        self.isDirtyFile = isDirty
        self.filePath = filePath
        self.tabIndex = tabIndex
        self.iconView = NSImageView()
        self.titleLabel = NSTextField(labelWithString: title)
        self.closeBtn = NSButton()
        self.dirtyDot = NSView()
        self.activeDot = NSView()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = isActive ? activeBg.cgColor : NSColor.clear.cgColor

        // File type icon
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        let iconCfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        let symbolName = fileIconName(for: filePath)
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(iconCfg)
        let iconColor = fileIconColor(for: filePath)
        iconView.contentTintColor = isActive ? iconColor : iconColor.withAlphaComponent(0.5)
        addSubview(iconView)

        // Title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 11, weight: isActive ? .medium : .regular)
        titleLabel.textColor = isActive ? NSColor(white: 0.92, alpha: 1.0) : NSColor(white: 0.50, alpha: 1.0)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        // Close button
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.bezelStyle = .texturedRounded
        closeBtn.isBordered = false
        closeBtn.title = ""
        let cfg = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        closeBtn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?.withSymbolConfiguration(cfg)
        closeBtn.contentTintColor = NSColor(white: 0.35, alpha: 1.0)
        closeBtn.target = self
        closeBtn.action = #selector(closeTapped)
        // Show close button only on active tab at rest
        closeBtn.alphaValue = isActive && !isDirty ? 0.8 : 0.0
        addSubview(closeBtn)

        // Dirty dot (overlays close button position)
        dirtyDot.translatesAutoresizingMaskIntoConstraints = false
        dirtyDot.wantsLayer = true
        dirtyDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        dirtyDot.layer?.cornerRadius = 3.5
        dirtyDot.alphaValue = isDirty ? 1.0 : 0.0
        addSubview(dirtyDot)

        // Active dot indicator (centered at bottom, color reflects file state)
        activeDot.translatesAutoresizingMaskIntoConstraints = false
        activeDot.wantsLayer = true
        activeDot.layer?.backgroundColor = Self.dotColor(for: isDirty).cgColor
        activeDot.layer?.cornerRadius = 1.5
        activeDot.alphaValue = isActive ? 1.0 : 0.0
        addSubview(activeDot)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            heightAnchor.constraint(equalToConstant: 28),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeBtn.leadingAnchor, constant: -4),

            closeBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeBtn.widthAnchor.constraint(equalToConstant: 14),
            closeBtn.heightAnchor.constraint(equalToConstant: 14),

            dirtyDot.centerXAnchor.constraint(equalTo: closeBtn.centerXAnchor),
            dirtyDot.centerYAnchor.constraint(equalTo: closeBtn.centerYAnchor),
            dirtyDot.widthAnchor.constraint(equalToConstant: 7),
            dirtyDot.heightAnchor.constraint(equalToConstant: 7),

            activeDot.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            activeDot.centerXAnchor.constraint(equalTo: centerXAnchor),
            activeDot.widthAnchor.constraint(equalToConstant: 3),
            activeDot.heightAnchor.constraint(equalToConstant: 3),
        ])

        setupTracking()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Returns the dot color for the given dirty state:
    /// - Clean: subtle white
    /// - Dirty (unsaved): orange
    private static func dotColor(for isDirty: Bool) -> NSColor {
        isDirty ? NSColor.systemOrange : NSColor(white: 1.0, alpha: 0.50)
    }

    func setActive(_ active: Bool) {
        isActiveTab = active

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        layer?.backgroundColor = active ? activeBg.cgColor : NSColor.clear.cgColor
        CATransaction.commit()

        titleLabel.font = .systemFont(ofSize: 11, weight: active ? .medium : .regular)
        titleLabel.textColor = active ? NSColor(white: 0.92, alpha: 1.0) : NSColor(white: 0.50, alpha: 1.0)
        let iconColor = fileIconColor(for: filePath)
        iconView.contentTintColor = active ? iconColor : iconColor.withAlphaComponent(0.5)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            activeDot.animator().alphaValue = active ? 1.0 : 0.0
        }

        updateCloseButtonVisibility()
    }

    func updateDirtyState(_ dirty: Bool) {
        isDirtyFile = dirty

        // Animate the dot color change
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        activeDot.layer?.backgroundColor = Self.dotColor(for: dirty).cgColor
        CATransaction.commit()

        updateCloseButtonVisibility()
    }

    private func updateCloseButtonVisibility() {
        let showClose: Bool
        let showDot: Bool

        if isDirtyFile {
            if isHovered || isActiveTab {
                showClose = true
                showDot = false
            } else {
                showClose = false
                showDot = true
            }
        } else {
            showClose = isActiveTab || isHovered
            showDot = false
        }

        // Tint close button orange when dirty
        closeBtn.contentTintColor = isDirtyFile && showClose
            ? NSColor.systemOrange
            : NSColor(white: 0.35, alpha: 1.0)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.allowsImplicitAnimation = true
            closeBtn.animator().alphaValue = showClose ? 0.8 : 0.0
            dirtyDot.animator().alphaValue = showDot ? 1.0 : 0.0
        }
    }

    @objc private func closeTapped() { onClose?() }

    override func mouseDown(with event: NSEvent) {
        dragStartPoint = event.locationInWindow
        isTabDragging = false
        // Brief press feedback
        layer?.backgroundColor = pressedBg.cgColor
        onSelect?()
    }

    override func mouseDragged(with event: NSEvent) {
        let dx = abs(event.locationInWindow.x - dragStartPoint.x)
        let dy = abs(event.locationInWindow.y - dragStartPoint.y)
        if dx > 4 || dy > 4 {
            if !isTabDragging {
                isTabDragging = true
                alphaValue = 0.5
                onTabDragBegan?()
            }
            onTabDragMoved?(event.locationInWindow)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isTabDragging {
            alphaValue = 1.0
            isTabDragging = false
            onTabDragEnded?(event.locationInWindow)
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.1)
        layer?.backgroundColor = isActiveTab ? activeBg.cgColor : (isHovered ? hoverBg.cgColor : NSColor.clear.cgColor)
        CATransaction.commit()
    }

    // MARK: - Right-click context menu

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()

        let closeItem = NSMenuItem(title: "Close", action: #selector(contextClose), keyEquivalent: "")
        closeItem.target = self
        menu.addItem(closeItem)

        let closeOthersItem = NSMenuItem(title: "Close Others", action: #selector(contextCloseOthers), keyEquivalent: "")
        closeOthersItem.target = self
        menu.addItem(closeOthersItem)

        let closeAllItem = NSMenuItem(title: "Close All", action: #selector(contextCloseAll), keyEquivalent: "")
        closeAllItem.target = self
        menu.addItem(closeAllItem)

        let closeRightItem = NSMenuItem(title: "Close Tabs to the Right", action: #selector(contextCloseToRight), keyEquivalent: "")
        closeRightItem.target = self
        menu.addItem(closeRightItem)

        menu.addItem(NSMenuItem.separator())

        if !filePath.isEmpty {
            let copyItem = NSMenuItem(title: "Copy Path", action: #selector(contextCopyPath), keyEquivalent: "")
            copyItem.target = self
            menu.addItem(copyItem)

            let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(contextRevealInFinder), keyEquivalent: "")
            revealItem.target = self
            menu.addItem(revealItem)
        }

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func contextClose() { onClose?() }
    @objc private func contextCloseOthers() { onCloseOthers?() }
    @objc private func contextCloseAll() { onCloseAll?() }
    @objc private func contextCloseToRight() { onCloseToRight?() }
    @objc private func contextCopyPath() { onCopyPath?() }
    @objc private func contextRevealInFinder() { onRevealInFinder?() }

    // MARK: - Hover tracking

    private func setupTracking() {
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHoverChanged?(true)
        if !isActiveTab {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            layer?.backgroundColor = hoverBg.cgColor
            CATransaction.commit()
        }
        updateCloseButtonVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHoverChanged?(false)
        if !isActiveTab {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            layer?.backgroundColor = NSColor.clear.cgColor
            CATransaction.commit()
        }
        updateCloseButtonVisibility()
    }
}

// MARK: - Editor Slot (Split Pane Container)

/// A lightweight container view that acts as a leaf in PaneContainerView.
/// Holds one file panel (EditorPanel, PDFPanel, NotebookPanel) at a time,
/// allowing the split layout to remain stable while swapping file content.
class EditorSlot: NSView {
    private(set) var currentPanel: NSView?

    override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func showPanel(_ panel: NSView) {
        if currentPanel === panel { return }
        currentPanel?.removeFromSuperview()
        currentPanel = panel
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func clear() {
        currentPanel?.removeFromSuperview()
        currentPanel = nil
    }

    /// Info for PaneHeaderBar display.
    var headerInfo: (icon: String, title: String) {
        guard let panel = currentPanel else { return ("square", "Empty") }
        if let editor = panel as? EditorPanel {
            return ("doc.text", editor.title)
        } else if let pdf = panel as? PDFPanel {
            return ("doc.richtext", pdf.title.isEmpty ? "PDF" : pdf.title)
        } else if let notebook = panel as? NotebookPanel {
            return ("book", notebook.title.isEmpty ? "Notebook" : notebook.title)
        }
        return ("doc", "File")
    }
}
