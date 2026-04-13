import AppKit
import CoreText

/// Navigation delegate for cross-file navigation (go-to-definition).
@MainActor
protocol EditorViewNavigationDelegate: AnyObject {
    func editorView(_ editorView: EditorView, openFileAtPath path: String, line: Int, column: Int)
}

/// LSP diagnostic severity levels.
enum DiagnosticSeverity: Int {
    case error = 1
    case warning = 2
    case information = 3
    case hint = 4
}

/// An LSP diagnostic with location and message.
struct LSPDiagnostic {
    let severity: DiagnosticSeverity
    let startLine: Int
    let startCharacter: Int
    let endLine: Int
    let endCharacter: Int
    let message: String
    let source: String?
}

/// A custom code editor view using CoreText for text rendering.
/// Supports line numbers, cursor, selection, syntax highlighting,
/// find & replace, LSP diagnostics, go-to-definition, completions,
/// multi-cursor editing, tree-sitter (when available), and minimap support.
class EditorView: NSView {
    private(set) var buffer: TextBuffer
    private var fileWatcher: SingleFileWatcher?
    private(set) var lspClient: LSPClient?
    private var treeSitter: TreeSitterHighlighter?

    // Large file performance thresholds
    private static let largeFileLineThreshold = 50_000
    private static let veryLargeFileLineThreshold = 200_000
    private(set) var isLargeFile = false
    private(set) var isVeryLargeFile = false

    // Rendering state
    private(set) var lineHeight: CGFloat = 18
    private let gutterWidth: CGFloat = 50
    private let textInset: CGFloat = 8
    private(set) var font: NSFont
    private var boldFont: NSFont
    private var cachedCharWidth: CGFloat

    // Scroll
    private(set) var scrollOffset: CGFloat = 0
    private(set) var horizontalScrollOffset: CGFloat = 0
    private(set) var visibleLineRange: Range<Int> = 0..<0

    // Colors (theme-aware via design system)
    private var bgColor: NSColor { ClomeSettings.shared.backgroundWithOpacity }
    private var gutterBgColor: NSColor {
        ClomeMacTheme.surfaceColor(.window, opacity: ClomeSettings.shared.windowOpacity - 0.05)
    }
    private var gutterTextColor: NSColor { ClomeMacColor.textTertiary }
    private var textColor: NSColor { ClomeMacColor.textPrimary }
    private var cursorColor: NSColor { ClomeMacColor.textPrimary }
    private var selectionColor: NSColor { ClomeMacColor.accent.withAlphaComponent(0.3) }
    private var currentLineColor: NSColor { ClomeMacColor.textPrimary.withAlphaComponent(0.03) }

    // Syntax colors (theme-aware)
    private var keywordColor: NSColor { SyntaxColorScheme.current.keyword }
    private var stringColor: NSColor { SyntaxColorScheme.current.string }
    private var commentColor: NSColor { SyntaxColorScheme.current.comment }
    private var numberColor: NSColor { SyntaxColorScheme.current.number }
    private var typeColor: NSColor { SyntaxColorScheme.current.type }
    private var functionColor: NSColor { SyntaxColorScheme.current.function }
    private var decoratorColor: NSColor { SyntaxColorScheme.current.decorator }

    // Auto-closing brackets
    private let pairMap: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'"]
    private let closingChars: Set<Character> = [")", "]", "}", "\"", "'"]

    // Multi-line syntax state
    private var lineStates: [LineSyntaxState] = []
    enum LineSyntaxState: Equatable { case normal, inBlockComment, inMultiLineString }

    // Cursor blink
    private var cursorVisible = true
    private var cursorTimer: Timer?

    // MARK: - Find & Replace state
    var findQuery: String = ""
    var findMatchRanges: [Range<Int>] = []
    var currentMatchIndex: Int = 0
    var findIsRegex: Bool = false
    var findCaseSensitive: Bool = false

    // MARK: - LSP Diagnostics
    var diagnostics: [LSPDiagnostic] = []
    private var documentVersion: Int = 0
    private var didChangeWorkItem: DispatchWorkItem?

    // MARK: - Go-to-Definition
    weak var navigationDelegate: EditorViewNavigationDelegate?

    // MARK: - Completion
    var completionPopup: CompletionPopupView?
    private var completionTriggerWorkItem: DispatchWorkItem?
    private var completionTokenStart: Int = 0

    // MARK: - Minimap support
    weak var minimapView: MinimapView?

    // MARK: - Agent modification banner
    private var agentBanner: NSView?
    /// Content before an agent modification, for diff/revert.
    private var preAgentContent: String?

    // MARK: - Scrollbar
    private var scrollbarOpacity: CGFloat = 0
    private var scrollbarFadeTimer: Timer?
    private let scrollbarWidth: CGFloat = 6
    private let scrollbarMinHeight: CGFloat = 30

    // Title for tab bar
    var title: String = "Untitled" {
        didSet {
            NotificationCenter.default.post(name: .terminalSurfaceTitleChanged, object: self)
        }
    }

    /// Visible line range exposed for minimap
    var visibleLines: Range<Int> { visibleLineRange }

