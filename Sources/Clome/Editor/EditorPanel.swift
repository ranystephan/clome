import AppKit

/// Detects the git branch for a file by walking up parent directories.
func detectGitBranch(forFileAt filePath: String) -> String? {
    var dir = (filePath as NSString).deletingLastPathComponent
    while dir != "/" && !dir.isEmpty {
        let headPath = (dir as NSString).appendingPathComponent(".git/HEAD")
        if let contents = try? String(contentsOfFile: headPath, encoding: .utf8) {
            let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("ref: refs/heads/") {
                return String(trimmed.dropFirst("ref: refs/heads/".count))
            }
            // Detached HEAD — return short hash
            return String(trimmed.prefix(7))
        }
        dir = (dir as NSString).deletingLastPathComponent
    }
    return nil
}

/// Delegate for LaTeX compilation results.
@MainActor
protocol LatexCompileDelegate: AnyObject {
    func editorPanel(_ panel: EditorPanel, didCompileLatexToPDF pdfPath: String)
}

/// An editor panel that can be placed in any split pane.
/// Wraps EditorView with a find bar, minimap, and bottom status bar.
class EditorPanel: NSView {
    private(set) var editorView: EditorView
    private var findBar: FindBarView?
    private var findBarTopConstraint: NSLayoutConstraint?
    private var editorTopConstraint: NSLayoutConstraint!
    private var editorTopToFindBar: NSLayoutConstraint?
    private(set) var minimapView: MinimapView!
    private var minimapWidthConstraint: NSLayoutConstraint!
    private var minimapToggleBtn: NSButton!
    private var isMinimapVisible: Bool = true

    // Status bar
    private var statusBarView: NSView!
    private var gitBranchLabel: NSTextField!
    private var cursorPositionLabel: NSTextField!
    private var selectionInfoLabel: NSTextField!
    private var modifiedLabel: NSTextField!
    private var encodingLabel: NSTextField!
    private var lineEndingLabel: NSTextField!
    private var lineCountLabel: NSTextField!
    private var statusLanguageLabel: NSTextField!

    // LaTeX compile
    private var compileButton: NSButton?
    private var compileSpinner: NSProgressIndicator?
    private var isCompiling = false

    /// Delegate for opening compiled PDF
    weak var compileDelegate: LatexCompileDelegate?

    var title: String = "Editor" {
        didSet {
            NotificationCenter.default.post(name: .terminalSurfaceTitleChanged, object: self)
        }
    }

