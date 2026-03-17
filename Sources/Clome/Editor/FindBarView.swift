import AppKit

/// Find and replace bar overlay for the editor.
/// Supports plain text and regex search, case sensitivity toggle, and replace.
class FindBarView: NSView {
    weak var editorView: EditorView?

    private var searchField: NSTextField!
    private var replaceField: NSTextField!
    private var matchCountLabel: NSTextField!
    private var prevButton: NSButton!
    private var nextButton: NSButton!
    private var caseButton: NSButton!
    private var regexButton: NSButton!
    private var replaceButton: NSButton!
    private var replaceAllButton: NSButton!
    private var closeButton: NSButton!
    private var replaceToggleButton: NSButton!

    private var replaceFieldConstraint: NSLayoutConstraint?
    private var collapsedHeightConstraint: NSLayoutConstraint?
    private var expandedHeightConstraint: NSLayoutConstraint?

    var showReplace: Bool = false {
        didSet { updateReplaceVisibility() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 0.95).cgColor
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        layer?.borderWidth = 1
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false

        // Close button
        closeButton = makeButton(symbol: "xmark", action: #selector(closeTapped))
        addSubview(closeButton)

        // Replace toggle (chevron)
        replaceToggleButton = makeButton(symbol: "chevron.right", action: #selector(toggleReplace))
        addSubview(replaceToggleButton)

        // Search field
        searchField = NSTextField()
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        searchField.placeholderString = "Find"
        searchField.focusRingType = .none
        searchField.backgroundColor = NSColor(white: 0.15, alpha: 1.0)
        searchField.textColor = NSColor(white: 0.9, alpha: 1.0)
        searchField.isBordered = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        addSubview(searchField)

        // Match count
        matchCountLabel = NSTextField(labelWithString: "")
        matchCountLabel.translatesAutoresizingMaskIntoConstraints = false
        matchCountLabel.font = .systemFont(ofSize: 10)
        matchCountLabel.textColor = NSColor(white: 0.5, alpha: 1.0)
        addSubview(matchCountLabel)

        // Navigation buttons
        prevButton = makeButton(symbol: "chevron.up", action: #selector(prevMatch))
        nextButton = makeButton(symbol: "chevron.down", action: #selector(nextMatch))
        addSubview(prevButton)
        addSubview(nextButton)

        // Toggle buttons
        caseButton = makeTextButton(title: "Aa", action: #selector(toggleCase))
        regexButton = makeTextButton(title: ".*", action: #selector(toggleRegex))
        addSubview(caseButton)
        addSubview(regexButton)

        // Replace field
        replaceField = NSTextField()
        replaceField.translatesAutoresizingMaskIntoConstraints = false
        replaceField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        replaceField.placeholderString = "Replace"
        replaceField.focusRingType = .none
        replaceField.backgroundColor = NSColor(white: 0.15, alpha: 1.0)
        replaceField.textColor = NSColor(white: 0.9, alpha: 1.0)
        replaceField.isBordered = true
        replaceField.isHidden = true
        addSubview(replaceField)

        // Replace buttons
        replaceButton = makeButton(symbol: "arrow.left.arrow.right", action: #selector(replaceCurrent))
        replaceButton.isHidden = true
        addSubview(replaceButton)

        replaceAllButton = makeButton(symbol: "arrow.left.arrow.right.circle", action: #selector(replaceAll))
        replaceAllButton.isHidden = true
        addSubview(replaceAllButton)

        collapsedHeightConstraint = heightAnchor.constraint(equalToConstant: 32)
        expandedHeightConstraint = heightAnchor.constraint(equalToConstant: 64)
        collapsedHeightConstraint?.isActive = true

        NSLayoutConstraint.activate([
            replaceToggleButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            replaceToggleButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            replaceToggleButton.widthAnchor.constraint(equalToConstant: 20),
            replaceToggleButton.heightAnchor.constraint(equalToConstant: 24),

            searchField.leadingAnchor.constraint(equalTo: replaceToggleButton.trailingAnchor, constant: 4),
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            searchField.heightAnchor.constraint(equalToConstant: 24),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),

            caseButton.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 4),
            caseButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            caseButton.widthAnchor.constraint(equalToConstant: 24),
            caseButton.heightAnchor.constraint(equalToConstant: 24),

            regexButton.leadingAnchor.constraint(equalTo: caseButton.trailingAnchor, constant: 2),
            regexButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            regexButton.widthAnchor.constraint(equalToConstant: 24),
            regexButton.heightAnchor.constraint(equalToConstant: 24),

            matchCountLabel.leadingAnchor.constraint(equalTo: regexButton.trailingAnchor, constant: 8),
            matchCountLabel.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),

            prevButton.leadingAnchor.constraint(equalTo: matchCountLabel.trailingAnchor, constant: 8),
            prevButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            prevButton.widthAnchor.constraint(equalToConstant: 24),
            prevButton.heightAnchor.constraint(equalToConstant: 24),

            nextButton.leadingAnchor.constraint(equalTo: prevButton.trailingAnchor, constant: 2),
            nextButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 24),
            nextButton.heightAnchor.constraint(equalToConstant: 24),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),

            replaceField.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            replaceField.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            replaceField.widthAnchor.constraint(equalTo: searchField.widthAnchor),
            replaceField.heightAnchor.constraint(equalToConstant: 24),

            replaceButton.leadingAnchor.constraint(equalTo: replaceField.trailingAnchor, constant: 4),
            replaceButton.centerYAnchor.constraint(equalTo: replaceField.centerYAnchor),
            replaceButton.widthAnchor.constraint(equalToConstant: 24),
            replaceButton.heightAnchor.constraint(equalToConstant: 24),

            replaceAllButton.leadingAnchor.constraint(equalTo: replaceButton.trailingAnchor, constant: 2),
            replaceAllButton.centerYAnchor.constraint(equalTo: replaceField.centerYAnchor),
            replaceAllButton.widthAnchor.constraint(equalToConstant: 24),
            replaceAllButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    private func makeButton(symbol: String, action: Selector) -> NSButton {
        let btn = NSButton()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.bezelStyle = .texturedRounded
        btn.isBordered = false
        btn.title = ""
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        btn.contentTintColor = NSColor(white: 0.6, alpha: 1.0)
        btn.target = self
        btn.action = action
        return btn
    }

    private func makeTextButton(title: String, action: Selector) -> NSButton {
        let btn = NSButton()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.bezelStyle = .texturedRounded
        btn.isBordered = false
        btn.title = title
        btn.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        btn.contentTintColor = NSColor(white: 0.5, alpha: 1.0)
        btn.target = self
        btn.action = action
        return btn
    }

    // MARK: - Actions

    @objc private func searchChanged() {
        editorView?.findQuery = searchField.stringValue
        editorView?.findMatches()
        updateMatchCount()
    }

    @objc func prevMatch() {
        editorView?.navigateMatch(delta: -1)
        updateMatchCount()
    }

    @objc func nextMatch() {
        editorView?.navigateMatch(delta: 1)
        updateMatchCount()
    }

    @objc private func toggleCase() {
        guard let editor = editorView else { return }
        editor.findCaseSensitive.toggle()
        caseButton.contentTintColor = editor.findCaseSensitive ?
            NSColor.systemBlue : NSColor(white: 0.5, alpha: 1.0)
        editor.findMatches()
        updateMatchCount()
    }

    @objc private func toggleRegex() {
        guard let editor = editorView else { return }
        editor.findIsRegex.toggle()
        regexButton.contentTintColor = editor.findIsRegex ?
            NSColor.systemBlue : NSColor(white: 0.5, alpha: 1.0)
        editor.findMatches()
        updateMatchCount()
    }

    @objc private func toggleReplace() {
        showReplace.toggle()
    }

    @objc private func closeTapped() {
        editorView?.dismissFindBar()
    }

    @objc private func replaceCurrent() {
        let replacement = replaceField.stringValue
        editorView?.replaceCurrentMatch(with: replacement)
        updateMatchCount()
    }

    @objc private func replaceAll() {
        let replacement = replaceField.stringValue
        editorView?.replaceAllMatches(with: replacement)
        updateMatchCount()
    }

    private func updateReplaceVisibility() {
        replaceField.isHidden = !showReplace
        replaceButton.isHidden = !showReplace
        replaceAllButton.isHidden = !showReplace
        collapsedHeightConstraint?.isActive = !showReplace
        expandedHeightConstraint?.isActive = showReplace

        let symbol = showReplace ? "chevron.down" : "chevron.right"
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        replaceToggleButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }

    func updateMatchCount() {
        guard let editor = editorView else { return }
        let matches = editor.findMatchRanges
        if matches.isEmpty {
            matchCountLabel.stringValue = editor.findQuery.isEmpty ? "" : "No results"
        } else {
            matchCountLabel.stringValue = "\(editor.currentMatchIndex + 1) of \(matches.count)"
        }
    }

    func focus() {
        window?.makeFirstResponder(searchField)
        if let selectedText = editorView?.selectedText(), !selectedText.isEmpty {
            searchField.stringValue = selectedText
            searchChanged()
        }
    }
}