    init(buffer: TextBuffer = TextBuffer()) {
        self.buffer = buffer
        let settings = ClomeSettings.shared
        self.font = settings.resolvedFont
        self.boldFont = settings.resolvedBoldFont
        self.lineHeight = settings.resolvedLineHeight
        let sample = "M" as NSString
        self.cachedCharWidth = sample.size(withAttributes: [.font: self.font]).width
        super.init(frame: .zero)
        wantsLayer = true
        // Don't set layer?.backgroundColor — draw() already fills the background.
        // Double-layering two semi-transparent fills blocks the backdrop blur.
        layer?.masksToBounds = true
        setupCursorBlink()

        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange), name: .clomeSettingsChanged, object: nil)

        if let lang = buffer.language {
            treeSitter = TreeSitterHighlighter(language: lang)
        }

        updateLargeFileMode()

        if let path = buffer.filePath {
            title = (path as NSString).lastPathComponent
            startFileWatcher(path)
            if !isVeryLargeFile { startLSP() }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func updateLargeFileMode() {
        let lines = buffer.lineCount
        isLargeFile = lines >= EditorView.largeFileLineThreshold
        isVeryLargeFile = lines >= EditorView.veryLargeFileLineThreshold
    }

    /// Walk up the view hierarchy to find the enclosing EditorPanel.
    func findEditorPanel() -> EditorPanel? {
        var v: NSView? = superview
        while let view = v {
            if let panel = view as? EditorPanel { return panel }
            v = view.superview
        }
        return nil
    }

    func cleanup() {
        cursorTimer?.invalidate()
        cursorTimer = nil
        scrollbarFadeTimer?.invalidate()
        scrollbarFadeTimer = nil
        fileWatcher?.stop()
        fileWatcher = nil
        lspClient?.stop()
        lspClient = nil
        completionPopup?.removeFromSuperview()
        completionPopup = nil
        completionTriggerWorkItem?.cancel()
        completionTriggerWorkItem = nil
        didChangeWorkItem?.cancel()
        didChangeWorkItem = nil
        findMatchRanges.removeAll()
        diagnostics.removeAll()
        lineStates.removeAll()
        minimapView = nil
        treeSitter = nil
    }

    /// Clear find match cache (called under memory pressure).
    func clearFindMatches() {
        findMatchRanges.removeAll()
        needsDisplay = true
    }

    // MARK: - File I/O

    func openFile(_ path: String) throws {
        buffer = try TextBuffer(contentsOfFile: path)
        title = (path as NSString).lastPathComponent
        scrollOffset = 0
        horizontalScrollOffset = 0
        maxLineWidthDirty = true
        diagnostics = []

        if let lang = buffer.language {
            treeSitter = TreeSitterHighlighter(language: lang)
        }

        updateLargeFileMode()
        startFileWatcher(path)
        if !isVeryLargeFile { startLSP() }
        recomputeLineStates()
        minimapView?.invalidateCache()
        needsDisplay = true
    }

    private func startFileWatcher(_ path: String) {
        fileWatcher?.stop()
        fileWatcher = SingleFileWatcher(path: path) { [weak self] in
            self?.handleExternalChange()
        }
        fileWatcher?.start()
    }

    var suppressNextExternalChange = false

    private func handleExternalChange() {
        guard let path = buffer.filePath else { return }

        // Suppress file watcher events caused by our own reject/revert writes
        if suppressNextExternalChange {
            suppressNextExternalChange = false
            if !buffer.isDirty {
                try? buffer.reload()
                minimapView?.invalidateCache()
                needsDisplay = true
            }
            return
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let _ = attrs[.modificationDate] as? Date else { return }

        // When Claude Code is actively editing, show a review banner instead of silently reloading
        if AgentFileTracker.shared.isTracking && !buffer.isDirty {
            let oldContent = buffer.text
            try? buffer.reload()
            let newContent = buffer.text
            minimapView?.invalidateCache()
            needsDisplay = true

            // Record the change in the tracker
            AgentFileTracker.shared.snapshotContent(oldContent, forPath: path)
            AgentFileTracker.shared.recordExternalChange(path: path, oldContent: oldContent, newContent: newContent)

            // Show the inline banner
            if oldContent != newContent {
                preAgentContent = oldContent
                showAgentBanner()
            }
            return
        }

        if !buffer.isDirty {
            try? buffer.reload()
            minimapView?.invalidateCache()
            needsDisplay = true
        }
    }

    // MARK: - Agent Banner

    private func showAgentBanner() {
        // Remove existing banner if any
        agentBanner?.removeFromSuperview()

        let banner = NSView()
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.wantsLayer = true
        banner.layer?.backgroundColor = NSColor(red: 0.15, green: 0.20, blue: 0.30, alpha: 0.95).cgColor
        banner.layer?.cornerRadius = 6

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Agent")
        icon.contentTintColor = NSColor(red: 0.45, green: 0.65, blue: 0.90, alpha: 1.0)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        banner.addSubview(icon)

        let label = NSTextField(labelWithString: "Claude modified this file")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor(white: 0.85, alpha: 1.0)
        banner.addSubview(label)

        let viewDiffBtn = makeAgentBannerButton(title: "View Diff", color: NSColor(red: 0.45, green: 0.65, blue: 0.90, alpha: 1.0))
        viewDiffBtn.target = self
        viewDiffBtn.action = #selector(agentBannerViewDiff)
        banner.addSubview(viewDiffBtn)

        let acceptBtn = makeAgentBannerButton(title: "Accept", color: NSColor(red: 0.4, green: 0.85, blue: 0.5, alpha: 1.0))
        acceptBtn.target = self
        acceptBtn.action = #selector(agentBannerAccept)
        banner.addSubview(acceptBtn)

        let dismissBtn = makeAgentBannerButton(title: "Dismiss", color: NSColor(white: 0.55, alpha: 1.0))
        dismissBtn.target = self
        dismissBtn.action = #selector(agentBannerDismiss)
        banner.addSubview(dismissBtn)

        addSubview(banner)

        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            banner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gutterWidth + 8),
            banner.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            banner.heightAnchor.constraint(equalToConstant: 32),

            icon.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: banner.centerYAnchor),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: banner.centerYAnchor),

            viewDiffBtn.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            viewDiffBtn.centerYAnchor.constraint(equalTo: banner.centerYAnchor),

            acceptBtn.leadingAnchor.constraint(equalTo: viewDiffBtn.trailingAnchor, constant: 6),
            acceptBtn.centerYAnchor.constraint(equalTo: banner.centerYAnchor),

            dismissBtn.leadingAnchor.constraint(equalTo: acceptBtn.trailingAnchor, constant: 6),
            dismissBtn.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            dismissBtn.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -10),
        ])

        agentBanner = banner
    }

    private func makeAgentBannerButton(title: String, color: NSColor) -> NSButton {
        let btn = NSButton()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.title = title
        btn.bezelStyle = .texturedRounded
        btn.isBordered = false
        btn.font = .systemFont(ofSize: 11, weight: .medium)
        btn.contentTintColor = color
        return btn
    }

    @objc private func agentBannerViewDiff() {
        guard let path = buffer.filePath else { return }
        // Post notification to open the diff review panel
        NotificationCenter.default.post(
            name: .openDiffReview,
            object: self,
            userInfo: ["path": path, "oldContent": preAgentContent ?? "", "newContent": buffer.text]
        )
    }

    @objc private func agentBannerAccept() {
        guard let path = buffer.filePath else { return }
        AgentFileTracker.shared.acceptChange(at: path)
        dismissAgentBanner()
    }

    @objc private func agentBannerDismiss() {
        dismissAgentBanner()
    }

    func dismissAgentBanner() {
        agentBanner?.removeFromSuperview()
        agentBanner = nil
        preAgentContent = nil
    }

    func startLSP() {
        guard let lang = buffer.language,
              let server = LanguageSupportView.effectiveServerCommand(for: lang) ?? LSPClient.serverCommand(for: lang),
              FileManager.default.isExecutableFile(atPath: server.command) else { return }

        let client = LSPClient(language: lang, command: server.command, args: server.args)
        client.delegate = self
        if let path = buffer.filePath {
            let rootPath = (path as NSString).deletingLastPathComponent
            try? client.start(rootPath: rootPath)

            let uri = "file://\(path)"
            client.openDocument(uri: uri, language: lang, text: buffer.text)
        }
        lspClient = client
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let totalLines = buffer.lineCount
        let frameHeight = bounds.height
        let firstVisibleLine = max(0, Int(scrollOffset / lineHeight))
        let lastVisibleLine = min(totalLines, firstVisibleLine + Int(frameHeight / lineHeight) + 2)
        visibleLineRange = firstVisibleLine..<lastVisibleLine

        // Background
        context.setFillColor(bgColor.cgColor)
        context.fill(bounds)

        // Gutter background
        context.setFillColor(gutterBgColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: gutterWidth, height: bounds.height))

        // Current line highlight (for all cursors)
        for cursor in buffer.cursors {
            let cursorY = bounds.height - CGFloat(cursor.line - firstVisibleLine + 1) * lineHeight + scrollOffset
            context.setFillColor(currentLineColor.cgColor)
            context.fill(CGRect(x: gutterWidth, y: cursorY, width: bounds.width - gutterWidth, height: lineHeight))
        }

        // Draw gutter content (line numbers + diagnostic icons) before clipping
        for lineIdx in visibleLineRange {
            let y = bounds.height - CGFloat(lineIdx - firstVisibleLine + 1) * lineHeight

            // Line number
            let lineNumStr = "\(lineIdx + 1)" as NSString
            let isCurrentLine = buffer.cursors.contains(where: { $0.line == lineIdx })
            let lineNumAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: isCurrentLine ? textColor : gutterTextColor
            ]
            let lineNumSize = lineNumStr.size(withAttributes: lineNumAttrs)
            lineNumStr.draw(
                at: NSPoint(x: gutterWidth - lineNumSize.width - 8, y: y + (lineHeight - lineNumSize.height) / 2),
                withAttributes: lineNumAttrs
            )

            // Diagnostic gutter icons
            drawDiagnosticGutterIcon(for: lineIdx, at: y, in: context)
        }

        // Clip text area so horizontal scroll doesn't bleed into gutter
        context.saveGState()
        context.clip(to: CGRect(x: gutterWidth, y: 0, width: bounds.width - gutterWidth, height: bounds.height))

        // Draw visible lines (text only, inside clip)
        for lineIdx in visibleLineRange {
            let y = bounds.height - CGFloat(lineIdx - firstVisibleLine + 1) * lineHeight

            // Line text
            let lineText = buffer.line(lineIdx)
            let displayText = lineText.hasSuffix("\n") ? String(lineText.dropLast()) : lineText
            let attrStr: NSAttributedString
            if isVeryLargeFile {
                // Skip syntax highlighting entirely for very large files
                attrStr = NSAttributedString(string: displayText, attributes: [.font: font, .foregroundColor: textColor])
            } else {
                attrStr = syntaxHighlight(displayText, language: buffer.language, lineIndex: lineIdx)
            }
            attrStr.draw(at: NSPoint(x: gutterWidth + textInset - horizontalScrollOffset, y: y + (lineHeight - font.pointSize) / 2 - 1))
        }

        // Find match highlights
        drawFindHighlights(firstVisibleLine: firstVisibleLine, in: context)

        // Diagnostic underlines
        drawDiagnosticUnderlines(firstVisibleLine: firstVisibleLine, in: context)

        // Selection (for all cursors)
        for cursor in buffer.cursors {
            if let selRange = cursor.selectionRange {
                context.setFillColor(selectionColor.cgColor)
                drawSelection(selRange, firstVisibleLine: firstVisibleLine, in: context)
            }
        }

        // Cursors (draw all)
        if cursorVisible {
            for cursor in buffer.cursors {
                let cursorLine = cursor.line
                let cursorCol = cursor.column
                if cursorLine >= firstVisibleLine && cursorLine < lastVisibleLine {
                    let cursorX = textX(cursorCol)
                    let cursorLineY = bounds.height - CGFloat(cursorLine - firstVisibleLine + 1) * lineHeight
                    context.setFillColor(cursorColor.cgColor)
                    context.fill(CGRect(x: cursorX, y: cursorLineY + 2, width: 1.5, height: lineHeight - 4))
                }
            }
        }

        // Restore from text area clip
        context.restoreGState()

        // Gutter divider
        context.setStrokeColor(NSColor(white: 1.0, alpha: 0.08).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: gutterWidth, y: 0))
        context.addLine(to: CGPoint(x: gutterWidth, y: bounds.height))
        context.strokePath()

        // Scrollbar
        drawScrollbar(in: context)
    }

    func charWidth(_ count: Int) -> CGFloat {
        cachedCharWidth * CGFloat(count)
    }

    /// X coordinate for a given column, accounting for horizontal scroll.
    private func textX(_ col: Int) -> CGFloat {
        gutterWidth + textInset + charWidth(col) - horizontalScrollOffset
    }

    /// Width of the longest line in characters, cached for horizontal scroll bounds.
    private var cachedMaxLineWidth: CGFloat = 0
    private var maxLineWidthDirty: Bool = true

    private var maxLineWidth: CGFloat {
        if maxLineWidthDirty {
            var maxChars = 0
            for i in 0..<buffer.lineCount {
                let line = buffer.line(i)
                let len = line.hasSuffix("\n") ? line.count - 1 : line.count
                if len > maxChars { maxChars = len }
            }
            cachedMaxLineWidth = charWidth(maxChars)
            maxLineWidthDirty = false
        }
        return cachedMaxLineWidth
    }

    private func drawSelection(_ range: Range<Int>, firstVisibleLine: Int, in context: CGContext) {
        let startPos = buffer.position(at: range.lowerBound)
        let endPos = buffer.position(at: range.upperBound)

        for line in startPos.line...endPos.line {
            guard line >= visibleLineRange.lowerBound && line < visibleLineRange.upperBound else { continue }

            let y = bounds.height - CGFloat(line - firstVisibleLine + 1) * lineHeight
            let startCol: Int = line == startPos.line ? startPos.column : 0
            let endCol: Int = line == endPos.line ? endPos.column : buffer.line(line).count

            let x = textX(startCol)
            let width = charWidth(endCol - startCol)
            context.fill(CGRect(x: x, y: y, width: width, height: lineHeight))
        }
    }

    // MARK: - Find & Replace Drawing

    private func drawFindHighlights(firstVisibleLine: Int, in context: CGContext) {
        guard !findMatchRanges.isEmpty else { return }

        for (i, matchRange) in findMatchRanges.enumerated() {
            let startPos = buffer.position(at: matchRange.lowerBound)
            let endPos = buffer.position(at: matchRange.upperBound)

            // Only draw if visible
            guard startPos.line < visibleLineRange.upperBound && endPos.line >= visibleLineRange.lowerBound else { continue }

            let isCurrentMatch = i == currentMatchIndex
            if isCurrentMatch {
                context.setFillColor(NSColor(red: 0.7, green: 0.55, blue: 0.2, alpha: 0.5).cgColor)
            } else {
                context.setFillColor(NSColor(red: 0.6, green: 0.5, blue: 0.2, alpha: 0.3).cgColor)
            }

            for line in startPos.line...endPos.line {
                guard line >= visibleLineRange.lowerBound && line < visibleLineRange.upperBound else { continue }
                let y = bounds.height - CGFloat(line - firstVisibleLine + 1) * lineHeight
                let startCol = line == startPos.line ? startPos.column : 0
                let endCol = line == endPos.line ? endPos.column : buffer.line(line).count
                let x = textX(startCol)
                let w = charWidth(endCol - startCol)
                context.fill(CGRect(x: x, y: y, width: w, height: lineHeight))
            }
        }
    }

    // MARK: - Find & Replace Logic

    /// Maximum find matches to track — keeps memory bounded.
    /// 10K matches × ~16 bytes each ≈ 160KB, plenty for navigation.
    private static let maxFindMatches = 10_000

    func findMatches() {
        findMatchRanges = []
        currentMatchIndex = 0
        guard !findQuery.isEmpty else {
            needsDisplay = true
            return
        }

        // Materialize text once for the entire search
        let text = buffer.text
        if findIsRegex {
            var options: NSRegularExpression.Options = []
            if !findCaseSensitive { options.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: findQuery, options: options) else {
                needsDisplay = true
                return
            }
            let nsRange = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: nsRange) {
                if let range = Range(match.range, in: text) {
                    let start = text.distance(from: text.startIndex, to: range.lowerBound)
                    let end = text.distance(from: text.startIndex, to: range.upperBound)
                    findMatchRanges.append(start..<end)
                    if findMatchRanges.count >= EditorView.maxFindMatches { break }
                }
            }
        } else {
            var searchOptions: String.CompareOptions = []
            if !findCaseSensitive { searchOptions.insert(.caseInsensitive) }
            var searchStart = text.startIndex
            while let range = text.range(of: findQuery, options: searchOptions, range: searchStart..<text.endIndex) {
                let start = text.distance(from: text.startIndex, to: range.lowerBound)
                let end = text.distance(from: text.startIndex, to: range.upperBound)
                findMatchRanges.append(start..<end)
                searchStart = range.upperBound
                if range.isEmpty { break }
                if findMatchRanges.count >= EditorView.maxFindMatches { break }
            }
        }
        needsDisplay = true
    }

    func navigateMatch(delta: Int) {
        guard !findMatchRanges.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + delta + findMatchRanges.count) % findMatchRanges.count
        let matchRange = findMatchRanges[currentMatchIndex]
        let pos = buffer.position(at: matchRange.lowerBound)
        scrollToLine(pos.line)
        needsDisplay = true
    }

    func replaceCurrentMatch(with replacement: String) {
        guard currentMatchIndex >= 0, currentMatchIndex < findMatchRanges.count else { return }
        let range = findMatchRanges[currentMatchIndex]
        buffer.replace(in: range, with: replacement)
        findMatches()
        minimapView?.invalidateCache()
        needsDisplay = true
    }

    func replaceAllMatches(with replacement: String) {
        guard !findMatchRanges.isEmpty else { return }
        // Replace in reverse to preserve earlier offsets
        for range in findMatchRanges.reversed() {
            buffer.replace(in: range, with: replacement)
        }
        findMatches()
        minimapView?.invalidateCache()
        needsDisplay = true
    }

    func selectedText() -> String? {
        guard let range = buffer.cursor.selectionRange else { return nil }
        return buffer.substring(in: range)
    }

    func dismissFindBar() {
        findQuery = ""
        findMatchRanges = []
        // Notify panel to hide the find bar
        NotificationCenter.default.post(name: .editorDismissFindBar, object: self)
        needsDisplay = true
    }

    // MARK: - LSP Diagnostics Drawing

    private func drawDiagnosticGutterIcon(for lineIdx: Int, at y: CGFloat, in context: CGContext) {
        // Find highest severity diagnostic on this line
        var highestSeverity: DiagnosticSeverity?
        for diag in diagnostics {
            if diag.startLine == lineIdx {
                if highestSeverity == nil || diag.severity.rawValue < (highestSeverity?.rawValue ?? 5) {
                    highestSeverity = diag.severity
                }
            }
        }

        guard let severity = highestSeverity else { return }

        let iconSize: CGFloat = 10
        let iconY = y + (lineHeight - iconSize) / 2
        let iconX: CGFloat = 4

        let symbolName: String
        let color: NSColor
        switch severity {
        case .error:
            symbolName = "exclamationmark.circle.fill"
            color = NSColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 1.0)
        case .warning:
            symbolName = "exclamationmark.triangle.fill"
            color = NSColor(red: 0.9, green: 0.75, blue: 0.3, alpha: 1.0)
        case .information:
            symbolName = "info.circle.fill"
            color = NSColor(red: 0.4, green: 0.6, blue: 0.9, alpha: 1.0)
        case .hint:
            symbolName = "lightbulb.fill"
            color = NSColor(white: 0.5, alpha: 1.0)
        }

        if let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 8, weight: .medium)
            if let configured = icon.withSymbolConfiguration(cfg) {
                NSGraphicsContext.saveGraphicsState()
                color.set()
                configured.draw(in: CGRect(x: iconX, y: iconY, width: iconSize, height: iconSize))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    private func drawDiagnosticUnderlines(firstVisibleLine: Int, in context: CGContext) {
        for diag in diagnostics {
            guard diag.startLine >= visibleLineRange.lowerBound && diag.startLine < visibleLineRange.upperBound else { continue }

            let y = bounds.height - CGFloat(diag.startLine - firstVisibleLine + 1) * lineHeight
            let startX = textX(diag.startCharacter)
            let endCol = diag.endCharacter > diag.startCharacter ? diag.endCharacter : diag.startCharacter + 1
            let endX = textX(endCol)

            let color: NSColor
            switch diag.severity {
            case .error:   color = NSColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 0.8)
            case .warning: color = NSColor(red: 0.9, green: 0.75, blue: 0.3, alpha: 0.8)
            default:       color = NSColor(red: 0.4, green: 0.6, blue: 0.9, alpha: 0.6)
            }

            // Draw squiggly underline
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(1.0)

            let path = CGMutablePath()
            let amplitude: CGFloat = 1.5
            let period: CGFloat = 4.0
            let baseY = y + 1 // just below the text baseline

            var x = startX
            path.move(to: CGPoint(x: x, y: baseY))
            while x < endX {
                let relX = x - startX
                let waveY = baseY + amplitude * sin(relX * .pi * 2 / period)
                path.addLine(to: CGPoint(x: x, y: waveY))
                x += 1
            }

            context.addPath(path)
            context.strokePath()
        }
    }

    private func notifyLSPDidChange() {
        recomputeLineStates(fromLine: buffer.cursor.line)
        guard let path = buffer.filePath, let client = lspClient else { return }

        // Skip LSP notifications entirely for very large files
        guard !isVeryLargeFile else { return }

        let uri = "file://\(path)"
        documentVersion += 1
        let version = documentVersion

        didChangeWorkItem?.cancel()
        // Larger debounce for large files
        let debounce: Double = isLargeFile ? 1.0 : 0.3
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            client.didChangeDocument(uri: uri, version: version, changes: [
                ["text": self.buffer.text]
            ])
        }
        didChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: workItem)
    }

    // MARK: - Go-to-Definition

    private func goToDefinition(line: Int, column: Int) {
        guard let path = buffer.filePath, let client = lspClient else { return }
        let uri = "file://\(path)"

        Task {
            do {
                let response = try await client.definition(uri: uri, line: line, character: column)
                handleDefinitionResponse(response)
            } catch {
                NSLog("Go-to-definition error: \(error)")
            }
        }
    }

    private func handleDefinitionResponse(_ response: LSPResponse) {
        // Response can be Location, Location[], or LocationLink[]
        var targetUri: String?
        var targetLine: Int?
        var targetChar: Int?

        if let result = response.result as? [String: Any] {
            targetUri = result["uri"] as? String
            if let range = result["range"] as? [String: Any],
               let start = range["start"] as? [String: Any] {
                targetLine = start["line"] as? Int
                targetChar = start["character"] as? Int
            }
        } else if let results = response.result as? [[String: Any]], let first = results.first {
            targetUri = first["uri"] as? String ?? (first["targetUri"] as? String)
            let range = first["range"] as? [String: Any] ?? first["targetRange"] as? [String: Any]
            if let start = range?["start"] as? [String: Any] {
                targetLine = start["line"] as? Int
                targetChar = start["character"] as? Int
            }
        }

        guard let uri = targetUri, let line = targetLine, let col = targetChar else { return }
        let path = uri.hasPrefix("file://") ? String(uri.dropFirst(7)) : uri

        if path == buffer.filePath {
            navigateTo(line: line, column: col)
        } else {
            navigationDelegate?.editorView(self, openFileAtPath: path, line: line, column: col)
        }
    }

    /// Navigate cursor to a specific line and column, scrolling to make it visible.
    func navigateTo(line: Int, column: Int) {
        buffer.cursor.line = line
        buffer.cursor.column = column
        buffer.cursor.offset = buffer.offset(line: line, column: column)
        buffer.cursor.selectionStart = nil
        scrollToLine(line)
        needsDisplay = true
    }

    // MARK: - Completion

    private func triggerCompletion() {
        // Skip completions for very large files to avoid buffer.text materialization
        guard !isVeryLargeFile else { return }
        guard let path = buffer.filePath, let client = lspClient else { return }
        let uri = "file://\(path)"
        let line = buffer.cursor.line
        let col = buffer.cursor.column

        completionTriggerWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            Task {
                do {
                    let response = try await client.completion(uri: uri, line: line, character: col)
                    self.handleCompletionResponse(response)
                } catch {
                    self.dismissCompletion()
                }
            }
        }
        completionTriggerWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func handleCompletionResponse(_ response: LSPResponse) {
        let items = response.completionItems.map { CompletionItem.fromLSP($0) }
        guard !items.isEmpty else {
            dismissCompletion()
            return
        }

        // Determine the start of the current token for filtering
        var tokenStart = buffer.cursor.offset
        while tokenStart > 0 {
            guard let ch = buffer.character(at: tokenStart - 1) else { break }
            if ch.isLetter || ch.isNumber || ch == "_" {
                tokenStart -= 1
            } else {
                break
            }
        }
        completionTokenStart = tokenStart

        let filterText = tokenStart < buffer.cursor.offset ?
            buffer.substring(in: tokenStart..<buffer.cursor.offset) : ""

        if completionPopup == nil {
            let popup = CompletionPopupView()
            popup.onAccept = { [weak self] item in
                self?.acceptCompletion(item)
            }
            popup.onDismiss = { [weak self] in
                self?.dismissCompletion()
            }
            addSubview(popup)
            completionPopup = popup
        }

        completionPopup?.update(items: items, filter: filterText)

        if completionPopup?.isEmpty == true {
            dismissCompletion()
            return
        }

        // Smart positioning: default below cursor, flip above if needed
        let firstVisibleLine = max(0, Int(scrollOffset / lineHeight))
        let cursorX = textX(buffer.cursor.column)
        let cursorY = bounds.height - CGFloat(buffer.cursor.line - firstVisibleLine + 1) * lineHeight
        let popupH = completionPopup?.frame.height ?? 0
        let popupW = completionPopup?.frame.width ?? 300

        var popupX = cursorX
        var popupY = cursorY - popupH

        // If popup goes below view, flip above cursor
        if popupY < 0 {
            popupY = cursorY + lineHeight
        }
        // If popup goes off right edge, shift left
        if popupX + popupW > bounds.width {
            popupX = bounds.width - popupW
        }
        // Clamp to view bounds
        popupX = max(0, popupX)
        popupY = max(0, min(popupY, bounds.height - popupH))

        completionPopup?.setFrameOrigin(NSPoint(x: popupX, y: popupY))
    }

    private func acceptCompletion(_ item: CompletionItem) {
        let insertText = item.textToInsert
        // Replace from token start to current cursor
        if completionTokenStart < buffer.cursor.offset {
            buffer.replace(in: completionTokenStart..<buffer.cursor.offset, with: insertText)
            buffer.cursor.offset = completionTokenStart + insertText.count
        } else {
            buffer.insertAtCursor(insertText)
        }

        // Auto-insert () for function/method/constructor completions
        let isFunctionKind = item.kind == 2 || item.kind == 3 || item.kind == 4 // Method, Function, Constructor
        if isFunctionKind {
            let off = buffer.cursor.offset
            let nextIsOpenParen = off < buffer.count && buffer.character(at: off) == Character("(")
            if !nextIsOpenParen {
                buffer.insertAtCursor("()")
                // Position cursor between parens
                buffer.cursor.offset -= 1
            }
        }

        let pos = buffer.position(at: buffer.cursor.offset)
        buffer.cursor.line = pos.line
        buffer.cursor.column = pos.column
        dismissCompletion()
        notifyLSPDidChange()
        minimapView?.invalidateCache()
        needsDisplay = true
    }

    func dismissCompletion() {
        completionPopup?.removeFromSuperview()
        completionPopup = nil
        completionTriggerWorkItem?.cancel()
    }

    // MARK: - Scroll

    func scrollToLine(_ line: Int) {
        let targetY = CGFloat(line) * lineHeight - bounds.height / 2
        let maxScroll = max(0, CGFloat(buffer.lineCount) * lineHeight - bounds.height)
        scrollOffset = max(0, min(targetY, maxScroll))
        ensureHorizontalCursorVisible()
        minimapView?.needsDisplay = true
        showScrollbar()
        needsDisplay = true
    }

    private func ensureHorizontalCursorVisible() {
        let cursorPixelX = charWidth(buffer.cursor.column)
        let visibleWidth = bounds.width - gutterWidth - textInset
        let margin: CGFloat = charWidth(4) // keep some chars visible ahead

        if cursorPixelX - horizontalScrollOffset > visibleWidth - margin {
            horizontalScrollOffset = cursorPixelX - visibleWidth + margin
        } else if cursorPixelX - horizontalScrollOffset < 0 {
            horizontalScrollOffset = max(0, cursorPixelX - margin)
        }
        let maxHScroll = max(0, maxLineWidth - visibleWidth)
        horizontalScrollOffset = max(0, min(horizontalScrollOffset, maxHScroll))
    }

    // MARK: - Scrollbar

    private func drawScrollbar(in context: CGContext) {
        guard scrollbarOpacity > 0 else { return }
        let totalContentHeight = CGFloat(buffer.lineCount) * lineHeight
        guard totalContentHeight > bounds.height else { return }

        let trackHeight = bounds.height
        let thumbRatio = bounds.height / totalContentHeight
        let thumbHeight = max(scrollbarMinHeight, trackHeight * thumbRatio)
        let maxScroll = totalContentHeight - bounds.height
        let scrollFraction = maxScroll > 0 ? scrollOffset / maxScroll : 0
        let thumbY = (trackHeight - thumbHeight) * (1 - scrollFraction)

        let thumbX = bounds.width - scrollbarWidth - 2
        let thumbRect = CGRect(x: thumbX, y: thumbY, width: scrollbarWidth, height: thumbHeight)

        context.saveGState()
        let thumbPath = CGPath(roundedRect: thumbRect, cornerWidth: scrollbarWidth / 2, cornerHeight: scrollbarWidth / 2, transform: nil)
        context.setFillColor(NSColor(white: 1.0, alpha: 0.25 * scrollbarOpacity).cgColor)
        context.addPath(thumbPath)
        context.fillPath()
        context.restoreGState()
    }

    private func showScrollbar() {
        scrollbarOpacity = 1.0
        scrollbarFadeTimer?.invalidate()
        scrollbarFadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.fadeOutScrollbar()
            }
        }
    }

    private func fadeOutScrollbar() {
        // Animate fade out over ~0.3s — only dirty the scrollbar strip, not the whole view.
        let steps = 6
        let interval = 0.05
        var remaining = steps
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            // Timer fires on the main run loop, safe to use MainActor.assumeIsolated.
            // Use nonisolated(unsafe) to move `timer` across the Sendable boundary.
            nonisolated(unsafe) let timer = timer
            MainActor.assumeIsolated {
                guard let self = self else { timer.invalidate(); return }
                remaining -= 1
                self.scrollbarOpacity = CGFloat(remaining) / CGFloat(steps)
                // Only invalidate the scrollbar strip (right edge)
                let scrollbarRect = NSRect(
                    x: self.bounds.width - self.scrollbarWidth - 4,
                    y: 0,
                    width: self.scrollbarWidth + 4,
                    height: self.bounds.height
                )
                self.setNeedsDisplay(scrollbarRect)
                if remaining <= 0 {
                    timer.invalidate()
                }
            }
        }
    }

    // MARK: - Multi-line Syntax State

    private func recomputeLineStates(fromLine editedLine: Int? = nil) {
        // Skip entirely for very large files (syntax highlighting is disabled)
        if isVeryLargeFile { return }

        let totalLines = buffer.lineCount
        let lang = buffer.language ?? ""
        let hasBlockComments = languageHasBlockComments(lang)

        // Determine start line for incremental update
        let startLine: Int
        if let edited = editedLine, edited > 0, edited < lineStates.count {
            startLine = edited
        } else {
            startLine = 0
        }

        // Resize lineStates array if needed
        if lineStates.count != totalLines {
            if totalLines > lineStates.count {
                lineStates.append(contentsOf: Array(repeating: .normal, count: totalLines - lineStates.count))
            } else {
                lineStates.removeLast(lineStates.count - totalLines)
            }
        }

        // Initial state: either from previous line or .normal
        var state: LineSyntaxState = startLine > 0 ? lineStates[startLine] : .normal
        if startLine == 0 {
            state = .normal
        }

        for i in startLine..<totalLines {
            let oldState = lineStates[i]
            lineStates[i] = state

            let line = buffer.line(i)
            switch state {
            case .normal:
                if hasBlockComments, let r = line.range(of: "/*") {
                    if line[r.upperBound...].range(of: "*/") == nil {
                        state = .inBlockComment
                    }
                }
                let tripleDoubleCount = line.components(separatedBy: "\"\"\"").count - 1
                if tripleDoubleCount % 2 == 1 {
                    state = .inMultiLineString
                }
                if state == .normal && lang == "python" {
                    let tripleSingleCount = line.components(separatedBy: "'''").count - 1
                    if tripleSingleCount % 2 == 1 {
                        state = .inMultiLineString
                    }
                }
            case .inBlockComment:
                if line.range(of: "*/") != nil {
                    state = .normal
                }
            case .inMultiLineString:
                if line.contains("\"\"\"") || (lang == "python" && line.contains("'''")) {
                    state = .normal
                }
            }

            // Early termination: if we're past the edited area and state matches old, stop
            if let edited = editedLine, i > edited + 1, lineStates[i] == oldState {
                // State has converged with previous computation — no need to continue
                break
            }
        }
    }

    // MARK: - Syntax Highlighting (Regex-based fallback)

    private func syntaxHighlight(_ text: String, language: String?, lineIndex: Int = 0) -> NSAttributedString {
        let attr = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: textColor
        ])

        guard let lang = language else { return attr }

        // 1. Multi-line state: if we start in a block comment or multi-line string
        let startState: LineSyntaxState = lineIndex < lineStates.count ? lineStates[lineIndex] : .normal

        if startState == .inBlockComment {
            let fullRange = NSRange(location: 0, length: (text as NSString).length)
            attr.addAttribute(.foregroundColor, value: commentColor, range: fullRange)
            // Check if block comment ends on this line
            if let closeRange = text.range(of: "*/") {
                let afterClose = text.distance(from: text.startIndex, to: closeRange.upperBound)
                // Re-highlight the portion after */
                let remaining = String(text[closeRange.upperBound...])
                let subAttr = syntaxHighlightNormal(remaining, language: lang)
                subAttr.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: subAttr.length)) { val, range, _ in
                    if let color = val as? NSColor {
                        let shifted = NSRange(location: range.location + afterClose, length: range.length)
                        attr.addAttribute(.foregroundColor, value: color, range: shifted)
                    }
                }
            }
            return attr
        }

        if startState == .inMultiLineString {
            let fullRange = NSRange(location: 0, length: (text as NSString).length)
            attr.addAttribute(.foregroundColor, value: stringColor, range: fullRange)
            // Check for both """ and ''' closers
            var closeRange: Range<String.Index>?
            if let r = text.range(of: "\"\"\"") {
                closeRange = r
            }
            if lang == "python", let r = text.range(of: "'''") {
                if closeRange == nil || r.lowerBound < closeRange!.lowerBound {
                    closeRange = r
                }
            }
            if let closeRange = closeRange {
                let afterClose = text.distance(from: text.startIndex, to: closeRange.upperBound)
                let remaining = String(text[closeRange.upperBound...])
                let subAttr = syntaxHighlightNormal(remaining, language: lang)
                subAttr.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: subAttr.length)) { val, range, _ in
                    if let color = val as? NSColor {
                        let shifted = NSRange(location: range.location + afterClose, length: range.length)
                        attr.addAttribute(.foregroundColor, value: color, range: shifted)
                    }
                }
            }
            return attr
        }

        return syntaxHighlightNormal(text, language: lang, into: attr)
    }

    @discardableResult
    private func syntaxHighlightNormal(_ text: String, language lang: String, into attr: NSMutableAttributedString? = nil) -> NSMutableAttributedString {
        let result = attr ?? NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: textColor
        ])

        // Apply patterns from lowest to highest priority so later ones override.

        // 2. Numbers (lowest priority)
        highlightPattern(result, pattern: "\\b\\d+(\\.\\d+)?\\b", color: numberColor)

        // 3. Types (capitalized identifiers)
        highlightPattern(result, pattern: "\\b[A-Z][a-zA-Z0-9]*\\b", color: typeColor)

        // 4. Function calls
        highlightCaptureGroup(result, pattern: "\\b([a-zA-Z_][a-zA-Z0-9_]*)\\s*\\(", color: functionColor, group: 1)

        // 5. Decorators
        switch lang {
        case "swift", "python", "java", "kotlin", "typescript", "tsx", "latex":
            highlightPattern(result, pattern: "@[a-zA-Z_][a-zA-Z0-9_]*", color: decoratorColor)
        case "rust":
            highlightPattern(result, pattern: "#\\[.*?\\]", color: decoratorColor)
        default:
            break
        }

        // 6. Keywords (override types/functions)
        let keywords = keywordsFor(language: lang)
        if !keywords.isEmpty {
            if lang == "latex" {
                // LaTeX commands use backslash prefix: \command
                let pattern = "\\\\(" + keywords.joined(separator: "|") + ")\\b"
                highlightPattern(result, pattern: pattern, color: keywordColor)
                // Also highlight all other \commands as functions
                highlightPattern(result, pattern: "\\\\[a-zA-Z@]+", color: functionColor)
                // Re-apply keyword coloring so known commands override generic
                highlightPattern(result, pattern: "\\\\(" + keywords.joined(separator: "|") + ")\\b", color: keywordColor)
                // LaTeX math delimiters
                highlightPattern(result, pattern: "\\$[^$]*\\$", color: numberColor)
                // LaTeX curly brace arguments
                highlightCaptureGroup(result, pattern: "\\\\[a-zA-Z]+\\{([^}]*)\\}", color: stringColor, group: 1)
                // LaTeX environment names in \begin{...} and \end{...}
                highlightCaptureGroup(result, pattern: "\\\\(?:begin|end)\\{([^}]*)\\}", color: typeColor, group: 1)
            } else if lang == "bibtex" {
                // BibTeX entry types: @article{...}
                let pattern = "@(" + keywords.joined(separator: "|") + ")\\b"
                highlightPattern(result, pattern: pattern, color: keywordColor, options: .caseInsensitive)
                // BibTeX field names
                highlightCaptureGroup(result, pattern: "^\\s*([a-zA-Z]+)\\s*=", color: functionColor, group: 1)
            } else {
                let pattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
                highlightPattern(result, pattern: pattern, color: keywordColor)
            }
        }

        // 7. Line comments (override everything within)
        let lineCommentPrefix: String?
        switch lang {
        case "python", "bash", "ruby", "r", "perl", "julia":
            lineCommentPrefix = "#"
        case "swift", "rust", "go", "c", "cpp", "javascript", "typescript", "tsx",
             "java", "kotlin", "c_sharp", "dart", "scala", "zig", "php":
            lineCommentPrefix = "//"
        case "lua", "sql", "haskell":
            lineCommentPrefix = "--"
        case "elisp":
            lineCommentPrefix = ";"
        case "latex", "bibtex":
            lineCommentPrefix = "%"
        default:
            lineCommentPrefix = nil
        }
        if let prefix = lineCommentPrefix {
            highlightPattern(result, pattern: "\(NSRegularExpression.escapedPattern(for: prefix)).*$", color: commentColor, options: .anchorsMatchLines)
        }

        // 8. Block comment starts within normal lines (language-aware)
        if languageHasBlockComments(lang) {
            highlightPattern(result, pattern: "/\\*.*?(\\*/|$)", color: commentColor)
        }

        // 9. Strings (highest priority — override everything within)
        highlightPattern(result, pattern: "\"[^\"\\\\]*(\\\\.[^\"\\\\]*)*\"", color: stringColor)
        highlightPattern(result, pattern: "'[^'\\\\]*(\\\\.[^'\\\\]*)*'", color: stringColor)

        return result
    }

    // MARK: - Regex Cache

    /// Thread-safe cache for compiled regex patterns. Avoids recompiling the same
    /// pattern+options on every line of every draw (was ~12 compiles × 50 lines × 2/sec).
    private static var regexCache: [String: NSRegularExpression] = [:]
    private static let regexCacheLock = NSLock()

    private static func cachedRegex(pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = "\(pattern)|\(options.rawValue)"
        regexCacheLock.lock()
        defer { regexCacheLock.unlock() }
        if let cached = regexCache[key] { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        regexCache[key] = regex
        return regex
    }

    private func highlightPattern(_ attr: NSMutableAttributedString, pattern: String, color: NSColor, options: NSRegularExpression.Options = []) {
        guard let regex = EditorView.cachedRegex(pattern: pattern, options: options) else { return }
        let str = attr.string
        let range = NSRange(str.startIndex..., in: str)
        for match in regex.matches(in: str, range: range) {
            attr.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    private func highlightCaptureGroup(_ attr: NSMutableAttributedString, pattern: String, color: NSColor, group: Int = 1) {
        guard let regex = EditorView.cachedRegex(pattern: pattern) else { return }
        let str = attr.string
        let range = NSRange(str.startIndex..., in: str)
        for match in regex.matches(in: str, range: range) {
            let groupRange = match.range(at: group)
            if groupRange.location != NSNotFound {
                attr.addAttribute(.foregroundColor, value: color, range: groupRange)
            }
        }
    }

    private func languageHasBlockComments(_ lang: String) -> Bool {
        switch lang {
        case "swift", "rust", "go", "c", "cpp", "javascript", "typescript", "tsx",
             "java", "kotlin", "c_sharp", "dart", "scala", "zig", "css", "scss", "php":
            return true
        default:
            return false
        }
    }

    private func editorDidChange() {
        maxLineWidthDirty = true
        ensureHorizontalCursorVisible()
        needsDisplay = true
        NotificationCenter.default.post(name: .editorCursorChanged, object: self)
    }

    private func keywordsFor(language: String) -> [String] {
        switch language {
        case "swift":
            return ["func", "var", "let", "class", "struct", "enum", "protocol", "extension", "import",
                    "if", "else", "guard", "switch", "case", "default", "for", "while", "repeat",
                    "return", "throw", "throws", "try", "catch", "do", "break", "continue",
                    "public", "private", "internal", "open", "fileprivate", "static", "override",
                    "init", "deinit", "self", "super", "nil", "true", "false", "async", "await",
                    "where", "in", "is", "as", "typealias", "associatedtype", "some", "any"]
        case "rust":
            return ["fn", "let", "mut", "const", "struct", "enum", "impl", "trait", "mod", "use",
                    "pub", "crate", "self", "super", "if", "else", "match", "for", "while", "loop",
                    "return", "break", "continue", "true", "false", "async", "await", "move",
                    "where", "type", "unsafe", "ref", "dyn", "static", "extern"]
        case "python":
            return ["def", "class", "if", "elif", "else", "for", "while", "try", "except", "finally",
                    "with", "as", "import", "from", "return", "yield", "raise", "pass", "break",
                    "continue", "and", "or", "not", "in", "is", "True", "False", "None", "lambda",
                    "global", "nonlocal", "async", "await", "self"]
        case "javascript", "typescript", "tsx":
            return ["function", "const", "let", "var", "class", "extends", "if", "else", "for",
                    "while", "do", "switch", "case", "default", "return", "throw", "try", "catch",
                    "finally", "new", "delete", "typeof", "instanceof", "void", "this", "super",
                    "import", "export", "from", "async", "await", "yield", "true", "false", "null",
                    "undefined", "of", "in", "type", "interface", "enum"]
        case "go":
            return ["func", "var", "const", "type", "struct", "interface", "map", "chan",
                    "if", "else", "for", "range", "switch", "case", "default", "select",
                    "return", "break", "continue", "goto", "go", "defer", "package", "import",
                    "true", "false", "nil", "fallthrough"]
        case "c", "cpp":
            return ["int", "char", "float", "double", "void", "long", "short", "unsigned", "signed",
                    "const", "static", "extern", "volatile", "register", "struct", "union", "enum",
                    "typedef", "if", "else", "for", "while", "do", "switch", "case", "default",
                    "return", "break", "continue", "goto", "sizeof", "NULL", "true", "false",
                    "class", "public", "private", "protected", "virtual", "override", "template",
                    "namespace", "using", "auto", "nullptr", "constexpr", "noexcept"]
        case "zig":
            return ["fn", "var", "const", "pub", "extern", "export", "inline", "comptime",
                    "if", "else", "for", "while", "switch", "break", "continue", "return",
                    "unreachable", "struct", "enum", "union", "error", "try", "catch",
                    "defer", "errdefer", "test", "true", "false", "null", "undefined",
                    "threadlocal", "anytype", "noreturn", "void"]
        case "latex":
            return ["documentclass", "usepackage", "begin", "end", "newcommand", "renewcommand",
                    "title", "author", "date", "maketitle", "tableofcontents",
                    "section", "subsection", "subsubsection", "paragraph", "subparagraph",
                    "chapter", "part", "textbf", "textit", "texttt", "emph", "underline",
                    "label", "ref", "cite", "bibliography", "bibliographystyle",
                    "includegraphics", "figure", "table", "tabular", "itemize", "enumerate",
                    "item", "caption", "centering", "input", "include",
                    "hspace", "vspace", "newpage", "clearpage", "pagebreak",
                    "frac", "sqrt", "sum", "int", "prod", "lim", "infty",
                    "alpha", "beta", "gamma", "delta", "epsilon", "theta", "lambda", "mu",
                    "pi", "sigma", "omega", "phi", "psi",
                    "left", "right", "big", "Big", "bigg", "Bigg",
                    "text", "mathrm", "mathbf", "mathit", "mathcal", "mathbb",
                    "def", "let", "newenvironment", "renewenvironment",
                    "if", "else", "fi", "ifx", "newif"]
        case "bibtex":
            return ["article", "book", "inproceedings", "conference", "incollection",
                    "inbook", "mastersthesis", "phdthesis", "techreport", "misc",
                    "unpublished", "manual", "proceedings", "booklet"]
        default:
            return []
        }
    }

    // MARK: - Input

    override var acceptsFirstResponder: Bool { true }

    /// Handle ⌘-key shortcuts before the Edit menu intercepts them.
    /// Without this, the menu bar's Copy/Paste/Undo actions (which target
    /// NSResponder selectors like copy:/paste:/undo:) consume the key
    /// equivalents before keyDown is ever called.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              window?.firstResponder === self,
              event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if mods == .command || mods == [.command, .shift] {
            switch event.charactersIgnoringModifiers {
            case "c":
                if let text = selectedText() {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                return true
            case "v":
                if let text = NSPasteboard.general.string(forType: .string) {
                    if buffer.cursors.count > 1 {
                        buffer.insertAtAllCursors(text)
                    } else {
                        buffer.insertAtCursor(text)
                    }
                    notifyLSPDidChange()
                    minimapView?.invalidateCache()
                    editorDidChange()
                }
                return true
            case "x":
                if let text = selectedText() {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    if buffer.cursors.count > 1 {
                        buffer.backspaceAll()
                    } else {
                        buffer.backspace()
                    }
                    notifyLSPDidChange()
                    minimapView?.invalidateCache()
                    editorDidChange()
                }
                return true
            case "z":
                if mods.contains(.shift) { buffer.redo() } else { buffer.undo() }
                notifyLSPDidChange()
                minimapView?.invalidateCache()
                editorDidChange()
                return true
            case "a":
                buffer.cursor.selectionStart = 0
                buffer.cursor.offset = buffer.count
                editorDidChange()
                return true
            case "s":
                try? buffer.save()
                editorDidChange()
                return true
            case "f":
                NotificationCenter.default.post(name: .editorShowFindBar, object: self, userInfo: ["replace": false])
                return true
            case "h":
                NotificationCenter.default.post(name: .editorShowFindBar, object: self, userInfo: ["replace": true])
                return true
            case "g":
                if mods.contains(.shift) {
                    navigateMatch(delta: -1)
                } else {
                    navigateMatch(delta: 1)
                }
                return true
            case "d":
                if mods == .command {
                    addCursorAtNextOccurrence()
                    return true
                }
                return false
            case "b":
                if mods == [.command, .shift] {
                    // ⌘⇧B: Compile LaTeX — forward to EditorPanel
                    if let editorPanel = superview as? EditorPanel ?? findEditorPanel() {
                        editorPanel.compileLaTeX()
                    }
                    return true
                }
                return false
            default:
                break
            }
        }

        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Completion popup key interception
        if completionPopup != nil {
            switch event.keyCode {
            case 126: // Up
                completionPopup?.moveSelection(delta: -1)
                return
            case 125: // Down
                completionPopup?.moveSelection(delta: 1)
                return
            case 36, 48: // Return or Tab — accept completion
                completionPopup?.acceptSelected()
                return
            case 53: // Escape
                dismissCompletion()
                return
            default:
                break
            }
        }

        // Cmd shortcuts
        if mods.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "z":
                if mods.contains(.shift) { buffer.redo() } else { buffer.undo() }
                notifyLSPDidChange()
                minimapView?.invalidateCache()
                editorDidChange()
                return
            case "s":
                try? buffer.save()
                editorDidChange()
                return
            case "a":
                buffer.cursor.selectionStart = 0
                buffer.cursor.offset = buffer.count
                editorDidChange()
                return
            case "f":
                // Open find bar
                NotificationCenter.default.post(name: .editorShowFindBar, object: self, userInfo: ["replace": false])
                return
            case "h":
                // Open find+replace
                NotificationCenter.default.post(name: .editorShowFindBar, object: self, userInfo: ["replace": true])
                return
            case "g":
                // Cmd+G next match, Cmd+Shift+G prev match
                if mods.contains(.shift) {
                    navigateMatch(delta: -1)
                } else {
                    navigateMatch(delta: 1)
                }
                return
            case "c":
                // Cmd+C: copy
                if let text = selectedText() {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                return
            case "v":
                // Cmd+V: paste
                if let text = NSPasteboard.general.string(forType: .string) {
                    if buffer.cursors.count > 1 {
                        buffer.insertAtAllCursors(text)
                    } else {
                        buffer.insertAtCursor(text)
                    }
                    notifyLSPDidChange()
                    minimapView?.invalidateCache()
                    editorDidChange()
                }
                return
            case "x":
                // Cmd+X: cut
                if let text = selectedText() {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    if buffer.cursors.count > 1 {
                        buffer.backspaceAll()
                    } else {
                        buffer.backspace()
                    }
                    notifyLSPDidChange()
                    minimapView?.invalidateCache()
                    editorDidChange()
                }
                return
            case "d":
                // Cmd+D: add cursor at next occurrence of selection
                addCursorAtNextOccurrence()
                return
            default:
                break
            }
        }

        // Escape: collapse multi-cursors or dismiss find bar
        if event.keyCode == 53 {
            if buffer.cursors.count > 1 {
                buffer.collapseCursors()
                editorDidChange()
                return
            }
            dismissFindBar()
            return
        }

        // F12: Go to definition
        if event.keyCode == 111 {
            goToDefinition(line: buffer.cursor.line, column: buffer.cursor.column)
            return
        }

        // Arrow keys
        switch event.keyCode {
        case 123: // Left
            if mods.contains(.shift) && buffer.cursor.selectionStart == nil {
                buffer.cursor.selectionStart = buffer.cursor.offset
            } else if !mods.contains(.shift) {
                buffer.cursor.selectionStart = nil
            }
            if mods.contains(.command) {
                // Cmd+Left: move to beginning of line
                let lineStart = buffer.lineStartOffset(buffer.cursor.line)
                buffer.cursor.offset = lineStart
                buffer.cursor.column = 0
            } else if mods.contains(.option) {
                // Option+Left: move to previous word boundary
                buffer.cursor.offset = findWordBoundary(from: buffer.cursor.offset, direction: .backward)
                let pos = buffer.position(at: buffer.cursor.offset)
                buffer.cursor.line = pos.line
                buffer.cursor.column = pos.column
            } else if buffer.cursor.offset > 0 {
                buffer.cursor.offset -= 1
                let pos = buffer.position(at: buffer.cursor.offset)
                buffer.cursor.line = pos.line
                buffer.cursor.column = pos.column
            }
            dismissCompletion()
            editorDidChange(); return
        case 124: // Right
            if mods.contains(.shift) && buffer.cursor.selectionStart == nil {
                buffer.cursor.selectionStart = buffer.cursor.offset
            } else if !mods.contains(.shift) {
                buffer.cursor.selectionStart = nil
            }
            if mods.contains(.command) {
                // Cmd+Right: move to end of line
                let lineText = buffer.line(buffer.cursor.line)
                let lineStart = buffer.lineStartOffset(buffer.cursor.line)
                buffer.cursor.offset = lineStart + lineText.count
                buffer.cursor.column = lineText.count
            } else if mods.contains(.option) {
                // Option+Right: move to next word boundary
                buffer.cursor.offset = findWordBoundary(from: buffer.cursor.offset, direction: .forward)
                let pos = buffer.position(at: buffer.cursor.offset)
                buffer.cursor.line = pos.line
                buffer.cursor.column = pos.column
            } else if buffer.cursor.offset < buffer.count {
                buffer.cursor.offset += 1
                let pos = buffer.position(at: buffer.cursor.offset)
                buffer.cursor.line = pos.line
                buffer.cursor.column = pos.column
            }
            dismissCompletion()
            editorDidChange(); return
        case 125: // Down
            moveCursorVertically(1, shift: mods.contains(.shift))
            dismissCompletion()
            editorDidChange(); return
        case 126: // Up
            moveCursorVertically(-1, shift: mods.contains(.shift))
            dismissCompletion()
            editorDidChange(); return
        default:
            break
        }

        // Special keys
        switch event.keyCode {
        case 51: // Backspace
            if mods.contains(.command) && buffer.cursors.count == 1 {
                // Cmd+Backspace: delete to beginning of line
                let off = buffer.cursor.offset
                let lineStart = buffer.lineStartOffset(buffer.cursor.line)
                if off > lineStart {
                    buffer.delete(in: lineStart..<off)
                    buffer.cursor.offset = lineStart
                    buffer.cursor.column = 0
                    notifyLSPDidChange()
                    minimapView?.invalidateCache()
                    editorDidChange()
                }
                return
            }
            if mods.contains(.option) && buffer.cursors.count == 1 {
                // Option+Backspace: delete word backward
                let off = buffer.cursor.offset
                let wordStart = findWordBoundary(from: off, direction: .backward)
                if wordStart < off {
                    buffer.delete(in: wordStart..<off)
                    buffer.cursor.offset = wordStart
                    let pos = buffer.position(at: wordStart)
                    buffer.cursor.line = pos.line
                    buffer.cursor.column = pos.column
                    notifyLSPDidChange()
                    minimapView?.invalidateCache()
                    editorDidChange()
                }
                return
            }
            // Auto-delete matching pair if cursor is between them
            if buffer.cursors.count == 1 {
                let off = buffer.cursor.offset
                if off > 0 && off < buffer.count,
                   let prevChar = buffer.character(at: off - 1),
                   let nextChar = buffer.character(at: off) {
                    if let closing = pairMap[prevChar], closing == nextChar {
                        // Delete both characters
                        buffer.replace(in: (off - 1)..<(off + 1), with: "")
                        buffer.cursor.offset = off - 1
                        let pos = buffer.position(at: buffer.cursor.offset)
                        buffer.cursor.line = pos.line
                        buffer.cursor.column = pos.column
                        notifyLSPDidChange()
                        minimapView?.invalidateCache()
                        editorDidChange()
                        return
                    }
                }
            }
            if buffer.cursors.count > 1 {
                buffer.backspaceAll()
            } else {
                buffer.backspace()
            }
            notifyLSPDidChange()
            minimapView?.invalidateCache()
            editorDidChange(); return
        case 117: // Forward Delete
            if mods.contains(.option) && buffer.cursors.count == 1 {
                // Option+Forward Delete: delete word forward
                let off = buffer.cursor.offset
                let wordEnd = findWordBoundary(from: off, direction: .forward)
                if wordEnd > off {
                    buffer.delete(in: off..<wordEnd)
                    notifyLSPDidChange()
                    minimapView?.invalidateCache()
                    editorDidChange()
                }
                return
            }
            if buffer.cursors.count > 1 {
                buffer.forwardDeleteAll()
            } else {
                buffer.forwardDelete()
            }
            notifyLSPDidChange()
            minimapView?.invalidateCache()
            editorDidChange(); return
        case 36: // Return
            if buffer.cursors.count > 1 {
                buffer.insertAtAllCursors("\n")
            } else {
                buffer.insertAtCursor("\n")
            }
            notifyLSPDidChange()
            minimapView?.invalidateCache()
            editorDidChange(); return
        case 48: // Tab
            if buffer.cursors.count > 1 {
                buffer.insertAtAllCursors("    ")
            } else {
                buffer.insertAtCursor("    ")
            }
            notifyLSPDidChange()
            minimapView?.invalidateCache()
            editorDidChange(); return
        default:
            break
        }

        // Regular text input
        if let chars = event.characters, !chars.isEmpty, let firstChar = chars.first, chars.count == 1 {
            // A. Skip-over closing bracket
            if closingChars.contains(firstChar) && buffer.cursors.count == 1 {
                let off = buffer.cursor.offset
                if off < buffer.count,
                   let nextChar = buffer.character(at: off),
                   nextChar == firstChar {
                    buffer.cursor.offset = off + 1
                    let pos = buffer.position(at: buffer.cursor.offset)
                    buffer.cursor.line = pos.line
                    buffer.cursor.column = pos.column
                    notifyLSPDidChange()
                    minimapView?.invalidateCache()
                    triggerCompletion()
                    editorDidChange()
                    return
                }
            }

            // B. Auto-insert closing pair
            if let closing = pairMap[firstChar], buffer.cursors.count == 1 {
                let shouldAutoClose: Bool
                if firstChar == "\"" || firstChar == "'" {
                    // Only auto-close quotes if prev char is not alphanumeric
                    let off = buffer.cursor.offset
                    if off > 0, let prevCh = buffer.character(at: off - 1) {
                        shouldAutoClose = !prevCh.isLetter && !prevCh.isNumber
                    } else {
                        shouldAutoClose = true
                    }
                } else {
                    shouldAutoClose = true
                }

                if shouldAutoClose {
                    buffer.insertAtCursor(String(firstChar) + String(closing))
                    // Position cursor between the pair
                    buffer.cursor.offset -= 1
                    let pos = buffer.position(at: buffer.cursor.offset)
                    buffer.cursor.line = pos.line
                    buffer.cursor.column = pos.column
                    notifyLSPDidChange()
                    minimapView?.invalidateCache()
                    triggerCompletion()
                    editorDidChange()
                    return
                }
            }

            // Default text input
            if buffer.cursors.count > 1 {
                buffer.insertAtAllCursors(chars)
            } else {
                buffer.insertAtCursor(chars)
            }
            notifyLSPDidChange()
            minimapView?.invalidateCache()
            triggerCompletion()
            editorDidChange()
        } else if let chars = event.characters, !chars.isEmpty {
            // Multi-char input (e.g. dead keys)
            if buffer.cursors.count > 1 {
                buffer.insertAtAllCursors(chars)
            } else {
                buffer.insertAtCursor(chars)
            }
            notifyLSPDidChange()
            minimapView?.invalidateCache()
            editorDidChange()
        }
    }

    private func moveCursorVertically(_ delta: Int, shift: Bool) {
        if shift && buffer.cursor.selectionStart == nil {
            buffer.cursor.selectionStart = buffer.cursor.offset
        } else if !shift {
            buffer.cursor.selectionStart = nil
        }

        let targetLine = max(0, min(buffer.lineCount - 1, buffer.cursor.line + delta))
        buffer.cursor.offset = buffer.offset(line: targetLine, column: buffer.cursor.column)
        buffer.cursor.line = targetLine
    }

    // MARK: - Word boundary navigation

    private enum WordDirection { case forward, backward }

    private func findWordBoundary(from offset: Int, direction: WordDirection) -> Int {
        guard buffer.count > 0 else { return offset }

        func isWordChar(_ ch: Character) -> Bool {
            ch.isLetter || ch.isNumber || ch == "_"
        }

        switch direction {
        case .backward:
            guard offset > 0 else { return 0 }
            var pos = offset
            // Skip whitespace/punctuation backward
            while pos > 0 {
                guard let ch = buffer.character(at: pos - 1) else { break }
                if isWordChar(ch) { break }
                pos -= 1
            }
            // Skip word characters backward
            while pos > 0 {
                guard let ch = buffer.character(at: pos - 1) else { break }
                if !isWordChar(ch) { break }
                pos -= 1
            }
            return pos

        case .forward:
            guard offset < buffer.count else { return buffer.count }
            var pos = offset
            // Skip word characters forward
            while pos < buffer.count {
                guard let ch = buffer.character(at: pos) else { break }
                if !isWordChar(ch) { break }
                pos += 1
            }
            // Skip whitespace/punctuation forward
            while pos < buffer.count {
                guard let ch = buffer.character(at: pos) else { break }
                if isWordChar(ch) { break }
                pos += 1
            }
            return pos
        }
    }

    // MARK: - Multi-cursor: add at next occurrence

    private func addCursorAtNextOccurrence() {
        guard let selRange = buffer.cursor.selectionRange else { return }
        let selectedText = buffer.substring(in: selRange)
        guard !selectedText.isEmpty else { return }

        // Search for next occurrence after the last cursor
        let searchStart = buffer.cursors.map { $0.offset }.max() ?? selRange.upperBound
        guard searchStart < buffer.count else { return }

        // Only materialize the substring from searchStart onward
        let searchSubstring = buffer.substring(in: searchStart..<buffer.count)
        let searchStr = searchSubstring as NSString
        let foundRange = searchStr.range(of: selectedText)

        if foundRange.location != NSNotFound {
            var newCursor = TextBuffer.CursorState()
            newCursor.offset = searchStart + foundRange.location + foundRange.length
            newCursor.selectionStart = searchStart + foundRange.location
            let pos = buffer.position(at: newCursor.offset)
            newCursor.line = pos.line
            newCursor.column = pos.column
            buffer.addCursor(newCursor)
            scrollToLine(pos.line)
        }
        editorDidChange()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)

        if event.modifierFlags.contains(.command) {
            // Cmd+Click: go to definition or add cursor
            if event.modifierFlags.contains(.option) {
                // Cmd+Option+Click: add cursor
                let offset = offsetFromPoint(point)
                var newCursor = TextBuffer.CursorState()
                newCursor.offset = offset
                let pos = buffer.position(at: offset)
                newCursor.line = pos.line
                newCursor.column = pos.column
                buffer.addCursor(newCursor)
            } else {
                // Cmd+Click: go to definition
                let firstVisibleLine = max(0, Int(scrollOffset / lineHeight))
                let clickedLine = firstVisibleLine + Int((bounds.height - point.y) / lineHeight)
                let line = max(0, min(buffer.lineCount - 1, clickedLine))
                let xInText = point.x - gutterWidth - textInset + horizontalScrollOffset
                let col = max(0, Int(xInText / charWidth(1)))
                goToDefinition(line: line, column: col)
            }
        } else {
            setCursorFromPoint(point)
            buffer.cursor.selectionStart = nil
            // Collapse multi-cursors on regular click
            if buffer.cursors.count > 1 {
                buffer.collapseCursors()
            }
        }

        dismissCompletion()
        editorDidChange()
    }

    override func mouseDragged(with event: NSEvent) {
        if buffer.cursor.selectionStart == nil {
            buffer.cursor.selectionStart = buffer.cursor.offset
        }
        let point = convert(event.locationInWindow, from: nil)
        setCursorFromPoint(point)
        editorDidChange()
    }

    private func setCursorFromPoint(_ point: NSPoint) {
        let firstVisibleLine = max(0, Int(scrollOffset / lineHeight))
        let clickedLine = firstVisibleLine + Int((bounds.height - point.y) / lineHeight)
        let line = max(0, min(buffer.lineCount - 1, clickedLine))

        let xInText = point.x - gutterWidth - textInset + horizontalScrollOffset
        let charW = charWidth(1)
        let rawCol = max(0, Int(round(xInText / charW)))
        // Clamp to visible text length (exclude trailing newline)
        let lineText = buffer.line(line)
        let displayLen = lineText.hasSuffix("\n") ? lineText.count - 1 : lineText.count
        let col = min(rawCol, displayLen)

        buffer.cursor.line = line
        buffer.cursor.column = col
        buffer.cursor.offset = buffer.offset(line: line, column: col)
    }

    private func offsetFromPoint(_ point: NSPoint) -> Int {
        let firstVisibleLine = max(0, Int(scrollOffset / lineHeight))
        let clickedLine = firstVisibleLine + Int((bounds.height - point.y) / lineHeight)
        let line = max(0, min(buffer.lineCount - 1, clickedLine))
        let xInText = point.x - gutterWidth - textInset + horizontalScrollOffset
        let rawCol = max(0, Int(round(xInText / charWidth(1))))
        let lineText = buffer.line(line)
        let displayLen = lineText.hasSuffix("\n") ? lineText.count - 1 : lineText.count
        let col = min(rawCol, displayLen)
        return buffer.offset(line: line, column: col)
    }

    // MARK: - Mouse hover for diagnostics tooltip

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect], owner: self)
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let firstVisibleLine = max(0, Int(scrollOffset / lineHeight))
        let hoveredLine = firstVisibleLine + Int((bounds.height - point.y) / lineHeight)
        let xInText = point.x - gutterWidth - textInset + horizontalScrollOffset
        let hoveredCol = max(0, Int(xInText / charWidth(1)))

        // Check if hovering over a diagnostic
        var tooltipText: String?
        for diag in diagnostics {
            if diag.startLine == hoveredLine &&
               hoveredCol >= diag.startCharacter && hoveredCol <= diag.endCharacter {
                let prefix = diag.severity == .error ? "Error" : "Warning"
                tooltipText = "\(prefix): \(diag.message)"
                break
            }
        }
        self.toolTip = tooltipText
    }

    override func scrollWheel(with event: NSEvent) {
        scrollOffset -= event.scrollingDeltaY * 3
        let maxScroll = max(0, CGFloat(buffer.lineCount) * lineHeight - bounds.height)
        scrollOffset = max(0, min(scrollOffset, maxScroll))

        // Horizontal scroll
        horizontalScrollOffset -= event.scrollingDeltaX * 3
        let maxHScroll = max(0, maxLineWidth - (bounds.width - gutterWidth - textInset))
        horizontalScrollOffset = max(0, min(horizontalScrollOffset, maxHScroll))

        minimapView?.needsDisplay = true
        showScrollbar()
        needsDisplay = true
    }

    // MARK: - Cursor Blink

    /// Compute a tight rect around the cursor for targeted invalidation.
    private func cursorRectForBlink() -> NSRect {
        let firstVisibleLine = max(0, Int(scrollOffset / lineHeight))
        let cursorLine = buffer.cursor.line
        guard cursorLine >= firstVisibleLine && cursorLine < firstVisibleLine + Int(bounds.height / lineHeight) + 2 else {
            return .zero
        }
        let cursorX = textX(buffer.cursor.column)
        let cursorY = bounds.height - CGFloat(cursorLine - firstVisibleLine + 1) * lineHeight
        // Include some padding around the cursor beam
        return NSRect(x: cursorX - 2, y: cursorY, width: 6, height: lineHeight)
    }

    private func setupCursorBlink() {
        cursorTimer?.invalidate()
        cursorTimer = nil
        guard ClomeSettings.shared.cursorBlink else {
            cursorVisible = true
            return
        }
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.cursorVisible.toggle()
                // Only dirty the cursor rect instead of the entire view.
                // This avoids re-running syntax highlighting on every blink.
                let cursorRect = self.cursorRectForBlink()
                if cursorRect != .zero {
                    self.setNeedsDisplay(cursorRect)
                } else {
                    self.needsDisplay = true
                }
            }
        }
    }

    @objc private func settingsDidChange() {
        let settings = ClomeSettings.shared
        font = settings.resolvedFont
        boldFont = settings.resolvedBoldFont
        lineHeight = settings.resolvedLineHeight
        let sample = "M" as NSString
        cachedCharWidth = sample.size(withAttributes: [.font: font]).width
        // No layer?.backgroundColor — draw() handles the background fill.
        setupCursorBlink()
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        cursorVisible = true
        needsDisplay = true
        return super.becomeFirstResponder()
    }
}

