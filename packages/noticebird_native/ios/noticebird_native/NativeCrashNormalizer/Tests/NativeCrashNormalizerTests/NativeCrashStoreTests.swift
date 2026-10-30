import Foundation
import XCTest

@testable import NativeCrashNormalizer

/// The on-disk contract (the native contract, "Storage" and the method
/// table), exercised on a real directory.
final class NativeCrashStoreTests: XCTestCase {
    private var base: URL!
    private var root: URL { base.appendingPathComponent("noticebird_native", isDirectory: true) }
    private var v1: URL { root.appendingPathComponent("v1", isDirectory: true) }
    private let fileManager = FileManager.default

    private let t0: Int64 = 1_790_344_000_000
    private let day: Int64 = 24 * 60 * 60 * 1000
    private let names: Set<String> = ["Runner", "Flutter", "App"]
    private lazy var runA = run("a", t0)

    override func setUpWithError() throws {
        base = fileManager.temporaryDirectory.appendingPathComponent("NativeCrashStoreTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: base)
    }

    // MARK: - Helpers

    private func makeStore() throws -> NativeCrashStore {
        try NativeCrashStore(rootDirectory: root)
    }

    private func run(_ letter: Character, _ startedAtMs: Int64) -> RunInfo {
        RunInfo(
            runId: String(repeating: letter, count: 32),
            pid: 42,
            startedAtMs: startedAtMs,
            appVersion: "1.0",
            appBuild: "7",
            debugBuild: false
        )
    }

    private func register(_ store: NativeCrashStore, _ run: RunInfo, at nowMs: Int64? = nil) throws {
        try store.registerProcess(run, nowMs: nowMs ?? run.startedAtMs)
    }

    /// Three runs after runA's start that register without a start of their
    /// own: the next registration is dormant.
    private func registerThreeUnconfirmedRuns(_ store: NativeCrashStore) throws {
        for (index, letter) in "bcd".enumerated() {
            try register(store, run(letter, t0 + Int64(index + 1) * 1000))
            XCTAssertEqual(store.loadState().unconfirmedRuns, Int64(index + 1))
        }
    }

    private func start(_ store: NativeCrashStore, strict: Bool = false, hangs: Bool = false, diskWrites: Bool = false,
                       run: RunInfo? = nil, at nowMs: Int64? = nil) throws {
        try store.start(
            CaptureOptions(strict: strict, hangs: hangs, diskWrites: diskWrites),
            run: run ?? runA,
            nowMs: nowMs ?? t0
        )
    }

    /// A report whose record carries only the required fields: distinct per
    /// time, so distinct per id.
    private func bare(_ occurredAtMs: Int64, _ kind: DiagnosticKind = .crash) -> DiagnosticReport {
        DiagnosticReport(kind: kind, occurredAtMs: occurredAtMs, json: Data("{}".utf8))
    }

    private func fixture(_ name: String, _ kind: DiagnosticKind = .crash, at occurredAtMs: Int64) throws -> DiagnosticReport {
        DiagnosticReport(kind: kind, occurredAtMs: occurredAtMs, json: try fixtureData(name), hangDurationMs: 2500)
    }

    private func json(_ path: String) -> JSONValue? {
        (try? Data(contentsOf: v1.appendingPathComponent(path))).flatMap { JSONValue(parsing: $0) }
    }

    private func inboxFiles() -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: v1.appendingPathComponent("inbox").path)) ?? []).sorted()
    }

    private func inboxRecords() -> [[String: JSONValue]] {
        inboxFiles().compactMap { json("inbox/\($0)")?.objectValue }
    }

    private func runDirectories() -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: v1.appendingPathComponent("runs").path)) ?? []).sorted()
    }

    private func runFileExists(_ run: RunInfo) -> Bool {
        fileManager.fileExists(atPath: v1.appendingPathComponent("runs/\(run.runId)/run.json").path)
    }

    private func onlyRecordId() throws -> String {
        let files = inboxFiles()
        XCTAssertEqual(files.count, 1)
        return String(try XCTUnwrap(files.first).dropLast(".json".count))
    }

    private let disabledState = JSONValue.object(["version": .integer(1), "enabled": .bool(false)])

    // MARK: - Enablement and runs

    func testAFreshStoreIsDisabledAndRecordsNothing() throws {
        let store = try makeStore()
        XCTAssertEqual(store.loadState(), .disabled)
        try register(store, runA)
        XCTAssertFalse(runFileExists(runA), "an app that never opted in gets no run record")
        XCTAssertEqual(store.ingest([bare(t0)], inAppBinaryNames: names, nowMs: t0), 0)
        XCTAssertTrue(inboxFiles().isEmpty)
        XCTAssertTrue(runDirectories().isEmpty)
        XCTAssertTrue(store.claim(max: 10, nowMs: t0).isEmpty)
    }

    func testStartEnablesWithTheOptionsAndRecordsTheRun() throws {
        let store = try makeStore()
        try start(store, strict: true, hangs: true, diskWrites: false)
        XCTAssertEqual(json("state.json"), .object([
            "version": .integer(1), "enabled": .bool(true), "strict": .bool(true), "hangs": .bool(true),
            "diskWrites": .bool(false), "unconfirmedRuns": .integer(0), "exitWatermarkMs": .integer(t0),
        ]))
        XCTAssertEqual(json("runs/\(runA.runId)/run.json"), .object([
            "version": .integer(1), "runId": .string(runA.runId), "pid": .integer(42), "startedAtMs": .integer(t0),
            "appVersion": .string("1.0"), "appBuild": .string("7"), "debugBuild": .bool(false),
        ]))

        // A later start changes the options, not the opt-in time.
        try start(store, strict: false, at: t0 + day)
        let state = store.loadState()
        XCTAssertFalse(state.strict)
        XCTAssertFalse(state.hangs)
        XCTAssertEqual(state.exitWatermarkMs, t0)
    }

    func testRegistrationCountsUnconfirmedRunsAndRecordsThemWhileEnabled() throws {
        let store = try makeStore()
        try start(store)
        let runB = run("b", t0 + 1000)
        try register(store, runB)
        XCTAssertTrue(runFileExists(runB))
        XCTAssertEqual(store.loadState().unconfirmedRuns, 1)
        try start(store, run: runB)
        XCTAssertEqual(store.loadState().unconfirmedRuns, 0, "start confirms the run")
    }

    func testADormantRunWithAnEmptyInboxPurges() throws {
        let store = try makeStore()
        try start(store)
        XCTAssertEqual(store.ingest([bare(t0 + 1)], inAppBinaryNames: names, nowMs: t0 + 1), 1)
        try store.settle(recordId: try onlyRecordId(), delivered: true, nowMs: t0 + 2)
        try registerThreeUnconfirmedRuns(store)
        let runE = run("e", t0 + 9000)
        try register(store, runE)
        XCTAssertEqual(json("state.json"), disabledState)
        XCTAssertNil(json("seen.json"))
        XCTAssertTrue(inboxFiles().isEmpty)
        XCTAssertTrue(runDirectories().isEmpty)

        // A start in the same run opts in afresh and records the run.
        try start(store, run: runE, at: t0 + 10_000)
        XCTAssertEqual(store.loadState().exitWatermarkMs, t0 + 10_000)
        XCTAssertTrue(runFileExists(runE))
        XCTAssertEqual(store.ingest([bare(t0 + 10_001)], inAppBinaryNames: names, nowMs: t0 + 10_002), 1)
    }

    func testADormantRunKeepsANonEmptyInboxAndRecordsNothingUntilStart() throws {
        let store = try makeStore()
        try start(store)
        XCTAssertEqual(store.ingest([bare(t0 + 1), bare(t0 + 2)], inAppBinaryNames: names, nowMs: t0 + 3), 2)
        let delivered = try XCTUnwrap(store.claim(max: 1, nowMs: t0 + 3).first)
        try store.settle(recordId: delivered.recordId, delivered: true, nowMs: t0 + 4)
        try registerThreeUnconfirmedRuns(store)
        // The Dart half of the ledger: an engine file of an earlier run.
        let engineFile = v1.appendingPathComponent("runs/\(runA.runId)/engine-0123456789abcdef.json")
        try Data("{}".utf8).write(to: engineFile)
        let state = try XCTUnwrap(json("state.json"))
        let seen = try XCTUnwrap(json("seen.json"))
        let inbox = inboxFiles()
        let runs = runDirectories()
        XCTAssertEqual(inbox.count, 1)

        let runE = run("e", t0 + 9000)
        try register(store, runE)
        XCTAssertEqual(json("state.json"), state, "neither counted further nor purged")
        XCTAssertEqual(json("seen.json"), seen)
        XCTAssertEqual(inboxFiles(), inbox)
        XCTAssertEqual(runDirectories(), runs, "the ledger is kept")
        XCTAssertTrue(fileManager.fileExists(atPath: engineFile.path))
        XCTAssertFalse(runFileExists(runE), "a dormant run writes no run record")
        XCTAssertEqual(store.ingest([bare(t0 + 9001)], inAppBinaryNames: names, nowMs: t0 + 9002), 0, "nor a diagnostic")
        XCTAssertEqual(inboxFiles(), inbox)

        // A fixed build starts again: this run records from here on.
        try start(store, run: runE, at: t0 + 9003)
        XCTAssertEqual(store.loadState().unconfirmedRuns, 0)
        XCTAssertEqual(store.loadState().exitWatermarkMs, t0, "the opt-in time stays")
        XCTAssertTrue(runFileExists(runE))
        XCTAssertEqual(store.ingest([bare(t0 + 9001)], inAppBinaryNames: names, nowMs: t0 + 9004), 1)
        XCTAssertEqual(store.claim(max: 10, nowMs: t0 + 9005).map(\.occurredAtMs), [t0 + 2, t0 + 9001], "the kept report too")
    }

    func testADormantInboxStillExpiresAndTheRegistrationThatFindsItEmptyPurges() throws {
        let store = try makeStore()
        try start(store)
        XCTAssertEqual(store.ingest([bare(t0 + 1)], inAppBinaryNames: names, nowMs: t0 + 1), 1)
        try registerThreeUnconfirmedRuns(store)
        try register(store, run("e", t0 + 10 * day))
        try register(store, run("f", t0 + 1 + 30 * day))
        XCTAssertEqual(inboxFiles().count, 1, "kept for 30 days")
        XCTAssertEqual(store.loadState().unconfirmedRuns, 3)
        XCTAssertEqual(runDirectories().count, 4)

        try register(store, run("g", t0 + 2 + 30 * day))
        XCTAssertEqual(json("state.json"), disabledState)
        XCTAssertTrue(inboxFiles().isEmpty)
        XCTAssertTrue(runDirectories().isEmpty)
    }

    func testRunsArePrunedToFiveAlwaysKeepingTheCurrentOne() throws {
        let store = try makeStore()
        for (index, letter) in "0123456".enumerated() {
            try start(store, run: run(letter, t0 + Int64(index) * 1000))
        }
        XCTAssertEqual(runDirectories(), ["2", "3", "4", "5", "6"].map { String(repeating: $0, count: 32) })

        // A directory without a readable run.json counts as oldest; a stray
        // file is not a run.
        try fileManager.createDirectory(at: v1.appendingPathComponent("runs/broken"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: v1.appendingPathComponent("runs/stray.json"))
        // The current run survives even when its clock says it is the oldest.
        let skewed = run("b", t0 - day)
        try start(store, run: skewed)
        let kept = runDirectories()
        XCTAssertEqual(kept.count, 5)
        XCTAssertTrue(kept.contains(skewed.runId))
        XCTAssertFalse(kept.contains("broken"))
        XCTAssertFalse(kept.contains("stray.json"))
        XCTAssertTrue(kept.contains(String(repeating: "6", count: 32)))
        XCTAssertFalse(kept.contains(String(repeating: "2", count: 32)))
    }

    func testDisableDeletesEverythingAndStaysDisabled() throws {
        let store = try makeStore()
        try start(store)
        _ = store.ingest([bare(t0 + 1)], inAppBinaryNames: names, nowMs: t0 + 1)
        try store.settle(recordId: try onlyRecordId(), delivered: true, nowMs: t0 + 2)
        _ = store.ingest([bare(t0 + 3)], inAppBinaryNames: names, nowMs: t0 + 3)
        try store.disable()
        XCTAssertEqual(json("state.json"), disabledState)
        XCTAssertNil(json("seen.json"))
        XCTAssertTrue(inboxFiles().isEmpty)
        XCTAssertTrue(runDirectories().isEmpty)
        XCTAssertEqual(store.ingest([bare(t0 + 4)], inAppBinaryNames: names, nowMs: t0 + 4), 0)
        XCTAssertTrue(store.claim(max: 10, nowMs: t0 + 4).isEmpty)
    }

    func testAnUnreadableStateIsDisabledAndDeleted() throws {
        let store = try makeStore()
        for garbage in ["not json", #"{"version":1,"enabled":"yes"}"#, #"{"version":2,"enabled":true}"#, "[]"] {
            try start(store)
            try Data(garbage.utf8).write(to: v1.appendingPathComponent("state.json"))
            XCTAssertEqual(store.loadState(), .disabled, garbage)
            XCTAssertFalse(fileManager.fileExists(atPath: v1.appendingPathComponent("state.json").path), garbage)
        }
        // A missing option fails closed.
        try Data(#"{"version":1,"enabled":true}"#.utf8).write(to: v1.appendingPathComponent("state.json"))
        XCTAssertTrue(store.loadState().strict)
    }

    #if os(iOS) || os(macOS)
    func testTheRootIsExcludedFromBackups() throws {
        _ = try makeStore()
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
    #endif

    // MARK: - Recording

    func testTheOptInFilterAllowsADayOfSlack() throws {
        let store = try makeStore()
        try start(store, at: t0)
        let now = t0 + 1000
        let slack = NativeCrashStore.optInSlackMs
        XCTAssertEqual(slack, day)
        XCTAssertEqual(store.ingest([bare(t0 - slack - 1)], inAppBinaryNames: names, nowMs: now), 0, "before the slack")
        XCTAssertEqual(store.ingest([bare(t0 - slack)], inAppBinaryNames: names, nowMs: now), 1, "at the slack")
        XCTAssertEqual(store.ingest([bare(t0 - 1)], inAppBinaryNames: names, nowMs: now), 1, "within the slack")
        XCTAssertEqual(store.ingest([bare(t0 - 30 * day)], inAppBinaryNames: names, nowMs: now), 0)
    }

    func testDuplicatesAndSettledIdsAreNotRecordedAgain() throws {
        let store = try makeStore()
        try start(store)
        let crash = try fixture("crash_sigbus_jit_evidence", at: t0 + 5000)
        XCTAssertEqual(store.ingest([crash], inAppBinaryNames: names, nowMs: t0 + 10_000), 1)
        XCTAssertEqual(store.ingest([crash, crash], inAppBinaryNames: names, nowMs: t0 + 10_000), 0)
        let recordId = try onlyRecordId()
        XCTAssertNil(json("inbox/\(recordId).json")?.objectValue?["claimedUntilMs"], "unclaimed on arrival")
        XCTAssertEqual(store.claim(max: 10, nowMs: t0 + 20_000).map(\.recordId), [recordId])
        try store.settle(recordId: recordId, delivered: true, nowMs: t0 + 30_000)
        XCTAssertTrue(inboxFiles().isEmpty)
        XCTAssertEqual(json("seen.json"), .object(["version": .integer(1), "ids": .array([.string(recordId)])]))
        XCTAssertEqual(store.ingest([crash], inAppBinaryNames: names, nowMs: t0 + 40_000), 0)
    }

    func testTheSeenSetKeepsTheLast256IdsNewestLast() throws {
        let store = try makeStore()
        try start(store)
        var settled: [String] = []
        for index in 0..<260 {
            let now = t0 + Int64(index) + 1
            XCTAssertEqual(store.ingest([bare(now)], inAppBinaryNames: names, nowMs: now), 1)
            let claimed = store.claim(max: 1, nowMs: now)
            XCTAssertEqual(claimed.count, 1)
            try store.settle(recordId: try XCTUnwrap(claimed.first).recordId, delivered: true, nowMs: now)
            settled.append(try XCTUnwrap(claimed.first).recordId)
        }
        let ids = try XCTUnwrap(json("seen.json")?.objectValue?["ids"]?.arrayValue).compactMap(\.stringValue)
        XCTAssertEqual(ids, Array(settled.suffix(256)))
    }

    func testClaimsAreLeasedForTenMinutesAndRetriesForADay() throws {
        let store = try makeStore()
        try start(store)
        _ = store.ingest([bare(t0 + 1)], inAppBinaryNames: names, nowMs: t0 + 1)
        let recordId = try onlyRecordId()
        let claimedAt = t0 + 20_000
        let claimed = store.claim(max: 10, nowMs: claimedAt)
        XCTAssertEqual(claimed.map(\.recordId), [recordId])
        XCTAssertNil(claimed.first?.channelValue["claimedUntilMs"], "the claim never crosses the channel")
        XCTAssertEqual(json("inbox/\(recordId).json")?.objectValue?["claimedUntilMs"], .integer(claimedAt + 600_000))
        XCTAssertTrue(store.claim(max: 10, nowMs: claimedAt + 599_999).isEmpty, "leased")
        XCTAssertEqual(store.claim(max: 10, nowMs: claimedAt + 600_000).count, 1, "claimable when the lease ends")

        let settledAt = claimedAt + 700_000
        try store.settle(recordId: recordId, delivered: false, nowMs: settledAt)
        XCTAssertEqual(json("inbox/\(recordId).json")?.objectValue?["claimedUntilMs"], .integer(settledAt + day))
        XCTAssertTrue(store.claim(max: 10, nowMs: settledAt + day - 1).isEmpty, "not before a day")
        XCTAssertEqual(store.claim(max: 10, nowMs: settledAt + day).count, 1)
    }

    func testClaimReturnsTheOldestFirstUpToMax() throws {
        let store = try makeStore()
        try start(store)
        _ = store.ingest([bare(t0 + 3), bare(t0 + 1), bare(t0 + 2)], inAppBinaryNames: names, nowMs: t0 + 10)
        XCTAssertEqual(store.claim(max: 2, nowMs: t0 + 10).map(\.occurredAtMs), [t0 + 1, t0 + 2])
        XCTAssertEqual(store.claim(max: 2, nowMs: t0 + 10).map(\.occurredAtMs), [t0 + 3])
        XCTAssertTrue(store.claim(max: 0, nowMs: t0 + 10).isEmpty)
        XCTAssertTrue(store.claim(max: -1, nowMs: t0 + 10).isEmpty)
    }

    func testSettleIgnoresUnknownAndPathLikeIds() throws {
        let store = try makeStore()
        try start(store)
        _ = store.ingest([bare(t0 + 1)], inAppBinaryNames: names, nowMs: t0 + 1)
        let before = inboxFiles()
        for recordId in ["../../state", "../state.json", "../../noticebird_native", String(repeating: "f", count: 64), ""] {
            try store.settle(recordId: recordId, delivered: true, nowMs: t0 + 2)
            try store.settle(recordId: recordId, delivered: false, nowMs: t0 + 2)
        }
        XCTAssertTrue(fileManager.fileExists(atPath: v1.appendingPathComponent("state.json").path))
        XCTAssertEqual(inboxFiles(), before)
        XCTAssertNil(json("seen.json"))
    }

    func testTheInboxKeepsTheNewestTwentyRecords() throws {
        let store = try makeStore()
        try start(store)
        let reports = (0..<25).map { bare(t0 + 100 + Int64($0)) }
        XCTAssertEqual(store.ingest(reports, inAppBinaryNames: names, nowMs: t0 + 1000), 20)
        let times = inboxRecords().compactMap { $0["occurredAtMs"]?.integerValue }.sorted()
        XCTAssertEqual(times, (5..<25).map { t0 + 100 + Int64($0) })
        // Older than everything kept: in and out at once.
        XCTAssertEqual(store.ingest([bare(t0 + 50)], inAppBinaryNames: names, nowMs: t0 + 1000), 0)
        XCTAssertEqual(inboxFiles().count, 20)
    }

    func testRecordsExpireAfterThirtyDays() throws {
        let store = try makeStore()
        try start(store)
        _ = store.ingest([bare(t0 + 10), bare(t0 + 20)], inAppBinaryNames: names, nowMs: t0 + 100)
        let later = t0 + 11 + 30 * day
        XCTAssertEqual(store.claim(max: 10, nowMs: later).map(\.occurredAtMs), [t0 + 20])
        XCTAssertEqual(inboxFiles().count, 1)
        XCTAssertEqual(store.ingest([bare(later - 30 * day - 1)], inAppBinaryNames: names, nowMs: later), 0)
    }

    func testOptionsGateHangsAndDiskWritesAndStrictDropsMessages() throws {
        let store = try makeStore()
        try start(store, strict: false)
        let hang = try fixture("hang", .hang, at: t0 + 1)
        let diskWrite = try fixture("disk_write_exception", .diskWriteException, at: t0 + 2)
        XCTAssertEqual(store.ingest([hang, diskWrite], inAppBinaryNames: names, nowMs: t0 + 10), 0)

        try start(store, strict: true, hangs: true, diskWrites: true)
        let objc = try fixture("crash_objc_exception", at: t0 + 3)
        XCTAssertEqual(store.ingest([hang, diskWrite, objc], inAppBinaryNames: names, nowMs: t0 + 10), 3)
        let records = inboxRecords()
        XCTAssertTrue(records.contains { $0["durationMs"] == .integer(2500) })
        let exception = try XCTUnwrap(records.first { $0["exceptionClass"] != nil })
        XCTAssertEqual(exception["exceptionClass"], .string("NSRangeException"))
        XCTAssertNil(exception["exceptionMessage"], "strict: no message is ever written")
    }

    func testCorruptStrayMisnamedAndTamperedFilesAreDeleted() throws {
        let store = try makeStore()
        try start(store)
        _ = store.ingest([bare(t0 + 1), bare(t0 + 2)], inAppBinaryNames: names, nowMs: t0 + 10)
        let valid = inboxFiles()
        XCTAssertEqual(valid.count, 2)
        let inbox = v1.appendingPathComponent("inbox")

        try Data("garbage".utf8).write(to: inbox.appendingPathComponent(String(repeating: "1", count: 64) + ".json"))
        try Data("{}".utf8).write(to: inbox.appendingPathComponent("stray.json.tmp"))
        try Data("{}".utf8).write(to: inbox.appendingPathComponent("notes.txt"))
        // A valid record under another record's name.
        try fileManager.copyItem(
            at: inbox.appendingPathComponent(valid[0]),
            to: inbox.appendingPathComponent(String(repeating: "2", count: 64) + ".json")
        )
        // A record whose content breaks the contract.
        var tampered = try XCTUnwrap(json("inbox/\(valid[1])")?.objectValue)
        tampered["pid"] = .integer(-1)
        try JSONValue.object(tampered).canonicalData.write(to: inbox.appendingPathComponent(valid[1]))
        // A claim that is not a time.
        var badClaim = try XCTUnwrap(json("inbox/\(valid[0])")?.objectValue)
        badClaim["claimedUntilMs"] = .string("soon")
        try JSONValue.object(badClaim).canonicalData.write(to: inbox.appendingPathComponent(valid[0]))

        XCTAssertTrue(store.claim(max: 10, nowMs: t0 + 20).isEmpty)
        XCTAssertTrue(inboxFiles().isEmpty)
    }

    func testSwitchingStrictOnStripsMessagesKeepingIdsAndClaims() throws {
        let store = try makeStore()
        try start(store, strict: false)
        let reports = [
            try fixture("crash_objc_exception", at: t0 + 1),
            try fixture("crash_objc_exception", at: t0 + 2),
            bare(t0 + 3),
        ]
        XCTAssertEqual(store.ingest(reports, inAppBinaryNames: names, nowMs: t0 + 10), 3)
        let claimedAt = t0 + 20
        let claimed = try XCTUnwrap(store.claim(max: 1, nowMs: claimedAt).first)
        XCTAssertEqual(claimed.occurredAtMs, t0 + 1)
        let files = inboxFiles()
        let before = inboxRecords()
        XCTAssertEqual(before.filter { $0["exceptionMessage"] != nil }.count, 2)

        try start(store, strict: true, at: t0 + 30)
        XCTAssertEqual(inboxFiles(), files, "every record keeps its id")
        let after = inboxRecords()
        XCTAssertEqual(after.count, before.count)
        for (old, new) in zip(before, after) {
            var expected = old
            expected["exceptionMessage"] = nil
            XCTAssertEqual(new, expected, "only the message goes")
        }
        XCTAssertEqual(json("inbox/\(claimed.recordId).json")?.objectValue?["claimedUntilMs"], .integer(claimedAt + 600_000))

        // Still records: claimable and settled under their ids.
        let reclaimed = store.claim(max: 10, nowMs: claimedAt + 600_000)
        XCTAssertEqual(reclaimed.map(\.recordId).sorted(), files.map { String($0.dropLast(".json".count)) })
        XCTAssertTrue(reclaimed.allSatisfy { $0.fields.exceptionMessage == nil })
        try store.settle(recordId: claimed.recordId, delivered: true, nowMs: claimedAt + 600_001)
        XCTAssertEqual(json("seen.json")?.objectValue?["ids"], .array([.string(claimed.recordId)]))
        let leftovers = fileManager.enumerator(atPath: v1.path)?.compactMap { $0 as? String }.filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers ?? [], [])
    }

    func testAStrictStartOverAnUnreadableStateStripsToo() throws {
        let store = try makeStore()
        try start(store, strict: false)
        XCTAssertEqual(store.ingest([try fixture("crash_objc_exception", at: t0 + 1)], inAppBinaryNames: names, nowMs: t0 + 10), 1)
        let recordId = try onlyRecordId()
        try Data("garbage".utf8).write(to: v1.appendingPathComponent("state.json"))
        try start(store, strict: true, at: t0 + 20)
        XCTAssertEqual(try onlyRecordId(), recordId)
        let record = try XCTUnwrap(json("inbox/\(recordId).json")?.objectValue)
        XCTAssertNil(record["exceptionMessage"])
        XCTAssertEqual(record["exceptionClass"], .string("NSRangeException"))
    }

    func testAStartThatDoesNotSwitchStrictOnLeavesMessagesAlone() throws {
        let store = try makeStore()
        try start(store, strict: false)
        XCTAssertEqual(store.ingest([try fixture("crash_objc_exception", at: t0 + 1)], inAppBinaryNames: names, nowMs: t0 + 10), 1)
        let records = inboxRecords()
        XCTAssertNotNil(records.first?["exceptionMessage"])
        try start(store, strict: false, hangs: true, at: t0 + day)
        XCTAssertEqual(inboxRecords(), records)
    }

    func testASeenSetWithAndroidsJvmCrashesIsReadAndNotDeleted() throws {
        let store = try makeStore()
        try start(store)
        let report = bare(t0 + 1)
        XCTAssertEqual(store.ingest([report], inAppBinaryNames: names, nowMs: t0 + 1), 1)
        let first = try onlyRecordId()
        try store.settle(recordId: first, delivered: true, nowMs: t0 + 2)
        let seenFile = v1.appendingPathComponent("seen.json")
        let jvmCrashes = #"[{"pid":4312,"runId":"\#(runA.runId)"}]"#
        try Data(#"{"ids":["\#(first)"],"jvmCrashes":\#(jvmCrashes),"version":1}"#.utf8).write(to: seenFile)

        XCTAssertEqual(store.ingest([report], inAppBinaryNames: names, nowMs: t0 + 3), 0, "its ids still count")
        XCTAssertTrue(fileManager.fileExists(atPath: seenFile.path), "not deleted as unreadable")

        // A rewrite keeps what iOS uses: `jvmCrashes` is Android's alone.
        XCTAssertEqual(store.ingest([bare(t0 + 4)], inAppBinaryNames: names, nowMs: t0 + 4), 1)
        let second = try onlyRecordId()
        try store.settle(recordId: second, delivered: true, nowMs: t0 + 5)
        XCTAssertEqual(json("seen.json"), .object(["version": .integer(1), "ids": .array([.string(first), .string(second)])]))
    }

    func testAnUnreadableSeenSetIsDeleted() throws {
        let store = try makeStore()
        try start(store)
        try Data("[1,2".utf8).write(to: v1.appendingPathComponent("seen.json"))
        XCTAssertEqual(store.ingest([bare(t0 + 1)], inAppBinaryNames: names, nowMs: t0 + 10), 1)
        XCTAssertFalse(fileManager.fileExists(atPath: v1.appendingPathComponent("seen.json").path))
    }

    func testWritesLeaveNoTemporaryFiles() throws {
        let store = try makeStore()
        try start(store)
        _ = store.ingest([bare(t0 + 1), bare(t0 + 2)], inAppBinaryNames: names, nowMs: t0 + 10)
        let claimed = store.claim(max: 10, nowMs: t0 + 10)
        try store.settle(recordId: claimed[0].recordId, delivered: true, nowMs: t0 + 11)
        try store.settle(recordId: claimed[1].recordId, delivered: false, nowMs: t0 + 11)
        let leftovers = fileManager.enumerator(atPath: v1.path)?.compactMap { $0 as? String }.filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers ?? [], [])
    }
}
