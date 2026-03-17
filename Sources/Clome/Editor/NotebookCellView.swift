import AppKit
import WebKit

// MARK: - NotebookTextView Shortcut Delegate

@MainActor
protocol NotebookTextViewShortcutDelegate: AnyObject {
    func textViewDidShiftEnter()
    func textViewDidRequestFocus()
}

// MARK: - NotebookTextView

@MainActor
class NotebookTextView: NSTextView {
    weak var shortcutDelegate: NotebookTextViewShortcutDelegate?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36 && flags == .shift {
            shortcutDelegate?.textViewDidShiftEnter()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let clickLocation = event.locationInWindow
        super.mouseDown(with: event)
        // After the tracking loop ends (mouse-up), update focus.
        // Then collapse any accidental selection caused by layout shifts.
        shortcutDelegate?.textViewDidRequestFocus()
        if selectedRange().length > 0 {
            // Check if the user intentionally dragged — compare mouse-up position
            let upLocation = window?.mouseLocationOutsideOfEventStream ?? clickLocation
            let dist = hypot(upLocation.x - clickLocation.x, upLocation.y - clickLocation.y)
            if dist < 3 {
                // Click without meaningful drag — collapse selection to click point
                let clickInView = convert(clickLocation, from: nil)
                let charIndex = characterIndexForInsertion(at: clickInView)
                setSelectedRange(NSRange(location: charIndex, length: 0))
            }
        }
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            shortcutDelegate?.textViewDidRequestFocus()
        }
        return result
    }

    /// Forward scroll events to the notebook's outer scroll view so the
    /// notebook scrolls even when the cursor sits over a cell's source editor.
    override func scrollWheel(with event: NSEvent) {
        // Find the notebook scroll view (ancestor NSScrollView that is NOT our immediate enclosing one)
        if let notebookScroll = findNotebookScrollView() {
            notebookScroll.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    private func findNotebookScrollView() -> NSScrollView? {
        // Walk up: skip our own enclosing scroll view, return the next one
        var skippedFirst = false
        var current: NSView? = superview
        while let v = current {
            if let sv = v as? NSScrollView {
                if !skippedFirst {
                    skippedFirst = true
                } else {
                    return sv
                }
            }
            current = v.superview
        }
        return nil
    }
}

// MARK: - NotebookPassthroughScrollView
/// An NSScrollView that always forwards scroll events to the notebook's
/// outer scroll view. Used for cell source editors that auto-size to content.
@MainActor
class NotebookPassthroughScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        nextNotebookScrollView?.scrollWheel(with: event)
    }

    private var nextNotebookScrollView: NSScrollView? {
        var current: NSView? = superview
        while let v = current {
            if let sv = v as? NSScrollView, sv !== self {
                return sv
            }
            current = v.superview
        }
        return nil
    }
}

// MARK: - NotebookOutputScrollView
/// An NSScrollView that scrolls its own content when possible, but forwards
/// scroll events to the enclosing notebook scroll view when at bounds.
@MainActor
class NotebookOutputScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard let docView = documentView else {
            forwardToNotebook(event)
            return
        }

        let contentHeight = docView.frame.height
        let visibleHeight = contentView.bounds.height
        let currentY = contentView.bounds.origin.y
        let maxY = max(0, contentHeight - visibleHeight)

        // If content fits entirely (no need to scroll internally), always forward
        if contentHeight <= visibleHeight {
            forwardToNotebook(event)
            return
        }

        let dy = event.scrollingDeltaY
        let atTop = currentY <= 0.5
        let atBottom = currentY >= maxY - 0.5

        // Forward when scrolling further past the bounds
        if (dy > 0 && atTop) || (dy < 0 && atBottom) {
            forwardToNotebook(event)
            return
        }

        super.scrollWheel(with: event)
    }

    private func forwardToNotebook(_ event: NSEvent) {
        var current: NSView? = superview
        while let v = current {
            if let sv = v as? NSScrollView, sv !== self {
                sv.scrollWheel(with: event)
                return
            }
            current = v.superview
        }
    }
}

// MARK: - Design Tokens

private enum Metrics {
    static let cellCornerRadius: CGFloat = 10
    static let cellPaddingH: CGFloat = 16
    static let cellPaddingV: CGFloat = 10
    static let outputPaddingTop: CGFloat = 10
    static let maxOutputHeight: CGFloat = 320
    static let maxImageHeight: CGFloat = 420
    static let minSourceHeight: CGFloat = 22
    static let focusBarWidth: CGFloat = 3
    static let badgeWidth: CGFloat = 32
    static let actionButtonSize: CGFloat = 18
    static let actionGap: CGFloat = 6
    static let cellMarginH: CGFloat = 24
}

private enum Colors {
    // baseBg removed — notebook uses AppearanceSettings.shared.mainPanelBgColor directly
    // Cell bg: barely lifted — just enough to sense a surface
    static let cellBg = NSColor(white: 1.0, alpha: 0.03)
    static let cellBgFocused = NSColor(white: 1.0, alpha: 0.05)

    static let focusAccent = NSColor(red: 0.40, green: 0.56, blue: 1.0, alpha: 1.0)
    static let focusGlow = NSColor(red: 0.40, green: 0.56, blue: 1.0, alpha: 0.08)

    static let textPrimary = NSColor(white: 1.0, alpha: 0.88)
    static let textSecondary = NSColor(white: 1.0, alpha: 0.50)
    static let textMuted = NSColor(white: 1.0, alpha: 0.30)

    static let accentGreen = NSColor(red: 0.38, green: 0.78, blue: 0.48, alpha: 1.0)
    static let accentAmber = NSColor(red: 0.88, green: 0.72, blue: 0.32, alpha: 1.0)
    static let accentRed = NSColor(red: 0.88, green: 0.32, blue: 0.32, alpha: 1.0)

    static let outputText = NSColor(white: 1.0, alpha: 0.72)
    static let errorText = NSColor(red: 0.88, green: 0.35, blue: 0.35, alpha: 1.0)
    static let errorBar = NSColor(red: 0.88, green: 0.32, blue: 0.32, alpha: 0.35)

    // Badge
    static let badgeBg = NSColor(white: 1.0, alpha: 0.06)
    static let badgeText = NSColor(white: 1.0, alpha: 0.40)
    static let badgeRunning = NSColor(red: 0.38, green: 0.78, blue: 0.48, alpha: 0.15)

