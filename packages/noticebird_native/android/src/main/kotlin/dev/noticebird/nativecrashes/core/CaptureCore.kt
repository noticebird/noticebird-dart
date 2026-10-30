package dev.noticebird.nativecrashes.core

import java.io.File
import java.io.IOException

/** What the core needs from the platform; the framework adapter implements it. */
internal interface CapturePlatform {
    val pid: Int

    fun nowMs(): Long

    /** The installed app, read once per process. */
    fun describeApp(): AppDescription

    /** `ActivityManager.setProcessStateSummary(runId)` (API 30+; no-op below). */
    fun setProcessStateSummary(runId: String)

    /** `getHistoricalProcessExitReasons(packageName, 0, 0)` (API 30+; empty below). */
    fun historicalExits(): List<ExitReport>

    /** Installs the chaining JVM handler once per process, recording through [record]. */
    fun installUncaughtExceptionHandler(record: (Thread, Throwable) -> Unit)
}

/** The app as `run.json` and the normalizer need it. */
internal data class AppDescription(
    val appVersion: String?,
    val appBuild: String?,
    val debugBuild: Boolean,
    val paths: AppPaths,
)

/**
 * This process's collector (the native contract): registration, the channel's
 * `start` / `claim` / `settle` / `disable`, the exit reader and the JVM
 * handler's record. Framework-free; the plugin calls it on one serial
 * thread, except [recordUncaught], which runs on the crashing thread.
 */
