import Foundation
import XCTest

@testable import NativeCrashNormalizer

/// The recorded shapes: Apple's documented sample and fixtures built from the
/// 2026-09-25 evidence reports.
final class NormalizerFixtureTests: XCTestCase {
    /// The first evidence crash, byte for byte: EXC_BAD_ACCESS (SIGBUS), code
    /// 50 (KERN_CODESIGN_ERROR), the top frame in JIT code of no image, a
    /// second thread left out. Cross-checked by an independent Python
    /// implementation of the mapping, canonical JSON and SHA-256.
    func testEvidenceCrashYieldsTheExactRecord() throws {
        let record = try XCTUnwrap(
            NativeCrashNormalizer.normalize(try fixtureData("crash_sigbus_jit_evidence"), context: context())
        )
        let expected = #"{"appBuild":"78","appVersion":"0.0.10","code":"0x32","frames":[{},{"image":0,"offset":10481952},{"image":0,"offset":5402168},{"image":0,"offset":5395532},{"image":0,"offset":5392396},{"image":0,"offset":1148424},{"image":0,"offset":1315432},{"image":0,"offset":1314244},{"image":0,"offset":198660},{"image":0,"offset":204968},{"image":1,"offset":2374492},{"image":1,"offset":2362780},{"image":1,"offset":2363000},{"image":2,"offset":6568},{"image":2,"offset":111076},{"image":2,"offset":232976},{"image":2,"offset":67940},{"image":2,"offset":67748},{"image":3,"offset":663600},{"image":3,"offset":194052},{"image":3,"offset":189772},{"image":4,"offset":5272},{"image":5,"offset":1184324},{"image":5,"offset":573784},{"image":5,"offset":2721304},{"image":1,"offset":20248},{"image":6,"offset":19484}],"images":[{"debugId":"4c4c44e555553144a13dcc7994841aac","inApp":true,"name":"Flutter"},{"debugId":"ac763912ffd53edfa533b144a2b68e38","inApp":true,"name":"Runner"},{"arch":"arm64e","debugId":"e1a24fa021603366ae7e420f0fa3c5bc","inApp":false,"name":"libdispatch.dylib"},{"arch":"arm64e","debugId":"dda24297289c30ec82284c426aad4d7f","inApp":false,"name":"CoreFoundation"},{"arch":"arm64e","debugId":"d0a89589718a3d3a96dad2c99bb19040","inApp":false,"name":"GraphicsServices"},{"arch":"arm64e","debugId":"9ee8c19aa3703599823b34b84131aad7","inApp":false,"name":"UIKitCore"},{"arch":"arm64e","debugId":"02f772fd9e3835a4b9fa9cce3a090e6d","inApp":false,"name":"dyld"}],"kind":"crash","machException":"EXC_BAD_ACCESS","occurredAtMs":1790344248000,"pid":4312,"recordId":"4c3716215535a2156382881524b859def67fa4af12648d6bd571ab583b380366","recordVersion":1,"signal":"SIGBUS","source":"metricKit","terminationCode":"0xa"}"#
        XCTAssertEqual(record.json.canonicalJSON, expected)
        assertValidRecord(record)
    }