    init(buffer: TextBuffer = TextBuffer()) {
        self.editorView = EditorView(buffer: buffer)
        super.init(frame: .zero)
        wantsLayer = true
        setupUI()
        updateFileInfo()
        setupNotifications()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setupUI() {
        // Status bar
        statusBarView = NSView()
        statusBarView.translatesAutoresizingMaskIntoConstraints = false
        statusBarView.wantsLayer = true
        statusBarView.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1.0).cgColor
        addSubview(statusBarView)

        let statusFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let statusColor = NSColor(white: 0.50, alpha: 1.0)

        gitBranchLabel = NSTextField(labelWithString: "")
        gitBranchLabel.translatesAutoresizingMaskIntoConstraints = false
        gitBranchLabel.font = statusFont
        gitBranchLabel.textColor = statusColor
        statusBarView.addSubview(gitBranchLabel)

        cursorPositionLabel = NSTextField(labelWithString: "Ln 1, Col 1")
        cursorPositionLabel.translatesAutoresizingMaskIntoConstraints = false
        cursorPositionLabel.font = statusFont
        cursorPositionLabel.textColor = statusColor
        statusBarView.addSubview(cursorPositionLabel)

        selectionInfoLabel = NSTextField(labelWithString: "")
        selectionInfoLabel.translatesAutoresizingMaskIntoConstraints = false
        selectionInfoLabel.font = statusFont
        selectionInfoLabel.textColor = statusColor
        statusBarView.addSubview(selectionInfoLabel)

        modifiedLabel = NSTextField(labelWithString: "Modified")
        modifiedLabel.translatesAutoresizingMaskIntoConstraints = false
        modifiedLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        modifiedLabel.textColor = NSColor.systemOrange
        modifiedLabel.isHidden = true
        statusBarView.addSubview(modifiedLabel)

        encodingLabel = NSTextField(labelWithString: "UTF-8")
        encodingLabel.translatesAutoresizingMaskIntoConstraints = false
        encodingLabel.font = statusFont
        encodingLabel.textColor = statusColor
        statusBarView.addSubview(encodingLabel)

        lineEndingLabel = NSTextField(labelWithString: "LF")
        lineEndingLabel.translatesAutoresizingMaskIntoConstraints = false
        lineEndingLabel.font = statusFont
        lineEndingLabel.textColor = statusColor
        statusBarView.addSubview(lineEndingLabel)

        lineCountLabel = NSTextField(labelWithString: "")
        lineCountLabel.translatesAutoresizingMaskIntoConstraints = false
        lineCountLabel.font = statusFont
        lineCountLabel.textColor = statusColor
        statusBarView.addSubview(lineCountLabel)

        statusLanguageLabel = NSTextField(labelWithString: "")
        statusLanguageLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLanguageLabel.font = statusFont
        statusLanguageLabel.textColor = statusColor
        statusBarView.addSubview(statusLanguageLabel)

        // Minimap
        minimapView = MinimapView()
        minimapView.translatesAutoresizingMaskIntoConstraints = false
        minimapView.editorView = editorView
        editorView.minimapView = minimapView
        addSubview(minimapView)

        // Minimap toggle button (top-right corner, over the minimap)
        minimapToggleBtn = NSButton()
        minimapToggleBtn.translatesAutoresizingMaskIntoConstraints = false
        minimapToggleBtn.bezelStyle = .texturedRounded
        minimapToggleBtn.isBordered = false
        minimapToggleBtn.title = ""
        let toggleCfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        minimapToggleBtn.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Toggle Minimap")?.withSymbolConfiguration(toggleCfg)
        minimapToggleBtn.contentTintColor = NSColor(white: 0.4, alpha: 1.0)
        minimapToggleBtn.target = self
        minimapToggleBtn.action = #selector(toggleMinimap)
        minimapToggleBtn.alphaValue = 0
        addSubview(minimapToggleBtn)

        // Editor view
        editorView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(editorView)

        editorTopConstraint = editorView.topAnchor.constraint(equalTo: topAnchor)
        minimapWidthConstraint = minimapView.widthAnchor.constraint(equalToConstant: 80)

        NSLayoutConstraint.activate([
            // Editor
            editorTopConstraint,
            editorView.leadingAnchor.constraint(equalTo: leadingAnchor),
            editorView.trailingAnchor.constraint(equalTo: minimapView.leadingAnchor),
            editorView.bottomAnchor.constraint(equalTo: statusBarView.topAnchor),

            // Minimap
            minimapView.topAnchor.constraint(equalTo: topAnchor),
            minimapView.trailingAnchor.constraint(equalTo: trailingAnchor),
            minimapView.bottomAnchor.constraint(equalTo: statusBarView.topAnchor),
            minimapWidthConstraint,

            // Toggle button
            minimapToggleBtn.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            minimapToggleBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            minimapToggleBtn.widthAnchor.constraint(equalToConstant: 20),
            minimapToggleBtn.heightAnchor.constraint(equalToConstant: 20),

            // Status bar
            statusBarView.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBarView.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBarView.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusBarView.heightAnchor.constraint(equalToConstant: 22),

            // Status bar contents
            gitBranchLabel.leadingAnchor.constraint(equalTo: statusBarView.leadingAnchor, constant: 10),
            gitBranchLabel.centerYAnchor.constraint(equalTo: statusBarView.centerYAnchor),

            cursorPositionLabel.leadingAnchor.constraint(equalTo: gitBranchLabel.trailingAnchor, constant: 16),
            cursorPositionLabel.centerYAnchor.constraint(equalTo: statusBarView.centerYAnchor),

            selectionInfoLabel.leadingAnchor.constraint(equalTo: cursorPositionLabel.trailingAnchor, constant: 16),
            selectionInfoLabel.centerYAnchor.constraint(equalTo: statusBarView.centerYAnchor),

            modifiedLabel.centerXAnchor.constraint(equalTo: statusBarView.centerXAnchor),
            modifiedLabel.centerYAnchor.constraint(equalTo: statusBarView.centerYAnchor),

            statusLanguageLabel.trailingAnchor.constraint(equalTo: statusBarView.trailingAnchor, constant: -10),
            statusLanguageLabel.centerYAnchor.constraint(equalTo: statusBarView.centerYAnchor),

            lineEndingLabel.trailingAnchor.constraint(equalTo: statusLanguageLabel.leadingAnchor, constant: -14),
            lineEndingLabel.centerYAnchor.constraint(equalTo: statusBarView.centerYAnchor),

            encodingLabel.trailingAnchor.constraint(equalTo: lineEndingLabel.leadingAnchor, constant: -14),
            encodingLabel.centerYAnchor.constraint(equalTo: statusBarView.centerYAnchor),

            lineCountLabel.trailingAnchor.constraint(equalTo: encodingLabel.leadingAnchor, constant: -14),
            lineCountLabel.centerYAnchor.constraint(equalTo: statusBarView.centerYAnchor),
        ])
    }

