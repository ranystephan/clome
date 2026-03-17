import AppKit

/// Provides colorful file type icons using official brand colors.
/// Each icon is a small rounded rectangle with the file extension abbreviation
/// rendered in the language's brand color.
@MainActor
class FileTypeIconProvider {
    static let shared = FileTypeIconProvider()

    private var cache: [String: NSImage] = [:]

    /// Returns a colorful icon for the given file extension, or nil if no custom icon exists.
    func icon(forExtension ext: String, size: CGFloat = 16) -> NSImage? {
        guard let spec = iconSpec(for: ext) else { return nil }

        let cacheKey = "\(ext)_\(Int(size))"
        if let cached = cache[cacheKey] { return cached }

        let image = drawIcon(spec: spec, size: size)
        cache[cacheKey] = image
        return image
    }

    /// Returns a colorful icon based on filename (for extensionless files like Dockerfile, Makefile).
    func icon(forFilename name: String, size: CGFloat = 16) -> NSImage? {
        let lower = name.lowercased()
        let ext: String?
        if lower == "dockerfile" || lower.hasPrefix("dockerfile.") {
            ext = "dockerfile"
        } else if lower == "makefile" || lower == "gnumakefile" {
            ext = "sh"
        } else if lower == ".gitignore" || lower == ".gitattributes" {
            ext = nil // no special icon
        } else if lower == ".env" || lower.hasPrefix(".env.") {
            ext = "env"
        } else {
            ext = nil
        }
        guard let ext else { return nil }
        return icon(forExtension: ext, size: size)
    }

