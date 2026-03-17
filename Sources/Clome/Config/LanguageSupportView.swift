import AppKit

/// Data model for a supported language.
struct LanguageInfo {
    let name: String
    let displayName: String
    let extensions: [String]
    let hasHighlighting: Bool
    let lspServerName: String?
    let defaultLspCommand: String?
    let defaultLspArgs: [String]
    var isLspInstalled: Bool
}

/// View displaying language support status (highlighting + LSP availability).
@MainActor
class LanguageSupportView: NSView {
    private var languages: [LanguageInfo] = []
    private var scrollView: NSScrollView!
    private var contentView: NSView!

    private static var customPaths: [String: String] = SessionState.shared.restoreLSPCustomPaths()

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildLanguageList()
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Returns custom server command if configured, else nil.
    static func effectiveServerCommand(for language: String) -> (command: String, args: [String])? {
        guard let path = customPaths[language],
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return (path, [])
    }

    private func buildLanguageList() {
        let defs: [(name: String, display: String, exts: [String], lspName: String?, lspCmd: String?, lspArgs: [String])] = [
            ("swift",       "Swift",        ["swift"],              "sourcekit-lsp",                "/usr/bin/xcrun",                           ["sourcekit-lsp"]),
            ("rust",        "Rust",         ["rs"],                 "rust-analyzer",                "/usr/local/bin/rust-analyzer",              []),
            ("python",      "Python",       ["py"],                 "pyright",                      "/usr/local/bin/pyright-langserver",         ["--stdio"]),
            ("javascript",  "JavaScript",   ["js", "jsx"],          "typescript-language-server",    "/usr/local/bin/typescript-language-server",  ["--stdio"]),
            ("typescript",  "TypeScript",   ["ts"],                 "typescript-language-server",    "/usr/local/bin/typescript-language-server",  ["--stdio"]),
            ("tsx",         "TSX",          ["tsx"],                 "typescript-language-server",    "/usr/local/bin/typescript-language-server",  ["--stdio"]),
            ("go",          "Go",           ["go"],                 "gopls",                        "/usr/local/bin/gopls",                      []),
            ("c",           "C",            ["c", "h"],             "clangd",                       "/usr/bin/clangd",                           []),
            ("cpp",         "C++",          ["cpp", "hpp", "cc"],   "clangd",                       "/usr/bin/clangd",                           []),
            ("zig",         "Zig",          ["zig"],                "zls",                          "/usr/local/bin/zls",                        []),
            ("java",        "Java",         ["java"],               nil, nil, []),
            ("kotlin",      "Kotlin",       ["kt"],                 nil, nil, []),
            ("c_sharp",     "C#",           ["cs"],                 nil, nil, []),
            ("ruby",        "Ruby",         ["rb"],                 nil, nil, []),
            ("bash",        "Bash",         ["sh", "bash", "zsh"],  nil, nil, []),
            ("lua",         "Lua",          ["lua"],                nil, nil, []),
            ("sql",         "SQL",          ["sql"],                nil, nil, []),
            ("html",        "HTML",         ["html"],               nil, nil, []),
            ("css",         "CSS",          ["css"],                nil, nil, []),
            ("json",        "JSON",         ["json"],               nil, nil, []),
            ("yaml",        "YAML",         ["yaml", "yml"],        nil, nil, []),
            ("toml",        "TOML",         ["toml"],               nil, nil, []),
            ("markdown",    "Markdown",     ["md"],                 nil, nil, []),
            ("dart",        "Dart",         ["dart"],               nil, nil, []),
            ("scala",       "Scala",        ["scala"],              nil, nil, []),
            ("haskell",     "Haskell",      ["hs"],                 nil, nil, []),
            ("elixir",      "Elixir",       ["ex"],                 nil, nil, []),
            ("php",         "PHP",          ["php"],                nil, nil, []),
            ("perl",        "Perl",         ["pl"],                 nil, nil, []),
            ("latex",       "LaTeX",        ["tex", "sty", "cls"],  "texlab",                       "/usr/local/bin/texlab",                     []),
            ("bibtex",      "BibTeX",       ["bib"],                nil, nil, []),
        ]

        // Highlighting keywords exist for these languages
        let highlightedLangs: Set<String> = ["swift", "rust", "python", "javascript", "typescript", "tsx", "go", "c", "cpp", "zig", "latex", "bibtex"]

        languages = defs.map { d in
            let installed: Bool
            if let cmd = d.lspCmd {
                if cmd == "/usr/bin/xcrun" {
                    // xcrun is always present on macOS with Xcode
                    installed = FileManager.default.isExecutableFile(atPath: cmd)
                } else {
                    installed = FileManager.default.isExecutableFile(atPath: cmd)
                }
            } else {
                installed = false
            }
            return LanguageInfo(
                name: d.name,
                displayName: d.display,
                extensions: d.exts,
                hasHighlighting: highlightedLangs.contains(d.name),
                lspServerName: d.lspName,
                defaultLspCommand: d.lspCmd,
                defaultLspArgs: d.lspArgs,
                isLspInstalled: installed
            )
        }

        // Sort: LSP languages first, then highlighting, then others
        languages.sort { a, b in
            let aScore = (a.lspServerName != nil ? 2 : 0) + (a.hasHighlighting ? 1 : 0)
            let bScore = (b.lspServerName != nil ? 2 : 0) + (b.hasHighlighting ? 1 : 0)
            if aScore != bScore { return aScore > bScore }
            return a.displayName < b.displayName
        }
    }

