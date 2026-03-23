import AppKit

/// Delegate for search field events.
@MainActor
protocol LauncherSearchFieldDelegate: AnyObject {
    func searchFieldDidChange(_ text: String)
    func searchFieldDidPressArrowDown()
    func searchFieldDidPressArrowUp()
    func searchFieldDidPressEnter()
    func searchFieldDidPressTab()
    func searchFieldDidPressEscape()
}

/// Custom search field for the launcher with mode-aware placeholder.
@MainActor
class LauncherSearchField: NSView, NSTextFieldDelegate {
    weak var searchDelegate: LauncherSearchFieldDelegate?

    private let iconView = NSImageView()
    private let textField = NSTextField()
    private let escHint = NSTextField(labelWithString: "Esc")
    private let escContainer = NSView()

    var stringValue: String {
        get { textField.stringValue }
        set { textField.stringValue = newValue }
    }

    /// The current mode prefix detected from the search text.
    var activeMode: LauncherMode {
        let text = textField.stringValue
        if text.hasPrefix(">") { return .commands }
        if text.hasPrefix("#") { return .sessions }
        if text.hasPrefix("/") { return .files }
        if text.hasPrefix("@") { return .terminals }
        return .all
    }

    /// The query text with mode prefix stripped.
    var queryText: String {
        let text = textField.stringValue
        switch activeMode {
        case .all: return text
        case .commands, .sessions, .files, .terminals:
            return String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setupViews() {
        wantsLayer = true

        // Search icon
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
        iconView.contentTintColor = NSColor(white: 0.5, alpha: 1.0)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        // Text field
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.font = .systemFont(ofSize: 16, weight: .regular)
        textField.textColor = NSColor(white: 0.9, alpha: 1.0)
        textField.placeholderAttributedString = NSAttributedString(
            string: "Search everything...",
            attributes: [
                .foregroundColor: NSColor(white: 0.4, alpha: 1.0),
                .font: NSFont.systemFont(ofSize: 16, weight: .regular)
            ]
        )
        textField.focusRingType = .none
        textField.delegate = self
        textField.cell?.sendsActionOnEndEditing = false
        addSubview(textField)

        // Esc hint container with padding
        escContainer.translatesAutoresizingMaskIntoConstraints = false
        escContainer.wantsLayer = true
        escContainer.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        escContainer.layer?.cornerRadius = 5
        addSubview(escContainer)

        // Esc hint label inside container
        escHint.translatesAutoresizingMaskIntoConstraints = false
        escHint.font = .systemFont(ofSize: 11, weight: .medium)
        escHint.textColor = NSColor(white: 0.35, alpha: 1.0)
        escHint.alignment = .center
        escContainer.addSubview(escHint)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 52),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            textField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textField.trailingAnchor.constraint(equalTo: escContainer.leadingAnchor, constant: -10),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            textField.heightAnchor.constraint(equalToConstant: 24),

            escContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            escContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            escContainer.heightAnchor.constraint(equalToConstant: 22),

            escHint.leadingAnchor.constraint(equalTo: escContainer.leadingAnchor, constant: 6),
            escHint.trailingAnchor.constraint(equalTo: escContainer.trailingAnchor, constant: -6),
            escHint.topAnchor.constraint(equalTo: escContainer.topAnchor, constant: 2),
            escHint.bottomAnchor.constraint(equalTo: escContainer.bottomAnchor, constant: -2),
        ])
    }

    func focus() {
        window?.makeFirstResponder(textField)
    }

    func clear() {
        textField.stringValue = ""
        updatePlaceholder()
    }

    private func updatePlaceholder() {
        let placeholder: String
        switch activeMode {
        case .all: placeholder = "Search everything..."
        case .commands: placeholder = "Run a command..."
        case .sessions: placeholder = "Search sessions..."
        case .files: placeholder = "Search files..."
        case .terminals: placeholder = "Search terminals..."
        }
        textField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor(white: 0.4, alpha: 1.0),
                .font: NSFont.systemFont(ofSize: 16, weight: .regular)
            ]
        )
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        updatePlaceholder()
        searchDelegate?.searchFieldDidChange(textField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            searchDelegate?.searchFieldDidPressArrowDown()
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            searchDelegate?.searchFieldDidPressArrowUp()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            searchDelegate?.searchFieldDidPressEnter()
            return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            searchDelegate?.searchFieldDidPressTab()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            searchDelegate?.searchFieldDidPressEscape()
            return true
        }
        return false
    }
}

/// Launcher search modes determined by prefix characters.
enum LauncherMode {
    case all        // No prefix
    case commands   // > prefix
    case sessions   // # prefix
    case files      // / prefix
    case terminals  // @ prefix
}