    // Action pill
    static let pillBg = NSColor(white: 1.0, alpha: 0.08)
}

// MARK: - Delegate Protocol

@MainActor
protocol NotebookCellViewDelegate: AnyObject {
    func cellDidUpdateSource(_ cellView: NotebookCellView, text: String)
    func cellDidRequestDelete(_ cellView: NotebookCellView)
    func cellDidRequestInsertBelow(_ cellView: NotebookCellView, type: NotebookCell.CellType)
    func cellDidRequestMoveUp(_ cellView: NotebookCellView)
    func cellDidRequestMoveDown(_ cellView: NotebookCellView)
    func cellDidRequestChangeType(_ cellView: NotebookCellView, to: NotebookCell.CellType)
    func cellDidRequestFocus(_ cellView: NotebookCellView)
    func cellDidRequestRun(_ cellView: NotebookCellView)
    func cellDidRequestRunAndAdvance(_ cellView: NotebookCellView)
    func cellDidRequestClearOutput(_ cellView: NotebookCellView)
    func cellDidRequestToggleSource(_ cellView: NotebookCellView)
    func cellDidRequestToggleOutput(_ cellView: NotebookCellView)
}

// MARK: - NotebookCellView

@MainActor
class NotebookCellView: NSView {
    private(set) var cellIndex: Int
    private var cell: NotebookCell
    private let language: String

    weak var delegate: NotebookCellViewDelegate?

    // State
    private var isFocused = false
    private var isHovered = false
    private var executionState: NotebookStore.CellExecutionState = .idle
    var isSourceCollapsed = false
    var isOutputCollapsed = false
    private(set) var isMarkdownRendered = false

    // Fonts
    private let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let outputFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    // UI — Cell body (single unified container)
    private var cellBody: NSView!
    private var focusBar: NSView!

    // UI — Execution badge (top-left inline)
    private var badgeView: NSView!
    private var badgeLabel: NSTextField!

    // UI — Source
    private var sourceScrollView: NSScrollView!
    private var sourceTextView: NotebookTextView!
    private var sourceHeightConstraint: NSLayoutConstraint?

    // UI — Rendered markdown (WKWebView with KaTeX)
    private var renderedWebView: WKWebView!
    private var renderedHeightConstraint: NSLayoutConstraint?
    // Bottom constraint for rendered view (alternative to source/output chains)
    private var renderedToBottomConstraint: NSLayoutConstraint?

    // UI — Output (lives inside cellBody, below source)
    private var outputDivider: NSView!
    private var outputScrollView: NSScrollView!
    private var outputStackView: NSStackView!
    private var outputHeightConstraint: NSLayoutConstraint?

    // Bottom constraint switching: source-to-bottom (no output) vs output-to-bottom
    private var sourceToBottomConstraint: NSLayoutConstraint?
    private var outputToBottomConstraint: NSLayoutConstraint?

    // UI — Inline actions (top-right, shown on hover/focus)
    private var actionPill: NSView!
    private var runButton: NSButton?
    private var moreButton: NSButton!

    // Tracking
    private var trackingArea: NSTrackingArea?

