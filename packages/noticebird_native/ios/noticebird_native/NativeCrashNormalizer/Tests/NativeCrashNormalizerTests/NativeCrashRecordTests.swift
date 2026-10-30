import Foundation
import XCTest

@testable import NativeCrashNormalizer

final class NativeCrashRecordTests: XCTestCase {
    private func sampleFields() -> NativeCrashRecord.Fields {
        var fields = NativeCrashRecord.Fields(kind: .crash, source: .metricKit, occurredAtMs: evidenceOccurredAtMs)
        fields.machException = "EXC_BAD_ACCESS"
        fields.signal = "SIGBUS"
        fields.code = "0x32"
        fields.images = [NativeCrashRecord.Image(name: "Flutter", debugId: "4c4c44e555553144a13dcc7994841aac", inApp: true)]
        fields.frames = [.unknown, .inImage(0, offset: 10_481_952)]
        fields.pid = 4312
        return fields
    }

    func testIdIsTheDigestOfTheCanonicalJSONWithoutTheId() throws {
        let record = try XCTUnwrap(NativeCrashRecord(fields: sampleFields()))
        var json = try XCTUnwrap(record.json.objectValue)
        XCTAssertEqual(json.removeValue(forKey: "recordId"), .string(record.recordId))
        XCTAssertEqual(record.recordId, SHA256.hexDigest(JSONValue.object(json).canonicalJSON.utf8))
        XCTAssertEqual(NativeCrashRecord(fields: sampleFields())?.recordId, record.recordId)
    }

    func testUnknownValuesAreOmittedNotNull() throws {
        let record = try XCTUnwrap(NativeCrashRecord(fields: .init(kind: .hang, source: .metricKit, occurredAtMs: 1)))
        XCTAssertEqual(
            record.json.canonicalJSON,
            #"{"kind":"hang","occurredAtMs":1,"recordId":"\#(record.recordId)","recordVersion":1,"source":"metricKit"}"#
        )
    }

    func testDecodesWhatItEncodes() throws {
        let record = try XCTUnwrap(NativeCrashRecord(fields: sampleFields()))
        let json = try XCTUnwrap(JSONValue(parsing: record.json.canonicalData))
        XCTAssertEqual(NativeCrashRecord(json: json), record)
    }

    func testDecodingRejectsAnythingOffContract() throws {
        let record = try XCTUnwrap(NativeCrashRecord(fields: sampleFields()))
        let object = try XCTUnwrap(record.json.objectValue)
        func rejects(_ change: (inout [String: JSONValue]) -> Void, _ message: String) {
            var copy = object
            change(&copy)
            XCTAssertNil(NativeCrashRecord(json: .object(copy)), message)
        }
        rejects({ $0["claimedUntilMs"] = .integer(1) }, "unknown key")
        rejects({ $0["recordVersion"] = .integer(2) }, "other version")
        rejects({ $0.removeValue(forKey: "recordId") }, "no id")
        rejects({ $0["recordId"] = .string(String(repeating: "A", count: 64)) }, "id not lowercase hex")
        rejects({ $0["recordId"] = .string(String(repeating: "0", count: 63)) }, "id too short")
        rejects({ $0["kind"] = .string("oom") }, "unknown kind")
        rejects({ $0["signal"] = .string("SIGbus") }, "signal pattern")
        rejects({ $0["code"] = .string("0X32") }, "code pattern")
        rejects({ $0["pid"] = .string("4312") }, "pid type")
        rejects({ $0["frames"] = .array([.object(["image": .integer(1), "offset": .integer(0)])]) }, "image index")
        rejects({ $0["frames"] = .array([.object(["image": .integer(0)])]) }, "image without offset")
        rejects({ $0["images"] = .array([.object(["name": .string("a/b"), "inApp": .bool(true)])]) }, "image name")
        rejects({ $0["appVersion"] = .string("") }, "empty string")
        XCTAssertNil(NativeCrashRecord(json: .array([])))
    }