// MARK: - LSPClientDelegate

extension EditorView: LSPClientDelegate {
    func lspClient(_ client: LSPClient, didReceiveDiagnostics params: [String: Any]) {
        guard let diagnosticsArray = params["diagnostics"] as? [[String: Any]] else { return }

        diagnostics = diagnosticsArray.compactMap { dict -> LSPDiagnostic? in
            guard let range = dict["range"] as? [String: Any],
                  let start = range["start"] as? [String: Any],
                  let end = range["end"] as? [String: Any],
                  let startLine = start["line"] as? Int,
                  let startChar = start["character"] as? Int,
                  let endLine = end["line"] as? Int,
                  let endChar = end["character"] as? Int,
                  let message = dict["message"] as? String else { return nil }

            let severityRaw = dict["severity"] as? Int ?? 1
            let severity = DiagnosticSeverity(rawValue: severityRaw) ?? .error
            let source = dict["source"] as? String

            return LSPDiagnostic(
                severity: severity,
                startLine: startLine,
                startCharacter: startChar,
                endLine: endLine,
                endCharacter: endChar,
                message: message,
                source: source
            )
        }
        needsDisplay = true
    }

    func lspClient(_ client: LSPClient, didLog message: String) {
        NSLog("LSP[\(client.language)]: \(message)")
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let editorShowFindBar = Notification.Name("editorShowFindBar")
    static let editorDismissFindBar = Notification.Name("editorDismissFindBar")
    static let editorCursorChanged = Notification.Name("editorCursorChanged")
    static let bufferDirtyStateChanged = Notification.Name("bufferDirtyStateChanged")
}
