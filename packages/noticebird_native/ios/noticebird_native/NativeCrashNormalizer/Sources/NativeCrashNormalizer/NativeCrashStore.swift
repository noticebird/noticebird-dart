import Foundation

/// The capture options `start` passes.
public struct CaptureOptions: Equatable, Sendable {
    public var strict: Bool
    public var hangs: Bool
    public var diskWrites: Bool

    public init(strict: Bool, hangs: Bool, diskWrites: Bool) {
        self.strict = strict
        self.hangs = hangs
        self.diskWrites = diskWrites
    }
}

/// This process's run, recorded in `runs/<runId>/run.json`.
struct RunInfo: Equatable {
    let runId: String
    let pid: Int64
    let startedAtMs: Int64
    let appVersion: String?
    let appBuild: String?
    let debugBuild: Bool

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "version": .integer(1),
            "runId": .string(runId),
            "pid": .integer(pid),
            "startedAtMs": .integer(startedAtMs),
            "debugBuild": .bool(debugBuild),
        ]
        object["appVersion"] = appVersion.map(JSONValue.string)
        object["appBuild"] = appBuild.map(JSONValue.string)
        return .object(object)
    }
}

/// `state.json`.
struct StoreState: Equatable {
    var enabled = false
    var strict = true
    var hangs = false
    var diskWrites = false
    var unconfirmedRuns: Int64 = 0
    /// On iOS: when capture was first enabled. Diagnostics from before are
    /// not recorded — they predate the opt-in.
    var exitWatermarkMs: Int64?

    static let disabled = StoreState()

    /// Nil when [json] is not a version-1 state.
    init?(json: JSONValue) {
        guard let object = json.objectValue, object["version"] == .integer(1),
              let enabled = object["enabled"]?.boolValue
        else { return nil }
        self.enabled = enabled
        guard enabled else { return }
        // A missing option fails closed: strict unless it says otherwise.
        strict = object["strict"]?.boolValue ?? true
        hangs = object["hangs"]?.boolValue ?? false
        diskWrites = object["diskWrites"]?.boolValue ?? false
        unconfirmedRuns = max(0, object["unconfirmedRuns"]?.integerValue ?? 0)
        exitWatermarkMs = object["exitWatermarkMs"]?.integerValue
    }

    init() {}

    var json: JSONValue {
        guard enabled else { return .object(["version": .integer(1), "enabled": .bool(false)]) }
        var object: [String: JSONValue] = [
            "version": .integer(1),
            "enabled": .bool(true),
            "strict": .bool(strict),
            "hangs": .bool(hangs),
            "diskWrites": .bool(diskWrites),
            "unconfirmedRuns": .integer(unconfirmedRuns),
        ]
        object["exitWatermarkMs"] = exitWatermarkMs.map(JSONValue.integer)
        return .object(object)
    }

    func records(_ kind: DiagnosticKind) -> Bool {
        switch kind {
        case .crash: return true
        case .hang: return hangs
        case .diskWriteException: return diskWrites
        }
    }
}

/// The on-disk half of the collector (the native contract, "Storage"):
/// `Application Support/noticebird_native/v1/` with the state, the
/// seen-set, the inbox and the run records.
///
/// Not thread-safe by design: the collector calls it from one serial queue
/// only, which is what makes claims atomic across engines. One store serves
/// one process: besides the files it holds whether this run records at all
/// (a dormant run does not, see [registerProcess]). Foundation only,
/// so it is tested with `swift test` like the normalizer; the backup
/// exclusion exists where backups do (iOS, macOS). Every write is a
/// temporary file renamed over the target; every unreadable file is deleted.
/// It uses no required-reason API: no `UserDefaults`, no file timestamps
/// (the times live inside the files), no disk-space queries.
final class NativeCrashStore {
    static let maxInboxRecords = 20
    static let maxRecordAgeMs: Int64 = 30 * 24 * 60 * 60 * 1000
    static let maxSeenIds = 256
    static let maxRuns = 5
    static let claimLeaseMs: Int64 = 10 * 60 * 1000
    static let retryLeaseMs: Int64 = 24 * 60 * 60 * 1000
    static let maxUnconfirmedRuns: Int64 = 3
    /// MetricKit stamps a payload with the start of the period it covers,
    /// which may be coarser than the crash itself, so the opt-in filter
    /// allows a day of slack rather than drop a crash of the first minutes.
    static let optInSlackMs: Int64 = 24 * 60 * 60 * 1000
    /// Diagnostics normalized per delivery; the inbox keeps 20 anyway.
    static let maxReportsPerDelivery = 64
    /// No file of ours comes near this; anything larger is not ours.
    static let maxFileBytes = 256 * 1024

