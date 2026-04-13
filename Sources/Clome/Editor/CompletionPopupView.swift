import AppKit

/// A completion item from the LSP server.
struct CompletionItem {
    let label: String
    let kind: Int       // LSP CompletionItemKind
    let detail: String?
    let insertText: String?
    let filterText: String?

    /// Parse from LSP JSON response
    static func fromLSP(_ dict: [String: Any]) -> CompletionItem {
        CompletionItem(
            label: dict["label"] as? String ?? "",
            kind: dict["kind"] as? Int ?? 1,
            detail: dict["detail"] as? String,
            insertText: dict["insertText"] as? String,
            filterText: dict["filterText"] as? String
        )
    }

    /// SF Symbol name for the completion item kind
    var iconName: String {
        switch kind {
        case 2:  return "m.square"          // Method
        case 3:  return "f.square"          // Function
        case 4:  return "wrench"            // Constructor
        case 5:  return "cube"              // Field
        case 6:  return "v.square"          // Variable
        case 7:  return "c.square"          // Class
        case 8:  return "i.square"          // Interface
        case 9:  return "shippingbox"       // Module
        case 10: return "p.square"          // Property
        case 13: return "e.square"          // Enum
        case 14: return "key"              // Keyword
        case 15: return "text.snippet"     // Snippet
        case 22: return "s.square"          // Struct
        default: return "textformat"       // Text / other
        }
    }

    var iconColor: NSColor {
        switch kind {
        case 2, 3:     return NSColor(red: 0.40, green: 0.73, blue: 0.42, alpha: 1.0) // Function - green
        case 5, 6, 10: return NSColor(red: 0.47, green: 0.75, blue: 0.87, alpha: 1.0) // Variable - cyan
        case 7, 8, 22: return NSColor(red: 0.82, green: 0.77, blue: 0.50, alpha: 1.0) // Type - yellow
        case 13:       return NSColor(red: 0.87, green: 0.56, blue: 0.40, alpha: 1.0) // Enum - orange
        case 14:       return NSColor(red: 0.78, green: 0.46, blue: 0.83, alpha: 1.0) // Keyword - purple
        default:       return NSColor(white: 0.6, alpha: 1.0)
        }
    }

    var textToInsert: String {
        insertText ?? label
    }
}

/// Popup view that displays LSP completion suggestions.
class CompletionPopupView: NSView {
    private var items: [CompletionItem] = []
    private var filteredItems: [CompletionItem] = []
    private(set) var selectedIndex: Int = 0
    private let rowHeight: CGFloat = 22
    private let maxVisibleRows: Int = 10
    private var scrollOffset: Int = 0

    var onAccept: ((CompletionItem) -> Void)?
    var onDismiss: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = ClomeMacColor.elevatedSurface.withAlphaComponent(0.98).cgColor
        layer?.borderColor = ClomeMacColor.border.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 4
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.5
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -4)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = ClomeMacColor.elevatedSurface.withAlphaComponent(0.98).cgColor
            self.layer?.borderColor = ClomeMacColor.border.cgColor
        }
    }

    func update(items: [CompletionItem], filter: String) {
        self.items = items
        if filter.isEmpty {
            filteredItems = items
        } else {
            let lower = filter.lowercased()
            var scored: [(item: CompletionItem, score: Int)] = []
            for item in items {
                let text = (item.filterText ?? item.label).lowercased()
                let score = fuzzyScore(text: text, filter: lower)
                if score > 0 {
                    scored.append((item, score))
                }
            }
            scored.sort { $0.score > $1.score }
            filteredItems = scored.map { $0.item }
        }
        selectedIndex = 0
        scrollOffset = 0
        updateFrame()
        needsDisplay = true
    }

    private func fuzzyScore(text: String, filter: String) -> Int {
        // Exact prefix
        if text.hasPrefix(filter) { return 1000 }
        // Case-insensitive prefix
        if text.lowercased().hasPrefix(filter.lowercased()) { return 800 }
        // Substring
        if text.contains(filter) { return 500 }
        // Fuzzy: chars in order with consecutive bonus
        var score = 0
        var filterIdx = filter.startIndex
        var consecutive = 0
        for ch in text {
            if filterIdx < filter.endIndex && ch == filter[filterIdx] {
                score += 10 + consecutive * 5
                consecutive += 1
                filterIdx = filter.index(after: filterIdx)
            } else {
                consecutive = 0
            }
        }
        return filterIdx == filter.endIndex ? 100 + score : 0
    }

    var isEmpty: Bool { filteredItems.isEmpty }

    private func updateFrame() {
        let rows = min(filteredItems.count, maxVisibleRows)
        let width: CGFloat = 300
        let height = CGFloat(rows) * rowHeight + 4
        setFrameSize(NSSize(width: width, height: height))
    }

    func moveSelection(delta: Int) {
        guard !filteredItems.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + filteredItems.count) % filteredItems.count
        // Scroll to keep selection visible
        if selectedIndex < scrollOffset {
            scrollOffset = selectedIndex
        } else if selectedIndex >= scrollOffset + maxVisibleRows {
            scrollOffset = selectedIndex - maxVisibleRows + 1
        }
        needsDisplay = true
    }

    func acceptSelected() {
        guard selectedIndex >= 0, selectedIndex < filteredItems.count else { return }
        onAccept?(filteredItems[selectedIndex])
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Background
        context.setFillColor(ClomeMacColor.elevatedSurface.withAlphaComponent(0.98).cgColor)
        let bgPath = CGPath(roundedRect: bounds, cornerWidth: 4, cornerHeight: 4, transform: nil)
        context.addPath(bgPath)
        context.fillPath()

        let visibleRange = scrollOffset..<min(scrollOffset + maxVisibleRows, filteredItems.count)

        for (drawIdx, itemIdx) in visibleRange.enumerated() {
            let item = filteredItems[itemIdx]
            let y = bounds.height - CGFloat(drawIdx + 1) * rowHeight - 2

            // Selection highlight
            if itemIdx == selectedIndex {
                context.setFillColor(ClomeMacColor.accent.withAlphaComponent(0.3).cgColor)
                context.fill(CGRect(x: 2, y: y, width: bounds.width - 4, height: rowHeight))
            }

            // Icon
            let iconRect = CGRect(x: 6, y: y + 3, width: 16, height: 16)
            if let iconImage = NSImage(systemSymbolName: item.iconName, accessibilityDescription: nil) {
                let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
                if let configured = iconImage.withSymbolConfiguration(cfg) {
                    NSGraphicsContext.saveGraphicsState()
                    item.iconColor.set()
                    configured.draw(in: iconRect)
                    NSGraphicsContext.restoreGraphicsState()
                }
            }

            // Label
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: ClomeMacColor.textPrimary
            ]
            let labelStr = item.label as NSString
            labelStr.draw(at: NSPoint(x: 26, y: y + (rowHeight - 14) / 2), withAttributes: labelAttrs)

            // Detail
            if let detail = item.detail {
                let detailAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: ClomeMacColor.textTertiary
                ]
                let detailStr = detail as NSString
                let labelWidth = labelStr.size(withAttributes: labelAttrs).width
                let maxDetailX = bounds.width - 10
                let detailX = min(26 + labelWidth + 12, maxDetailX - 100)
                if detailX > 26 + labelWidth + 4 {
                    detailStr.draw(at: NSPoint(x: detailX, y: y + (rowHeight - 12) / 2), withAttributes: detailAttrs)
                }
            }
        }
    }
}
