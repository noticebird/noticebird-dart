import Foundation
import XCTest

@testable import NativeCrashNormalizer

/// The process-wide collector over a fake diagnostic source: once-only
/// activation, the channel methods, and arrivals.
final class NativeCrashCollectorTests: XCTestCase {
    private final class FakeSource: DiagnosticSource {
        private(set) var starts = 0
        private(set) var handler: (([DiagnosticReport]) -> Void)?

        func start(_ handler: @escaping ([DiagnosticReport]) -> Void) {
            starts += 1
            self.handler = handler
        }
    }

    /// Arrivals come in on the collector's queue.
    private final class Arrivals {
        private let lock = NSLock()
        private var values: [Int] = []

        func append(_ count: Int) {
            lock.lock()
            values.append(count)
            lock.unlock()
        }

        var counts: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private var base: URL!
    private let source = FakeSource()
    private let arrivals = Arrivals()
    private let t0: Int64 = 1_790_344_000_000
    private let runA = RunInfo(
        runId: String(repeating: "a", count: 32),
        pid: 42,
        startedAtMs: 1_790_344_000_000,
        appVersion: "1.0",
        appBuild: "7",
        debugBuild: false
    )

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("NativeCrashCollectorTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private var root: URL { base.appendingPathComponent("noticebird_native", isDirectory: true) }
    private var v1: URL { root.appendingPathComponent("v1", isDirectory: true) }

    private func makeCollector(openStore: (() throws -> NativeCrashStore)? = nil) -> NativeCrashCollector {
        let root = root
        let now = t0 + 10_000
        let arrivals = arrivals
        return NativeCrashCollector(
            source: source,
            run: runA,
            openStore: openStore ?? { try NativeCrashStore(rootDirectory: root) },
            inAppBinaryNames: { ["Runner", "Flutter"] },
            clock: { now },
            onArrivals: { arrivals.append($0) }
        )
    }

    private func start(_ collector: NativeCrashCollector) -> [String: Any] {
        let done = expectation(description: "start")
        var reply: [String: Any] = [:]
        collector.start(CaptureOptions(strict: false, hangs: false, diskWrites: false)) {
            reply = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return reply
    }

    private func claim(_ collector: NativeCrashCollector, max: Int = 10) -> [[String: Any]] {
        let done = expectation(description: "claim")
        var reply: [[String: Any]] = []
        collector.claim(max: max) {
            reply = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return reply
    }

    /// Returns once the collector's queue has handled everything before:
    /// settling an unknown id changes nothing.
    private func drain(_ collector: NativeCrashCollector) {
        let done = expectation(description: "drain")
        collector.settle(recordId: String(repeating: "0", count: 64), delivered: false) { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    private func report(at occurredAtMs: Int64) -> DiagnosticReport {
        DiagnosticReport(kind: .crash, occurredAtMs: occurredAtMs, json: Data("{}".utf8))
    }

    private func run(_ letter: Character) -> RunInfo {
        RunInfo(runId: String(repeating: letter, count: 32), pid: 7, startedAtMs: t0, appVersion: nil, appBuild: nil, debugBuild: false)
    }

    private func runFileExists(_ run: RunInfo) -> Bool {
        FileManager.default.fileExists(atPath: v1.appendingPathComponent("runs/\(run.runId)/run.json").path)
    }

    private func inboxCount() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: v1.appendingPathComponent("inbox").path)) ?? []).count
    }

    /// An earlier run's start and report, then three runs that registered
    /// without a start: the collector's run is the dormant one.
    private func prepareDormantRun() throws {
        let store = try NativeCrashStore(rootDirectory: root)
        try store.start(CaptureOptions(strict: false, hangs: false, diskWrites: false), run: run("b"), nowMs: t0)
        XCTAssertEqual(store.ingest([report(at: t0 + 1)], inAppBinaryNames: [], nowMs: t0 + 1), 1)
        for letter in "cde" {
            try store.registerProcess(run(letter), nowMs: t0 + 2)
        }
    }

    func testActivationHappensOncePerProcess() {
        let collector = makeCollector()
        collector.activate()
        collector.activate()
        _ = start(collector)
        XCTAssertEqual(source.starts, 1)
    }

    func testRegistrationBeforeAnyStartRecordsNothing() {
        let collector = makeCollector()
        collector.activate()
        XCTAssertTrue(claim(collector).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: v1.appendingPathComponent("runs/\(runA.runId)/run.json").path))
    }

    func testStartRepliesWithTheRunAndTheDirectoryAndRecordsTheRun() {
        let collector = makeCollector()
        let reply = start(collector)
        XCTAssertEqual(reply["runId"] as? String, runA.runId)
        XCTAssertEqual(reply["directory"] as? String, v1.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: v1.appendingPathComponent("runs/\(runA.runId)/run.json").path))
    }

