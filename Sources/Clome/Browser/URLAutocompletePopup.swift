import AppKit

/// A single autocomplete suggestion for the URL bar.
struct URLSuggestion {
    let title: String
    let url: String
    let isBookmark: Bool
}

/// A floating popup below the URL bar showing autocomplete suggestions
/// from history and bookmarks, styled to match the Clome dark theme.
@MainActor
final class URLAutocompletePopup: NSObject {

    private(set) var suggestions: [URLSuggestion] = []
    private(set) var selectedIndex: Int = -1

    var onSelect: ((URLSuggestion) -> Void)?

    private var panel: NSPanel?
    private var tableView: NSTableView?
    private var scrollView: NSScrollView?

    private let rowHeight: CGFloat = 36
    private let maxVisible: Int = 7

    var popupHeight: CGFloat {
        min(CGFloat(suggestions.count), CGFloat(maxVisible)) * rowHeight + 4
    }

    func update(suggestions: [URLSuggestion]) {
        self.suggestions = suggestions
        self.selectedIndex = -1
        tableView?.reloadData()
    }

    func showBelow(view: NSView, in parentWindow: NSWindow) {
        let viewFrameInWindow = view.convert(view.bounds, to: nil)
        let viewFrameOnScreen = parentWindow.convertToScreen(viewFrameInWindow)
        let width = viewFrameOnScreen.width
        let height = popupHeight
        let origin = NSPoint(x: viewFrameOnScreen.origin.x, y: viewFrameOnScreen.origin.y - height)
        let frame = NSRect(x: origin.x, y: origin.y, width: width, height: height)

        if let panel = panel {
            panel.setFrame(frame, display: true)
            tableView?.reloadData()
            return
        }

        // Create panel
        let p = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = true
        p.becomesKeyOnlyIfNeeded = true

        // Container with rounded corners
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 0.98).cgColor
        container.layer?.cornerRadius = 10
        container.layer?.cornerCurve = .continuous
        container.layer?.borderColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        container.layer?.borderWidth = 0.5
        container.autoresizingMask = [.width, .height]

        // Table view
        let tv = NSTableView()
        tv.backgroundColor = .clear
        tv.headerView = nil
        tv.rowHeight = rowHeight
        tv.intercellSpacing = NSSize(width: 0, height: 0)
        tv.selectionHighlightStyle = .none
        tv.delegate = self
        tv.dataSource = self
        tv.action = #selector(rowClicked(_:))
        tv.target = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("suggestion"))
        column.width = frame.width
        tv.addTableColumn(column)

        let sv = NSScrollView(frame: NSRect(x: 0, y: 2, width: frame.width, height: frame.height - 4))
        sv.documentView = tv
        sv.drawsBackground = false
        sv.hasVerticalScroller = false
        sv.autoresizingMask = [.width, .height]
        container.addSubview(sv)

        p.contentView = container
        self.panel = p
        self.tableView = tv
        self.scrollView = sv

        parentWindow.addChildWindow(p, ordered: .above)
    }

    func dismiss() {
        if let p = panel {
            p.parent?.removeChildWindow(p)
            p.orderOut(nil)
        }
        panel = nil
        tableView = nil
        scrollView = nil
    }

    func moveSelection(down: Bool) {
        guard !suggestions.isEmpty else { return }
        if down {
            selectedIndex = selectedIndex < suggestions.count - 1 ? selectedIndex + 1 : 0
        } else {
            selectedIndex = selectedIndex > 0 ? selectedIndex - 1 : suggestions.count - 1
        }
        tableView?.reloadData()
        if selectedIndex >= 0 {
            tableView?.scrollRowToVisible(selectedIndex)
        }
    }

    @objc private func rowClicked(_ sender: Any?) {
        guard let tv = tableView else { return }
        let row = tv.clickedRow
        guard row >= 0, row < suggestions.count else { return }
        onSelect?(suggestions[row])
    }
}

// MARK: - NSTableViewDataSource & NSTableViewDelegate

extension URLAutocompletePopup: NSTableViewDataSource, NSTableViewDelegate {

    nonisolated func numberOfRows(in tableView: NSTableView) -> Int {
        MainActor.assumeIsolated { suggestions.count }
    }

    nonisolated func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        MainActor.assumeIsolated {
            guard row < suggestions.count else { return nil }
            let suggestion = suggestions[row]
            let isSelected = row == selectedIndex

            let cellView = NSView(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: rowHeight))
            cellView.wantsLayer = true
            cellView.layer?.cornerRadius = 6
            cellView.layer?.backgroundColor = isSelected
                ? NSColor(white: 1.0, alpha: 0.08).cgColor
                : NSColor.clear.cgColor

            // Icon
            let iconView = NSImageView(frame: NSRect(x: 10, y: 10, width: 16, height: 16))
            let symbolName = suggestion.isBookmark ? "star.fill" : "clock"
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            iconView.contentTintColor = suggestion.isBookmark
                ? NSColor.systemYellow.withAlphaComponent(0.7)
                : NSColor(white: 0.4, alpha: 1.0)
            cellView.addSubview(iconView)

            // Title
            let displayTitle = suggestion.title.isEmpty ? suggestion.url : suggestion.title
            let titleLabel = NSTextField(labelWithString: displayTitle)
            titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
            titleLabel.textColor = NSColor(white: 0.85, alpha: 1.0)
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.frame = NSRect(x: 34, y: 18, width: tableView.bounds.width - 48, height: 16)
            cellView.addSubview(titleLabel)

            // URL
            let cleanedURL = cleanURL(suggestion.url)
            let urlLabel = NSTextField(labelWithString: cleanedURL)
            urlLabel.font = .systemFont(ofSize: 10, weight: .regular)
            urlLabel.textColor = NSColor(white: 0.4, alpha: 1.0)
            urlLabel.lineBreakMode = .byTruncatingTail
            urlLabel.frame = NSRect(x: 34, y: 3, width: tableView.bounds.width - 48, height: 14)
            cellView.addSubview(urlLabel)

            return cellView
        }
    }

    nonisolated func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        MainActor.assumeIsolated { rowHeight }
    }

    private func cleanURL(_ url: String) -> String {
        var cleaned = url
        if cleaned.hasPrefix("https://") { cleaned = String(cleaned.dropFirst(8)) }
        else if cleaned.hasPrefix("http://") { cleaned = String(cleaned.dropFirst(7)) }
        if cleaned.hasPrefix("www.") { cleaned = String(cleaned.dropFirst(4)) }
        if cleaned.hasSuffix("/") { cleaned = String(cleaned.dropLast()) }
        return cleaned
    }
}
