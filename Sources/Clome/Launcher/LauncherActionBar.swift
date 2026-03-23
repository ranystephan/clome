import AppKit

/// A small padded key hint badge (e.g. "Enter", "Tab", "Esc").
@MainActor
private class KeyHintView: NSView {
    private let label: NSTextField

    init(text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        layer?.cornerRadius = 4

        label.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        label.textColor = NSColor(white: 0.4, alpha: 1.0)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }
}

/// Bottom bar showing contextual actions for the selected launcher item.
@MainActor
class LauncherActionBar: NSView {

    private let stackView = NSStackView()
    private var actionViews: [NSView] = []

    /// Whether the action panel is expanded (Tab pressed).
    private(set) var isExpanded: Bool = false

    /// Current actions.
    private var currentActions: [LauncherAction] = []

    /// Called when an action is executed.
    var onActionExecuted: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.03).cgColor

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 16
        addSubview(stackView)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Default hints
        showDefaultHints()
    }

    func updateActions(_ actions: [LauncherAction]) {
        currentActions = actions
        if !isExpanded {
            showDefaultHints()
        }
    }

    func toggleExpanded() {
        isExpanded.toggle()
        if isExpanded {
            showExpandedActions()
        } else {
            showDefaultHints()
        }
    }

    func collapse() {
        isExpanded = false
        showDefaultHints()
    }

    /// Execute action at index (used for keyboard shortcuts in expanded mode).
    func executeAction(at index: Int) {
        guard index >= 0, index < currentActions.count else { return }
        currentActions[index].handler()
        onActionExecuted?()
    }

    private func showDefaultHints() {
        clearStack()
        addHint(key: "Enter", label: "Open")
        addSeparatorDot()
        addHint(key: "Tab", label: "Actions")
        addSeparatorDot()
        addHint(key: "Esc", label: "Close")
    }

    private func showExpandedActions() {
        clearStack()
        for (index, action) in currentActions.enumerated() {
            if index > 0 {
                addSeparatorDot()
            }
            let shortcut = action.shortcut ?? ""
            addHint(key: shortcut, label: action.title, icon: action.icon)
        }
        if currentActions.isEmpty {
            addHint(key: "", label: "No actions available")
        }
    }

    private func addHint(key: String, label: String, icon: String? = nil) {
        let container = NSStackView()
        container.orientation = .horizontal
        container.spacing = 4
        container.alignment = .centerY

        if !key.isEmpty {
            let keyHint = KeyHintView(text: key)
            container.addArrangedSubview(keyHint)
        }

        if let iconName = icon {
            let imgView = NSImageView()
            imgView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
            imgView.contentTintColor = NSColor(white: 0.45, alpha: 1.0)
            imgView.translatesAutoresizingMaskIntoConstraints = false
            imgView.widthAnchor.constraint(equalToConstant: 12).isActive = true
            imgView.heightAnchor.constraint(equalToConstant: 12).isActive = true
            container.addArrangedSubview(imgView)
        }

        let textLabel = NSTextField(labelWithString: label)
        textLabel.font = .systemFont(ofSize: 11, weight: .regular)
        textLabel.textColor = NSColor(white: 0.4, alpha: 1.0)
        container.addArrangedSubview(textLabel)

        stackView.addArrangedSubview(container)
    }

    private func addSeparatorDot() {
        let dot = NSTextField(labelWithString: "\u{00B7}")
        dot.font = .systemFont(ofSize: 11, weight: .medium)
        dot.textColor = NSColor(white: 0.4, alpha: 1.0)
        stackView.addArrangedSubview(dot)
    }

    private func clearStack() {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }
}