    func testStrippingTheMessageKeepsTheIdItWasCreatedWith() throws {
        var fields = sampleFields()
        fields.exceptionClass = "NSRangeException"
        fields.exceptionMessage = "index 3 beyond bounds [0 .. 2]"
        let record = try XCTUnwrap(NativeCrashRecord(fields: fields))
        let stripped = record.withoutExceptionMessage()
        XCTAssertEqual(stripped.recordId, record.recordId)
        XCTAssertNil(stripped.fields.exceptionMessage)
        XCTAssertEqual(stripped.fields.exceptionClass, "NSRangeException")
        XCTAssertNotEqual(stripped.recordId, NativeCrashRecord(fields: stripped.fields)?.recordId, "no longer the digest")
        let json = try XCTUnwrap(JSONValue(parsing: stripped.json.canonicalData))
        XCTAssertEqual(NativeCrashRecord(json: json), stripped, "decodes under the stored id")

        let plain = try XCTUnwrap(NativeCrashRecord(fields: sampleFields()))
        XCTAssertEqual(plain.withoutExceptionMessage(), plain, "nothing to strip")
    }

    func testFieldRulesFollowTheContract() {
        func invalid(_ change: (inout NativeCrashRecord.Fields) -> Void, _ message: String) {
            var fields = sampleFields()
            change(&fields)
            XCTAssertNil(NativeCrashRecord(fields: fields), message)
        }
        invalid({ $0.durationMs = 1 }, "durationMs outside a hang")
        invalid({ $0.bytesWritten = 1 }, "bytesWritten outside a disk-write exception")
        invalid({ $0.images.append(.init(name: "Unused", inApp: false)) }, "unreferenced image")
        invalid({ $0.images[0].debugId = "4c4c44e5-5555-3144-a13d-cc7994841aac" }, "dashed debug id")
        invalid({ $0.frames[1].offset = NativeCrashRecord.maxOffset + 1 }, "offset beyond 2^48")
        invalid({ $0.frames = Array(repeating: .unknown, count: 65) + [.inImage(0, offset: 0)] }, "more than 64 frames")
        invalid({ $0.exceptionMessage = String(repeating: "x", count: 1025) }, "message beyond 1024")
        invalid({ $0.exceptionMessage = "" }, "empty message")
        invalid({ $0.exceptionClass = "Foo Bar" }, "exception class pattern")
        invalid({ $0.runId = "ABC" }, "run id pattern")
        invalid({ $0.occurredAtMs = -1 }, "negative time")
        invalid({ $0.frames.append(.init(symbol: "a", line: 0)) }, "line below 1")
        invalid({ $0.frames.append(.init(image: 0, offset: 1, symbol: "a", line: 3)) }, "line with an image")

        var hang = NativeCrashRecord.Fields(kind: .hang, source: .metricKit, occurredAtMs: 0)
        hang.durationMs = NativeCrashRecord.maxHangDurationMs
        XCTAssertNotNil(NativeCrashRecord(fields: hang))
        hang.durationMs = NativeCrashRecord.maxHangDurationMs + 1
        XCTAssertNil(NativeCrashRecord(fields: hang))
    }

    func testChannelValueIsAStandardCodecMap() throws {
        let record = try XCTUnwrap(NativeCrashRecord(fields: sampleFields()))
        let map = record.channelValue
        XCTAssertEqual(map["recordVersion"] as? Int, 1)
        XCTAssertEqual(map["recordId"] as? String, record.recordId)
        XCTAssertEqual(map["occurredAtMs"] as? Int, Int(evidenceOccurredAtMs))
        let frames = try XCTUnwrap(map["frames"] as? [[String: Any]])
        XCTAssertTrue(frames[0].isEmpty)
        XCTAssertEqual(frames[1]["offset"] as? Int, 10_481_952)
        let images = try XCTUnwrap(map["images"] as? [[String: Any]])
        XCTAssertEqual(images[0]["inApp"] as? Bool, true)
        XCTAssertNil(map["claimedUntilMs"])
    }
}
