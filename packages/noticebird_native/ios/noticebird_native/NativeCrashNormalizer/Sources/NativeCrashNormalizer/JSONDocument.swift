import Foundation

/// A parsed JSON text, held as a flat list of nodes that refer to their
/// children by index.
///
/// MetricKit's call stack trees are undocumented and can nest one level per
/// frame, so the parser is built to survive any input:
///
/// - it is iterative (an explicit stack, no recursion), so nesting cannot
///   overflow the thread's stack;
/// - the nodes are flat, so releasing a document never recurses either;
/// - containers deeper than ``Limits/maxDepth`` are syntax-checked and
///   replaced by ``Node/truncated`` instead of being materialized;
/// - the input size and the node count are capped, beyond which the whole
///   text is rejected;
/// - numbers keep their exact kind (signed, unsigned or floating point), and
///   booleans are never confused with numbers, on every platform.
///
/// Children always have a higher index than their container, so any walk
/// that follows child indices terminates.
struct JSONDocument {
    enum Node: Equatable {
        case null
        case bool(Bool)
        case integer(Int64)
        /// An integer above `Int64.max`.
        case unsignedInteger(UInt64)
        case double(Double)
        case string(String)
        case array([Int])
        case object([String: Int])
        /// A container nested beyond ``Limits/maxDepth``: valid, not kept.
        case truncated
    }

    struct Limits {
        var maxBytes: Int
        var maxDepth: Int
        var maxNodes: Int

        /// For a MetricKit diagnostic: real ones are well below a megabyte
        /// and a few thousand nodes; the depth keeps about 2 000 frames of a
        /// chain, far more than a record keeps.
        static let diagnostic = Limits(maxBytes: 16 << 20, maxDepth: 4096, maxNodes: 500_000)

        /// For the collector's own small files.
        static let storedFile = Limits(maxBytes: 1 << 20, maxDepth: 16, maxNodes: 20_000)
    }

    let nodes: [Node]
    let root: Int

    /// Parses [data], or returns nil when it is not one well-formed JSON
    /// value within [limits].
    static func parse(_ data: Data, limits: Limits) -> JSONDocument? {
        guard data.count <= limits.maxBytes else { return nil }
        var parser = Parser(bytes: [UInt8](data), limits: limits)
        return parser.parseDocument()
    }

    // MARK: - Typed access; every accessor tolerates any index and any node.

    func node(_ index: Int) -> Node? {
        guard index >= 0, index < nodes.count else { return nil }
        return nodes[index]
    }

    func object(_ index: Int?) -> [String: Int]? {
        guard let index, case .object(let members)? = node(index) else { return nil }
        return members
    }

    func array(_ index: Int?) -> [Int]? {
        guard let index, case .array(let children)? = node(index) else { return nil }
        return children
    }

    func string(_ index: Int?) -> String? {
        guard let index, case .string(let value)? = node(index) else { return nil }
        return value
    }

    func bool(_ index: Int?) -> Bool? {
        guard let index, case .bool(let value)? = node(index) else { return nil }
        return value
    }

    func isTruncated(_ index: Int?) -> Bool {
        guard let index, case .truncated? = node(index) else { return false }
        return true
    }

    /// A signed integer; an integral floating-point value within ±2^53 counts.
    func integer(_ index: Int?) -> Int64? {
        guard let index else { return nil }
        switch node(index) {
        case .integer(let value)?:
            return value
        case .double(let value)?:
            return Self.exactInteger(value)
        default:
            return nil
        }
    }

    /// The unsigned 64-bit value of an integer: a negative one by its two's
    /// complement bit pattern, as the kernel stores exception codes.
    func unsignedBitPattern(_ index: Int?) -> UInt64? {
        guard let index else { return nil }
        switch node(index) {
        case .integer(let value)?:
            return UInt64(bitPattern: value)
        case .unsignedInteger(let value)?:
            return value
        case .double(let value)?:
            guard let exact = Self.exactInteger(value) else { return nil }
            return UInt64(bitPattern: exact)
        default:
            return nil
        }
    }

    /// 2^53: every integer up to it is exact in a `Double`.
    private static let maxExactDouble: Double = 9_007_199_254_740_992

