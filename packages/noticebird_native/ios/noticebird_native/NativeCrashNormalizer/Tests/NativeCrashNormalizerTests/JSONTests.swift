import Foundation
import XCTest

@testable import NativeCrashNormalizer

final class JSONDocumentTests: XCTestCase {
    private func parse(_ text: String, limits: JSONDocument.Limits = .diagnostic) -> JSONDocument? {
        JSONDocument.parse(Data(text.utf8), limits: limits)
    }

    func testParsesEveryKindOfValue() throws {
        let document = try XCTUnwrap(parse(#" {"a": [1, -2, 18446744073709551615, 1.5, 1e3, true, false, null, "x\n\u00e9\ud83d\ude00"]} "#))
        let root = try XCTUnwrap(document.object(document.root))
        let values = try XCTUnwrap(document.array(root["a"]))
        XCTAssertEqual(values.count, 9)
        XCTAssertEqual(document.integer(values[0]), 1)
        XCTAssertEqual(document.integer(values[1]), -2)
        XCTAssertEqual(document.node(values[2]), .unsignedInteger(UInt64.max))
        XCTAssertNil(document.integer(values[3]))
        XCTAssertEqual(document.integer(values[4]), 1000)
        XCTAssertEqual(document.bool(values[5]), true)
        XCTAssertEqual(document.bool(values[6]), false)
        XCTAssertEqual(document.node(values[7]), .null)
        XCTAssertEqual(document.string(values[8]), "x\né😀")
    }

    func testBooleansAreNeverNumbers() throws {
        let document = try XCTUnwrap(parse(#"[true, 1, 0, false]"#))
        let values = try XCTUnwrap(document.array(document.root))
        XCTAssertNil(document.integer(values[0]))
        XCTAssertNil(document.bool(values[1]))
        XCTAssertNil(document.bool(values[2]))
        XCTAssertNil(document.unsignedBitPattern(values[3]))
    }

    func testNegativeIntegersKeepTheirBitPattern() throws {
        let document = try XCTUnwrap(parse("[-1]"))
        let values = try XCTUnwrap(document.array(document.root))
        XCTAssertEqual(document.unsignedBitPattern(values[0]), UInt64.max)
    }

    func testRejectsMalformedText() {
        for text in ["", "{", "[1,]", "{\"a\" 1}", "{\"a\":1,}", "01", "1.", "-", "tru", "\"\u{01}\"", "[1] 2",
                     "\"abc", "{\"a\":\"\\q\"}", "[\"\\u12\"]", "{1:2}", "[}"] {
            XCTAssertNil(parse(text), "accepted \(text)")
        }
    }

    func testUnpairedSurrogateEscapesBecomeReplacementCharacters() throws {
        let document = try XCTUnwrap(parse(#"["\ud800x", "\udc00"]"#))
        let values = try XCTUnwrap(document.array(document.root))
        XCTAssertEqual(document.string(values[0]), "\u{FFFD}x")
        XCTAssertEqual(document.string(values[1]), "\u{FFFD}")
    }

    func testInvalidUTF8IsRepaired() throws {
        var bytes = [UInt8]("[\"a".utf8)
        bytes.append(0xFF)
        bytes.append(contentsOf: "b\"]".utf8)
        let document = try XCTUnwrap(JSONDocument.parse(Data(bytes), limits: .diagnostic))
        let values = try XCTUnwrap(document.array(document.root))
        XCTAssertEqual(document.string(values[0]), "a\u{FFFD}b")
    }

    func testContainersBeyondTheDepthLimitAreTruncatedNotRejected() throws {
        let limits = JSONDocument.Limits(maxBytes: 1 << 20, maxDepth: 3, maxNodes: 1000)
        let document = try XCTUnwrap(parse(#"{"a":{"b":{"c":{"d":[1,{"e":"]}"}]}}}}"#, limits: limits))
        let a = try XCTUnwrap(document.object(document.root)?["a"])
        let b = try XCTUnwrap(document.object(a)?["b"])
        let c = document.object(b)?["c"]
        XCTAssertTrue(document.isTruncated(c))
        // A skipped region must still balance.
        XCTAssertNil(parse(#"{"a":{"b":{"c":{"d":[1}}}}"#, limits: limits))
    }

    func testNestingFarBeyondAnyStackIsSafe() throws {
        let depth = 200_000
        let text = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        let document = try XCTUnwrap(parse(text))
        XCTAssertLessThanOrEqual(document.nodes.count, JSONDocument.Limits.diagnostic.maxDepth + 1)
        XCTAssertNil(parse(String(repeating: "[", count: depth)))
    }

    func testSizeAndNodeLimitsRejectTheWholeText() {
        let small = JSONDocument.Limits(maxBytes: 16, maxDepth: 8, maxNodes: 4)
        XCTAssertNil(parse(#"["0123456789abcdef"]"#, limits: small))
        XCTAssertNil(parse("[1,2,3,4]", limits: small))
        XCTAssertNotNil(parse("[1,2,3]", limits: small))
    }

    func testChildrenAlwaysFollowTheirContainer() throws {
        let document = try XCTUnwrap(parse(#"{"a":[{"b":[1,2]},{"c":{}}],"d":3}"#))
        for (index, node) in document.nodes.enumerated() {
            switch node {
            case .array(let children): XCTAssertTrue(children.allSatisfy { $0 > index })
            case .object(let members): XCTAssertTrue(members.values.allSatisfy { $0 > index })
            default: break
            }
        }
    }
}

final class JSONValueTests: XCTestCase {
    func testCanonicalEncodingSortsKeysAtEveryDepthWithoutWhitespace() {
        let value = JSONValue.object([
            "b": .array([.object(["z": .integer(1), "a": .null])]),
            "a": .bool(true),
            "B": .integer(-7),
        ])
        XCTAssertEqual(value.canonicalJSON, #"{"B":-7,"a":true,"b":[{"a":null,"z":1}]}"#)
    }

    func testCanonicalEncodingEscapesAsDartDoes() {
        let value = JSONValue.string("q\"\\/\u{08}\u{09}\u{0A}\u{0C}\u{0D}\u{01}\u{1F}é😀")
        XCTAssertEqual(value.canonicalJSON, #""q\"\\/\b\t\n\f\r\u0001\u001fé😀""#)
    }

    func testKeysSortByUTF16CodeUnits() {
        // U+FF5E sorts after U+1F600 by scalar value but before it in UTF-16.
        let value = JSONValue.object(["\u{1F600}": .integer(1), "\u{FF5E}": .integer(2)])
        XCTAssertEqual(value.canonicalJSON, "{\"\u{1F600}\":1,\"\u{FF5E}\":2}")
    }

    func testParsingRoundTripsAndRejectsWhatItCannotHold() throws {
        let text = #"{"a":[1,"x",false,null,{"b":-9223372036854775808}]}"#
        let value = try XCTUnwrap(JSONValue(parsing: Data(text.utf8)))
        XCTAssertEqual(value.canonicalJSON, text)
        XCTAssertNil(JSONValue(parsing: Data("[1.5]".utf8)))
        XCTAssertNil(JSONValue(parsing: Data("[18446744073709551615]".utf8)))
        XCTAssertNil(JSONValue(parsing: Data((String(repeating: "[", count: 20) + String(repeating: "]", count: 20)).utf8)))
    }

    func testFoundationObjectsUseStandardCodecTypes() throws {
        let value = JSONValue.object(["i": .integer(42), "b": .bool(true), "s": .string("x"), "a": .array([.object([:])])])
        let object = try XCTUnwrap(value.foundationObject as? [String: Any])
        XCTAssertEqual(object["i"] as? Int, 42)
        XCTAssertEqual(object["b"] as? Bool, true)
        XCTAssertEqual(object["s"] as? String, "x")
        XCTAssertEqual((object["a"] as? [Any])?.count, 1)
        XCTAssertNotNil((object["a"] as? [Any])?.first as? [String: Any])
    }
}
