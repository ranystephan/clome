import AppKit

/// A minimap view showing a scaled-down overview of the entire file.
/// Displays colored rectangles representing syntax-highlighted tokens.
/// Click or drag to navigate to any position in the file.
class MinimapView: NSView {
    weak var editorView: EditorView?

    private let minimapWidth: CGFloat = 80
    private var lineHeightScale: CGFloat = 2.0
    private var cachedImage: NSImage?
    private var needsRedraw: Bool = true

    // Viewport indicator
    private var viewportRect: NSRect = .zero

    // Dragging state
    private var isDragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: minimapWidth, height: NSView.noIntrinsicMetric)
    }

    func invalidateCache() {
        needsRedraw = true
        cachedImage = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let editor = editorView else { return }

        // Hide minimap for very large files
        if editor.isVeryLargeFile {
            isHidden = true
            return
        }

        // Subtle darkened overlay behind minimap content (no opaque background)
        context.setFillColor(NSColor(white: 0.0, alpha: 0.25).cgColor)
        context.fill(bounds)

        let totalLines = editor.buffer.lineCount
        guard totalLines > 0 else { return }

        // Adaptive line height: shrink for very long files
        if totalLines > 5000 {
            lineHeightScale = 1.0
        } else if totalLines > 2000 {
            lineHeightScale = 1.5
        } else {
            lineHeightScale = 2.0
        }

        let totalMapHeight = CGFloat(totalLines) * lineHeightScale
        let scale: CGFloat = totalMapHeight > bounds.height ? bounds.height / totalMapHeight : 1.0

        // Draw lines as colored rectangles
        if needsRedraw || cachedImage == nil {
            cachedImage = renderMinimap(editor: editor, totalLines: totalLines, scale: scale)
            needsRedraw = false
        }

        if let img = cachedImage {
            img.draw(in: bounds)
        }

        // Viewport indicator
        let editorVisibleLines = editor.visibleLines
        let viewportTop = CGFloat(editorVisibleLines.lowerBound) * lineHeightScale * scale
        let viewportHeight = CGFloat(editorVisibleLines.count) * lineHeightScale * scale
        let viewportY = bounds.height - viewportTop - viewportHeight

        viewportRect = CGRect(x: 0, y: viewportY, width: bounds.width, height: viewportHeight)

        context.setFillColor(NSColor(white: 1.0, alpha: 0.1).cgColor)
        context.fill(viewportRect)
        context.setStrokeColor(NSColor(white: 1.0, alpha: 0.2).cgColor)
        context.setLineWidth(1)
        context.stroke(viewportRect)

        // Left border
        context.setStrokeColor(NSColor(white: 1.0, alpha: 0.06).cgColor)
        context.move(to: CGPoint(x: 0, y: 0))
        context.addLine(to: CGPoint(x: 0, y: bounds.height))
        context.strokePath()
    }

    /// Maximum lines to render in the minimap bitmap. Beyond this, we sample lines.
    private static let maxRenderedLines = 3000

    /// Maximum cached image memory (~4 MB cap at 2x scale for 80px wide minimap).
    private static let maxCachedImageBytes = 4 * 1024 * 1024

    private func renderMinimap(editor: EditorView, totalLines: Int, scale: CGFloat) -> NSImage {
        let size = bounds.size
        guard size.width > 0 && size.height > 0 else {
            return NSImage(size: NSSize(width: 1, height: 1))
        }

        // Cap image dimensions to prevent excessive memory usage.
        // An 80x2000 image at 2x = 640KB; 80x8000 at 2x = 2.5MB.
        let maxHeight: CGFloat = 4000
        let clampedSize = NSSize(width: size.width, height: min(size.height, maxHeight))

        let image = NSImage(size: clampedSize)
        image.lockFocus()

        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        let charWidth: CGFloat = 1.2
        let scaledLineHeight = lineHeightScale * scale

        // Syntax colors for minimap blocks
        let keywordColor = NSColor(red: 0.78, green: 0.46, blue: 0.83, alpha: 0.7)
        let stringColor = NSColor(red: 0.87, green: 0.56, blue: 0.40, alpha: 0.7)
        let commentColor = NSColor(white: 0.35, alpha: 0.7)
        let defaultColor = NSColor(white: 0.5, alpha: 0.4)

        // For very large files, sample every Nth line instead of rendering all
        let stride: Int
        if totalLines > MinimapView.maxRenderedLines {
            stride = max(1, totalLines / MinimapView.maxRenderedLines)
        } else {
            stride = 1
        }

        var lineIdx = 0
        while lineIdx < totalLines {
            let y = clampedSize.height - CGFloat(lineIdx + 1) * scaledLineHeight

            // Skip lines that are off-screen
            if y < -scaledLineHeight {
                break
            }
            if y > clampedSize.height {
                lineIdx += stride
                continue
            }

            let lineText = editor.buffer.line(lineIdx)
            let trimmed = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                lineIdx += stride
                continue
            }

            // Simple heuristic coloring for minimap
            let color: NSColor
            let stripped = trimmed
            if stripped.hasPrefix("//") || stripped.hasPrefix("#") || stripped.hasPrefix("/*") {
                color = commentColor
            } else if stripped.contains("\"") || stripped.contains("'") {
                color = stringColor
            } else if isKeywordLine(stripped, language: editor.buffer.language) {
                color = keywordColor
            } else {
                color = defaultColor
            }

            // Count leading spaces for indent
            let indent = lineText.prefix(while: { $0 == " " || $0 == "\t" }).count
            let textLen = trimmed.count

            let x = CGFloat(indent) * charWidth + 4
            let width = min(CGFloat(textLen) * charWidth, clampedSize.width - x - 4)
            let blockHeight = max(scaledLineHeight * CGFloat(stride) - 0.5, 1)

            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: x, y: y, width: max(width, 2), height: blockHeight))

            lineIdx += stride
        }

        image.unlockFocus()
        return image
    }

    private func isKeywordLine(_ text: String, language: String?) -> Bool {
        let commonKeywords = ["func ", "fn ", "def ", "class ", "struct ", "enum ", "import ", "return ",
                              "if ", "else ", "for ", "while ", "let ", "var ", "const ", "pub "]
        return commonKeywords.contains(where: { text.hasPrefix($0) })
    }

    // MARK: - Mouse interaction

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        scrollToClick(event)
    }

    override func mouseDragged(with event: NSEvent) {
        if isDragging {
            scrollToClick(event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }

    private func scrollToClick(_ event: NSEvent) {
        guard let editor = editorView else { return }
        let point = convert(event.locationInWindow, from: nil)
        let totalLines = editor.buffer.lineCount
        guard totalLines > 0 else { return }

        let totalMapHeight = CGFloat(totalLines) * lineHeightScale
        let scale: CGFloat = totalMapHeight > bounds.height ? bounds.height / totalMapHeight : 1.0
        let clickedLine = Int((bounds.height - point.y) / (lineHeightScale * scale))
        let targetLine = max(0, min(totalLines - 1, clickedLine))
        editor.scrollToLine(targetLine)
    }
}
