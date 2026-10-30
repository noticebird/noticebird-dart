import Foundation

/// A small JSON value for the collector's own files and for records: exact
/// integers, no floating point, and one canonical encoding.
public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Parses one of the collector's own small files, or returns nil when it
    /// is not well-formed JSON of this shape (a floating-point number, an
    /// integer beyond 64 bits, more than 16 levels, more than 1 MiB).
    public init?(parsing data: Data) {
        guard let document = JSONDocument.parse(data, limits: .storedFile),
              let value = JSONValue.convert(document, document.root, depth: 0)
        else { return nil }
        self = value
    }

    /// The document's depth is capped at 16 by its limits, so the recursion
    /// here is too.
    private static func convert(_ document: JSONDocument, _ index: Int, depth: Int) -> JSONValue? {
        guard depth <= JSONDocument.Limits.storedFile.maxDepth, let node = document.node(index) else {
            return nil
        }
        switch node {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .integer(let value): return .integer(value)
        case .string(let value): return .string(value)
        case .unsignedInteger, .double, .truncated: return nil
        case .array(let children):
            var values: [JSONValue] = []
            values.reserveCapacity(children.count)
            for child in children {
                guard let value = convert(document, child, depth: depth + 1) else { return nil }
                values.append(value)
            }
            return .array(values)
        case .object(let members):
            var values: [String: JSONValue] = [:]
            for (key, child) in members {
                guard let value = convert(document, child, depth: depth + 1) else { return nil }
                values[key] = value
            }
            return .object(values)
        }
    }

    // MARK: - Canonical encoding

    /// Keys sorted at every depth (by UTF-16 code units, as Dart sorts
    /// strings), no whitespace, strings escaped as Dart's `jsonEncode` does.
    public var canonicalJSON: String {
        var output = ""
        encode(into: &output)
        return output
    }

    public var canonicalData: Data { Data(canonicalJSON.utf8) }

    private func encode(into output: inout String) {
        switch self {
        case .null:
            output += "null"
        case .bool(let value):
            output += value ? "true" : "false"
        case .integer(let value):
            output += String(value)
        case .string(let value):
            JSONValue.encodeString(value, into: &output)
        case .array(let values):
            output += "["
            for (position, value) in values.enumerated() {
                if position > 0 { output += "," }
                value.encode(into: &output)
            }
            output += "]"
        case .object(let members):
            output += "{"
            let keys = members.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            for (position, key) in keys.enumerated() {
                if position > 0 { output += "," }
                JSONValue.encodeString(key, into: &output)
                output += ":"
                members[key]?.encode(into: &output)
            }
            output += "}"
        }
    }

    private static func encodeString(_ value: String, into output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\u{08}": output += "\\b"
            case "\u{09}": output += "\\t"
            case "\u{0A}": output += "\\n"
            case "\u{0C}": output += "\\f"
            case "\u{0D}": output += "\\r"
            default:
                if scalar.value < 0x20 {
                    let digits = String(scalar.value, radix: 16)
                    output += "\\u" + String(repeating: "0", count: 4 - digits.count) + digits
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }

    // MARK: - Platform channel values

    /// The value as standard-codec-compatible Foundation objects: `Bool`,
    /// `Int`, `String`, `[Any]`, `[String: Any]`, `NSNull`.
    public var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .integer(let value): return Int(truncatingIfNeeded: value)
        case .string(let value): return value
        case .array(let values): return values.map(\.foundationObject)
        case .object(let members): return members.mapValues(\.foundationObject)
        }
    }

    // MARK: - Access

    public var objectValue: [String: JSONValue]? {
        if case .object(let members) = self { return members }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var integerValue: Int64? {
        if case .integer(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}