    func testRecordIdIsDeterministic() throws {
        let data = try fixtureData("crash_sigbus_jit_evidence")
        let first = NativeCrashNormalizer.normalize(data, context: context())
        let second = NativeCrashNormalizer.normalize(data, context: context())
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first?.recordId, second?.recordId)
        // The same crash reported at another time is another record.
        XCTAssertNotEqual(
            first?.recordId,
            NativeCrashNormalizer.normalize(data, context: context(occurredAtMs: evidenceOccurredAtMs + 1))?.recordId
        )
    }

    func testNoAbsoluteAddressSurvivesAnyFixture() throws {
        for name in ["crash_sigbus_jit_evidence", "crash_apple_sample", "crash_watchdog", "crash_objc_exception",
                     "hang", "disk_write_exception"] {
            let data = try fixtureData(name)
            let addresses = try allAddresses(in: data)
            XCTAssertFalse(addresses.isEmpty, name)
            for kind in DiagnosticKind.allCases {
                let record = try XCTUnwrap(
                    NativeCrashNormalizer.normalize(data, context: context(kind, hangDurationMs: 1, bytesWritten: 1)),
                    name
                )
                assertValidRecord(record)
                let leaked = integers(in: record.json).intersection(addresses)
                XCTAssertTrue(leaked.isEmpty, "\(name) as \(kind): addresses \(leaked) in the record")
            }
        }
    }

    func testAppleSampleShape() throws {
        let record = try XCTUnwrap(NativeCrashNormalizer.normalize(try fixtureData("crash_apple_sample"), context: context()))
        let fields = record.fields
        XCTAssertEqual(fields.kind, .crash)
        XCTAssertEqual(fields.machException, "EXC_BAD_ACCESS")
        XCTAssertEqual(fields.signal, "SIGSEGV")
        XCTAssertEqual(fields.code, "0x0")
        XCTAssertEqual(fields.terminationCode, "0xb")
        XCTAssertEqual(fields.appVersion, "1.0")
        XCTAssertEqual(fields.appBuild, "1")
        XCTAssertNil(fields.pid)
        // Two binaries of one name but different UUIDs are two images.
        XCTAssertEqual(fields.images, [
            .init(name: "testBinaryName", debugId: "70b89f2716343580a69557cdb41d7743", arch: .arm64e, inApp: false),
            .init(name: "testBinaryName", debugId: "77a62f2e821230f384c1e8497440acf8", arch: .arm64e, inApp: false),
        ])
        XCTAssertEqual(fields.frames, [.inImage(0, offset: 123), .inImage(1, offset: 123)])
        assertValidRecord(record)
    }

    func testWatchdogTermination() throws {
        let record = try XCTUnwrap(NativeCrashNormalizer.normalize(try fixtureData("crash_watchdog"), context: context()))
        let fields = record.fields
        XCTAssertEqual(fields.kind, .watchdogKill)
        XCTAssertEqual(fields.terminationCode, "0x8badf00d")
        XCTAssertEqual(fields.machException, "EXC_CRASH")
        XCTAssertEqual(fields.signal, "SIGKILL")
        XCTAssertEqual(fields.code, "0x0")
        XCTAssertEqual(fields.pid, 5120)
        XCTAssertEqual(fields.frames.count, 19)
        XCTAssertEqual(fields.images.map(\.name), [
            "libsystem_kernel.dylib", "libsystem_pthread.dylib", "App", "Flutter", "CoreFoundation",
            "GraphicsServices", "UIKitCore", "Runner", "dyld",
        ])
        XCTAssertEqual(fields.images.filter(\.inApp).map(\.name), ["App", "Flutter", "Runner"])
        XCTAssertTrue(fields.images.filter(\.inApp).allSatisfy { $0.arch == nil })
        XCTAssertTrue(fields.images.filter { !$0.inApp }.allSatisfy { $0.arch == .arm64e })
        XCTAssertEqual(fields.frames.first, .inImage(0, offset: 26088))
        assertValidRecord(record)
    }

    func testObjectiveCException() throws {
        let data = try fixtureData("crash_objc_exception")
        let record = try XCTUnwrap(NativeCrashNormalizer.normalize(data, context: context()))
        let fields = record.fields
        XCTAssertEqual(fields.kind, .crash)
        XCTAssertEqual(fields.machException, "EXC_CRASH")
        XCTAssertEqual(fields.signal, "SIGABRT")
        XCTAssertEqual(fields.terminationCode, "0x6")
        XCTAssertEqual(fields.exceptionClass, "NSRangeException")
        XCTAssertEqual(
            fields.exceptionMessage,
            "*** -[__NSArrayM objectAtIndexedSubscript:]: index 5 beyond bounds [0 .. 2]"
        )
        XCTAssertEqual(fields.images.first?.name, "CoreFoundation")
        XCTAssertEqual(fields.images[1].name, "libobjc.A.dylib")
        assertValidRecord(record)
    }

    func testStrictDropsTheExceptionMessageAndChangesTheId() throws {
        let data = try fixtureData("crash_objc_exception")
        let open = try XCTUnwrap(NativeCrashNormalizer.normalize(data, context: context()))
        let strict = try XCTUnwrap(NativeCrashNormalizer.normalize(data, context: context(strict: true)))
        XCTAssertNotNil(open.fields.exceptionMessage)
        XCTAssertNil(strict.fields.exceptionMessage)
        XCTAssertEqual(strict.fields.exceptionClass, "NSRangeException")
        XCTAssertFalse(strict.json.canonicalJSON.contains("exceptionMessage"))
        XCTAssertFalse(strict.json.canonicalJSON.contains("beyond bounds"))
        XCTAssertNotEqual(open.recordId, strict.recordId)
        assertValidRecord(strict)
    }

    func testHangTakesTheTypedDurationNotTheLocalizedText() throws {
        let data = try fixtureData("hang")
        let record = try XCTUnwrap(NativeCrashNormalizer.normalize(data, context: context(.hang, hangDurationMs: 3200.4)))
        let fields = record.fields
        XCTAssertEqual(fields.kind, .hang)
        XCTAssertEqual(fields.durationMs, 3200)
        XCTAssertNil(fields.machException)
        XCTAssertNil(fields.signal)
        XCTAssertNil(fields.bytesWritten)
        // The attributed (main) thread, not the first one listed.
        XCTAssertEqual(fields.frames.count, 12)
        XCTAssertEqual(fields.images.first?.name, "libsystem_kernel.dylib")
        XCTAssertEqual(fields.frames.first, .inImage(0, offset: 26088))
        XCTAssertEqual(fields.pid, 5122)
        assertValidRecord(record)

        let unknown = try XCTUnwrap(NativeCrashNormalizer.normalize(data, context: context(.hang)))
        XCTAssertNil(unknown.fields.durationMs)
    }

    func testDiskWriteExceptionFollowsTheHeaviestPathTopFirst() throws {
        let data = try fixtureData("disk_write_exception")
        let record = try XCTUnwrap(
            NativeCrashNormalizer.normalize(data, context: context(.diskWriteException, bytesWritten: 4_326_720_000))
        )
        let fields = record.fields
        XCTAssertEqual(fields.kind, .diskWriteException)
        XCTAssertEqual(fields.bytesWritten, 4_326_720_000)
        XCTAssertNil(fields.durationMs)
        XCTAssertEqual(fields.appVersion, "0.0.8")
        XCTAssertEqual(fields.appBuild, "23")
        XCTAssertEqual(fields.images, [
            .init(name: "libsystem_kernel.dylib", debugId: "f70c76e313523a17ba3e95f85cbd1d5b", arch: .arm64e, inApp: false),
            .init(name: "Flutter", debugId: "4c4c448255553144a18947cffba6d499", arch: nil, inApp: true),
            .init(name: "libsystem_pthread.dylib", debugId: "39dacbe16bf639569f6c802bea4ec760", arch: .arm64e, inApp: false),
        ])
        XCTAssertEqual(fields.frames, [
            .inImage(0, offset: 20528),
            .inImage(1, offset: 5204708),
            .inImage(1, offset: 5011324),
            .inImage(1, offset: 5870088),
            .inImage(1, offset: 6316220),
            .inImage(1, offset: 6179464),
            .inImage(2, offset: 17464),
            .inImage(2, offset: 2252),
        ])
        assertValidRecord(record)
    }

    func testDiagnosticKindDecidesWhichMeasurementIsKept() throws {
        let data = try fixtureData("crash_watchdog")
        let crash = try XCTUnwrap(
            NativeCrashNormalizer.normalize(data, context: context(.crash, hangDurationMs: 5, bytesWritten: 5))
        )
        XCTAssertNil(crash.fields.durationMs)
        XCTAssertNil(crash.fields.bytesWritten)
    }
}