    private static func exactInteger(_ value: Double) -> Int64? {
        guard value.isFinite, value.rounded(.towardZero) == value,
              value >= -maxExactDouble, value <= maxExactDouble
        else { return nil }
        return Int64(value)
    }
}

// MARK: - Parser

private struct Parser {
    let bytes: [UInt8]
    let limits: JSONDocument.Limits
    var index = 0
    var nodes: [JSONDocument.Node] = []

    /// One open container.
    struct Frame {
        let node: Int
        let isObject: Bool
        var children: [Int] = []
        var members: [String: Int] = [:]
        var pendingKey = ""
    }

    var stack: [Frame] = []

    init(bytes: [UInt8], limits: JSONDocument.Limits) {
        self.bytes = bytes
        self.limits = limits
    }

    mutating func parseDocument() -> JSONDocument? {
        guard let root = parseRoot() else { return nil }
        skipWhitespace()
        guard index == bytes.count else { return nil }
        return JSONDocument(nodes: nodes, root: root)
    }

    /// Parses one value and everything nested in it, iteratively.
    private mutating func parseRoot() -> Int? {
        while true {
            skipWhitespace()
            guard index < bytes.count else { return nil }
            var completed: Int?
            switch bytes[index] {
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                let isObject = bytes[index] == UInt8(ascii: "{")
                if stack.count >= limits.maxDepth {
                    guard skipContainer(), let node = append(.truncated) else { return nil }
                    completed = node
                    break
                }
                index += 1
                guard let node = append(.null) else { return nil }
                skipWhitespace()
                let close = isObject ? UInt8(ascii: "}") : UInt8(ascii: "]")
                if index < bytes.count, bytes[index] == close {
                    index += 1
                    nodes[node] = isObject ? .object([:]) : .array([])
                    completed = node
                    break
                }
                var frame = Frame(node: node, isObject: isObject)
                if isObject {
                    guard let key = parseMemberKey() else { return nil }
                    frame.pendingKey = key
                }
                stack.append(frame)
                continue
            case UInt8(ascii: "\""):
                guard let value = parseString(), let node = append(.string(value)) else { return nil }
                completed = node
            case UInt8(ascii: "t"):
                guard consumeLiteral("true"), let node = append(.bool(true)) else { return nil }
                completed = node
            case UInt8(ascii: "f"):
                guard consumeLiteral("false"), let node = append(.bool(false)) else { return nil }
                completed = node
            case UInt8(ascii: "n"):
                guard consumeLiteral("null"), let node = append(.null) else { return nil }
                completed = node
            default:
                guard let number = parseNumber(), let node = append(number) else { return nil }
                completed = node
            }

            // Hand the finished value to its container, closing every
            // container the value finishes in turn.
            while let value = completed {
                guard !stack.isEmpty else { return value }
                let top = stack.count - 1
                if stack[top].isObject {
                    stack[top].members[stack[top].pendingKey] = value
                } else {
                    stack[top].children.append(value)
                }
                skipWhitespace()
                guard index < bytes.count else { return nil }
                let byte = bytes[index]
                if byte == UInt8(ascii: ",") {
                    index += 1
                    if stack[top].isObject {
                        guard let key = parseMemberKey() else { return nil }
                        stack[top].pendingKey = key
                    }
                    completed = nil
                } else if byte == (stack[top].isObject ? UInt8(ascii: "}") : UInt8(ascii: "]")) {
                    index += 1
                    let frame = stack.removeLast()
                    nodes[frame.node] = frame.isObject ? .object(frame.members) : .array(frame.children)
                    completed = frame.node
                } else {
                    return nil
                }
            }
        }
    }

    private mutating func append(_ node: JSONDocument.Node) -> Int? {
        guard nodes.count < limits.maxNodes else { return nil }
        nodes.append(node)
        return nodes.count - 1
    }