internal class CaptureCore(
    directory: File,
    private val platform: CapturePlatform,
    /** This process's run id: 32 lowercase hex characters. */
    val runId: String,
) {
    init {
        require(RecordRules.RUN_ID.matches(runId)) { "runId" }
    }

    val store = InboxStore(directory, platform::nowMs)
    private val startedAtMs = platform.nowMs()
    private val app by lazy { platform.describeApp() }
    private val normalizer by lazy { RecordNormalizer(app.paths) }

    /** Non-null while recording is enabled: what the JVM handler needs. */
    @Volatile
    private var recording: Recording? = null

    /** Built before the handler can run, so a crash never waits on `PackageManager`. */
    private class Recording(val strict: Boolean, val normalizer: RecordNormalizer)

    /**
     * At the first plugin registration in this process. Sets the process
     * state summary; when capture is enabled, counts this run as unconfirmed,
     * records it, installs the JVM handler and reads new exits — unless
     * [MAX_UNCONFIRMED_RUNS] runs in a row never called `start`: then this
     * run stays dormant. Returns how many records it added.
     */
    fun register(): Int {
        try {
            platform.setProcessStateSummary(runId)
        } catch (_: Exception) {
            // Without the summary, exits of this run are not linked to it.
        }
        return store.locked {
            val state = store.readState()
            if (!state.enabled) return@locked 0
            if (state.unconfirmedRuns >= MAX_UNCONFIRMED_RUNS) {
                stayDormant()
                return@locked 0
            }
            val counted = state.copy(unconfirmedRuns = state.unconfirmedRuns + 1)
            store.writeState(counted)
            store.removeTemporaryFiles()
            store.trim()
            activate(counted)
            readExitsGuarded(counted)
        }
    }

    /** The result of [start]: the channel reply and how many records it added. */
    class Started(val reply: Map<String, Any>, val added: Int)

    /**
     * Enables capture with these options, resets the unconfirmed-run count,
     * initializes the exit watermark to now on the first enable, records this
     * run — a dormant one too — installs the JVM handler and reads new exits.
     * Switching strict on strips the message from every record already in
     * the inbox.
     */
    fun start(strict: Boolean, hangs: Boolean, diskWrites: Boolean): Started = store.locked {
        val previous = store.readState()
        // Before the state is written, so a strip cut short is redone by the next start.
        if (strict && !(previous.enabled && previous.strict)) store.stripMessages()
        val watermark = previous.exitWatermarkMs.takeIf { previous.enabled } ?: platform.nowMs()
        val state = CaptureState(
            enabled = true,
            strict = strict,
            hangs = hangs,
            diskWrites = diskWrites,
            unconfirmedRuns = 0,
            exitWatermarkMs = watermark,
        )
        store.writeState(state)
        activate(state)
        val added = readExitsGuarded(state)
        Started(mapOf("runId" to runId, "directory" to store.directory.absolutePath), added)
    }

    /** Up to [max] records, claimed, as channel maps (no claim state). */
    fun claim(max: Int): List<Map<String, Any>> = store.locked {
        store.claim(max.coerceIn(0, InboxStore.MAX_RECORDS)).map { it.toJson() }
    }

    fun settle(recordId: String, delivered: Boolean) = store.locked { store.settle(recordId, delivered) }

    /** Deletes `v1/`, writes the disabled state and stops recording. */
    fun disable() = store.locked {
        recording = null
        store.purge()
    }

    /**
     * The JVM handler's step, on the crashing thread: one bounded record,
     * written synchronously while capture is enabled. It may throw; the
     * handler guards it and chains either way.
     */
    fun recordUncaught(thread: Thread, error: Throwable) {
        val options = recording ?: return
        val record = options.normalizer.jvmCrash(error, options.strict, runId, platform.pid, platform.nowMs())
        store.lockedOrNot(UNCAUGHT_LOCK_TIMEOUT_MS) { store.add(record) }
    }

    /**
     * A registration after [MAX_UNCONFIRMED_RUNS] runs without a `start` —
     * the host dropped native capture, or the app dies before Dart starts:
     * this run records nothing. Records still in the inbox — a crash-on-launch
     * loop's — wait for a fixed build's `start` until they expire; once none
     * is left, everything is purged.
     */
    private fun stayDormant() {
        store.removeTemporaryFiles()
        store.trim()
        if (store.stored().isEmpty()) store.purge()
    }

    /**
     * Starts recording: the run's `run.json` and the JVM handler. Each step
     * that fails costs only itself — a run without `run.json` loses its
     * attribution, a missing handler its JVM records — so `start` still
     * replies once `state.json` is written.
     */
    private fun activate(state: CaptureState) {
        recording = Recording(strict = state.strict, normalizer = normalizer)
        try {
            if (!store.hasRun(runId)) {
                store.writeRun(
                    RunRecord(
                        runId = runId,
                        pid = platform.pid,
                        startedAtMs = startedAtMs,
                        appVersion = app.appVersion,
                        appBuild = app.appBuild,
                        debugBuild = app.debugBuild,
                    ),
                )
            }
        } catch (_: IOException) {
            // The run's reports fall back to matching by version and time.
        }
        try {
            platform.installUncaughtExceptionHandler(::recordUncaught)
        } catch (_: Exception) {
            // Without the handler, JVM crashes arrive as REASON_CRASH exits.
        }
    }

    /**
     * [readExits], where a failure costs only this read: the watermark has
     * not moved, so the same exits are read again next time, and records
     * already added are refused by id.
     */
    private fun readExitsGuarded(state: CaptureState): Int = try {
        readExits(state)
    } catch (_: Exception) {
        0
    }

    /** Reads the exits newer than the watermark, adds their records, moves the watermark. */
    private fun readExits(state: CaptureState): Int {
        val watermark = state.exitWatermarkMs ?: return 0
        val reports = platform.historicalExits()
        if (reports.isEmpty()) return 0
        val jvmCrashes = store.stored().mapNotNull { JvmCrash.of(it.record) } + store.readSeen().jvmCrashes
        val result = ExitCollector.collect(reports, watermark, jvmCrashes, normalizer, state.strict)
        val added = result.records.count { store.add(it) }
        if (result.watermarkMs > watermark) store.writeState(state.copy(exitWatermarkMs = result.watermarkMs))
        return added
    }

    companion object {
        /** Registrations in a row without a `start` after which a run stays dormant. */
        const val MAX_UNCONFIRMED_RUNS = 3

        private const val UNCAUGHT_LOCK_TIMEOUT_MS = 250L
    }
}
