import Dispatch
import Foundation

/// The process-wide collector (the native contract, "iOS"). Plugin
/// registration happens once per engine — the UI engine and every headless
/// background engine — but collection happens once per process: one run
/// record, one diagnostic subscriber, one store behind one serial queue.
///
/// Every completion and every arrival runs on that queue; the plugin hops to
/// the main thread. Nothing here throws into the host: every store operation
/// is guarded, and a failure costs only the report or the reply it was
/// handling.
public final class NativeCrashCollector {
    let run: RunInfo
    private let source: DiagnosticSource
    private let openStore: () throws -> NativeCrashStore
    private let binaryNames: () -> Set<String>
    private let clock: () -> Int64
    private let onArrivals: (Int) -> Void
    private let queue = DispatchQueue(label: "dev.noticebird.nativecrashes.collector", qos: .utility)

    private let activation = NSLock()
    private var activated = false

    /// Confined to `queue`.
    private var store: NativeCrashStore?
    private var cachedBinaryNames: Set<String>?

    /// This app's collector: a fresh run, the store in Application Support,
    /// the main bundle's binaries, the wall clock. [onArrivals] receives the
    /// number of records a delivery added to the inbox.
    public convenience init(source: DiagnosticSource, onArrivals: @escaping (Int) -> Void) {
        self.init(
            source: source,
            run: .current(),
            openStore: { try NativeCrashStore.inApplicationSupport() },
            inAppBinaryNames: { AppBundle.binaryNames() },
            clock: { epochMilliseconds(Date()) ?? 0 },
            onArrivals: onArrivals
        )
    }

    init(
        source: DiagnosticSource,
        run: RunInfo,
        openStore: @escaping () throws -> NativeCrashStore,
        inAppBinaryNames: @escaping () -> Set<String>,
        clock: @escaping () -> Int64,
        onArrivals: @escaping (Int) -> Void
    ) {
        self.source = source
        self.run = run
        self.openStore = openStore
        self.binaryNames = inAppBinaryNames
        self.clock = clock
        self.onArrivals = onArrivals
    }

    /// At every plugin registration; only the first does anything. The
    /// store opens — and the run is registered with it — before the source
    /// starts, so a diagnostic delivered right away is handled after it, on
    /// the same queue.
    public func activate() {
        activation.lock()
        let first = !activated
        activated = true
        activation.unlock()
        guard first else { return }
        queue.async { [self] in _ = currentStore() }
        source.start { [weak self] reports in self?.receive(reports) }
    }

    // MARK: - Channel methods

    /// `start`: replies `{"runId", "directory"}`, or an empty map on failure.
    public func start(_ options: CaptureOptions, completion: @escaping ([String: Any]) -> Void) {
        activate()
        queue.async { [self] in
            guard let store = currentStore() else { return completion([:]) }
            do {
                try store.start(options, run: run, nowMs: clock())
                completion(["runId": run.runId, "directory": store.directory.path])
            } catch {
                completion([:])
            }
        }
    }

    /// `claim`: up to [max] records as channel maps, each leased.
    public func claim(max: Int, completion: @escaping ([[String: Any]]) -> Void) {
        queue.async { [self] in
            let records = currentStore()?.claim(max: max, nowMs: clock()) ?? []
            completion(records.map(\.channelValue))
        }
    }

    /// `settle`.
    public func settle(recordId: String, delivered: Bool, completion: @escaping () -> Void) {
        queue.async { [self] in
            do {
                try currentStore()?.settle(recordId: recordId, delivered: delivered, nowMs: clock())
            } catch {
                // An unsettled claim expires with its lease.
            }
            completion()
        }
    }

    /// `disable`.
    public func disable(completion: @escaping () -> Void) {
        queue.async { [self] in
            do {
                try currentStore()?.disable()
            } catch {
                // Whatever could not be deleted now is purged at the next
                // registration or disable.
            }
            completion()
        }
    }

    // MARK: - Deliveries

    private func receive(_ reports: [DiagnosticReport]) {
        queue.async { [self] in
            guard let store = currentStore() else { return }
            let added = store.ingest(reports, inAppBinaryNames: inAppBinaryNames(), nowMs: clock())
            if added > 0 { onArrivals(added) }
        }
    }

    // MARK: - Queue-confined state

    /// The store, opened on first use. Opening registers this run with it,
    /// so the run is counted — and a dormant run records nothing — even when
    /// the store could only open after activation.
    private func currentStore() -> NativeCrashStore? {
        if let store { return store }
        guard let opened = try? openStore() else { return nil }
        store = opened
        do {
            try opened.registerProcess(run, nowMs: clock())
        } catch {
            // Unrecorded, the run's reports fall back to version matching.
        }
        return opened
    }

    private func inAppBinaryNames() -> Set<String> {
        if let cachedBinaryNames { return cachedBinaryNames }
        let names = binaryNames()
        cachedBinaryNames = names
        return names
    }
}

extension RunInfo {
    /// This process's run: a fresh random id, the pid, now, and the bundle's
    /// version and build.
    static func current(bundle: Bundle = .main) -> RunInfo {
        var generator = SystemRandomNumberGenerator()
        var runId = ""
        for _ in 0..<16 {
            let byte = UInt8.random(in: .min ... .max, using: &generator)
            runId += String(byte >> 4, radix: 16) + String(byte & 0x0F, radix: 16)
        }
        let info = bundle.infoDictionary ?? [:]
        #if DEBUG
        let debugBuild = true
        #else
        let debugBuild = false
        #endif
        return RunInfo(
            runId: runId,
            pid: Int64(ProcessInfo.processInfo.processIdentifier),
            startedAtMs: epochMilliseconds(Date()) ?? 0,
            appVersion: (info["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            appBuild: (info["CFBundleVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            debugBuild: debugBuild
        )
    }
}

/// The binaries that ship in the app bundle, by file name: what makes an
/// image in-app. Names are stable across builds; UUIDs are not.
enum AppBundle {
    static func binaryNames(bundle: Bundle = .main, fileManager: FileManager = .default) -> Set<String> {
        let entries = bundle.privateFrameworksURL.flatMap { try? fileManager.contentsOfDirectory(atPath: $0.path) }
        return binaryNames(executable: bundle.executableURL?.lastPathComponent, frameworkEntries: entries ?? [])
    }

    /// The main executable's name plus every binary in `Frameworks/`:
    /// `X.framework` is `X`, `libY.dylib` stays `libY.dylib`.
    static func binaryNames(executable: String?, frameworkEntries: [String]) -> Set<String> {
        var names = Set<String>()
        if let executable, !executable.isEmpty {
            names.insert(executable)
        }
        for entry in frameworkEntries {
            if entry.hasSuffix(".framework") {
                let name = String(entry.dropLast(".framework".count))
                if !name.isEmpty { names.insert(name) }
            } else if entry.hasSuffix(".dylib") {
                names.insert(entry)
            }
        }
        return names
    }
}