    /// `"key" :` — leaves the index at the member's value.
    private mutating func parseMemberKey() -> String? {
        skipWhitespace()
        guard index < bytes.count, bytes[index] == UInt8(ascii: "\""), let key = parseString() else {
            return nil
        }
        skipWhitespace()
        guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
        index += 1
        return key
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private mutating func consumeLiteral(_ literal: String) -> Bool {
        let expected = Array(literal.utf8)
        guard bytes.count - index >= expected.count,
              bytes[index..<(index + expected.count)].elementsEqual(expected)
        else { return false }
        index += expected.count
        return true
    }

    /// A string starting at the opening quote. Invalid UTF-8 and unpaired
    /// surrogate escapes become U+FFFD; raw control characters are an error.
    private mutating func parseString() -> String? {
        index += 1
        var buffer: [UInt8] = []
        var runStart = index
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                buffer.append(contentsOf: bytes[runStart..<index])
                index += 1
                return String(decoding: buffer, as: UTF8.self)
            }
            if byte < 0x20 { return nil }
            if byte != UInt8(ascii: "\\") {
                index += 1
                continue
            }
            buffer.append(contentsOf: bytes[runStart..<index])
            index += 1
            guard index < bytes.count else { return nil }
            let escape = bytes[index]
            index += 1
            switch escape {
            case UInt8(ascii: "\""): buffer.append(0x22)
            case UInt8(ascii: "\\"): buffer.append(0x5C)
            case UInt8(ascii: "/"): buffer.append(0x2F)
            case UInt8(ascii: "b"): buffer.append(0x08)
            case UInt8(ascii: "f"): buffer.append(0x0C)
            case UInt8(ascii: "n"): buffer.append(0x0A)
            case UInt8(ascii: "r"): buffer.append(0x0D)
            case UInt8(ascii: "t"): buffer.append(0x09)
            case UInt8(ascii: "u"):
                guard let unit = parseHex4() else { return nil }
                var scalar = Unicode.Scalar(UInt32(unit))
                if (0xD800...0xDBFF).contains(unit) {
                    // A high surrogate needs its low half right after it.
                    let save = index
                    if index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"),
                       bytes[index + 1] == UInt8(ascii: "u") {
                        index += 2
                        if let low = parseHex4(), (0xDC00...0xDFFF).contains(low) {
                            let combined = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                            scalar = Unicode.Scalar(combined)
                        } else {
                            index = save
                        }
                    }
                }
                let resolved = scalar ?? "\u{FFFD}"
                buffer.append(contentsOf: String(resolved).utf8)
            default:
                return nil
            }
            runStart = index
        }
        return nil
    }

    private mutating func parseHex4() -> UInt16? {
        guard bytes.count - index >= 4 else { return nil }
        var value: UInt16 = 0
        for _ in 0..<4 {
            guard let digit = Self.hexValue(bytes[index]) else { return nil }
            value = value << 4 | UInt16(digit)
            index += 1
        }
        return value
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`, kept exact where it
    /// is an integer.
    private mutating func parseNumber() -> JSONDocument.Node? {
        let start = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard index < bytes.count, Self.isDigit(bytes[index]) else { return nil }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else {
            while index < bytes.count, Self.isDigit(bytes[index]) { index += 1 }
        }
        var integral = true
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            integral = false
            index += 1
            guard index < bytes.count, Self.isDigit(bytes[index]) else { return nil }
            while index < bytes.count, Self.isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            integral = false
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            guard index < bytes.count, Self.isDigit(bytes[index]) else { return nil }
            while index < bytes.count, Self.isDigit(bytes[index]) { index += 1 }
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        if integral {
            if let value = Int64(text) { return .integer(value) }
            if let value = UInt64(text) { return .unsignedInteger(value) }
        }
        guard let value = Double(text) else { return nil }
        return .double(value)
    }

    /// Steps over a container nested too deep to keep, checking only that its
    /// brackets balance and its strings are well-formed.
    private mutating func skipContainer() -> Bool {
        var open: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "{"):
                open.append(UInt8(ascii: "}"))
                index += 1
            case UInt8(ascii: "["):
                open.append(UInt8(ascii: "]"))
                index += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                guard let expected = open.popLast(), expected == byte else { return false }
                index += 1
                if open.isEmpty { return true }
            case UInt8(ascii: "\""):
                guard skipString() else { return false }
            default:
                index += 1
            }
        }
        return false
    }

    private mutating func skipString() -> Bool {
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                index += 1
                return true
            }
            if byte < 0x20 { return false }
            index += byte == UInt8(ascii: "\\") ? 2 : 1
        }
        return false
    }
}