    /// `noticebird_native/`, excluded from backups.
    let rootDirectory: URL
    /// `noticebird_native/v1/`.
    let directory: URL
    private let fileManager: FileManager
    private var excludedFromBackup = false
    /// This run records nothing: set at registration after too many
    /// unconfirmed runs, cleared by `start`.
    private var dormant = false

    private var stateURL: URL { directory.appendingPathComponent("state.json") }
    private var seenURL: URL { directory.appendingPathComponent("seen.json") }
    private var inboxDirectory: URL { directory.appendingPathComponent("inbox", isDirectory: true) }
    private var runsDirectory: URL { directory.appendingPathComponent("runs", isDirectory: true) }

    init(rootDirectory: URL, fileManager: FileManager = .default) throws {
        self.rootDirectory = rootDirectory
        self.directory = rootDirectory.appendingPathComponent("v1", isDirectory: true)
        self.fileManager = fileManager
        try ensureDirectories()
    }

    /// The store in this app's Application Support directory.
    static func inApplicationSupport(fileManager: FileManager = .default) throws -> NativeCrashStore {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return try NativeCrashStore(
            rootDirectory: support.appendingPathComponent("noticebird_native", isDirectory: true),
            fileManager: fileManager
        )
    }

    // MARK: - Lifecycle

    /// At the first plugin registration of a process, while enabled: count
    /// the run as unconfirmed until `start` confirms it, and record it.
    ///
    /// After three unconfirmed runs in a row (the host removed native
    /// capture, or the app dies before Dart starts) this run is dormant: it
    /// writes no run record and no diagnostic until a `start`. With an empty
    /// inbox everything is purged. A non-empty inbox is kept with the ledger,
    /// so a crash-on-launch loop's reports reach the platform once a fixed
    /// build starts again; its records still expire, and the first
    /// registration that finds it empty purges.
    func registerProcess(_ run: RunInfo, nowMs: Int64) throws {
        var state = loadState()
        dormant = state.enabled && state.unconfirmedRuns >= Self.maxUnconfirmedRuns
        guard state.enabled else { return }
        if dormant {
            if expire(loadInbox(), nowMs: nowMs).isEmpty { try purge() }
            return
        }
        state.unconfirmedRuns += 1
        try save(state)
        try recordRun(run)
    }

    /// `start`: enable capture with [options], confirm the run, and record it
    /// if registration did not — a dormant run records again from here.
    /// Switching `strict` on strips the messages already in the inbox first.
    func start(_ options: CaptureOptions, run: RunInfo, nowMs: Int64) throws {
        var state = loadState()
        if options.strict, !(state.enabled && state.strict) {
            stripExceptionMessages()
        }
        state.enabled = true
        state.strict = options.strict
        state.hangs = options.hangs
        state.diskWrites = options.diskWrites
        state.unconfirmedRuns = 0
        if state.exitWatermarkMs == nil { state.exitWatermarkMs = nowMs }
        try save(state)
        dormant = false
        try recordRun(run)
    }

    /// `disable`: delete everything and stay disabled.
    func disable() throws {
        try purge()
    }

    func loadState() -> StoreState {
        guard let json = readJSON(stateURL), let state = StoreState(json: json) else {
            removeItem(stateURL)
            return .disabled
        }
        return state
    }

    private func save(_ state: StoreState) throws {
        try ensureDirectories()
        try write(state.json, to: stateURL)
    }

    private func purge() throws {
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try save(.disabled)
    }

    // MARK: - Runs

    /// Writes this run's `run.json` once, then keeps the five newest runs.
    private func recordRun(_ run: RunInfo) throws {
        let runDirectory = runsDirectory.appendingPathComponent(run.runId, isDirectory: true)
        let runFile = runDirectory.appendingPathComponent("run.json")
        guard !fileManager.fileExists(atPath: runFile.path) else { return }
        try fileManager.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        try write(run.json, to: runFile)
        pruneRuns(keeping: run.runId)
    }

