import Foundation
import XCTest

@testable import NativeCrashNormalizer

/// The binaries a Flutter app bundle ships: the executable and `Frameworks/`.
let flutterAppBinaries: Set<String> = ["Runner", "Flutter", "App", "CSQLite", "sqlite3"]

/// 2026-09-25T13:50:48Z, the first evidence crash.
let evidenceOccurredAtMs: Int64 = 1_790_344_248_000

func fixtureData(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
    let url = try XCTUnwrap(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
        "Missing fixture \(name)",
        file: file,
        line: line
    )
    return try Data(contentsOf: url)
}

func context(
    _ kind: DiagnosticKind = .crash,
    strict: Bool = false,
    hangDurationMs: Double? = nil,
    bytesWritten: Double? = nil,
    occurredAtMs: Int64 = evidenceOccurredAtMs
) -> NormalizationContext {
    NormalizationContext(
        kind: kind,
        occurredAtMs: occurredAtMs,
        inAppBinaryNames: flutterAppBinaries,
        strict: strict,
        hangDurationMs: hangDurationMs,
        bytesWritten: bytesWritten
    )
}

func normalize(_ json: String, _ context: NormalizationContext = context()) -> NativeCrashRecord? {
    NativeCrashNormalizer.normalize(Data(json.utf8), context: context)
}

/// Every record the normalizer returns must be bounded, valid, and decode
/// back to itself through the contract's JSON.
func assertValidRecord(_ record: NativeCrashRecord?, file: StaticString = #filePath, line: UInt = #line) {
    guard let record else { return }
    XCTAssertLessThanOrEqual(record.fields.frames.count, 64, file: file, line: line)
    XCTAssertLessThanOrEqual(record.fields.images.count, 32, file: file, line: line)
    let referenced = Set(record.fields.frames.compactMap(\.image))
    XCTAssertEqual(referenced, Set(record.fields.images.indices), "every image referenced", file: file, line: line)
    let data = record.json.canonicalData
    guard let json = JSONValue(parsing: data) else {
        return XCTFail("record JSON does not parse back", file: file, line: line)
    }
    XCTAssertEqual(NativeCrashRecord(json: json), record, "record decodes back to itself", file: file, line: line)
    XCTAssertEqual(record.recordId.count, 64, file: file, line: line)
}

/// Every `address` value anywhere in a (shallow enough) JSON text.
func allAddresses(in data: Data) throws -> [Int64] {
    var addresses: [Int64] = []
    var pending: [Any] = [try JSONSerialization.jsonObject(with: data)]
    while let value = pending.popLast() {
        if let object = value as? [String: Any] {
            for (key, member) in object {
                if key == "address", let number = member as? NSNumber {
                    addresses.append(number.int64Value)
                } else {
                    pending.append(member)
                }
            }
        } else if let array = value as? [Any] {
            pending.append(contentsOf: array)
        }
    }
    return addresses
}

/// Every integer anywhere in a record's JSON.
func integers(in value: JSONValue) -> Set<Int64> {
    switch value {
    case .integer(let integer): return [integer]
    case .array(let values): return values.reduce(into: []) { $0.formUnion(integers(in: $1)) }
    case .object(let members): return members.values.reduce(into: []) { $0.formUnion(integers(in: $1)) }
    default: return []
    }
}

/// A per-thread call stack tree: one attributed chain of [depth] frames,
/// built as text so its nesting can exceed any recursive parser's.
func deepChainJSON(depth: Int, perThread: Bool = true, binaryName: String = "Flutter") -> String {
    var text = #"{"callStackTree":{"callStackPerThread":\#(perThread),"callStacks":[{"threadAttributed":true,"callStackRootFrames":["#
    let frame = #"{"binaryName":"\#(binaryName)","binaryUUID":"4C4C44E5-5555-3144-A13D-CC7994841AAC","sampleCount":1,"address":4401295648,"offsetIntoBinaryTextSegment":"#
    text.reserveCapacity(depth * (frame.count + 24))
    for level in 0..<depth {
        text += frame + String(level) + #","subFrames":["#
    }
    text += "]"
    text += String(repeating: "}]", count: depth - 1)
    text += "}"
    text += #"]}]},"diagnosticMetaData":{"exceptionType":1,"signal":11,"platformArchitecture":"arm64"}}"#
    return text
}