    func testDeliveriesArriveOnceAndOnlyWhenRecorded() throws {
        let collector = makeCollector()
        _ = start(collector)
        let handler = try XCTUnwrap(source.handler)
        handler([report(at: t0 + 1)])
        handler([report(at: t0 + 1)])
        handler([report(at: t0 - 30 * 24 * 60 * 60 * 1000)])
        // The queue is serial: once a claim replies, every delivery before it
        // has been handled.
        let claimed = claim(collector)
        XCTAssertEqual(arrivals.counts, [1])
        XCTAssertEqual(claimed.count, 1)
        XCTAssertEqual(claimed.first?["recordVersion"] as? Int, 1)
        XCTAssertEqual(claimed.first?["kind"] as? String, "crash")
        XCTAssertEqual(claimed.first?["occurredAtMs"] as? Int, Int(t0 + 1))
        XCTAssertNil(claimed.first?["claimedUntilMs"])
    }

    func testSettleAndDisableReply() throws {
        let collector = makeCollector()
        _ = start(collector)
        try XCTUnwrap(source.handler)([report(at: t0 + 1)])
        let recordId = try XCTUnwrap(claim(collector).first?["recordId"] as? String)

        let settled = expectation(description: "settle")
        collector.settle(recordId: recordId, delivered: true) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        try XCTUnwrap(source.handler)([report(at: t0 + 1)])
        XCTAssertTrue(claim(collector).isEmpty, "a settled report is not recorded again")

        let disabled = expectation(description: "disable")
        collector.disable { disabled.fulfill() }
        wait(for: [disabled], timeout: 5)
        let state = try XCTUnwrap(JSONValue(parsing: try Data(contentsOf: v1.appendingPathComponent("state.json"))))
        XCTAssertEqual(state, .object(["version": .integer(1), "enabled": .bool(false)]))
    }

    func testADormantRunDropsDeliveriesUntilStart() throws {
        try prepareDormantRun()
        let collector = makeCollector()
        collector.activate()
        try XCTUnwrap(source.handler)([report(at: t0 + 3)])
        drain(collector)
        XCTAssertEqual(arrivals.counts, [])
        XCTAssertEqual(inboxCount(), 1, "the earlier report is kept")
        XCTAssertFalse(runFileExists(runA), "a dormant run writes no run record")

        XCTAssertEqual(start(collector)["runId"] as? String, runA.runId)
        XCTAssertTrue(runFileExists(runA), "start records the run after all")
        try XCTUnwrap(source.handler)([report(at: t0 + 3)])
        XCTAssertEqual(claim(collector).count, 2)
        XCTAssertEqual(arrivals.counts, [1])
    }

    func testTheRunIsRegisteredWhenTheStoreOpensAfterActivation() throws {
        try prepareDormantRun()
        struct Unavailable: Error {}
        let root = root
        var opens = 0
        let collector = makeCollector(openStore: {
            // Called on the collector's queue only.
            opens += 1
            if opens == 1 { throw Unavailable() }
            return try NativeCrashStore(rootDirectory: root)
        })
        collector.activate()
        try XCTUnwrap(source.handler)([report(at: t0 + 3)])
        drain(collector)
        XCTAssertEqual(opens, 2)
        XCTAssertEqual(arrivals.counts, [], "the late-opened store knows this run is dormant")
        XCTAssertEqual(inboxCount(), 1)
    }

    func testAStoreThatCannotOpenRepliesEmpty() throws {
        struct Unavailable: Error {}
        let collector = makeCollector(openStore: { throw Unavailable() })
        XCTAssertTrue(start(collector).isEmpty)
        XCTAssertTrue(claim(collector).isEmpty)
        let settled = expectation(description: "settle")
        collector.settle(recordId: String(repeating: "0", count: 64), delivered: true) { settled.fulfill() }
        let disabled = expectation(description: "disable")
        collector.disable { disabled.fulfill() }
        wait(for: [settled, disabled], timeout: 5)
        try XCTUnwrap(source.handler)([report(at: t0 + 1)])
        XCTAssertTrue(claim(collector).isEmpty)
        XCTAssertEqual(arrivals.counts, [])
    }
}

final class RunInfoAndAppBundleTests: XCTestCase {
    func testEachRunHasAFreshThirtyTwoHexId() {
        let first = RunInfo.current()
        let second = RunInfo.current()
        XCTAssertNotEqual(first.runId, second.runId)
        for run in [first, second] {
            XCTAssertEqual(run.runId.count, 32)
            XCTAssertTrue(run.runId.utf8.allSatisfy(Pattern.isLowerHex))
            XCTAssertEqual(run.pid, Int64(ProcessInfo.processInfo.processIdentifier))
            XCTAssertGreaterThan(run.startedAtMs, 0)
        }
    }

    func testInAppBinariesAreTheExecutableAndTheFrameworks() {
        XCTAssertEqual(
            AppBundle.binaryNames(
                executable: "Runner",
                frameworkEntries: ["Flutter.framework", "App.framework", "libswift_Concurrency.dylib", "README", ".framework"]
            ),
            ["Runner", "Flutter", "App", "libswift_Concurrency.dylib"]
        )
        XCTAssertEqual(AppBundle.binaryNames(executable: nil, frameworkEntries: []), [])
        XCTAssertEqual(AppBundle.binaryNames(executable: "", frameworkEntries: ["App.framework"]), ["App"])
    }
}