    init(cell: NotebookCell, index: Int, language: String) {
        self.cell = cell
        self.cellIndex = index
        self.language = language
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setupUI()
        populateCell()
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(cell: NotebookCell, index: Int, executionState: NotebookStore.CellExecutionState = .idle) {
        self.cell = cell
        self.cellIndex = index
        let prev = self.executionState
        self.executionState = executionState
        populateCell()
        if prev != executionState { updateRunningAnimation() }
    }

    func setFocused(_ focused: Bool) {
        isFocused = focused
        updateAppearance()
    }

    /// Make this cell's source text view the first responder so the cursor moves here.
    func activateSourceEditor() {
        guard !isMarkdownRendered else { return }
        window?.makeFirstResponder(sourceTextView)
    }

    // MARK: - Layout

    private func setupUI() {
        // Cell body — single unified container for source + output
        cellBody = NSView()
        cellBody.translatesAutoresizingMaskIntoConstraints = false
        cellBody.wantsLayer = true
        cellBody.layer?.backgroundColor = Colors.cellBg.cgColor
        cellBody.layer?.cornerRadius = Metrics.cellCornerRadius
        cellBody.layer?.cornerCurve = .continuous
        cellBody.layer?.borderColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        cellBody.layer?.borderWidth = 0.5
        addSubview(cellBody)

        // Focus bar — thin accent on left edge
        focusBar = NSView()
        focusBar.translatesAutoresizingMaskIntoConstraints = false
        focusBar.wantsLayer = true
        focusBar.layer?.backgroundColor = Colors.focusAccent.cgColor
        focusBar.layer?.cornerRadius = Metrics.focusBarWidth / 2
        focusBar.alphaValue = 0
        addSubview(focusBar)

        // Execution badge — top-left corner, overlapping the cell body edge
        setupBadge()

        // Source editor
        setupSource()

        // Rendered markdown view (hidden by default)
        setupRenderedMarkdown()

        // Output area (below source, inside cell body)
        setupOutput()

        // Action pill (top-right of cell body)
        setupActionPill()

        NSLayoutConstraint.activate([
            // Focus bar — sits just outside cell body left edge
            focusBar.trailingAnchor.constraint(equalTo: cellBody.leadingAnchor, constant: -3),
            focusBar.topAnchor.constraint(equalTo: cellBody.topAnchor, constant: 6),
            focusBar.bottomAnchor.constraint(equalTo: cellBody.bottomAnchor, constant: -6),
            focusBar.widthAnchor.constraint(equalToConstant: Metrics.focusBarWidth),

            // Cell body
            cellBody.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.cellMarginH),
            cellBody.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.cellMarginH),
            cellBody.topAnchor.constraint(equalTo: topAnchor),
            cellBody.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Badge

    private func setupBadge() {
        // Badge sits in the left margin, vertically centered with the first line of code
        badgeView = NSView()
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeView.wantsLayer = true
        badgeView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(badgeView)

        badgeLabel = NSTextField(labelWithString: "")
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        badgeLabel.textColor = Colors.badgeText
        badgeLabel.alignment = .center
        badgeLabel.lineBreakMode = .byTruncatingTail
        badgeView.addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            badgeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            badgeView.widthAnchor.constraint(equalToConstant: Metrics.cellMarginH - 4),
            badgeView.topAnchor.constraint(equalTo: cellBody.topAnchor, constant: Metrics.cellPaddingV),
            badgeView.heightAnchor.constraint(equalToConstant: 16),

            badgeLabel.leadingAnchor.constraint(equalTo: badgeView.leadingAnchor, constant: 2),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeView.trailingAnchor),
            badgeLabel.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),
        ])
    }

    // MARK: - Source

    private func setupSource() {
        sourceScrollView = NotebookPassthroughScrollView()
        sourceScrollView.translatesAutoresizingMaskIntoConstraints = false
        sourceScrollView.hasVerticalScroller = false
        sourceScrollView.hasHorizontalScroller = false
        sourceScrollView.drawsBackground = false
        sourceScrollView.borderType = .noBorder
        cellBody.addSubview(sourceScrollView)

        sourceTextView = NotebookTextView()
        sourceTextView.shortcutDelegate = self
        sourceTextView.isEditable = true
        sourceTextView.isSelectable = true
        sourceTextView.isRichText = false
        sourceTextView.allowsUndo = true
        sourceTextView.font = codeFont
        sourceTextView.textColor = Colors.textPrimary
        sourceTextView.backgroundColor = .clear
        sourceTextView.drawsBackground = false
        sourceTextView.isAutomaticQuoteSubstitutionEnabled = false
        sourceTextView.isAutomaticDashSubstitutionEnabled = false
        sourceTextView.isAutomaticTextReplacementEnabled = false
        sourceTextView.isAutomaticSpellingCorrectionEnabled = false
        sourceTextView.insertionPointColor = NSColor(white: 0.92, alpha: 1.0)
        sourceTextView.selectedTextAttributes = [
            .backgroundColor: NSColor(red: 0.30, green: 0.40, blue: 0.70, alpha: 0.35)
        ]
        sourceTextView.textContainerInset = NSSize(width: Metrics.cellPaddingH, height: Metrics.cellPaddingV)
        sourceTextView.isVerticallyResizable = true
        sourceTextView.isHorizontallyResizable = false
        sourceTextView.textContainer?.widthTracksTextView = true
        sourceTextView.delegate = self
        sourceScrollView.documentView = sourceTextView

        NSLayoutConstraint.activate([
            sourceScrollView.leadingAnchor.constraint(equalTo: cellBody.leadingAnchor),
            sourceScrollView.trailingAnchor.constraint(equalTo: cellBody.trailingAnchor),
            sourceScrollView.topAnchor.constraint(equalTo: cellBody.topAnchor),
        ])
    }

    // MARK: - Rendered Markdown

    private func setupRenderedMarkdown() {
        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        userContentController.add(MarkdownWebViewMessageHandler(cellView: self), name: "clome")
        config.userContentController = userContentController

        renderedWebView = WKWebView(frame: .zero, configuration: config)
        renderedWebView.translatesAutoresizingMaskIntoConstraints = false
        renderedWebView.setValue(false, forKey: "drawsBackground")
        renderedWebView.isHidden = true
        renderedWebView.navigationDelegate = self
        cellBody.addSubview(renderedWebView)

        NSLayoutConstraint.activate([
            renderedWebView.leadingAnchor.constraint(equalTo: cellBody.leadingAnchor),
            renderedWebView.trailingAnchor.constraint(equalTo: cellBody.trailingAnchor),
            renderedWebView.topAnchor.constraint(equalTo: cellBody.topAnchor),
        ])

        renderedHeightConstraint = renderedWebView.heightAnchor.constraint(equalToConstant: Metrics.minSourceHeight)
        renderedToBottomConstraint = renderedWebView.bottomAnchor.constraint(equalTo: cellBody.bottomAnchor)
    }

    fileprivate func renderedMarkdownDoubleClicked() {
        guard cell.cell_type == .markdown, isMarkdownRendered else { return }
        exitMarkdownRendered()
        delegate?.cellDidRequestFocus(self)
    }

    /// Switch markdown cell to rendered mode.
    func enterMarkdownRendered() {
        guard cell.cell_type == .markdown else { return }
        isMarkdownRendered = true

        // Load markdown into WKWebView with KaTeX
        let html = Self.buildMarkdownHTML(cell.sourceText)
        renderedWebView.loadHTMLString(html, baseURL: nil)

        // Set initial height, will be updated by JS callback
        renderedHeightConstraint?.isActive = true

        // Hide source, show rendered
        sourceScrollView.isHidden = true
        sourceHeightConstraint?.isActive = false
        renderedWebView.isHidden = false

        // Switch bottom constraints
        sourceToBottomConstraint?.isActive = false
        outputToBottomConstraint?.isActive = false
        renderedToBottomConstraint?.isActive = true

        // Hide output for markdown
        outputScrollView.isHidden = true
        outputDivider.isHidden = true

        needsLayout = true
    }

    /// Switch markdown cell back to source editing mode.
    func exitMarkdownRendered() {
        guard isMarkdownRendered else { return }
        isMarkdownRendered = false

        // Show source, hide rendered
        renderedWebView.isHidden = true
        renderedWebView.loadHTMLString("", baseURL: nil)
        renderedHeightConstraint?.isActive = false
        renderedToBottomConstraint?.isActive = false

        sourceScrollView.isHidden = false
        updateSourceHeight()

        // Restore bottom constraint chain
        let hasOutput = cell.outputs != nil && !(cell.outputs?.isEmpty ?? true)
        if hasOutput {
            sourceToBottomConstraint?.isActive = false
            outputToBottomConstraint?.isActive = true
        } else {
            outputToBottomConstraint?.isActive = false
            sourceToBottomConstraint?.isActive = true
        }

        // Make source editable and focus it
        window?.makeFirstResponder(sourceTextView)
        needsLayout = true
    }

    // MARK: - Markdown HTML Rendering (KaTeX)

    /// Build a self-contained HTML page that renders markdown with KaTeX math support.
    /// Uses KaTeX CDN for LaTeX rendering and a lightweight markdown-to-HTML conversion.
    static func buildMarkdownHTML(_ markdown: String) -> String {
        // Escape for embedding in JS string
        let escaped = markdown
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
        <script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
        <script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"></script>
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
                font-size: 13px;
                line-height: 1.6;
                color: rgba(255,255,255,0.88);
                background: transparent;
                padding: 10px 14px;
                -webkit-user-select: text;
            }
            /* Symmetric vertical margins on block elements.
               First/last children lose their outer margin so only body padding controls edge spacing. */
            h1 { font-size: 20px; font-weight: 700; margin: 8px 0; color: rgba(255,255,255,0.95); }
            h2 { font-size: 17px; font-weight: 700; margin: 6px 0; color: rgba(255,255,255,0.95); }
            h3 { font-size: 15px; font-weight: 700; margin: 5px 0; color: rgba(255,255,255,0.95); }
            h4 { font-size: 14px; font-weight: 600; margin: 4px 0; color: rgba(255,255,255,0.95); }
            h5 { font-size: 13.5px; font-weight: 600; margin: 4px 0; color: rgba(255,255,255,0.95); }
            h6 { font-size: 13px; font-weight: 600; margin: 3px 0; color: rgba(255,255,255,0.95); }
            p { margin: 4px 0; }
            strong { color: rgba(255,255,255,0.95); }
            em { font-style: italic; }
            a { color: #6CB6FF; text-decoration: underline; }
            code {
                font-family: "SF Mono", Menlo, monospace;
                font-size: 12px;
                color: #E6994D;
                background: rgba(255,255,255,0.04);
                padding: 1px 4px;
                border-radius: 3px;
            }
            pre {
                background: rgba(255,255,255,0.04);
                padding: 8px 12px;
                border-radius: 4px;
                margin: 6px 0;
                overflow-x: auto;
            }
            pre code { background: none; padding: 0; }
            blockquote {
                border-left: 3px solid rgba(108,182,255,0.3);
                padding-left: 12px;
                color: rgba(255,255,255,0.6);
                margin: 6px 0;
            }
            ul, ol { padding-left: 24px; margin: 4px 0; }
            li { margin: 2px 0; }
            li::marker { color: #6CB6FF; }
            hr { border: none; border-top: 1px solid rgba(255,255,255,0.15); margin: 8px 0; }
            del { color: rgba(255,255,255,0.5); text-decoration: line-through; }
            table { border-collapse: collapse; margin: 6px 0; }
            th, td { border: 1px solid rgba(255,255,255,0.15); padding: 4px 8px; }
            th { background: rgba(255,255,255,0.06); font-weight: 600; }
            .katex-display { margin: 8px 0; overflow-x: auto; }
            .katex { font-size: 1.1em; }
            /* Remove outer margins on first/last children so body padding is the only edge spacing */
            #content > :first-child { margin-top: 0; }
            #content > :last-child { margin-bottom: 0; }
        </style>
        </head>
        <body>
        <div id="content"></div>
        <script>
        // Lightweight markdown to HTML (handles common syntax)
        function mdToHTML(md) {
            let html = md;

            // Fenced code blocks
            html = html.replace(/```(\\w*)\\n([\\s\\S]*?)```/g, function(m, lang, code) {
                return '<pre><code>' + escapeHtml(code.replace(/\\n$/, '')) + '</code></pre>';
            });

            // Headings
            html = html.replace(/^######\\s+(.*)$/gm, '<h6>$1</h6>');
            html = html.replace(/^#####\\s+(.*)$/gm, '<h5>$1</h5>');
            html = html.replace(/^####\\s+(.*)$/gm, '<h4>$1</h4>');
            html = html.replace(/^###\\s+(.*)$/gm, '<h3>$1</h3>');
            html = html.replace(/^##\\s+(.*)$/gm, '<h2>$1</h2>');
            html = html.replace(/^#\\s+(.*)$/gm, '<h1>$1</h1>');

            // Horizontal rules
            html = html.replace(/^(---+|\\*\\*\\*+|___+)\\s*$/gm, '<hr>');

            // Bold + Italic
            html = html.replace(/\\*\\*\\*(.+?)\\*\\*\\*/g, '<strong><em>$1</em></strong>');
            html = html.replace(/\\*\\*(.+?)\\*\\*/g, '<strong>$1</strong>');
            html = html.replace(/(?<!\\*)\\*([^*]+)\\*(?!\\*)/g, '<em>$1</em>');

            // Strikethrough
            html = html.replace(/~~(.+?)~~/g, '<del>$1</del>');

            // Inline code (but not inside <pre>)
            html = html.replace(/`([^`]+)`/g, '<code>$1</code>');

            // Images
            html = html.replace(/!\\[([^\\]]*)\\]\\(([^)]+)\\)/g, '<img src="$2" alt="$1" style="max-width:100%">');

            // Links
            html = html.replace(/\\[([^\\]]+)\\]\\(([^)]+)\\)/g, '<a href="$2">$1</a>');

            // Blockquotes (simple, single level)
            html = html.replace(/^>\\s?(.*)$/gm, '<blockquote>$1</blockquote>');
            // Merge adjacent blockquotes
            html = html.replace(/<\\/blockquote>\\n<blockquote>/g, '\\n');

            // Unordered lists
            html = html.replace(/^(\\s*)[*\\-+]\\s+(.*)$/gm, '<li>$2</li>');

            // Ordered lists
            html = html.replace(/^(\\s*)\\d+\\.\\s+(.*)$/gm, '<li>$2</li>');

            // Wrap consecutive <li> in <ul> (simple approach)
            html = html.replace(/((?:<li>.*<\\/li>\\n?)+)/g, '<ul>$1</ul>');

            // Paragraphs: wrap lines that aren't already in block elements
            let lines = html.split('\\n');
            let result = [];
            for (let i = 0; i < lines.length; i++) {
                let line = lines[i].trim();
                if (line === '') {
                    result.push('');
                } else if (/^<(h[1-6]|pre|ul|ol|li|blockquote|hr|div|table|img)/.test(line)) {
                    result.push(line);
                } else if (/<\\/(h[1-6]|pre|ul|ol|li|blockquote|div|table)>$/.test(line)) {
                    result.push(line);
                } else {
                    result.push('<p>' + line + '</p>');
                }
            }
            return result.join('\\n');
        }

        function escapeHtml(text) {
            return text.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
        }

        // Render markdown
        const md = `\(escaped)`;
        document.getElementById('content').innerHTML = mdToHTML(md);

        // Render math with KaTeX auto-render
        renderMathInElement(document.getElementById('content'), {
            delimiters: [
                {left: '$$', right: '$$', display: true},
                {left: '$', right: '$', display: false},
                {left: '\\\\(', right: '\\\\)', display: false},
                {left: '\\\\[', right: '\\\\]', display: true}
            ],
            throwOnError: false
        });

        // Report height to native
        function reportHeight() {
            const h = document.body.scrollHeight;
            window.webkit.messageHandlers.clome.postMessage({type: 'height', value: h});
        }
        // Report after fonts/KaTeX CSS load
        window.addEventListener('load', function() { setTimeout(reportHeight, 50); });
        setTimeout(reportHeight, 200);
        setTimeout(reportHeight, 500);

        // Double-click → edit mode
        document.addEventListener('dblclick', function(e) {
            window.webkit.messageHandlers.clome.postMessage({type: 'doubleClick'});
        });

        // Shift+Enter → run and advance
        document.addEventListener('keydown', function(e) {
            if (e.key === 'Enter' && e.shiftKey) {
                e.preventDefault();
                window.webkit.messageHandlers.clome.postMessage({type: 'shiftEnter'});
            } else if (e.key === 'Enter' && !e.shiftKey && !e.metaKey && !e.ctrlKey) {
                e.preventDefault();
                window.webkit.messageHandlers.clome.postMessage({type: 'doubleClick'});
            }
        });
        </script>
        </body>
        </html>
        """
    }

    /// Handle height updates from the rendered WKWebView.
    fileprivate func updateRenderedHeight(_ height: CGFloat) {
        let h = max(Metrics.minSourceHeight, height)
        renderedHeightConstraint?.constant = h
        renderedHeightConstraint?.isActive = true
        needsLayout = true
        // Notify the notebook scroll view to relayout
        superview?.needsLayout = true
    }

    // MARK: - Output

    private func setupOutput() {
        // Thin divider between source and output
        outputDivider = NSView()
        outputDivider.translatesAutoresizingMaskIntoConstraints = false
        outputDivider.wantsLayer = true
        outputDivider.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        outputDivider.isHidden = true
        cellBody.addSubview(outputDivider)

        outputScrollView = NotebookOutputScrollView()
        outputScrollView.translatesAutoresizingMaskIntoConstraints = false
        outputScrollView.hasVerticalScroller = true
        outputScrollView.hasHorizontalScroller = false
        outputScrollView.scrollerStyle = .overlay
        outputScrollView.autohidesScrollers = true
        outputScrollView.drawsBackground = false
        outputScrollView.borderType = .noBorder
        outputScrollView.isHidden = true
        cellBody.addSubview(outputScrollView)

        let docView = FlippedView()
        docView.translatesAutoresizingMaskIntoConstraints = false
        docView.wantsLayer = true
        outputScrollView.documentView = docView

        outputStackView = NSStackView()
        outputStackView.translatesAutoresizingMaskIntoConstraints = false
        outputStackView.orientation = .vertical
        outputStackView.alignment = .leading
        outputStackView.spacing = 4
        docView.addSubview(outputStackView)

        NSLayoutConstraint.activate([
            // Divider
            outputDivider.topAnchor.constraint(equalTo: sourceScrollView.bottomAnchor, constant: Metrics.outputPaddingTop),
            outputDivider.leadingAnchor.constraint(equalTo: cellBody.leadingAnchor, constant: Metrics.cellPaddingH),
            outputDivider.trailingAnchor.constraint(equalTo: cellBody.trailingAnchor, constant: -Metrics.cellPaddingH),
            outputDivider.heightAnchor.constraint(equalToConstant: 1),

            // Output scroll view
            outputScrollView.topAnchor.constraint(equalTo: outputDivider.bottomAnchor, constant: Metrics.outputPaddingTop),
            outputScrollView.leadingAnchor.constraint(equalTo: cellBody.leadingAnchor),
            outputScrollView.trailingAnchor.constraint(equalTo: cellBody.trailingAnchor),

            // Document view
            docView.leadingAnchor.constraint(equalTo: outputScrollView.contentView.leadingAnchor),
            docView.trailingAnchor.constraint(equalTo: outputScrollView.contentView.trailingAnchor),
            docView.topAnchor.constraint(equalTo: outputScrollView.contentView.topAnchor),

            // Stack view inside doc
            outputStackView.topAnchor.constraint(equalTo: docView.topAnchor),
            outputStackView.leadingAnchor.constraint(equalTo: docView.leadingAnchor, constant: Metrics.cellPaddingH),
            outputStackView.trailingAnchor.constraint(equalTo: docView.trailingAnchor, constant: -Metrics.cellPaddingH),
            outputStackView.bottomAnchor.constraint(equalTo: docView.bottomAnchor),
        ])

        // Mutually exclusive bottom constraints
        sourceToBottomConstraint = sourceScrollView.bottomAnchor.constraint(equalTo: cellBody.bottomAnchor)
        outputToBottomConstraint = outputScrollView.bottomAnchor.constraint(equalTo: cellBody.bottomAnchor, constant: -Metrics.cellPaddingV)
        // Start with source-to-bottom (no output by default)
        sourceToBottomConstraint?.isActive = true
    }

    // MARK: - Action Pill

    private func setupActionPill() {
        actionPill = NSView()
        actionPill.translatesAutoresizingMaskIntoConstraints = false
        actionPill.wantsLayer = true
        actionPill.layer?.backgroundColor = Colors.pillBg.cgColor
        actionPill.layer?.cornerRadius = 6
        actionPill.layer?.cornerCurve = .continuous
        actionPill.layer?.borderColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        actionPill.layer?.borderWidth = 0.5
        actionPill.alphaValue = 0
        actionPill.isHidden = true
        cellBody.addSubview(actionPill)

        var buttons: [NSButton] = []

        // Run (code cells only)
        let runBtn = makeActionButton(systemImage: "play.fill", action: #selector(runCell), tint: Colors.accentGreen)
        runButton = runBtn
        buttons.append(runBtn)

        // More (context menu)
        let moreBtn = makeActionButton(systemImage: "ellipsis", action: #selector(showMoreMenu(_:)), tint: Colors.textMuted)
        moreButton = moreBtn
        buttons.append(moreBtn)

        let stack = NSStackView(views: buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = Metrics.actionGap
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        actionPill.addSubview(stack)

        NSLayoutConstraint.activate([
            actionPill.topAnchor.constraint(equalTo: cellBody.topAnchor, constant: 4),
            actionPill.trailingAnchor.constraint(equalTo: cellBody.trailingAnchor, constant: -8),

            stack.topAnchor.constraint(equalTo: actionPill.topAnchor),
            stack.leadingAnchor.constraint(equalTo: actionPill.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: actionPill.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: actionPill.bottomAnchor),
        ])

        for btn in buttons {
            NSLayoutConstraint.activate([
                btn.widthAnchor.constraint(equalToConstant: Metrics.actionButtonSize),
                btn.heightAnchor.constraint(equalToConstant: Metrics.actionButtonSize),
            ])
        }
    }

    private func makeActionButton(systemImage: String, action: Selector, tint: NSColor) -> NSButton {
        let img = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil) ?? NSImage()
        let btn = NSButton(image: img, target: self, action: action)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.bezelStyle = .accessoryBarAction
        btn.isBordered = false
        btn.contentTintColor = tint
        return btn
    }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateActionPillVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateActionPillVisibility()
    }

    override func mouseDown(with event: NSEvent) {
        delegate?.cellDidRequestFocus(self)
        super.mouseDown(with: event)
    }

    // MARK: - Appearance

    private func updateAppearance() {
        // Focus bar
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            focusBar.animator().alphaValue = isFocused ? 1.0 : 0
        }

        // Cell body tint
        cellBody.layer?.backgroundColor = isFocused ? Colors.cellBgFocused.cgColor : Colors.cellBg.cgColor

        // Focus glow (subtle shadow)
        if isFocused {
            cellBody.shadow = {
                let s = NSShadow()
                s.shadowColor = Colors.focusGlow
                s.shadowBlurRadius = 12
                s.shadowOffset = .zero
                return s
            }()
        } else {
            cellBody.shadow = nil
        }

        updateActionPillVisibility()
    }

    private func updateActionPillVisibility() {
        let show = isHovered || isFocused
        if show {
            actionPill.isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                actionPill.animator().alphaValue = 1.0
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                actionPill.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self else { return }
                if !self.isHovered && !self.isFocused { self.actionPill.isHidden = true }
            })
        }
    }

    // MARK: - Running Animation

    private func updateRunningAnimation() {
        executionLabel.layer?.removeAllAnimations()
        guard executionState == .running else { return }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0.4
        anim.toValue = 1.0
        anim.duration = 1.0
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        executionLabel.layer?.add(anim, forKey: "pulse")
    }

    // MARK: - Populate

    private func populateCell() {
        // Badge — small execution count in left margin
        if cell.cell_type == .code {
            badgeView.isHidden = false
            switch executionState {
            case .running:
                badgeLabel.stringValue = "\u{25CF}"  // filled dot
                badgeLabel.textColor = Colors.accentGreen
            case .queued:
                badgeLabel.stringValue = "\u{25CB}"  // hollow dot
                badgeLabel.textColor = Colors.accentAmber
            case .idle:
                if let count = cell.execution_count {
                    badgeLabel.stringValue = "\(count)"
                } else {
                    badgeLabel.stringValue = ""
                }
                badgeLabel.textColor = Colors.badgeText
            }
        } else {
            badgeView.isHidden = true
        }

        // Run button
        runButton?.isHidden = cell.cell_type != .code

        // Source / rendered markdown
        if cell.cell_type == .markdown && isMarkdownRendered {
            // Re-render in case source changed
            let html = Self.buildMarkdownHTML(cell.sourceText)
            renderedWebView.loadHTMLString(html, baseURL: nil)
            renderedHeightConstraint?.isActive = true
            sourceScrollView.isHidden = true
            renderedWebView.isHidden = false
            renderedToBottomConstraint?.isActive = true
            sourceToBottomConstraint?.isActive = false
            outputToBottomConstraint?.isActive = false
            outputScrollView.isHidden = true
            outputDivider.isHidden = true
        } else {
            // Trim trailing newlines — .ipynb stores lines with trailing \n which
            // causes the layout manager to reserve space for an empty trailing line
            let src = cell.sourceText.replacingOccurrences(of: "\\n+$", with: "", options: .regularExpression)
            if sourceTextView.string != src { sourceTextView.string = src }
            if cell.cell_type == .code { applySyntaxColoring() }
            else if cell.cell_type == .markdown { applyMarkdownColoring() }
            updateSourceHeight()
            renderedWebView.isHidden = true
            renderedToBottomConstraint?.isActive = false
            sourceScrollView.isHidden = false

            // Output
            rebuildOutputViews()
        }
        updateAppearance()
    }

    private func updateSourceHeight() {
        sourceHeightConstraint?.isActive = false
        guard let lm = sourceTextView.layoutManager, let tc = sourceTextView.textContainer else {
            sourceHeightConstraint = sourceScrollView.heightAnchor.constraint(equalToConstant: Metrics.minSourceHeight)
            sourceHeightConstraint?.isActive = true
            return
        }
        lm.ensureLayout(for: tc)
        // textContainerInset adds cellPaddingV top and bottom
        let h = lm.usedRect(for: tc).height + (Metrics.cellPaddingV * 2)
        sourceHeightConstraint = sourceScrollView.heightAnchor.constraint(equalToConstant: max(Metrics.minSourceHeight, h))
        sourceHeightConstraint?.isActive = true
    }

    // MARK: - Output Rendering

    private func rebuildOutputViews() {
        for v in outputStackView.arrangedSubviews {
            outputStackView.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        guard let outputs = cell.outputs, !outputs.isEmpty else {
            outputScrollView.isHidden = true
            outputDivider.isHidden = true
            outputHeightConstraint?.isActive = false
            outputHeightConstraint = outputScrollView.heightAnchor.constraint(equalToConstant: 0)
            outputHeightConstraint?.isActive = true
            // Pin source directly to bottom (no dead space)
            outputToBottomConstraint?.isActive = false
            sourceToBottomConstraint?.isActive = true
            return
        }

        outputScrollView.isHidden = false
        outputDivider.isHidden = false
        // Switch to output-to-bottom chain
        sourceToBottomConstraint?.isActive = false
        outputToBottomConstraint?.isActive = true

        for output in outputs {
            let v = renderOutput(output)
            v.translatesAutoresizingMaskIntoConstraints = false
            outputStackView.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: outputStackView.widthAnchor).isActive = true
        }

        outputStackView.layoutSubtreeIfNeeded()
        let contentH = outputStackView.fittingSize.height + 8
        outputHeightConstraint?.isActive = false
        outputHeightConstraint = outputScrollView.heightAnchor.constraint(
            equalToConstant: min(contentH, Metrics.maxOutputHeight)
        )
        outputHeightConstraint?.isActive = true
    }

    private func renderOutput(_ output: CellOutput) -> NSView {
        switch output.output_type {
        case .stream:
            return renderText(outputText(from: output), isError: output.name == "stderr")
        case .execute_result, .display_data:
            if let png = output.data?.image_png, let d = Data(base64Encoded: png), let img = NSImage(data: d) {
                return renderImage(img)
            }
            if let jpg = output.data?.image_jpeg, let d = Data(base64Encoded: jpg), let img = NSImage(data: d) {
                return renderImage(img)
            }
            let text = output.data?.text_plain.map { cellSourceText($0) } ?? outputText(from: output)
            return renderText(text, isError: false)
        case .error:
            let trace = output.traceback?.joined(separator: "\n") ?? "\(output.ename ?? "Error"): \(output.evalue ?? "")"
            let clean = trace.replacingOccurrences(of: "\\x1b\\[[0-9;]*m", with: "", options: .regularExpression)
            return renderText(clean, isError: true)
        }
    }

    private func outputText(from output: CellOutput) -> String {
        output.text.map { cellSourceText($0) } ?? ""
    }

    private func cellSourceText(_ src: CellSource) -> String {
        switch src {
        case .string(let s): return s
        case .array(let a): return a.joined()
        }
    }

    private func renderText(_ text: String, isError: Bool) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.cornerCurve = .continuous

        if isError {
            container.layer?.backgroundColor = NSColor(red: 0.88, green: 0.32, blue: 0.32, alpha: 0.04).cgColor

            let bar = NSView()
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.wantsLayer = true
            bar.layer?.backgroundColor = Colors.errorBar.cgColor
            bar.layer?.cornerRadius = 1.5
            container.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                bar.topAnchor.constraint(equalTo: container.topAnchor),
                bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                bar.widthAnchor.constraint(equalToConstant: 3),
            ])
        } else {
            container.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.015).cgColor
        }

        let tv = NSTextField(wrappingLabelWithString: text)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = outputFont
        tv.textColor = isError ? Colors.errorText : Colors.outputText
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.lineBreakMode = .byWordWrapping
        tv.maximumNumberOfLines = 0
        tv.cell?.truncatesLastVisibleLine = false

        let inset: CGFloat = isError ? 10 : 8
        container.addSubview(tv)
        NSLayoutConstraint.activate([
            tv.topAnchor.constraint(equalTo: container.topAnchor),
            tv.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            tv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    private func renderImage(_ image: NSImage) -> NSView {
        let iv = NSImageView(image: image)
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.imageScaling = .scaleProportionallyDown
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 8
        iv.layer?.cornerCurve = .continuous
        iv.layer?.masksToBounds = true
        iv.layer?.borderColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        iv.layer?.borderWidth = 0.5
        NSLayoutConstraint.activate([
            iv.heightAnchor.constraint(lessThanOrEqualToConstant: Metrics.maxImageHeight),
        ])
        return iv
    }

    // MARK: - Actions

    @objc private func runCell() { delegate?.cellDidRequestRun(self) }

    @objc private func showMoreMenu(_ sender: NSButton) {
        let menu = NSMenu()

        menu.addItem(withTitle: "Insert Code Cell Below", action: #selector(insertCodeBelow), keyEquivalent: "")
        menu.addItem(withTitle: "Insert Markdown Cell Below", action: #selector(insertMarkdownBelow), keyEquivalent: "")
        menu.addItem(.separator())

        menu.addItem(withTitle: "Move Up", action: #selector(moveCellUp), keyEquivalent: "")
        menu.addItem(withTitle: "Move Down", action: #selector(moveCellDown), keyEquivalent: "")
        menu.addItem(.separator())

        // Change type — show options that differ from current type
        if cell.cell_type != .code {
            menu.addItem(withTitle: "Change to Code", action: #selector(changeToCode), keyEquivalent: "")
        }
        if cell.cell_type != .markdown {
            menu.addItem(withTitle: "Change to Markdown", action: #selector(changeToMarkdown), keyEquivalent: "")
        }
        if cell.cell_type != .raw {
            menu.addItem(withTitle: "Change to Raw", action: #selector(changeToRaw), keyEquivalent: "")
        }
        menu.addItem(.separator())

        // Clear output — only if cell has outputs
        if let outputs = cell.outputs, !outputs.isEmpty {
            menu.addItem(withTitle: "Clear Output", action: #selector(clearOutput), keyEquivalent: "")
            menu.addItem(.separator())
        }

        let deleteItem = NSMenuItem(title: "Delete Cell", action: #selector(deleteCell), keyEquivalent: "")
        deleteItem.attributedTitle = NSAttributedString(
            string: "Delete Cell",
            attributes: [.foregroundColor: Colors.accentRed]
        )
        menu.addItem(deleteItem)

        for item in menu.items where item.action != nil {
            item.target = self
        }

        let point = NSPoint(x: 0, y: sender.bounds.height)
        menu.popUp(positioning: nil, at: point, in: sender)
    }

    @objc private func insertCodeBelow() { delegate?.cellDidRequestInsertBelow(self, type: .code) }
    @objc private func insertMarkdownBelow() { delegate?.cellDidRequestInsertBelow(self, type: .markdown) }
    @objc private func moveCellUp() { delegate?.cellDidRequestMoveUp(self) }
    @objc private func moveCellDown() { delegate?.cellDidRequestMoveDown(self) }
    @objc private func changeToCode() { delegate?.cellDidRequestChangeType(self, to: .code) }
    @objc private func changeToMarkdown() { delegate?.cellDidRequestChangeType(self, to: .markdown) }
    @objc private func changeToRaw() { delegate?.cellDidRequestChangeType(self, to: .raw) }
    @objc private func clearOutput() { delegate?.cellDidRequestClearOutput(self) }
    @objc private func deleteCell() { delegate?.cellDidRequestDelete(self) }

    // Convenience used by badgeLabel
    private var executionLabel: NSTextField { badgeLabel }

    // MARK: - Syntax Coloring

    private func applySyntaxColoring() {
        guard let storage = sourceTextView.textStorage else { return }
        let text = storage.string
        let fullRange = NSRange(location: 0, length: text.utf16.count)

        storage.beginEditing()
        storage.setAttributes([
            .font: codeFont,
            .foregroundColor: Colors.textPrimary,
        ], range: fullRange)

        applyPattern(storage: storage, pattern: "#[^\n]*", color: NSColor(white: 0.45, alpha: 1.0))
        applyPattern(storage: storage, pattern: "//[^\n]*", color: NSColor(white: 0.45, alpha: 1.0))

        let strColor = NSColor(red: 0.9, green: 0.6, blue: 0.3, alpha: 1.0)
        applyPattern(storage: storage, pattern: "\"\"\"[\\s\\S]*?\"\"\"", color: strColor)
        applyPattern(storage: storage, pattern: "\"[^\"\\n]*\"", color: strColor)
        applyPattern(storage: storage, pattern: "'[^'\\n]*'", color: strColor)

        applyPattern(storage: storage, pattern: "\\b\\d+(\\.\\d+)?\\b", color: NSColor(red: 0.9, green: 0.85, blue: 0.4, alpha: 1.0))

        let keywords: [String]
        switch language {
        case "python":
            keywords = ["import","from","def","class","return","if","elif","else","for","while",
                        "in","not","and","or","is","None","True","False","try","except","finally",
                        "with","as","yield","lambda","raise","pass","break","continue","global",
                        "nonlocal","assert","del","async","await"]
        case "julia":
            keywords = ["function","end","if","else","elseif","for","while","return","module",
                        "using","import","export","struct","mutable","abstract","begin","let",
                        "const","true","false","nothing","try","catch","finally"]
        case "r":
            keywords = ["function","if","else","for","while","repeat","in","next","break",
                        "return","TRUE","FALSE","NULL","NA","library","require"]
        default:
            keywords = ["import","from","def","class","return","if","else","for","while",
                        "in","not","and","or","None","True","False","try","except",
                        "with","as","lambda","raise","pass"]
        }

        let kwPattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
        applyPattern(storage: storage, pattern: kwPattern, color: NSColor(red: 0.78, green: 0.55, blue: 0.96, alpha: 1.0))

        applyPattern(storage: storage, pattern: "\\b(print|len|range|type|int|float|str|list|dict|set|tuple|enumerate|zip|map|filter|sorted|open|input|super|isinstance|hasattr|getattr|setattr)\\b",
                     color: NSColor(red: 0.4, green: 0.75, blue: 0.95, alpha: 1.0))
        applyPattern(storage: storage, pattern: "\\b\\w+(?=\\()", color: NSColor(red: 0.4, green: 0.75, blue: 0.95, alpha: 1.0))
        applyPattern(storage: storage, pattern: "@\\w+", color: NSColor(red: 0.9, green: 0.85, blue: 0.4, alpha: 1.0))

        storage.endEditing()
    }

    private func applyMarkdownColoring() {
        guard let storage = sourceTextView.textStorage else { return }
        let text = storage.string
        let fullRange = NSRange(location: 0, length: text.utf16.count)

        storage.beginEditing()
        storage.setAttributes([.font: codeFont, .foregroundColor: NSColor(white: 0.8, alpha: 1.0)], range: fullRange)

        applyPattern(storage: storage, pattern: "^#{1,6}\\s.*$", color: NSColor(red: 0.5, green: 0.7, blue: 0.95, alpha: 1.0))
        applyPattern(storage: storage, pattern: "\\*\\*[^*]+\\*\\*", color: NSColor(white: 0.95, alpha: 1.0))
        applyPattern(storage: storage, pattern: "\\*[^*]+\\*", color: NSColor(white: 0.85, alpha: 1.0))
        applyPattern(storage: storage, pattern: "`[^`]+`", color: NSColor(red: 0.9, green: 0.6, blue: 0.3, alpha: 1.0))
        applyPattern(storage: storage, pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)", color: NSColor(red: 0.4, green: 0.7, blue: 0.95, alpha: 1.0))

        storage.endEditing()
    }

    private func applyPattern(storage: NSTextStorage, pattern: String, color: NSColor) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
        let text = storage.string
        let range = NSRange(location: 0, length: text.utf16.count)
        for match in regex.matches(in: text, range: range) {
            storage.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}

// MARK: - NSTextViewDelegate

extension NotebookCellView: NSTextViewDelegate {
    nonisolated func textDidChange(_ notification: Notification) {
        MainActor.assumeIsolated {
            let text = sourceTextView.string
            // Keep local cell copy in sync so cell.sourceText reflects edits
            cell.source = .string(text)
            delegate?.cellDidUpdateSource(self, text: text)
            if cell.cell_type == .code { applySyntaxColoring() }
            else if cell.cell_type == .markdown { applyMarkdownColoring() }
            updateSourceHeight()
        }
    }
}

// MARK: - NotebookTextViewShortcutDelegate

extension NotebookCellView: NotebookTextViewShortcutDelegate {
    func textViewDidShiftEnter() {
        delegate?.cellDidRequestRunAndAdvance(self)
    }

    func textViewDidRequestFocus() {
        delegate?.cellDidRequestFocus(self)
    }
}

// MARK: - WKNavigationDelegate

extension NotebookCellView: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            // Query height after page finishes loading
            webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] result, _ in
                if let h = result as? CGFloat {
                    self?.updateRenderedHeight(h)
                }
            }
        }
    }
}

// MARK: - MarkdownWebViewMessageHandler

/// Bridging class for WKScriptMessageHandler (must be NSObject, cannot be @MainActor).
/// Routes messages from the rendered markdown WKWebView back to the cell view.
class MarkdownWebViewMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var cellView: NotebookCellView?

    init(cellView: NotebookCellView) {
        self.cellView = cellView
        super.init()
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        MainActor.assumeIsolated {
            guard let cellView = cellView else { return }
            switch type {
            case "height":
                if let value = body["value"] as? CGFloat {
                    cellView.updateRenderedHeight(value)
                }
            case "doubleClick":
                cellView.renderedMarkdownDoubleClicked()
            case "shiftEnter":
                cellView.delegate?.cellDidRequestRunAndAdvance(cellView)
            default:
                break
            }
        }
    }
}
