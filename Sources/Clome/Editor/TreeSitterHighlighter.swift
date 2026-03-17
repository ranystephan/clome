import Foundation

/// Token types for syntax highlighting, mapped to editor colors.
enum TokenType {
    case keyword
    case string
    case comment
    case number
    case type
    case function
    case variable
    case property
    case `operator`
    case punctuation
    case plain
}

/// A highlighted range within a line of text.
struct HighlightToken {
    let range: Range<Int>
    let type: TokenType
}

/// Tree-sitter based syntax highlighter.
///
/// NOTE: This is a stub for the tree-sitter integration. Full tree-sitter requires
/// linking the C library and language grammar shared objects. The architecture is:
///
/// 1. SwiftTreeSitter SPM package provides Swift bindings to the tree-sitter C API
/// 2. Language grammar packages (tree-sitter-swift, tree-sitter-python, etc.) provide parsers
/// 3. highlights.scm query files define which AST nodes map to which token types
///
/// For now, this provides the interface that EditorView uses, with a flag to indicate
/// whether tree-sitter is available. When unavailable, EditorView falls back to regex.
///
/// To enable tree-sitter:
/// 1. Add SwiftTreeSitter and language grammar SPM packages to project.yml
/// 2. Bundle highlights.scm query files in Resources/queries/
/// 3. Implement the parsing and query logic below
class TreeSitterHighlighter {
    /// Whether tree-sitter is available for the given language
    static func isAvailable(for language: String) -> Bool {
        // Tree-sitter integration is not yet linked.
        // When SPM packages are added, this will check for available parsers.
        return false
    }

    /// Supported languages (when tree-sitter is fully integrated)
    static let supportedLanguages = ["swift", "python", "javascript", "typescript", "rust", "go", "c", "cpp", "zig"]

    private var language: String
    private var sourceText: String = ""

    // When tree-sitter is linked, these would be:
    // private var parser: TSParser?
    // private var tree: TSTree?
    // private var query: TSQuery?

    init(language: String) {
        self.language = language
    }

    /// Parse the full source text and return highlight tokens for a given line range.
    /// Returns nil if tree-sitter is not available for this language.
    func highlight(text: String, lineRange: Range<Int>) -> [[HighlightToken]]? {
        guard TreeSitterHighlighter.isAvailable(for: language) else { return nil }

        // When tree-sitter is linked, the implementation would:
        // 1. Parse `text` with TSParser to get TSTree
        // 2. Execute highlights.scm TSQuery on the tree
        // 3. Map captured nodes to TokenType based on capture names
        // 4. Return tokens for the requested line range

        return nil
    }

    /// Incrementally update the tree after an edit.
    /// This is much faster than re-parsing the entire document.
    func applyEdit(startByte: Int, oldEndByte: Int, newEndByte: Int,
                   startPoint: (row: Int, column: Int),
                   oldEndPoint: (row: Int, column: Int),
                   newEndPoint: (row: Int, column: Int)) {
        // When tree-sitter is linked:
        // 1. Call tree.edit() with the edit parameters
        // 2. Re-parse with the new source text
        // 3. The parser will reuse unchanged parts of the old tree
    }

    /// Map a tree-sitter capture name to a TokenType.
    static func tokenType(for captureName: String) -> TokenType {
        switch captureName {
        case "keyword", "keyword.function", "keyword.return", "keyword.operator",
             "keyword.conditional", "keyword.repeat", "keyword.import":
            return .keyword
        case "string", "string.special":
            return .string
        case "comment", "comment.line", "comment.block":
            return .comment
        case "number", "float", "integer":
            return .number
        case "type", "type.builtin", "type.definition":
            return .type
        case "function", "function.call", "function.method", "method":
            return .function
        case "variable", "variable.builtin", "variable.parameter":
            return .variable
        case "property", "field":
            return .property
        case "operator":
            return .operator
        case "punctuation.bracket", "punctuation.delimiter":
            return .punctuation
        default:
            return .plain
        }
    }
}