    /// Returns a folder icon with the brand color tint.
    func folderIcon(expanded: Bool, size: CGFloat = 16) -> NSImage? {
        let name = expanded ? "folder.fill" : "folder"
        let cfg = NSImage.SymbolConfiguration(pointSize: size - 2, weight: .regular)
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return nil }
        let tinted = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor(red: 0.45, green: 0.65, blue: 0.85, alpha: 1.0).set()
            img.draw(in: rect)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }

    func clearCache() {
        cache.removeAll()
    }

    // MARK: - Icon Specs

    private struct IconSpec {
        let label: String        // Short text shown on the icon
        let bgColor: NSColor     // Background fill color
        let fgColor: NSColor     // Text color
    }

    private func iconSpec(for ext: String) -> IconSpec? {
        switch ext.lowercased() {
        // Python
        case "py", "pyw", "pyi":
            return IconSpec(
                label: "py",
                bgColor: NSColor(red: 0.216, green: 0.463, blue: 0.671, alpha: 1.0), // #3776AB
                fgColor: NSColor(red: 1.0, green: 0.835, blue: 0.373, alpha: 1.0)     // #FFD43B
            )
        // JavaScript
        case "js", "mjs", "cjs":
            return IconSpec(
                label: "JS",
                bgColor: NSColor(red: 0.969, green: 0.875, blue: 0.118, alpha: 1.0), // #F7DF1E
                fgColor: NSColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1.0)
            )
        // TypeScript
        case "ts":
            return IconSpec(
                label: "TS",
                bgColor: NSColor(red: 0.192, green: 0.471, blue: 0.776, alpha: 1.0), // #3178C6
                fgColor: .white
            )
        // TSX
        case "tsx":
            return IconSpec(
                label: "TX",
                bgColor: NSColor(red: 0.192, green: 0.471, blue: 0.776, alpha: 1.0),
                fgColor: .white
            )
        // JSX / React
        case "jsx":
            return IconSpec(
                label: "JX",
                bgColor: NSColor(red: 0.376, green: 0.843, blue: 0.961, alpha: 1.0), // #61DAFB
                fgColor: NSColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 1.0)
            )
        // Swift
        case "swift":
            return IconSpec(
                label: "Sw",
                bgColor: NSColor(red: 0.941, green: 0.318, blue: 0.220, alpha: 1.0), // #F05138
                fgColor: .white
            )
        // Rust
        case "rs":
            return IconSpec(
                label: "Rs",
                bgColor: NSColor(red: 0.871, green: 0.380, blue: 0.204, alpha: 1.0), // #DE6034
                fgColor: .white
            )
        // Go
        case "go":
            return IconSpec(
                label: "Go",
                bgColor: NSColor(red: 0.0, green: 0.678, blue: 0.847, alpha: 1.0),   // #00ADD8
                fgColor: .white
            )
        // C
        case "c":
            return IconSpec(
                label: "C",
                bgColor: NSColor(red: 0.337, green: 0.380, blue: 0.667, alpha: 1.0), // #5661AA
                fgColor: .white
            )
        // C++
        case "cpp", "cc", "cxx":
            return IconSpec(
                label: "C+",
                bgColor: NSColor(red: 0.0, green: 0.349, blue: 0.612, alpha: 1.0),   // #00599C
                fgColor: .white
            )
        // C/C++ headers
        case "h", "hpp", "hxx":
            return IconSpec(
                label: "H",
                bgColor: NSColor(red: 0.502, green: 0.306, blue: 0.651, alpha: 1.0), // #804EA6
                fgColor: .white
            )
        // Zig
        case "zig":
            return IconSpec(
                label: "Zig",
                bgColor: NSColor(red: 0.957, green: 0.659, blue: 0.082, alpha: 1.0), // #F4A815
                fgColor: NSColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 1.0)
            )
        // Ruby
        case "rb", "erb":
            return IconSpec(
                label: "Rb",
                bgColor: NSColor(red: 0.800, green: 0.114, blue: 0.114, alpha: 1.0), // #CC1D1D
                fgColor: .white
            )
        // Java
        case "java":
            return IconSpec(
                label: "Jv",
                bgColor: NSColor(red: 0.906, green: 0.439, blue: 0.141, alpha: 1.0), // #E87024
                fgColor: .white
            )
        // Kotlin
        case "kt", "kts":
            return IconSpec(
                label: "Kt",
                bgColor: NSColor(red: 0.686, green: 0.322, blue: 0.871, alpha: 1.0), // #AF52DE
                fgColor: .white
            )
        // PHP
        case "php":
            return IconSpec(
                label: "php",
                bgColor: NSColor(red: 0.467, green: 0.549, blue: 0.694, alpha: 1.0), // #778CB1
                fgColor: .white
            )
        // HTML
        case "html", "htm":
            return IconSpec(
                label: "</>",
                bgColor: NSColor(red: 0.890, green: 0.310, blue: 0.149, alpha: 1.0), // #E34F26
                fgColor: .white
            )
        // CSS
        case "css":
            return IconSpec(
                label: "#",
                bgColor: NSColor(red: 0.082, green: 0.447, blue: 0.714, alpha: 1.0), // #1572B6
                fgColor: .white
            )
        // SCSS/SASS
        case "scss", "sass":
            return IconSpec(
                label: "S",
                bgColor: NSColor(red: 0.804, green: 0.365, blue: 0.584, alpha: 1.0), // #CD5D95
                fgColor: .white
            )
        // JSON
        case "json":
            return IconSpec(
                label: "{ }",
                bgColor: NSColor(red: 0.369, green: 0.369, blue: 0.369, alpha: 1.0), // #5E5E5E
                fgColor: NSColor(red: 1.0, green: 0.835, blue: 0.373, alpha: 1.0)
            )
        // YAML/TOML config
        case "yaml", "yml":
            return IconSpec(
                label: "yml",
                bgColor: NSColor(red: 0.796, green: 0.235, blue: 0.200, alpha: 1.0), // #CB3C33
                fgColor: .white
            )
        case "toml":
            return IconSpec(
                label: "tml",
                bgColor: NSColor(red: 0.608, green: 0.471, blue: 0.329, alpha: 1.0), // #9B7854
                fgColor: .white
            )
        // Markdown
        case "md", "mdx":
            return IconSpec(
                label: "M",
                bgColor: NSColor(red: 0.30, green: 0.30, blue: 0.32, alpha: 1.0),
                fgColor: .white
            )
        // Text
        case "txt":
            return IconSpec(
                label: "txt",
                bgColor: NSColor(red: 0.35, green: 0.35, blue: 0.37, alpha: 1.0),
                fgColor: NSColor(white: 0.85, alpha: 1.0)
            )
        // PDF
        case "pdf":
            return IconSpec(
                label: "PDF",
                bgColor: NSColor(red: 0.847, green: 0.161, blue: 0.161, alpha: 1.0), // #D82929
                fgColor: .white
            )
        // Shell
        case "sh", "bash", "zsh", "fish":
            return IconSpec(
                label: ">_",
                bgColor: NSColor(red: 0.286, green: 0.357, blue: 0.263, alpha: 1.0), // #495B43
                fgColor: NSColor(red: 0.569, green: 0.871, blue: 0.475, alpha: 1.0)   // #91DE79
            )
        // Docker
        case "dockerfile":
            return IconSpec(
                label: "D",
                bgColor: NSColor(red: 0.141, green: 0.569, blue: 0.843, alpha: 1.0), // #2496ED
                fgColor: .white
            )
        // SQL
        case "sql":
            return IconSpec(
                label: "SQL",
                bgColor: NSColor(red: 0.878, green: 0.561, blue: 0.141, alpha: 1.0), // #E09024
                fgColor: .white
            )
        // Images
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "ico":
            return IconSpec(
                label: ext.prefix(3).uppercased(),
                bgColor: NSColor(red: 0.427, green: 0.655, blue: 0.306, alpha: 1.0), // #6DA74E
                fgColor: .white
            )
        // SVG
        case "svg":
            return IconSpec(
                label: "SVG",
                bgColor: NSColor(red: 1.0, green: 0.647, blue: 0.0, alpha: 1.0),     // #FFA500
                fgColor: .white
            )
        // Jupyter Notebook
        case "ipynb":
            return IconSpec(
                label: "Jn",
                bgColor: NSColor(red: 0.957, green: 0.518, blue: 0.220, alpha: 1.0), // #F48435
                fgColor: .white
            )
        // LaTeX
        case "tex", "sty", "cls":
            return IconSpec(
                label: "TeX",
                bgColor: NSColor(red: 0.0, green: 0.514, blue: 0.494, alpha: 1.0),   // #00837E teal
                fgColor: .white
            )
        // BibTeX
        case "bib":
            return IconSpec(
                label: "bib",
                bgColor: NSColor(red: 0.671, green: 0.557, blue: 0.180, alpha: 1.0), // #AB8E2E
                fgColor: .white
            )
        // XML / Plist
        case "xml", "plist":
            return IconSpec(
                label: "< >",
                bgColor: NSColor(red: 0.0, green: 0.529, blue: 0.318, alpha: 1.0),   // #008751
                fgColor: .white
            )
        // Lua
        case "lua":
            return IconSpec(
                label: "Lua",
                bgColor: NSColor(red: 0.0, green: 0.0, blue: 0.502, alpha: 1.0),     // #000080
                fgColor: .white
            )
        // Dart
        case "dart":
            return IconSpec(
                label: "Dt",
                bgColor: NSColor(red: 0.012, green: 0.671, blue: 0.863, alpha: 1.0), // #03ABDC
                fgColor: .white
            )
        // R
        case "r", "rmd":
            return IconSpec(
                label: "R",
                bgColor: NSColor(red: 0.161, green: 0.502, blue: 0.725, alpha: 1.0), // #2980B9
                fgColor: .white
            )
        // Elixir
        case "ex", "exs":
            return IconSpec(
                label: "Ex",
                bgColor: NSColor(red: 0.439, green: 0.271, blue: 0.565, alpha: 1.0), // #704590
                fgColor: .white
            )
        // Lock files / config
        case "lock":
            return IconSpec(
                label: "lk",
                bgColor: NSColor(red: 0.30, green: 0.30, blue: 0.32, alpha: 1.0),
                fgColor: NSColor(white: 0.6, alpha: 1.0)
            )
        // Env
        case "env":
            return IconSpec(
                label: "env",
                bgColor: NSColor(red: 0.969, green: 0.875, blue: 0.118, alpha: 1.0),
                fgColor: NSColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1.0)
            )
        // GraphQL
        case "graphql", "gql":
            return IconSpec(
                label: "GQ",
                bgColor: NSColor(red: 0.882, green: 0.0, blue: 0.569, alpha: 1.0),   // #E10098
                fgColor: .white
            )
        // Protobuf
        case "proto":
            return IconSpec(
                label: "pb",
                bgColor: NSColor(red: 0.31, green: 0.53, blue: 0.43, alpha: 1.0),
                fgColor: .white
            )
        // CSV / TSV
        case "csv":
            return IconSpec(
                label: "csv",
                bgColor: NSColor(red: 0.208, green: 0.667, blue: 0.325, alpha: 1.0), // #35AA53 (Excel green)
                fgColor: .white
            )
        case "tsv":
            return IconSpec(
                label: "tsv",
                bgColor: NSColor(red: 0.208, green: 0.667, blue: 0.325, alpha: 1.0),
                fgColor: .white
            )
        // Archives
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar":
            return IconSpec(
                label: "zip",
                bgColor: NSColor(red: 0.502, green: 0.400, blue: 0.302, alpha: 1.0), // #80664D
                fgColor: NSColor(red: 1.0, green: 0.867, blue: 0.667, alpha: 1.0)
            )
        // Excel
        case "xls", "xlsx":
            return IconSpec(
                label: "xls",
                bgColor: NSColor(red: 0.129, green: 0.588, blue: 0.325, alpha: 1.0), // #219653
                fgColor: .white
            )
        // Word
        case "doc", "docx":
            return IconSpec(
                label: "doc",
                bgColor: NSColor(red: 0.165, green: 0.384, blue: 0.725, alpha: 1.0), // #2A62B9
                fgColor: .white
            )
        // PowerPoint
        case "ppt", "pptx":
            return IconSpec(
                label: "ppt",
                bgColor: NSColor(red: 0.827, green: 0.310, blue: 0.208, alpha: 1.0), // #D34F35
                fgColor: .white
            )
        // Audio
        case "mp3", "wav", "flac", "aac", "ogg", "m4a", "wma":
            return IconSpec(
                label: ext.prefix(3).uppercased(),
                bgColor: NSColor(red: 0.612, green: 0.153, blue: 0.690, alpha: 1.0), // #9C27B0
                fgColor: .white
            )
        // Video
        case "mp4", "mov", "avi", "mkv", "webm", "flv", "wmv", "m4v":
            return IconSpec(
                label: ext.prefix(3).uppercased(),
                bgColor: NSColor(red: 0.898, green: 0.224, blue: 0.208, alpha: 1.0), // #E53935
                fgColor: .white
            )
        // Font files
        case "ttf", "otf", "woff", "woff2":
            return IconSpec(
                label: "Aa",
                bgColor: NSColor(red: 0.557, green: 0.267, blue: 0.678, alpha: 1.0), // #8E44AD
                fgColor: .white
            )
        // Log files
        case "log":
            return IconSpec(
                label: "log",
                bgColor: NSColor(red: 0.35, green: 0.35, blue: 0.37, alpha: 1.0),
                fgColor: NSColor(white: 0.70, alpha: 1.0)
            )
        // INI / Config
        case "ini", "cfg", "conf":
            return IconSpec(
                label: "cfg",
                bgColor: NSColor(red: 0.40, green: 0.40, blue: 0.42, alpha: 1.0),
                fgColor: NSColor(white: 0.80, alpha: 1.0)
            )
        // Diff / Patch
        case "diff", "patch":
            return IconSpec(
                label: "+/-",
                bgColor: NSColor(red: 0.25, green: 0.40, blue: 0.25, alpha: 1.0),
                fgColor: NSColor(red: 0.569, green: 0.871, blue: 0.475, alpha: 1.0)
            )
        // Terraform
        case "tf", "tfvars":
            return IconSpec(
                label: "TF",
                bgColor: NSColor(red: 0.380, green: 0.318, blue: 0.788, alpha: 1.0), // #6151C9
                fgColor: .white
            )
        // Nix
        case "nix":
            return IconSpec(
                label: "Nix",
                bgColor: NSColor(red: 0.325, green: 0.494, blue: 0.667, alpha: 1.0), // #537EAA
                fgColor: .white
            )
        // Scala
        case "scala", "sc":
            return IconSpec(
                label: "Sc",
                bgColor: NSColor(red: 0.863, green: 0.247, blue: 0.208, alpha: 1.0), // #DC3F35
                fgColor: .white
            )
        // Haskell
        case "hs", "lhs":
            return IconSpec(
                label: "Hs",
                bgColor: NSColor(red: 0.369, green: 0.310, blue: 0.537, alpha: 1.0), // #5E4F89
                fgColor: .white
            )
        // Clojure
        case "clj", "cljs", "cljc":
            return IconSpec(
                label: "Clj",
                bgColor: NSColor(red: 0.380, green: 0.604, blue: 0.086, alpha: 1.0), // #619A16
                fgColor: .white
            )
        // Erlang
        case "erl":
            return IconSpec(
                label: "Erl",
                bgColor: NSColor(red: 0.659, green: 0.063, blue: 0.322, alpha: 1.0), // #A81052
                fgColor: .white
            )
        // Vue
        case "vue":
            return IconSpec(
                label: "V",
                bgColor: NSColor(red: 0.259, green: 0.718, blue: 0.482, alpha: 1.0), // #42B77B
                fgColor: .white
            )
        // Svelte
        case "svelte":
            return IconSpec(
                label: "Sv",
                bgColor: NSColor(red: 1.0, green: 0.247, blue: 0.0, alpha: 1.0),     // #FF3E00
                fgColor: .white
            )
        // Assembly
        case "asm", "s":
            return IconSpec(
                label: "asm",
                bgColor: NSColor(red: 0.40, green: 0.42, blue: 0.50, alpha: 1.0),
                fgColor: NSColor(red: 0.75, green: 0.85, blue: 1.0, alpha: 1.0)
            )
        // WASM
        case "wasm", "wat":
            return IconSpec(
                label: "WA",
                bgColor: NSColor(red: 0.396, green: 0.318, blue: 0.820, alpha: 1.0), // #6551D1
                fgColor: .white
            )
        // Certificate / Key
        case "pem", "crt", "cer", "key", "p12":
            return IconSpec(
                label: "key",
                bgColor: NSColor(red: 0.827, green: 0.678, blue: 0.176, alpha: 1.0), // #D3AD2D
                fgColor: NSColor(red: 0.15, green: 0.15, blue: 0.10, alpha: 1.0)
            )
        default:
            return nil
        }
    }

    // MARK: - Drawing

    private func drawIcon(spec: IconSpec, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // Rounded rect background
            let bgRect = rect.insetBy(dx: 0.5, dy: 0.5)
            let cornerRadius: CGFloat = size * 0.2
            let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: cornerRadius, yRadius: cornerRadius)
            spec.bgColor.setFill()
            bgPath.fill()

            // Text
            let fontSize: CGFloat
            if spec.label.count <= 1 {
                fontSize = size * 0.58
            } else if spec.label.count <= 2 {
                fontSize = size * 0.46
            } else {
                fontSize = size * 0.34
            }

            let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: spec.fgColor,
            ]
            let str = NSAttributedString(string: spec.label, attributes: attrs)
            let strSize = str.size()
            let textRect = NSRect(
                x: (rect.width - strSize.width) / 2,
                y: (rect.height - strSize.height) / 2,
                width: strSize.width,
                height: strSize.height
            )
            str.draw(in: textRect)

            return true
        }
        image.isTemplate = false
        return image
    }
}