    // MARK: - Minimap Toggle

    @objc private func toggleMinimap() {
        isMinimapVisible.toggle()

        let targetWidth: CGFloat = isMinimapVisible ? 80 : 0
        let toggleCfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        minimapToggleBtn.image = NSImage(
            systemSymbolName: isMinimapVisible ? "sidebar.right" : "sidebar.right",
            accessibilityDescription: "Toggle Minimap"
        )?.withSymbolConfiguration(toggleCfg)
        minimapToggleBtn.contentTintColor = isMinimapVisible
            ? NSColor(white: 0.4, alpha: 1.0)
            : NSColor(white: 0.3, alpha: 1.0)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            minimapWidthConstraint.animator().constant = targetWidth
            minimapView.animator().alphaValue = isMinimapVisible ? 1.0 : 0.0
            self.layoutSubtreeIfNeeded()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Track mouse in the minimap area to show/hide the toggle button
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let inMinimapZone = point.x > bounds.width - 100
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            minimapToggleBtn.animator().alphaValue = inMinimapZone ? 1.0 : 0.0
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            minimapToggleBtn.animator().alphaValue = 0.0
        }
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(showFindBar(_:)),
                                               name: .editorShowFindBar, object: editorView)
        NotificationCenter.default.addObserver(self, selector: #selector(hideFindBar),
                                               name: .editorDismissFindBar, object: editorView)
        NotificationCenter.default.addObserver(self, selector: #selector(handleCursorChanged),
                                               name: .editorCursorChanged, object: editorView)
    }

    @objc private func handleCursorChanged() {
        updateStatusBar()
    }

    @objc private func showFindBar(_ notification: Notification) {
        let showReplace = (notification.userInfo?["replace"] as? Bool) ?? false

        if findBar == nil {
            let bar = FindBarView()
            bar.editorView = editorView
            bar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bar)

            let topConstraint = bar.topAnchor.constraint(equalTo: topAnchor)
            NSLayoutConstraint.activate([
                topConstraint,
                bar.leadingAnchor.constraint(equalTo: leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            findBarTopConstraint = topConstraint

            // Adjust editor top
            editorTopConstraint.isActive = false
            editorTopToFindBar = editorView.topAnchor.constraint(equalTo: bar.bottomAnchor)
            editorTopToFindBar?.isActive = true

            findBar = bar
        }

        findBar?.showReplace = showReplace
        findBar?.focus()
    }

    @objc private func hideFindBar() {
        guard let bar = findBar else { return }
        bar.removeFromSuperview()
        findBar = nil
        editorTopToFindBar?.isActive = false
        editorTopToFindBar = nil
        editorTopConstraint.isActive = true
        window?.makeFirstResponder(editorView)
    }

    func openFile(_ path: String) throws {
        try editorView.openFile(path)
        minimapView.editorView = editorView
        editorView.minimapView = minimapView
        minimapView.invalidateCache()
        updateFileInfo()

        // Detect git branch on background queue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let branch = detectGitBranch(forFileAt: path)
            DispatchQueue.main.async {
                if let branch = branch {
                    self?.gitBranchLabel.stringValue = "⎇ \(branch)"
                } else {
                    self?.gitBranchLabel.stringValue = ""
                }
            }
        }
    }

    func updateFileInfo() {
        let buf = editorView.buffer
        title = buf.filePath.map { ($0 as NSString).lastPathComponent } ?? "Untitled"
        statusLanguageLabel.stringValue = buf.language ?? ""
        updateStatusBar()
        setupCompileButton()
    }

    // MARK: - LaTeX Compile

    private func setupCompileButton() {
        // Remove existing if any
        compileButton?.removeFromSuperview()
        compileSpinner?.removeFromSuperview()
        compileButton = nil
        compileSpinner = nil

        guard editorView.buffer.language == "latex" else { return }

        let btn = NSButton()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.bezelStyle = .texturedRounded
        btn.isBordered = false
        btn.title = ""
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        btn.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Compile LaTeX")?
            .withSymbolConfiguration(cfg)
        btn.contentTintColor = NSColor(red: 0.0, green: 0.75, blue: 0.65, alpha: 1.0)
        btn.toolTip = "Compile LaTeX (⌘⇧B)"
        btn.target = self
        btn.action = #selector(compileLaTeX)
        statusBarView.addSubview(btn)

        let spinner = NSProgressIndicator()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isHidden = true
        statusBarView.addSubview(spinner)

        NSLayoutConstraint.activate([
            btn.trailingAnchor.constraint(equalTo: statusLanguageLabel.leadingAnchor, constant: -8),
            btn.centerYAnchor.constraint(equalTo: statusBarView.centerYAnchor),
            btn.widthAnchor.constraint(equalToConstant: 18),
            btn.heightAnchor.constraint(equalToConstant: 18),

            spinner.centerXAnchor.constraint(equalTo: btn.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: btn.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
        ])

        compileButton = btn
        compileSpinner = spinner
    }

    @objc func compileLaTeX() {
        guard let texPath = editorView.buffer.filePath,
              editorView.buffer.language == "latex",
              !isCompiling else { return }

        // Save before compiling
        if editorView.buffer.isDirty {
            try? editorView.buffer.save()
        }

        isCompiling = true
        compileButton?.isHidden = true
        compileSpinner?.isHidden = false
        compileSpinner?.startAnimation(nil)

        // Pick best available engine
        let engines = LatexCompiler.availableEngines()
        let engine = engines.first ?? .pdflatex

        LatexCompiler.compile(texPath: texPath, engine: engine) { [weak self] result in
            guard let self = self else { return }
            self.isCompiling = false
            self.compileSpinner?.stopAnimation(nil)
            self.compileSpinner?.isHidden = true
            self.compileButton?.isHidden = false

            if result.success, let pdfPath = result.pdfPath {
                // Notify delegate to open PDF
                self.compileDelegate?.editorPanel(self, didCompileLatexToPDF: pdfPath)

                // Brief green flash on the compile button to indicate success
                self.compileButton?.contentTintColor = NSColor.systemGreen
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.compileButton?.contentTintColor = NSColor(red: 0.0, green: 0.75, blue: 0.65, alpha: 1.0)
                }
            } else {
                // Show error
                self.compileButton?.contentTintColor = NSColor.systemRed
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.compileButton?.contentTintColor = NSColor(red: 0.0, green: 0.75, blue: 0.65, alpha: 1.0)
                }

                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "LaTeX Compilation Failed"
                if result.errors.isEmpty {
                    alert.informativeText = result.log.suffix(500).description
                } else {
                    alert.informativeText = result.errors.prefix(5).joined(separator: "\n")
                }
                alert.addButton(withTitle: "OK")
                if let window = self.window {
                    alert.beginSheetModal(for: window)
                }
            }
        }
    }

    private func updateStatusBar() {
        let buf = editorView.buffer
        let cursor = buf.cursor

        // Cursor position (1-based)
        cursorPositionLabel.stringValue = "Ln \(cursor.line + 1), Col \(cursor.column + 1)"

        // Selection info
        if let selStart = cursor.selectionStart {
            let len = abs(cursor.offset - selStart)
            selectionInfoLabel.stringValue = "(\(len) selected)"
        } else if buf.cursors.count > 1 {
            selectionInfoLabel.stringValue = "\(buf.cursors.count) cursors"
        } else {
            selectionInfoLabel.stringValue = ""
        }

        // Line count
        lineCountLabel.stringValue = "\(buf.lineCount) lines"

        // Update dirty indicator
        modifiedLabel.isHidden = !buf.isDirty
    }
}
