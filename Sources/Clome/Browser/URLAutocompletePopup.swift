import AppKit

enum URLSuggestionKind {
    case directNavigation
    case search
    case bookmark
    case history

    var symbolName: String {
        switch self {
        case .directNavigation: return "arrow.up.forward"
        case .search: return "magnifyingglass"
        case .bookmark: return "star.fill"
        case .history: return "clock"
        }
    }

    var badgeText: String {
        switch self {
        case .directNavigation: return "Open"
        case .search: return "Search"
        case .bookmark: return "Saved"
        case .history: return "Recent"
        }
    }

    var tintColor: NSColor {
        switch self {
        case .directNavigation: return NSColor.systemBlue.withAlphaComponent(0.82)
        case .search: return NSColor.white.withAlphaComponent(0.72)
        case .bookmark: return NSColor.systemYellow.withAlphaComponent(0.86)
        case .history: return NSColor.white.withAlphaComponent(0.42)
        }
    }
}

/// A single autocomplete suggestion for the URL bar.
struct URLSuggestion {
    let title: String
    let subtitle: String
    let value: String
    let kind: URLSuggestionKind
}

/// A floating popup below the URL bar showing local navigation suggestions.
@MainActor
final class URLAutocompletePopup: NSObject {

    private(set) var suggestions: [URLSuggestion] = []
    private(set) var selectedIndex: Int = -1

    var onSelect: ((URLSuggestion) -> Void)?

    private var panel: NSPanel?
    private var tableView: NSTableView?

    private let rowHeight: CGFloat = 52
    private let maxVisible = 8

    var popupHeight: CGFloat {
        min(CGFloat(suggestions.count), CGFloat(maxVisible)) * rowHeight + 12
    }

    func update(suggestions: [URLSuggestion]) {
        self.suggestions = suggestions
        self.selectedIndex = suggestions.isEmpty ? -1 : 0
        tableView?.reloadData()
    }

    func showBelow(view: NSView, in parentWindow: NSWindow) {
        let viewFrameInWindow = view.convert(view.bounds, to: nil)
        let viewFrameOnScreen = parentWindow.convertToScreen(viewFrameInWindow)
        let width = viewFrameOnScreen.width
        let height = popupHeight
        let frame = NSRect(
            x: viewFrameOnScreen.origin.x,
            y: viewFrameOnScreen.origin.y - height - 6,
            width: width,
            height: height
        )

        if let panel {
            panel.setFrame(frame, display: true)
            tableView?.reloadData()
            return
        }

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true

        let container = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        container.material = .hudWindow
        container.blendingMode = .withinWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 16
        container.layer?.cornerCurve = .continuous
        container.layer?.borderColor = NSColor(white: 1.0, alpha: 0.10).cgColor
        container.layer?.borderWidth = 1
        container.autoresizingMask = [.width, .height]

        let tableView = NSTableView()
        tableView.backgroundColor = .clear
        tableView.headerView = nil
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.focusRingType = .none
        tableView.delegate = self
        tableView.dataSource = self
        tableView.action = #selector(rowClicked(_:))
        tableView.target = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("suggestion"))
        column.width = frame.width
        tableView.addTableColumn(column)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 6, width: frame.width, height: frame.height - 12))
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)

        panel.contentView = container
        self.panel = panel
        self.tableView = tableView

        parentWindow.addChildWindow(panel, ordered: .above)
    }

    func dismiss() {
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        tableView = nil
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
        guard let tableView else { return }
        let row = tableView.clickedRow
        guard row >= 0, row < suggestions.count else { return }
        onSelect?(suggestions[row])
    }
}

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
            cellView.layer?.cornerRadius = 12
            cellView.layer?.cornerCurve = .continuous
            cellView.layer?.backgroundColor = isSelected
                ? NSColor.white.withAlphaComponent(0.09).cgColor
                : NSColor.clear.cgColor

            let iconContainer = NSView(frame: NSRect(x: 12, y: 9, width: 34, height: 34))
            iconContainer.wantsLayer = true
            iconContainer.layer?.cornerRadius = 10
            iconContainer.layer?.cornerCurve = .continuous
            iconContainer.layer?.backgroundColor = suggestion.kind.tintColor.withAlphaComponent(0.16).cgColor
            cellView.addSubview(iconContainer)

            let iconView = NSImageView(frame: NSRect(x: 9, y: 9, width: 16, height: 16))
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            iconView.image = NSImage(systemSymbolName: suggestion.kind.symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            iconView.contentTintColor = suggestion.kind.tintColor
            iconContainer.addSubview(iconView)

            let titleLabel = NSTextField(labelWithString: suggestion.title)
            titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            titleLabel.textColor = NSColor.white.withAlphaComponent(0.92)
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.frame = NSRect(x: 56, y: 25, width: tableView.bounds.width - 138, height: 16)
            cellView.addSubview(titleLabel)

            let subtitleLabel = NSTextField(labelWithString: suggestion.subtitle)
            subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
            subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.42)
            subtitleLabel.lineBreakMode = .byTruncatingTail
            subtitleLabel.frame = NSRect(x: 56, y: 10, width: tableView.bounds.width - 138, height: 14)
            cellView.addSubview(subtitleLabel)

            let badgeLabel = NSTextField(labelWithString: suggestion.kind.badgeText.uppercased())
            badgeLabel.font = .systemFont(ofSize: 9, weight: .semibold)
            badgeLabel.alignment = .center
            badgeLabel.textColor = isSelected
                ? NSColor.white.withAlphaComponent(0.85)
                : NSColor.white.withAlphaComponent(0.52)
            badgeLabel.frame = NSRect(x: tableView.bounds.width - 72, y: 18, width: 56, height: 14)
            badgeLabel.wantsLayer = true
            badgeLabel.layer?.cornerRadius = 7
            badgeLabel.layer?.cornerCurve = .continuous
            badgeLabel.layer?.backgroundColor = isSelected
                ? NSColor.white.withAlphaComponent(0.13).cgColor
                : NSColor.white.withAlphaComponent(0.06).cgColor
            cellView.addSubview(badgeLabel)

            return cellView
        }
    }

    nonisolated func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        MainActor.assumeIsolated { rowHeight }
    }
}
