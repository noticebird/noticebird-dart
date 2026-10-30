package dev.noticebird.nativecrashes.core

import java.io.ByteArrayOutputStream
import java.io.InputStream

/** The `ApplicationExitInfo` reasons the contract distinguishes. */
internal enum class ExitReason { CRASH_NATIVE, ANR, LOW_MEMORY, CRASH, OTHER }

/**
 * One `ApplicationExitInfo`, as plain data: the boundary between the
 * framework adapter and the testable core.
 */
internal class ExitReport(
    val reason: ExitReason,
    /** `RunningAppProcessInfo.importance` at death. */
    val importance: Int,
    val pid: Int,
    val timestampMs: Long,
    /** What the process set with `setProcessStateSummary`: our run id. */
    val processStateSummary: ByteArray?,
    /**
     * Opens the exit's trace — the tombstone of a native crash (API 31+),
     * the ANR trace of an ANR — or null when it has none.
     */
    val openTrace: (() -> InputStream?)? = null,
) {
    /** The crashed run's id, when the summary is exactly one. */
    val runId: String?
        get() = processStateSummary
            ?.takeIf { it.size == RUN_ID_LENGTH }
            ?.toString(Charsets.UTF_8)
            ?.takeIf { RecordRules.RUN_ID.matches(it) }

    /** Foreground or visible at death. */
    val foreground: Boolean get() = importance <= IMPORTANCE_VISIBLE

    companion object {
        /** `ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE`. */
        const val IMPORTANCE_VISIBLE = 200

        private const val RUN_ID_LENGTH = 32
    }
}

/** Reads at most [limit] + 1 bytes, so a caller can tell an oversized input. */
internal object BoundedInput {
    class Bytes(val buffer: ByteArray, val length: Int) {
        fun exceeds(limit: Int) = length > limit
    }

    fun read(input: InputStream, limit: Int): Bytes {
        val out = ByteArrayOutputStream(minOf(limit + 1, 64 * 1024))
        val chunk = ByteArray(16 * 1024)
        var remaining = limit + 1
        while (remaining > 0) {
            val count = input.read(chunk, 0, minOf(chunk.size, remaining))
            if (count < 0) break
            out.write(chunk, 0, count)
            remaining -= count
        }
        val bytes = out.toByteArray()
        return Bytes(bytes, bytes.size)
    }
}

/**
 * Turns the exits newer than the watermark into records, per the
 * contract's reasons table:
 *
 * - `REASON_CRASH_NATIVE` → `crash`, with the tombstone when there is one.
 * - `REASON_ANR` → `anr`, with the trace's main thread.
 * - `REASON_LOW_MEMORY` → `memoryKill`, only when foreground or visible.
 * - `REASON_CRASH` → `crash` without frames, unless the JVM handler already
 *   wrote a record for that process — one still in the inbox, or one
 *   delivered already (`seen.json`'s `jvmCrashes`): same pid, and the same
 *   run id when both are known.
 * - everything else → nothing.
 *
 * The watermark moves to the newest exit read, reported or not.
 */
internal object ExitCollector {
    class Result(val records: List<NativeCrashRecord>, val watermarkMs: Long)

    fun collect(
        reports: List<ExitReport>,
        watermarkMs: Long,
        jvmCrashes: Collection<JvmCrash>,
        normalizer: RecordNormalizer,
        strict: Boolean,
    ): Result {
        var newest = watermarkMs
        val records = ArrayList<NativeCrashRecord>()
        for (report in reports) {
            if (report.timestampMs <= watermarkMs) continue
            newest = maxOf(newest, report.timestampMs)
            val record = try {
                normalize(report, jvmCrashes, normalizer, strict)
            } catch (_: Exception) {
                // One exit that cannot be normalized costs only itself.
                null
            }
            if (record != null) records.add(record)
        }
        return Result(records, newest)
    }

    private fun normalize(
        report: ExitReport,
        jvmCrashes: Collection<JvmCrash>,
        normalizer: RecordNormalizer,
        strict: Boolean,
    ): NativeCrashRecord? = when (report.reason) {
        ExitReason.CRASH_NATIVE -> normalizer.nativeCrash(
            report,
            readTrace(report, TombstoneParser.MAX_INPUT_BYTES)?.let { TombstoneParser.parse(it.buffer, it.length) },
            strict,
        )
        ExitReason.ANR -> normalizer.anr(
            report,
            readTrace(report, AnrTraceParser.MAX_INPUT_BYTES)?.let { AnrTraceParser.parse(it.buffer, it.length) }
                ?: emptyList(),
        )
        ExitReason.LOW_MEMORY -> if (report.foreground) normalizer.memoryKill(report) else null
        ExitReason.CRASH -> if (jvmCrashes.any { it.isSameProcessAs(report) }) null else normalizer.jvmCrashExit(report)
        ExitReason.OTHER -> null
    }

    private fun JvmCrash.isSameProcessAs(report: ExitReport): Boolean {
        if (pid != report.pid) return false
        val exitRunId = report.runId
        return runId == null || exitRunId == null || runId == exitRunId
    }

    /** The trace, capped; null when there is none or it cannot be read. */
    private fun readTrace(report: ExitReport, limit: Int): BoundedInput.Bytes? = try {
        report.openTrace?.invoke()?.use { BoundedInput.read(it, limit) }
    } catch (_: Exception) {
        null
    }
}