    private func setupUI() {
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        addSubview(scrollView)

        contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentView

        // Detect button
        let detectBtn = NSButton(title: "Detect Servers", target: self, action: #selector(detectServers))
        detectBtn.bezelStyle = .rounded
        detectBtn.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detectBtn)

        NSLayoutConstraint.activate([
            detectBtn.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            detectBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: detectBtn.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        rebuildRows()
    }

    private func rebuildRows() {
        contentView.subviews.forEach { $0.removeFromSuperview() }

        let rowHeight: CGFloat = 28
        let totalHeight = CGFloat(languages.count + 1) * rowHeight
        contentView.frame = NSRect(x: 0, y: 0, width: scrollView.frame.width > 0 ? scrollView.frame.width : 400, height: totalHeight)

        // Header row
        var y = totalHeight - rowHeight
        addRowLabel("Language", x: 12, y: y, width: 120, bold: true)
        addRowLabel("Highlighting", x: 140, y: y, width: 80, bold: true)
        addRowLabel("LSP Server", x: 228, y: y, width: 130, bold: true)
        addRowLabel("Status", x: 366, y: y, width: 60, bold: true)

        for lang in languages {
            y -= rowHeight

            // Language name
            addRowLabel(lang.displayName, x: 12, y: y, width: 120)

            // Highlighting status
            let hlText = lang.hasHighlighting ? "\u{2713}" : "\u{2013}"
            let hlColor: NSColor = lang.hasHighlighting ? .systemGreen : NSColor(white: 0.4, alpha: 1.0)
            addRowLabel(hlText, x: 160, y: y, width: 30, color: hlColor)

            // LSP server name
            addRowLabel(lang.lspServerName ?? "—", x: 228, y: y, width: 130,
                       color: lang.lspServerName != nil ? .labelColor : NSColor(white: 0.4, alpha: 1.0))

            // Status dot
            if lang.lspServerName != nil {
                let dot = NSView(frame: NSRect(x: 386, y: y + 9, width: 10, height: 10))
                dot.wantsLayer = true
                dot.layer?.cornerRadius = 5
                dot.layer?.backgroundColor = lang.isLspInstalled ? NSColor.systemGreen.cgColor : NSColor.systemRed.cgColor
                contentView.addSubview(dot)
            } else {
                let dot = NSView(frame: NSRect(x: 386, y: y + 9, width: 10, height: 10))
                dot.wantsLayer = true
                dot.layer?.cornerRadius = 5
                dot.layer?.backgroundColor = NSColor(white: 0.3, alpha: 1.0).cgColor
                contentView.addSubview(dot)
            }
        }
    }

    private func addRowLabel(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, bold: Bool = false, color: NSColor = .labelColor) {
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: x, y: y, width: width, height: 20)
        label.font = bold ? .systemFont(ofSize: 11, weight: .semibold) : .systemFont(ofSize: 11)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        contentView.addSubview(label)
    }

    @objc private func detectServers() {
        for i in languages.indices {
            if let cmd = languages[i].defaultLspCommand {
                languages[i].isLspInstalled = FileManager.default.isExecutableFile(atPath: cmd)
            }
        }
        rebuildRows()
    }
}
