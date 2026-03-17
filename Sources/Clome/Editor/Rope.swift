import Foundation

/// A rope data structure for efficient text editing of large files.
/// Uses a balanced binary tree of text chunks, providing O(log n) insert/delete
/// and O(1) access to total length. Same approach as Zed and Xi editor.
final class Rope {
    private var root: RopeNode

    /// Maximum leaf size before splitting
    static let maxLeafSize = 512

    /// Initialize with empty content.
    init() {
        root = RopeNode.leaf("")
    }

    /// Initialize from a string.
    init(_ string: String) {
        if string.count <= Rope.maxLeafSize {
            root = RopeNode.leaf(string)
        } else {
            root = Rope.buildTree(from: string)
        }
    }

    /// Total character count.
    var count: Int {
        root.weight
    }

    /// Total number of lines.
    var lineCount: Int {
        root.lineCount
    }

    /// Whether the rope is empty.
    var isEmpty: Bool {
        count == 0
    }

    // MARK: - Read Operations

    /// Get the full string content. O(n).
    func toString() -> String {
        var result = ""
        result.reserveCapacity(count)
        root.appendTo(&result)
        return result
    }

    /// Get a character at the given index. O(log n).
    func character(at index: Int) -> Character? {
        guard index >= 0 && index < count else { return nil }
        return root.character(at: index)
    }

    /// Get a substring in the given range. O(log n + k) where k = range length.
    func substring(in range: Range<Int>) -> String {
        let start = max(0, range.lowerBound)
        let end = min(count, range.upperBound)
        guard start < end else { return "" }
        var result = ""
        result.reserveCapacity(end - start)
        root.substring(from: start, to: end, into: &result)
        return result
    }

    /// Get text for a specific line (0-indexed). Returns the line content including newline if present.
    func line(_ lineIndex: Int) -> String {
        guard lineIndex >= 0 && lineIndex < lineCount else { return "" }
        let startOffset = lineStartOffset(lineIndex)
        let endOffset: Int
        if lineIndex + 1 < lineCount {
            endOffset = lineStartOffset(lineIndex + 1)
        } else {
            endOffset = count
        }
        return substring(in: startOffset..<endOffset)
    }

    /// Get the character offset where a line starts. O(log n).
    func lineStartOffset(_ lineIndex: Int) -> Int {
        guard lineIndex > 0 else { return 0 }
        guard lineIndex < lineCount else { return count }
        return root.lineStartOffset(lineIndex)
    }

    /// Get the line index for a character offset. O(log n).
    func lineIndex(at offset: Int) -> Int {
        guard offset > 0 else { return 0 }
        guard offset < count else { return max(0, lineCount - 1) }
        return root.lineIndex(at: offset)
    }

    /// Search for all occurrences of a plain text string. Returns character offset ranges.
    /// For large files, materializes the string once and caches nothing — but avoids
    /// repeated materialization across multiple operations.
    func findAll(_ query: String, caseInsensitive: Bool = false) -> [Range<Int>] {
        guard !query.isEmpty, count > 0 else { return [] }
        let text = toString()
        var results: [Range<Int>] = []
        var options: String.CompareOptions = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        var searchStart = text.startIndex
        while let range = text.range(of: query, options: options, range: searchStart..<text.endIndex) {
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let end = text.distance(from: text.startIndex, to: range.upperBound)
            results.append(start..<end)
            searchStart = range.upperBound
            if range.isEmpty { break }
        }
        return results
    }

    // MARK: - Write Operations

    /// Insert a string at the given offset. O(log n).
    func insert(_ string: String, at offset: Int) {
        guard !string.isEmpty else { return }
        let pos = max(0, min(offset, count))
        let (left, right) = root.split(at: pos)
        let middle = RopeNode.leaf(string)
        root = RopeNode.merge(RopeNode.merge(left, middle), right)
        rebalanceIfNeeded()
    }

    /// Delete characters in the given range. O(log n).
    func delete(in range: Range<Int>) {
        let start = max(0, range.lowerBound)
        let end = min(count, range.upperBound)
        guard start < end else { return }
        let (left, temp) = root.split(at: start)
        let (_, right) = temp.split(at: end - start)
        root = RopeNode.merge(left, right)
        rebalanceIfNeeded()
    }

    /// Replace text in a range with new text. O(log n).
    func replace(in range: Range<Int>, with string: String) {
        delete(in: range)
        insert(string, at: range.lowerBound)
    }

    // MARK: - Balance

    private func rebalanceIfNeeded() {
        if root.depth > Int(2.0 * log2(Double(max(root.leafCount, 2)))) {
            let str = toString()
            root = Rope.buildTree(from: str)
        }
    }

    private static func buildTree(from string: String) -> RopeNode {
        let chars = Array(string)
        var leaves: [RopeNode] = []
        var i = 0
        while i < chars.count {
            let end = min(i + maxLeafSize, chars.count)
            leaves.append(RopeNode.leaf(String(chars[i..<end])))
            i = end
        }
        if leaves.isEmpty { return RopeNode.leaf("") }
        return mergeLeaves(leaves)
    }

