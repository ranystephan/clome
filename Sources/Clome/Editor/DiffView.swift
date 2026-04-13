import AppKit

/// Displays a side-by-side or unified diff between two versions of text.
/// Used for reviewing agent-generated changes.
class DiffView: NSView {
    enum DiffMode {
        case unified
        case sideBySide
    }

    struct DiffLine {
        enum Kind {
            case context    // Unchanged
            case addition   // Added
            case deletion   // Removed
        }
        let kind: Kind
        let lineNumber: (old: Int?, new: Int?)
        let text: String
    }

    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private var diffLines: [DiffLine] = []
    var mode: DiffMode = .unified

    // Accept/reject callbacks
    var onAccept: (() -> Void)?
    var onReject: (() -> Void)?

    override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.055, green: 0.055, blue: 0.07, alpha: 1.0).cgColor
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setupUI() {
        // Toolbar
        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1.0).cgColor
        addSubview(toolbar)

        let acceptButton = makeButton(title: "Accept", color: .systemGreen, action: #selector(acceptTapped))
        toolbar.addSubview(acceptButton)

        let rejectButton = makeButton(title: "Reject", color: .systemRed, action: #selector(rejectTapped))
        toolbar.addSubview(rejectButton)

        // Scroll view + text view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor(white: 0.85, alpha: 1.0)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        scrollView.documentView = textView

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 36),

            acceptButton.trailingAnchor.constraint(equalTo: rejectButton.leadingAnchor, constant: -8),
            acceptButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            rejectButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            rejectButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func makeButton(title: String, color: NSColor, action: Selector) -> NSButton {
        let btn = NSButton()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.title = title
        btn.bezelStyle = .texturedRounded
        btn.isBordered = false
        btn.font = .systemFont(ofSize: 12, weight: .medium)
        btn.contentTintColor = color
        btn.target = self
        btn.action = action
        return btn
    }

    // MARK: - Diff Computation

    /// Compute and display the diff between old and new text.
    func showDiff(oldText: String, newText: String) {
        diffLines = computeDiff(old: oldText, new: newText)
        renderDiff()
    }

    private func computeDiff(old: String, new: String) -> [DiffLine] {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")

        // Simple LCS-based diff (Myers algorithm would be better but this works)
        var result: [DiffLine] = []
        let lcs = longestCommonSubsequence(oldLines, newLines)

        var oi = 0, ni = 0, li = 0
        while oi < oldLines.count || ni < newLines.count {
            if li < lcs.count && oi < oldLines.count && ni < newLines.count && oldLines[oi] == lcs[li] && newLines[ni] == lcs[li] {
                result.append(DiffLine(kind: .context, lineNumber: (oi + 1, ni + 1), text: oldLines[oi]))
                oi += 1; ni += 1; li += 1
            } else if oi < oldLines.count && (li >= lcs.count || oldLines[oi] != lcs[li]) {
                result.append(DiffLine(kind: .deletion, lineNumber: (oi + 1, nil), text: oldLines[oi]))
                oi += 1
            } else if ni < newLines.count {
                result.append(DiffLine(kind: .addition, lineNumber: (nil, ni + 1), text: newLines[ni]))
                ni += 1
            }
        }
        return result
    }

    private func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [String] {
        let m = a.count, n = b.count
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }
        var result: [String] = []
        var i = m, j = n
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] {
                result.insert(a[i - 1], at: 0)
                i -= 1; j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return result
    }

    private func renderDiff() {
        let attributed = NSMutableAttributedString()
        let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let addBg = NSColor(red: 0.15, green: 0.25, blue: 0.15, alpha: 1.0)
        let delBg = NSColor(red: 0.25, green: 0.15, blue: 0.15, alpha: 1.0)

        for line in diffLines {
            let prefix: String
            let fgColor: NSColor
            let bgColor: NSColor?

            switch line.kind {
            case .context:
                prefix = "  "
                fgColor = NSColor(white: 0.7, alpha: 1.0)
                bgColor = nil
            case .addition:
                prefix = "+ "
                fgColor = NSColor(red: 0.5, green: 0.9, blue: 0.5, alpha: 1.0)
                bgColor = addBg
            case .deletion:
                prefix = "- "
                fgColor = NSColor(red: 0.9, green: 0.5, blue: 0.5, alpha: 1.0)
                bgColor = delBg
            }

            let lineStr = "\(prefix)\(line.text)\n"
            var attrs: [NSAttributedString.Key: Any] = [
                .font: monoFont,
                .foregroundColor: fgColor,
            ]
            if let bg = bgColor {
                attrs[.backgroundColor] = bg
            }
            attributed.append(NSAttributedString(string: lineStr, attributes: attrs))
        }

        textView.textStorage?.setAttributedString(attributed)
    }

    // MARK: - Actions

    @objc private func acceptTapped() {
        onAccept?()
    }

    @objc private func rejectTapped() {
        onReject?()
    }
}
