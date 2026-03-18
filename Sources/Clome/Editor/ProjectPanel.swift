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
    private var editorContainer: NSView!
    private var welcomeLabel: NSTextField?

    struct OpenFile {
        let path: String
        let panel: NSView  // EditorPanel, NotebookPanel, or PDFPanel
        var editor: EditorPanel? { panel as? EditorPanel }
        var notebook: NotebookPanel? { panel as? NotebookPanel }
        var pdf: PDFPanel? { panel as? PDFPanel }
        var name: String { (path as NSString).lastPathComponent }
        var isNotebook: Bool { panel is NotebookPanel }
        var isPDF: Bool { panel is PDFPanel }
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

        // Editor container
        editorContainer = NSView()
        editorContainer.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.wantsLayer = true
        addSubview(editorContainer)

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

            editorContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            editorContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            editorContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            editorContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        showWelcome()
    }

    private func showWelcome() {
        let label = NSTextField(labelWithString: "Open a file from the sidebar")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 14)
        label.textColor = NSColor(white: 0.4, alpha: 1.0)
        label.alignment = .center
        editorContainer.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: editorContainer.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: editorContainer.centerYAnchor),
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
            let notebookPanel = NotebookPanel()
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

        editorContainer.subviews.forEach { $0.removeFromSuperview() }
        let contentView = openFiles[index].panel
        contentView.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: editorContainer.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor),
        ])

        // Make the content the first responder
        DispatchQueue.main.async {
            if let editor = contentView as? EditorPanel {
                editor.window?.makeFirstResponder(editor.editorView)
            } else {
                contentView.window?.makeFirstResponder(contentView)
            }
        }

        // Update file explorer active highlight
        fileExplorer.activeFilePath = openFiles[index].path

        updateTabHighlights()
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

        file.editor?.editorView.cleanup()
        openFiles.remove(at: index)

        if openFiles.isEmpty {
            activeFileIndex = -1
            fileExplorer.activeFilePath = nil
            editorContainer.subviews.forEach { $0.removeFromSuperview() }
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
        _ = openFiles[keepIndex].path
        for i in stride(from: openFiles.count - 1, through: 0, by: -1) where i != keepIndex {
            openFiles[i].editor?.editorView.cleanup()
            openFiles.remove(at: i)
        }
        activeFileIndex = 0
        if openFiles.isEmpty {
            activeFileIndex = -1
            editorContainer.subviews.forEach { $0.removeFromSuperview() }
            showWelcome()
        } else {
            selectFile(0)
        }
        rebuildTabBar()
    }

    private func closeAllFiles() {
        for file in openFiles { file.editor?.editorView.cleanup() }
        openFiles.removeAll()
        activeFileIndex = -1
        fileExplorer.activeFilePath = nil
        editorContainer.subviews.forEach { $0.removeFromSuperview() }
        showWelcome()
        rebuildTabBar()
    }

    private func closeFilesToRight(_ fromIndex: Int) {
        for i in stride(from: openFiles.count - 1, through: fromIndex + 1, by: -1) {
            openFiles[i].editor?.editorView.cleanup()
            openFiles.remove(at: i)
        }
        if activeFileIndex > fromIndex {
            selectFile(fromIndex)
        }
        rebuildTabBar()
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
        openFile(pdfPath)
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

    private var isActiveTab: Bool
    private var isDirtyFile: Bool
    private var isHovered: Bool = false
    private let filePath: String
    let tabIndex: Int

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
        // Brief press feedback
        layer?.backgroundColor = pressedBg.cgColor
        onSelect?()
    }

    override func mouseUp(with event: NSEvent) {
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