    private static func mergeLeaves(_ nodes: [RopeNode]) -> RopeNode {
        if nodes.count == 1 { return nodes[0] }
        var merged: [RopeNode] = []
        var i = 0
        while i < nodes.count {
            if i + 1 < nodes.count {
                merged.append(RopeNode.merge(nodes[i], nodes[i + 1]))
                i += 2
            } else {
                merged.append(nodes[i])
                i += 1
            }
        }
        return mergeLeaves(merged)
    }
}

// MARK: - Rope Node

indirect enum RopeNode {
    case leaf(String, weight: Int, lineBreaks: Int)
    case branch(left: RopeNode, right: RopeNode, weight: Int, lineBreaks: Int)

    /// Create a leaf node, pre-computing weight and lineBreaks.
    static func leaf(_ s: String) -> RopeNode {
        let w = s.count
        var lb = 0
        for ch in s where ch == "\n" { lb += 1 }
        return .leaf(s, weight: w, lineBreaks: lb)
    }

    /// Total character count of this subtree.
    var weight: Int {
        switch self {
        case .leaf(_, let w, _): return w
        case .branch(_, _, let w, _): return w
        }
    }

    /// Number of newline characters in this subtree.
    var lineBreaks: Int {
        switch self {
        case .leaf(_, _, let lb): return lb
        case .branch(_, _, _, let lb): return lb
        }
    }

    /// Total lines (lineBreaks + 1).
    var lineCount: Int {
        lineBreaks + 1
    }

    var depth: Int {
        switch self {
        case .leaf: return 0
        case .branch(let l, let r, _, _): return 1 + max(l.depth, r.depth)
        }
    }

    var leafCount: Int {
        switch self {
        case .leaf: return 1
        case .branch(let l, let r, _, _): return l.leafCount + r.leafCount
        }
    }

    func appendTo(_ result: inout String) {
        switch self {
        case .leaf(let s, _, _): result += s
        case .branch(let l, let r, _, _):
            l.appendTo(&result)
            r.appendTo(&result)
        }
    }

    func character(at index: Int) -> Character? {
        switch self {
        case .leaf(let s, _, _):
            let strIndex = s.index(s.startIndex, offsetBy: index)
            return s[strIndex]
        case .branch(let left, let right, _, _):
            let leftWeight = left.weight
            if index < leftWeight {
                return left.character(at: index)
            } else {
                return right.character(at: index - leftWeight)
            }
        }
    }

    func substring(from start: Int, to end: Int, into result: inout String) {
        switch self {
        case .leaf(let s, _, _):
            let sStart = s.index(s.startIndex, offsetBy: start)
            let sEnd = s.index(s.startIndex, offsetBy: end)
            result += s[sStart..<sEnd]
        case .branch(let left, let right, _, _):
            let leftWeight = left.weight
            if start < leftWeight {
                left.substring(from: start, to: min(end, leftWeight), into: &result)
            }
            if end > leftWeight {
                right.substring(from: max(0, start - leftWeight), to: end - leftWeight, into: &result)
            }
        }
    }

    func lineStartOffset(_ lineIndex: Int) -> Int {
        switch self {
        case .leaf(let s, _, _):
            var line = 0
            for (i, ch) in s.enumerated() {
                if line == lineIndex { return i }
                if ch == "\n" { line += 1 }
            }
            return s.count

        case .branch(let left, let right, _, _):
            let leftLineBreaks = left.lineBreaks
            if lineIndex <= leftLineBreaks {
                return left.lineStartOffset(lineIndex)
            } else {
                return left.weight + right.lineStartOffset(lineIndex - leftLineBreaks)
            }
        }
    }

    func lineIndex(at offset: Int) -> Int {
        switch self {
        case .leaf(let s, _, _):
            var lines = 0
            let endIndex = s.index(s.startIndex, offsetBy: min(offset, s.count))
            for ch in s[s.startIndex..<endIndex] {
                if ch == "\n" { lines += 1 }
            }
            return lines

        case .branch(let left, let right, _, _):
            let leftWeight = left.weight
            if offset <= leftWeight {
                return left.lineIndex(at: offset)
            } else {
                return left.lineBreaks + right.lineIndex(at: offset - leftWeight)
            }
        }
    }

    func split(at position: Int) -> (RopeNode, RopeNode) {
        switch self {
        case .leaf(let s, _, _):
            let pos = min(max(position, 0), s.count)
            let left = String(s.prefix(pos))
            let right = String(s.suffix(s.count - pos))
            return (RopeNode.leaf(left), RopeNode.leaf(right))

        case .branch(let left, let right, _, _):
            let leftWeight = left.weight
            if position <= 0 {
                return (RopeNode.leaf(""), self)
            } else if position >= weight {
                return (self, RopeNode.leaf(""))
            } else if position <= leftWeight {
                let (ll, lr) = left.split(at: position)
                return (ll, RopeNode.merge(lr, right))
            } else {
                let (rl, rr) = right.split(at: position - leftWeight)
                return (RopeNode.merge(left, rl), rr)
            }
        }
    }

    static func merge(_ left: RopeNode, _ right: RopeNode) -> RopeNode {
        if left.weight == 0 { return right }
        if right.weight == 0 { return left }
        return .branch(
            left: left,
            right: right,
            weight: left.weight + right.weight,
            lineBreaks: left.lineBreaks + right.lineBreaks
        )
    }
}
