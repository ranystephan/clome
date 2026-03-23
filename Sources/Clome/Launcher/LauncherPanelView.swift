import AppKit

/// The floating launcher panel containing search, results, and action bar.
@MainActor
class LauncherPanelView: NSView, LauncherSearchFieldDelegate, LauncherResultsDelegate {

    let searchField = LauncherSearchField()
    let resultsView = LauncherResultsView()
    let actionBar = LauncherActionBar()

    /// All registered providers.
    private var providers: [LauncherProvider] = []

    /// Called when the user activates an item (primary action).
    var onItemActivated: ((LauncherItem) -> Void)?

    /// Called when the user presses Escape.
    var onDismiss: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.085, alpha: 0.96).cgColor
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        layer?.borderWidth = 0.5

        // Separator between search and results
        let topSeparator = NSView()
        topSeparator.translatesAutoresizingMaskIntoConstraints = false
        topSeparator.wantsLayer = true
        topSeparator.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor

        // Separator between results and action bar
        let bottomSeparator = NSView()
        bottomSeparator.translatesAutoresizingMaskIntoConstraints = false
        bottomSeparator.wantsLayer = true
        bottomSeparator.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.searchDelegate = self

        resultsView.translatesAutoresizingMaskIntoConstraints = false
        resultsView.resultsDelegate = self

        actionBar.translatesAutoresizingMaskIntoConstraints = false
        actionBar.onActionExecuted = { [weak self] in
            self?.onDismiss?()
        }

        addSubview(searchField)
        addSubview(topSeparator)
        addSubview(resultsView)
        addSubview(bottomSeparator)
        addSubview(actionBar)

        NSLayoutConstraint.activate([
            // Panel sizing
            widthAnchor.constraint(equalToConstant: 640),
            heightAnchor.constraint(equalToConstant: 460),

            // Search field at top
            searchField.topAnchor.constraint(equalTo: topAnchor),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor),

            // Top separator (inset 12px each side)
            topSeparator.topAnchor.constraint(equalTo: searchField.bottomAnchor),
            topSeparator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            topSeparator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            topSeparator.heightAnchor.constraint(equalToConstant: 1),

            // Results
            resultsView.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            resultsView.leadingAnchor.constraint(equalTo: leadingAnchor),
            resultsView.trailingAnchor.constraint(equalTo: trailingAnchor),
            resultsView.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),

            // Bottom separator (inset 12px each side)
            bottomSeparator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            bottomSeparator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            bottomSeparator.heightAnchor.constraint(equalToConstant: 1),
            bottomSeparator.bottomAnchor.constraint(equalTo: actionBar.topAnchor),

            // Action bar at bottom
            actionBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionBar.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Provider Management

    func registerProvider(_ provider: LauncherProvider) {
        providers.append(provider)
    }

    func refreshResults() {
        let mode = searchField.activeMode
        let query = searchField.queryText

        let activeProviders: [LauncherProvider]
        switch mode {
        case .all: activeProviders = providers
        case .commands: activeProviders = providers.filter { $0.sectionTitle == "Commands" }
        case .sessions: activeProviders = providers.filter { $0.sectionTitle == "Sessions" }
        case .files: activeProviders = providers.filter { $0.sectionTitle == "Files" }
        case .terminals: activeProviders = providers.filter { $0.sectionTitle == "Terminals" }
        }

        var sections: [(title: String, items: [LauncherItem])] = []

        // Collect all items, separate attention items
        var attentionItems: [LauncherItem] = []
        var normalSections: [(title: String, items: [LauncherItem])] = []

        for provider in activeProviders {
            let items = provider.search(query: query)
            let attention = items.filter { $0.priority >= 1000 }
            let normal = items.filter { $0.priority < 1000 }
            attentionItems.append(contentsOf: attention)
            if !normal.isEmpty {
                normalSections.append((provider.sectionTitle, normal))
            }
        }

        // Attention items always come first
        if !attentionItems.isEmpty {
            attentionItems.sort { $0.priority > $1.priority }
            sections.append(("Needs Attention", attentionItems))
        }

        sections.append(contentsOf: normalSections)

        resultsView.updateResults(sections, query: query)

        // Update action bar for selected item
        if let selected = resultsView.selectedItem {
            updateActionsForItem(selected)
        }
    }

    private func updateActionsForItem(_ item: LauncherItem) {
        for provider in providers {
            let actions = provider.actions(for: item)
            if !actions.isEmpty {
                actionBar.updateActions(actions)
                return
            }
        }
        actionBar.updateActions([])
    }

    // MARK: - LauncherSearchFieldDelegate

    func searchFieldDidChange(_ text: String) {
        actionBar.collapse()
        refreshResults()
    }

    func searchFieldDidPressArrowDown() {
        resultsView.moveSelectionDown()
    }

    func searchFieldDidPressArrowUp() {
        resultsView.moveSelectionUp()
    }

    func searchFieldDidPressEnter() {
        resultsView.activateSelection()
    }

    func searchFieldDidPressTab() {
        actionBar.toggleExpanded()
    }

    func searchFieldDidPressEscape() {
        if actionBar.isExpanded {
            actionBar.collapse()
        } else {
            onDismiss?()
        }
    }

    // MARK: - LauncherResultsDelegate

    func resultsView(_ view: LauncherResultsView, didSelectItem item: LauncherItem) {
        updateActionsForItem(item)
    }

    func resultsView(_ view: LauncherResultsView, didActivateItem item: LauncherItem) {
        onItemActivated?(item)
    }
}
