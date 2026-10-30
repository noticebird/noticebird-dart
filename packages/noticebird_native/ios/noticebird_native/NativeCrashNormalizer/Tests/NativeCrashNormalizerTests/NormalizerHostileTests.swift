import Foundation
import XCTest

@testable import NativeCrashNormalizer

/// Inputs no real MetricKit payload should contain. Each yields a bounded,
/// valid record or nil — never a crash, never an unbounded loop.
final class NormalizerHostileTests: XCTestCase {
    func testWhatIsNotAJSONObjectYieldsNothing() {
        for text in ["", "null", "[]", "42", "\"crash\"", "{", "{\"callStackTree\":", "\u{FEFF}{}"] {
            XCTAssertNil(normalize(text), "accepted \(text.debugDescription)")
        }
        XCTAssertNil(NativeCrashNormalizer.normalize(Data([0xFF, 0xFE, 0x00]), context: context()))
    }

    func testMissingKeysYieldTheRequiredFieldsOnly() throws {
        for text in ["{}", #"{"diagnosticMetaData":{}}"#, #"{"callStackTree":{}}"#,
                     #"{"callStackTree":{"callStackPerThread":true}}"#,
                     #"{"callStackTree":{"callStackPerThread":true,"callStacks":[]}}"#,
                     #"{"callStackTree":{"callStackPerThread":true,"callStacks":[{"threadAttributed":true}]}}"#,
                     #"{"callStackTree":{"callStackPerThread":true,"callStacks":[{"threadAttributed":true,"callStackRootFrames":[]}]}}"#] {
            let record = try XCTUnwrap(normalize(text), text)
            XCTAssertEqual(
                record.json.canonicalJSON,
                #"{"kind":"crash","occurredAtMs":1790344248000,"recordId":"\#(record.recordId)","recordVersion":1,"source":"metricKit"}"#,
                text
            )
            assertValidRecord(record)
        }
    }