    /// Keeps the run directories with the newest `startedAtMs` (a directory
    /// without a readable `run.json` counts as oldest) — and always the
    /// current one, whatever the clock says.
    private func pruneRuns(keeping currentRunId: String) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: runsDirectory.path) else { return }
        var others: [(name: String, startedAtMs: Int64)] = []
        for name in names where name != currentRunId {
            let url = runsDirectory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                removeItem(url)
                continue
            }
            let run = readJSON(url.appendingPathComponent("run.json"))?.objectValue
            others.append((name, run?["startedAtMs"]?.integerValue ?? .min))
        }
        others.sort { ($0.startedAtMs, $0.name) > ($1.startedAtMs, $1.name) }
        for stale in others.dropFirst(Self.maxRuns - 1) {
            removeItem(runsDirectory.appendingPathComponent(stale.name))
        }
    }

    // MARK: - Inbox

    private struct InboxEntry {
        let record: NativeCrashRecord
        let claimedUntilMs: Int64?
    }

    /// Normalizes and records what a delivery holds, under the current
    /// state; returns how many records it added to the inbox. A dormant run
    /// drops it unread.
    func ingest(_ reports: [DiagnosticReport], inAppBinaryNames: Set<String>, nowMs: Int64) -> Int {
        guard !dormant else { return 0 }
        let state = loadState()
        guard state.enabled else { return 0 }
        let wanted = reports.filter { state.records($0.kind) }
            .sorted { $0.occurredAtMs > $1.occurredAtMs }
            .prefix(Self.maxReportsPerDelivery)
        let records = wanted.compactMap { report in
            NativeCrashNormalizer.normalize(
                report.json,
                context: NormalizationContext(
                    kind: report.kind,
                    occurredAtMs: report.occurredAtMs,
                    inAppBinaryNames: inAppBinaryNames,
                    strict: state.strict,
                    hangDurationMs: report.hangDurationMs,
                    bytesWritten: report.bytesWritten
                )
            )
        }
        return add(records, state: state, nowMs: nowMs)
    }

    private func add(_ records: [NativeCrashRecord], state: StoreState, nowMs: Int64) -> Int {
        var entries = expire(loadInbox(), nowMs: nowMs)
        var known = Set(entries.map(\.record.recordId)).union(loadSeen())
        var added = Set<String>()
        for record in records {
            guard !known.contains(record.recordId),
                  record.occurredAtMs >= Self.subtract(nowMs, Self.maxRecordAgeMs),
                  record.occurredAtMs >= Self.subtract(state.exitWatermarkMs ?? .min, Self.optInSlackMs),
                  !state.strict || record.fields.exceptionMessage == nil
            else { continue }
            do {
                try writeEntry(InboxEntry(record: record, claimedUntilMs: nil))
            } catch {
                continue
            }
            entries.append(InboxEntry(record: record, claimedUntilMs: nil))
            known.insert(record.recordId)
            added.insert(record.recordId)
        }
        // Over the cap, the oldest go first — new ones included.
        let ordered = entries.sorted(by: Self.oldestFirst)
        for entry in ordered.prefix(max(0, ordered.count - Self.maxInboxRecords)) {
            removeItem(inboxURL(entry.record.recordId))
            added.remove(entry.record.recordId)
        }
        return added.count
    }

    /// `claim`: the oldest unclaimed records, each leased for 10 minutes.
    func claim(max: Int, nowMs: Int64) -> [NativeCrashRecord] {
        guard max > 0, loadState().enabled else { return [] }
        let claimable = expire(loadInbox(), nowMs: nowMs)
            .filter { ($0.claimedUntilMs ?? .min) <= nowMs }
            .sorted(by: Self.oldestFirst)
            .prefix(Swift.min(max, Self.maxInboxRecords))
        var claimed: [NativeCrashRecord] = []
        for entry in claimable {
            do {
                try writeEntry(InboxEntry(record: entry.record, claimedUntilMs: Self.add(nowMs, Self.claimLeaseMs)))
                claimed.append(entry.record)
            } catch {
                // Not leased, so not handed out: it stays claimable.
            }
        }
        return claimed
    }

    /// `settle`: a delivered record is deleted and remembered as seen; an
    /// undelivered one is leased for 24 hours. An unknown id does nothing.
    func settle(recordId: String, delivered: Bool, nowMs: Int64) throws {
        guard NativeCrashRecord.isRecordId(recordId), let entry = loadEntry(inboxURL(recordId)),
              entry.record.recordId == recordId
        else { return }
        if delivered {
            removeItem(inboxURL(recordId))
            var seen = loadSeen().filter { $0 != recordId }
            seen.append(recordId)
            // Only what iOS keeps: Android's `jvmCrashes` never applies here.
            try write(.object([
                "version": .integer(1),
                "ids": .array(seen.suffix(Self.maxSeenIds).map(JSONValue.string)),
            ]), to: seenURL)
        } else {
            try writeEntry(InboxEntry(record: entry.record, claimedUntilMs: Self.add(nowMs, Self.retryLeaseMs)))
        }
    }

    private func loadInbox() -> [InboxEntry] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: inboxDirectory.path) else { return [] }
        var entries: [InboxEntry] = []
        for name in names {
            let url = inboxDirectory.appendingPathComponent(name)
            // Anything but `<recordId>.json` — a leftover temporary file
            // included — is not a record.
            let recordId = name.hasSuffix(".json") ? String(name.dropLast(5)) : ""
            guard NativeCrashRecord.isRecordId(recordId) else {
                removeItem(url)
                continue
            }
            guard let entry = loadEntry(url), entry.record.recordId == recordId else {
                removeItem(url)
                continue
            }
            entries.append(entry)
        }
        return entries
    }

    private func loadEntry(_ url: URL) -> InboxEntry? {
        guard var object = readJSON(url)?.objectValue else { return nil }
        var claimedUntilMs: Int64?
        if let claim = object.removeValue(forKey: "claimedUntilMs") {
            guard let value = claim.integerValue else { return nil }
            claimedUntilMs = value
        }
        guard let record = NativeCrashRecord(json: .object(object)) else { return nil }
        return InboxEntry(record: record, claimedUntilMs: claimedUntilMs)
    }

    private func writeEntry(_ entry: InboxEntry) throws {
        guard var object = entry.record.json.objectValue else { return }
        object["claimedUntilMs"] = entry.claimedUntilMs.map(JSONValue.integer)
        try ensureDirectories()
        try write(.object(object), to: inboxURL(entry.record.recordId))
    }

    /// Removes `exceptionMessage` from every inbox record, keeping each
    /// record's id and claim. A record that cannot be rewritten is deleted
    /// rather than keep its message.
    private func stripExceptionMessages() {
        for entry in loadInbox() where entry.record.fields.exceptionMessage != nil {
            let stripped = InboxEntry(record: entry.record.withoutExceptionMessage(), claimedUntilMs: entry.claimedUntilMs)
            do {
                try writeEntry(stripped)
            } catch {
                removeItem(inboxURL(entry.record.recordId))
            }
        }
    }

    /// Deletes records older than 30 days and returns the rest.
    private func expire(_ entries: [InboxEntry], nowMs: Int64) -> [InboxEntry] {
        let oldest = Self.subtract(nowMs, Self.maxRecordAgeMs)
        return entries.filter { entry in
            guard entry.record.occurredAtMs < oldest else { return true }
            removeItem(inboxURL(entry.record.recordId))
            return false
        }
    }

    private func inboxURL(_ recordId: String) -> URL {
        inboxDirectory.appendingPathComponent(recordId + ".json")
    }

    private static func oldestFirst(_ a: InboxEntry, _ b: InboxEntry) -> Bool {
        (a.record.occurredAtMs, a.record.recordId) < (b.record.occurredAtMs, b.record.recordId)
    }

    // MARK: - Seen

    /// The settled ids of `seen.json`. Other keys are ignored, Android's
    /// optional `jvmCrashes` among them: it does not make the file unreadable.
    private func loadSeen() -> [String] {
        guard let json = readJSON(seenURL) else { return [] }
        guard let object = json.objectValue, object["version"] == .integer(1),
              let ids = object["ids"]?.arrayValue
        else {
            removeItem(seenURL)
            return []
        }
        return Array(ids.compactMap(\.stringValue).filter(NativeCrashRecord.isRecordId).suffix(Self.maxSeenIds))
    }

    // MARK: - Files

    private func ensureDirectories() throws {
        if !fileManager.fileExists(atPath: rootDirectory.path) {
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            excludedFromBackup = false
        }
        if !excludedFromBackup {
            #if os(iOS) || os(macOS)
            var root = rootDirectory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try root.setResourceValues(values)
            #endif
            excludedFromBackup = true
        }
        try fileManager.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runsDirectory, withIntermediateDirectories: true)
    }

    /// Writes `<name>.tmp` beside [url], then renames it over [url].
    private func write(_ value: JSONValue, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".tmp")
        try value.canonicalData.write(to: temporary)
        guard rename(temporary.path, url.path) == 0 else {
            removeItem(temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// The JSON in [url]; nil when there is none. A file that cannot be read
    /// or parsed is deleted.
    private func readJSON(_ url: URL) -> JSONValue? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = readCapped(url), let json = JSONValue(parsing: data) else {
            removeItem(url)
            return nil
        }
        return json
    }

    private func readCapped(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maxFileBytes + 1), data.count <= Self.maxFileBytes else {
            return nil
        }
        return data
    }

    private func removeItem(_ url: URL) {
        try? fileManager.removeItem(at: url)
    }

    private static func add(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : sum
    }

    private static func subtract(_ a: Int64, _ b: Int64) -> Int64 {
        let (difference, overflow) = a.subtractingReportingOverflow(b)
        return overflow ? .min : difference
    }
}