    func testUnknownNumbersAreDroppedNotGuessed() throws {
        let record = try XCTUnwrap(normalize(
            #"{"diagnosticMetaData":{"exceptionType":99,"signal":64,"exceptionCode":-1,"terminationReason":"Namespace X, Code 0x1ffffffffffffffff","platformArchitecture":"riscv64"}}"#
        ))
        XCTAssertNil(record.fields.machException)
        XCTAssertNil(record.fields.signal)
        XCTAssertEqual(record.fields.code, "0xffffffffffffffff")
        XCTAssertNil(record.fields.terminationCode)
        assertValidRecord(record)

        for (text, code) in [(#"18446744073709551615"#, "0xffffffffffffffff"), ("1.0", "0x1"), ("50", "0x32")] {
            let record = try XCTUnwrap(normalize(#"{"diagnosticMetaData":{"exceptionCode":\#(text)}}"#))
            XCTAssertEqual(record.fields.code, code, text)
        }
        for text in ["18446744073709551616", "1.5", "1e400", "true", "\"50\"", "null", "{}"] {
            let record = try XCTUnwrap(normalize(#"{"diagnosticMetaData":{"exceptionCode":\#(text)}}"#))
            XCTAssertNil(record.fields.code, text)
        }
    }

    func testTerminationReasonsParseStrictly() {
        let cases: [(String, String?)] = [
            ("Namespace SPRINGBOARD, Code 0x8BADF00D", "0x8badf00d"),
            ("Namespace FRONTBOARD, Code 2343432205", "0x8badf00d"),
            ("Namespace SIGNAL, Code 0x0000000b", "0xb"),
            ("Namespace SIGNAL, Code 0xb Termination Reason: whatever", "0xb"),
            ("Namespace CODESIGNING, Code 2, Invalid Page", "0x2"),
            ("Namespace SIGNAL, Code 0x", nil),
            ("Namespace SIGNAL, Code 0xbadz", nil),
            ("Namespace SIGNAL, Code 99999999999999999999999", nil),
            ("Namespace SIGNAL", nil),
            ("code 0xb", nil),
            ("", nil),
        ]
        for (reason, expected) in cases {
            XCTAssertEqual(Sanitize.terminationCode(reason), expected, reason)
        }
        XCTAssertEqual(
            normalize(#"{"diagnosticMetaData":{"terminationReason":"Namespace SPRINGBOARD, Code 0x8badf00d"}}"#)?.kind,
            .watchdogKill
        )
        // Only a crash diagnostic can be a watchdog kill.
        XCTAssertEqual(
            normalize(#"{"diagnosticMetaData":{"terminationReason":"Namespace SPRINGBOARD, Code 0x8badf00d"}}"#, context(.hang))?.kind,
            .hang
        )
    }

    func testWrongTypesAreIgnored() throws {
        let text = #"""
        {"diagnosticMetaData":{"exceptionType":"1","signal":true,"exceptionCode":"0x32","terminationReason":11,
          "appVersion":1,"appBuildVersion":["78"],"pid":"4312","platformArchitecture":64,
          "objectiveCexceptionReason":"NSRangeException"},
         "callStackTree":{"callStackPerThread":"true","callStacks":[{"threadAttributed":true,"callStackRootFrames":[{}]}]}}
        """#
        let record = try XCTUnwrap(normalize(text))
        XCTAssertEqual(record.fields, NativeCrashRecord.Fields(kind: .crash, source: .metricKit, occurredAtMs: evidenceOccurredAtMs))
        assertValidRecord(record)

        let frames = #"""
        {"callStackTree":{"callStackPerThread":true,"callStacks":[{"threadAttributed":"yes"},7,
          {"threadAttributed":true,"callStackRootFrames":[{"binaryName":42,"binaryUUID":"4C4C44E5-5555-3144-A13D-CC7994841AAC","offsetIntoBinaryTextSegment":1,"subFrames":[
            {"binaryName":"Flutter","binaryUUID":"4C4C44E5-5555-3144-A13D-CC7994841AAC","offsetIntoBinaryTextSegment":"1","subFrames":[
              {"binaryName":"Flutter","binaryUUID":7,"offsetIntoBinaryTextSegment":2,"subFrames":[
                {"binaryName":"Flutter","binaryUUID":"not-a-uuid","offsetIntoBinaryTextSegment":3,"subFrames":[
                  {"binaryName":"Flutter","binaryUUID":"4C4C44E5-5555-3144-A13D-CC7994841AAC","offsetIntoBinaryTextSegment":-4,"subFrames":[
                    {"binaryName":"Flutter","binaryUUID":"4C4C44E5-5555-3144-A13D-CC7994841AAC","offsetIntoBinaryTextSegment":281474976710657,"subFrames":[
                      {"binaryName":"Flutter","binaryUUID":"4C4C44E5-5555-3144-A13D-CC7994841AAC","offsetIntoBinaryTextSegment":5,"subFrames":"none"}]}]}]}]}]}]}]}]}}
        """#
        let chained = try XCTUnwrap(normalize(frames))
        XCTAssertEqual(chained.fields.images, [
            .init(name: "Flutter", debugId: nil, inApp: true),
            .init(name: "Flutter", debugId: "4c4c44e555553144a13dcc7994841aac", inApp: true),
        ])
        XCTAssertEqual(chained.fields.frames, [
            .unknown, .unknown, .unknown, .inImage(0, offset: 3), .unknown, .unknown, .inImage(1, offset: 5),
        ])
        assertValidRecord(chained)
    }

    func testNullUUIDsAndNamelessBinariesAreFramesInNoImage() throws {
        let text = #"""
        {"callStackTree":{"callStackPerThread":true,"callStacks":[{"threadAttributed":true,"callStackRootFrames":[
          {"binaryName":"???","binaryUUID":"00000000-0000-0000-0000-000000000000","offsetIntoBinaryTextSegment":5172640176,"address":5172640176,"subFrames":[
            {"binaryName":"","binaryUUID":"4C4C44E5-5555-3144-A13D-CC7994841AAC","offsetIntoBinaryTextSegment":1,"subFrames":[
              {"binaryName":"Flutter","binaryUUID":"","offsetIntoBinaryTextSegment":2,"subFrames":[
                {"binaryName":"/private/var/containers/Bundle/Application/0000/Runner.app/Frameworks/Flutter.framework/Flutter","binaryUUID":"4C4C44E5-5555-3144-A13D-CC7994841AAC","offsetIntoBinaryTextSegment":3}]}]}]}]}]}}
        """#
        let record = try XCTUnwrap(normalize(text))
        XCTAssertEqual(record.fields.frames, [.unknown, .unknown, .unknown, .inImage(0, offset: 3)])
        XCTAssertEqual(record.fields.images.map(\.name), ["Flutter"])
        XCTAssertFalse(record.json.canonicalJSON.contains("private"))
        assertValidRecord(record)
    }

    func testTenThousandChainedFramesKeepTheTopSixtyFour() throws {
        let record = try XCTUnwrap(normalize(deepChainJSON(depth: 10_000)))
        XCTAssertEqual(record.fields.frames.count, 64)
        XCTAssertEqual(record.fields.frames.first, .inImage(0, offset: 0))
        XCTAssertEqual(record.fields.frames.last, .inImage(0, offset: 63))
        XCTAssertEqual(record.fields.images.count, 1)
        XCTAssertEqual(record.fields.images.first?.arch, .arm64)
        assertValidRecord(record)
    }

    func testTenThousandRootFramesAndCallStacksStayBounded() throws {
        let frame = #"{"binaryName":"Flutter","binaryUUID":"4C4C44E5-5555-3144-A13D-CC7994841AAC","offsetIntoBinaryTextSegment":7,"sampleCount":1}"#
        let roots = Array(repeating: frame, count: 10_000).joined(separator: ",")
        let manyRoots = #"{"callStackTree":{"callStackPerThread":false,"callStacks":[{"threadAttributed":true,"callStackRootFrames":[\#(roots)]}]}}"#
        let aggregated = try XCTUnwrap(normalize(manyRoots))
        XCTAssertEqual(aggregated.fields.frames, [.inImage(0, offset: 7)])
        assertValidRecord(aggregated)

        let stack = #"{"threadAttributed":false,"callStackRootFrames":[\#(frame)]}"#
        let stacks = Array(repeating: stack, count: 10_000).joined(separator: ",")
        let manyStacks = #"{"callStackTree":{"callStackPerThread":true,"callStacks":[\#(stacks),{"threadAttributed":true,"callStackRootFrames":[\#(frame)]}]}}"#
        let perThread = try XCTUnwrap(normalize(manyStacks))
        XCTAssertEqual(perThread.fields.frames, [.inImage(0, offset: 7)])
        assertValidRecord(perThread)
    }

    func testAChainDeeperThanTheParserKeepsStillYieldsItsTop() throws {
        let record = try XCTUnwrap(normalize(deepChainJSON(depth: 60_000)))
        XCTAssertEqual(record.fields.frames.count, 64)
        assertValidRecord(record)
    }

    func testAnAggregatedTreeDeeperThanTheParserKeepsHasNoKnownTop() throws {
        // The leaf, and so the top of the stack, lies beyond the kept depth:
        // no frames rather than wrong ones; the diagnostic itself stays.
        let record = try XCTUnwrap(normalize(deepChainJSON(depth: 60_000, perThread: false), context(.hang, hangDurationMs: 250)))
        XCTAssertEqual(record.fields.kind, .hang)
        XCTAssertEqual(record.fields.durationMs, 250)
        XCTAssertTrue(record.fields.frames.isEmpty)
        XCTAssertTrue(record.fields.images.isEmpty)
        assertValidRecord(record)
    }

    func testAnAggregatedTreeWithinTheLimitKeepsItsInnermostFrames() throws {
        let record = try XCTUnwrap(normalize(deepChainJSON(depth: 1_000, perThread: false), context(.diskWriteException)))
        XCTAssertEqual(record.fields.frames.count, 64)
        XCTAssertEqual(record.fields.frames.first, .inImage(0, offset: 999))
        XCTAssertEqual(record.fields.frames.last, .inImage(0, offset: 936))
        assertValidRecord(record)
    }

    func testAggregatedTreesWithoutAnAttributedStackUseOnlyASoleStack() throws {
        let frame = #"{"binaryName":"Flutter","binaryUUID":"4C4C44E5-5555-3144-A13D-CC7994841AAC","offsetIntoBinaryTextSegment":7,"sampleCount":1}"#
        let sole = #"{"callStackTree":{"callStackPerThread":false,"callStacks":[{"callStackRootFrames":[\#(frame)]}]}}"#
        XCTAssertEqual(normalize(sole)?.fields.frames, [.inImage(0, offset: 7)])
        let two = #"{"callStackTree":{"callStackPerThread":false,"callStacks":[{"callStackRootFrames":[\#(frame)]},{"callStackRootFrames":[\#(frame)]}]}}"#
        XCTAssertEqual(normalize(two)?.fields.frames, [])
        let unattributedChain = #"{"callStackTree":{"callStackPerThread":true,"callStacks":[{"callStackRootFrames":[\#(frame)]}]}}"#
        XCTAssertEqual(normalize(unattributedChain)?.fields.frames, [])
    }

    func testMoreThanThirtyTwoImagesEndTheStackAtTheLastImageThatFits() throws {
        var frames: [String] = []
        for index in 0..<50 {
            let hex = String(index + 1, radix: 16, uppercase: true)
            let uuid = String(repeating: "0", count: 8 - hex.count) + hex + "-0000-3000-8000-000000000000"
            frames.append(#"{"binaryName":"lib\#(index).dylib","binaryUUID":"\#(uuid)","offsetIntoBinaryTextSegment":\#(index),"subFrames":["#)
        }
        let text = #"{"callStackTree":{"callStackPerThread":true,"callStacks":[{"threadAttributed":true,"callStackRootFrames":["#
            + frames.joined() + "]" + String(repeating: "}]", count: 49) + "}" + "]}]}}"
        let record = try XCTUnwrap(normalize(text))
        XCTAssertEqual(record.fields.images.count, 32)
        XCTAssertEqual(record.fields.frames.count, 32)
        XCTAssertEqual(record.fields.frames.last, .inImage(31, offset: 31))
        assertValidRecord(record)
    }

    func testHugeStringsAreCutToTheirRules() throws {
        let hugeMessage = String(repeating: "é", count: 3_000_000) // 6 MB of UTF-8
        let hugeName = String(repeating: "N", count: 100_000)
        let text = #"""
        {"diagnosticMetaData":{"exceptionType":10,"signal":6,"appVersion":"\#(hugeName)",
          "objectiveCexceptionReason":{"exceptionName":"My Custom Exception \#(hugeName)","composedMessage":"\#(hugeMessage)"}},
         "callStackTree":{"callStackPerThread":true,"callStacks":[{"threadAttributed":true,"callStackRootFrames":[
           {"binaryName":"\#(hugeName) bin","binaryUUID":"4C4C44E5-5555-3144-A13D-CC7994841AAC","offsetIntoBinaryTextSegment":1}]}]}}
        """#
        let record = try XCTUnwrap(normalize(text))
        XCTAssertEqual(record.fields.exceptionMessage?.utf16.count, 1024)
        XCTAssertEqual(record.fields.exceptionClass, "My_Custom_Exception_" + String(repeating: "N", count: 140))
        XCTAssertEqual(record.fields.images.first?.name, String(repeating: "N", count: 100))
        XCTAssertNil(record.fields.appVersion)
        assertValidRecord(record)
    }

    func testMessagesAreNeverCutInsideACharacter() throws {
        let message = String(repeating: "a", count: 1023) + "😀" + "tail"
        let record = try XCTUnwrap(normalize(
            #"{"diagnosticMetaData":{"objectiveCexceptionReason":{"exceptionName":"E","composedMessage":"\#(message)"}}}"#
        ))
        XCTAssertEqual(record.fields.exceptionMessage, String(repeating: "a", count: 1023))
        XCTAssertEqual(Sanitize.exceptionMessage(""), nil)
        XCTAssertEqual(Sanitize.exceptionMessage("\u{0065}\u{0301}"), "\u{0065}\u{0301}")
    }

    func testExceptionNameFallsBackToTheExceptionType() throws {
        let record = try XCTUnwrap(normalize(
            #"{"diagnosticMetaData":{"objectiveCexceptionReason":{"exceptionName":"","exceptionType":"NSException","composedMessage":""}}}"#
        ))
        XCTAssertEqual(record.fields.exceptionClass, "NSException")
        XCTAssertNil(record.fields.exceptionMessage)
    }

    func testMeasurementsAreBoundedOrOmitted() throws {
        let cases: [(Double?, Int64?)] = [(nil, nil), (-1, nil), (.nan, nil), (.infinity, nil),
                                         (0, 0), (0.4, 0), (1_000_000, 600_000), (599_999.6, 600_000)]
        for (value, expected) in cases {
            XCTAssertEqual(normalize("{}", context(.hang, hangDurationMs: value))?.fields.durationMs, expected, "\(String(describing: value))")
        }
        XCTAssertEqual(
            normalize("{}", context(.diskWriteException, bytesWritten: 1e300))?.fields.bytesWritten,
            NativeCrashRecord.maxBytesWritten
        )
    }

    func testMetadataOutsideItsRangeIsDropped() throws {
        let record = try XCTUnwrap(normalize(#"{"diagnosticMetaData":{"pid":0,"appVersion":"","appBuildVersion":"1"}}"#))
        XCTAssertNil(record.fields.pid)
        XCTAssertNil(record.fields.appVersion)
        XCTAssertEqual(record.fields.appBuild, "1")
        XCTAssertNil(normalize(#"{"diagnosticMetaData":{"pid":4294967296}}"#)?.fields.pid)
    }

    func testTimesOutsideTheContractYieldNothing() {
        XCTAssertNil(normalize("{}", context(occurredAtMs: -1)))
        XCTAssertNil(normalize("{}", context(occurredAtMs: .max)))
    }

    func testDuplicateKeysAndDeepGarbageInOtherBranchesDoNotMatter() throws {
        let garbage = String(repeating: #"{"x":["#, count: 50_000) + String(repeating: "]}", count: 50_000)
        let text = #"{"virtualMemoryRegionInfo":\#(garbage),"diagnosticMetaData":{"signal":1,"signal":10}}"#
        let record = try XCTUnwrap(normalize(text))
        XCTAssertEqual(record.fields.signal, "SIGBUS")
        assertValidRecord(record)
    }
}
