package dev.noticebird.nativecrashes.core

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File

class CaptureCoreTest {
    @TempDir
    lateinit var root: File

    private val directory get() = File(root, "v1")
    private var now = 1_758_787_200_000L
    private var runs = 0

    /** A new process: its own platform, pid and run id, over the same files. */
    private fun process(exits: List<ExitReport> = emptyList(), pid: Int = 5000 + runs): Pair<CaptureCore, FakePlatform> {
        val platform = FakePlatform(now, pid).also { it.exits = exits }
        return CaptureCore(directory, platform, runIdOf(++runs)) to platform
    }

    private fun CaptureCore.started(strict: Boolean = false) = start(strict = strict, hangs = false, diskWrites = false)

    private fun CaptureCore.claimAll() = claim(20).map { StoredRecord.fromJson(it).record }

    private fun state() = InboxStore(directory) { now }.readState()

    @Test
    fun `before the first start, registration writes nothing and installs nothing`() {
        val (core, platform) = process(exits = listOf(exit(ExitReason.ANR, now - 1)))

        assertEquals(0, core.register())

        assertEquals(listOf(core.runId), platform.summaries)
        assertFalse(directory.exists())
        assertEquals(0, platform.installs)
        core.recordUncaught(Thread.currentThread(), IllegalStateException("before opt-in"))
        assertFalse(directory.exists())
    }

    @Test
    fun `start enables capture, records the run and replies its id and directory`() {
        val (core, platform) = process()
        core.register()

        val started = core.started()

        assertEquals(mapOf("runId" to core.runId, "directory" to directory.absolutePath), started.reply)
        assertEquals(CaptureState(enabled = true, exitWatermarkMs = now), state())
        assertTrue(File(directory, "runs/${core.runId}/run.json").isFile)
        assertEquals(1, platform.installs)
        assertTrue(Json.write(core.claim(20)) == "[]")
    }

    @Test
    fun `the watermark starts at the first enable and only newer exits are read`() {
        val (first, platform) = process()
        first.register()
        platform.exits = listOf(exit(ExitReason.ANR, now), exit(ExitReason.ANR, now - 60_000))
        first.started()
        assertEquals(emptyList<NativeCrashRecord>(), first.claimAll())

        val enabledAt = now
        now += 3_600_000
        val (second, _) = process(
            exits = listOf(
                exit(ExitReason.OTHER, enabledAt + 30),
                exit(ExitReason.ANR, enabledAt + 20, pid = 7),
                exit(ExitReason.ANR, enabledAt, pid = 8),
                exit(ExitReason.ANR, enabledAt - 10, pid = 9),
            ),
        )
        assertEquals(1, second.register())

        assertEquals(listOf(7), second.claimAll().map { it.pid })
        assertEquals(enabledAt + 30, state().exitWatermarkMs)

        // The same exits read again, at start and in the next process, add nothing.
        assertEquals(0, second.started().added)
        val (third, _) = process(exits = listOf(exit(ExitReason.ANR, enabledAt + 20, pid = 7)))
        assertEquals(0, third.register())
    }

    @Test
    fun `a later start keeps the watermark, a start after disable resets it`() {
        val (core, platform) = process()
        core.started()
        val enabledAt = now

        now += 1_000
        platform.now = now
        core.started()
        assertEquals(enabledAt, state().exitWatermarkMs)

        core.disable()
        now += 1_000
        platform.now = now
        platform.exits = listOf(exit(ExitReason.ANR, now - 1))
        core.started()
        assertEquals(now, state().exitWatermarkMs)
        assertEquals(emptyList<NativeCrashRecord>(), core.claimAll())
    }

    @Test
    fun `a JVM record and a REASON_CRASH exit of the same process merge into one`() {
        val (crashed, platform) = process(pid = 4312)
        crashed.started()
        now += 1_000
        platform.now = now
        platform.record!!(Thread.currentThread(), IllegalStateException("Fragment not attached"))

        now += 5_000
        val (next, _) = process(
            exits = listOf(
                exit(ExitReason.CRASH, now - 4_000, pid = 4312, runId = crashed.runId),
                exit(ExitReason.CRASH, now - 3_000, pid = 6000),
                exit(ExitReason.CRASH, now - 2_000, pid = 4312, runId = runIdOf(77)),
            ),
        )
        next.register()

        val records = next.claimAll()
        assertEquals(3, records.size)
        val jvm = records.single { it.source == RecordSource.JVM }
        assertEquals("java.lang.IllegalStateException", jvm.exceptionClass)
        assertEquals(crashed.runId, jvm.runId)
        assertEquals(4312, jvm.pid)
        // Another process, and a reused pid of another run, are reported on their own.
        assertEquals(
            setOf(6000 to null, 4312 to runIdOf(77)),
            records.filter { it.source == RecordSource.EXIT_INFO }.map { it.pid to it.runId }.toSet(),
        )
        assertTrue(records.filter { it.source == RecordSource.EXIT_INFO }.all { it.kind == RecordKind.CRASH && it.frames.isEmpty() })
    }

    @Test
    fun `a low-memory kill is reported only when foreground or visible`() {
        val (core, platform) = process()
        core.started()
        val importances = listOf(100, 125, 200, 230, 300, 325, 400, 1000)
        platform.exits = importances.mapIndexed { index, importance ->
            exit(ExitReason.LOW_MEMORY, now + 1 + index, pid = importance, importance = importance)
        }
        val (next, _) = process(exits = platform.exits)
        now += 10
        next.register()

        val records = next.claimAll()
        assertEquals(listOf(100, 125, 200), records.map { it.pid })
        assertTrue(records.all { it.kind == RecordKind.MEMORY_KILL && it.foreground == true })
    }

    @Test
    fun `native crashes carry their tombstone, ANRs their main thread`() {
        val (core, _) = process()
        core.started()
        val (next, _) = process(
            exits = listOf(
                exit(ExitReason.CRASH_NATIVE, now + 1, runId = core.runId, trace = Tombstones.realistic()),
                exit(ExitReason.ANR, now + 2, pid = 4400, importance = 300, trace = AnrTraces.realistic.toByteArray()),
                exit(ExitReason.CRASH_NATIVE, now + 3, pid = 4500, trace = byteArrayOf(0x0a, 0x7f)),
            ),
        )
        next.register()

        val (crash, anr, malformed) = next.claimAll()
        assertEquals("SIGABRT", crash.signal)
        assertEquals(8, crash.frames.size)
        assertEquals(Tombstones.ABORT_MESSAGE, crash.exceptionMessage)
        assertEquals(core.runId, crash.runId)
        assertEquals(RecordKind.ANR, anr.kind)
        assertEquals(false, anr.foreground)
        assertEquals(13, anr.frames.size)
        // A tombstone that does not parse costs its frames, not the report.
        assertEquals(RecordKind.CRASH, malformed.kind)
        assertNull(malformed.signal)
        assertEquals(emptyList<RecordFrame>(), malformed.frames)
    }

    @Test
    fun `strict writes no message, neither from a tombstone nor from the JVM`() {
        val (core, platform) = process()
        core.started(strict = true)
        platform.record!!(Thread.currentThread(), IllegalStateException("user@example.com"))
        val (next, _) = process(exits = listOf(exit(ExitReason.CRASH_NATIVE, now + 1, trace = Tombstones.realistic())))
        next.register()

        val records = next.claimAll()
        assertEquals(2, records.size)
        assertTrue(records.all { it.exceptionMessage == null })
        assertFalse(directory.walkTopDown().filter { it.isFile }.any { it.readText().contains("example.com") })
    }

    /**
     * Enables capture in a first process — which records a JVM crash when
     * [crashFirst] — then registers three processes that never call `start`.
     * Returns the first process.
     */
    private fun unconfirmedRuns(crashFirst: Boolean = false): CaptureCore {
        val (first, platform) = process()
        first.started()
        if (crashFirst) platform.record!!(Thread.currentThread(), IllegalStateException("crash on launch"))
        repeat(CaptureCore.MAX_UNCONFIRMED_RUNS) { index ->
            process().first.register()
            assertEquals(index + 1, state().unconfirmedRuns)
        }
        return first
    }

    @Test
    fun `after three runs without start, a registration with an empty inbox purges everything`() {
        unconfirmedRuns()
        now += 1_000

        val (purging, platform) = process(exits = listOf(exit(ExitReason.ANR, now - 1)))
        assertEquals(0, purging.register())

        assertEquals(listOf("state.json"), directory.tree())
        assertEquals(CaptureState.DISABLED, state())
        assertEquals(0, platform.installs)
    }

    @Test
    fun `after three runs without start, a registration with records keeps them and records nothing`() {
        val first = unconfirmedRuns(crashFirst = true)
        File(directory, "runs/${first.runId}/engine-0123456789abcdef.json").writeText("{}")
        val files = directory.tree()
        val counted = state()
        now += 1_000

        val (dormant, platform) = process(
            exits = listOf(exit(ExitReason.CRASH, now - 500, pid = 4400), exit(ExitReason.ANR, now - 400, pid = 4401)),
        )
        assertEquals(0, dormant.register())

        // No run.json, no exit read, no count, no handler: inbox and ledger as they were.
        assertEquals(files, directory.tree())
        assertEquals(counted, state())
        assertEquals(0, platform.installs)
        dormant.recordUncaught(Thread.currentThread(), RuntimeException("while dormant"))
        assertEquals(files, directory.tree())

        // A fixed build's start resumes: the run is recorded and the loop's exits read.
        assertEquals(2, dormant.started().added)
        assertTrue(File(directory, "runs/${dormant.runId}/run.json").isFile)
        assertEquals(1, platform.installs)
        assertEquals(counted.copy(unconfirmedRuns = 0, exitWatermarkMs = now - 400), state())
        val records = dormant.claimAll()
        assertEquals(listOf(RecordSource.JVM, RecordSource.EXIT_INFO, RecordSource.EXIT_INFO), records.map { it.source })
        assertEquals(listOf(4400, 4401), records.drop(1).map { it.pid })
    }

    @Test
    fun `dormant records still expire, and the registration that finds none left purges`() {
        unconfirmedRuns(crashFirst = true)
        now += 1_000
        assertEquals(0, process().first.register())
        assertEquals(1, File(directory, "inbox").list()!!.size)

        now += InboxStore.MAX_AGE_MS
        assertEquals(0, process().first.register())

        assertEquals(listOf("state.json"), directory.tree())
        assertEquals(CaptureState.DISABLED, state())
    }

    @Test
    fun `switching strict on strips every message in the inbox, keeping ids and claims`() {
        val (crashed, platform) = process()
        crashed.started()
        platform.record!!(Thread.currentThread(), IllegalStateException("user@example.com"))
        now += 1_000
        val (next, nextPlatform) = process(
            exits = listOf(
                exit(ExitReason.CRASH_NATIVE, now - 2, trace = Tombstones.realistic()),
                exit(ExitReason.ANR, now - 1, pid = 4400, trace = AnrTraces.realistic.toByteArray()),
            ),
        )
        assertEquals(2, next.register())
        assertEquals(1, next.claim(1).size)
        val before = InboxStore(directory) { now }.stored().associateBy { it.recordId }
        assertEquals(2, before.values.count { it.record.exceptionMessage != null })

        next.started(strict = true)

        val after = InboxStore(directory) { now }.stored()
        assertEquals(before.keys, after.map { it.recordId }.toSet())
        for (stored in after) {
            val original = before.getValue(stored.recordId)
            assertEquals(original.record.copy(exceptionMessage = null), stored.record)
            assertEquals(original.claimedUntilMs, stored.claimedUntilMs)
        }
        assertFalse(directory.walkTopDown().filter { it.isFile }.any { it.readText().contains("example.com") })
        // The channel carries each record's original id, the claimed one once its lease ends.
        nextPlatform.now = now + InboxStore.CLAIM_LEASE_MS
        val channel = next.claim(20)
        assertEquals(before.keys, channel.map { it["recordId"] }.toSet())
        assertTrue(channel.none { it.containsKey("exceptionMessage") })
    }

    @Test
    fun `a start that does not switch strict on leaves the messages, one after a lost state strips them`() {
        val (core, platform) = process()
        core.started()
        platform.record!!(Thread.currentThread(), IllegalStateException("user@example.com"))
        val before = InboxStore(directory) { now }.stored()

        core.started(strict = false)
        assertEquals(before, InboxStore(directory) { now }.stored())

        File(directory, "state.json").delete()
        core.started(strict = true)
        assertEquals(before.map { it.withoutMessage() }, InboxStore(directory) { now }.stored())
    }

    @Test
    fun `a delivered JVM record still merges with its REASON_CRASH exit read later`() {
        val (crashed, platform) = process(pid = 4312)
        crashed.started()
        now += 1_000
        platform.now = now
        platform.record!!(Thread.currentThread(), IllegalStateException("delivered before its exit is read"))
        val jvm = crashed.claimAll().single()
        crashed.settle(jvm.recordId, delivered = true)
        assertEquals(listOf(JvmCrash(4312, crashed.runId)), InboxStore(directory) { now }.readSeen().jvmCrashes)

        now += 5_000
        val (next, _) = process(
            exits = listOf(
                exit(ExitReason.CRASH, now - 4_000, pid = 4312, runId = crashed.runId),
                exit(ExitReason.CRASH, now - 3_500, pid = 4312),
                exit(ExitReason.CRASH, now - 3_000, pid = 4312, runId = runIdOf(77)),
                exit(ExitReason.CRASH, now - 2_000, pid = 6000),
            ),
        )
        next.register()

        // Another run that reused the pid, and another process, are reported on their own.
        assertEquals(setOf(4312 to runIdOf(77), 6000 to null), next.claimAll().map { it.pid to it.runId }.toSet())
    }

    @Test
    fun `start confirms the run and resets the count`() {
        val (first, _) = process()
        first.started()
        repeat(2) { process().first.register() }
        assertEquals(2, state().unconfirmedRuns)

        val (confirmed, _) = process()
        confirmed.register()
        assertEquals(3, state().unconfirmedRuns)
        confirmed.started()
        assertEquals(0, state().unconfirmedRuns)
        assertTrue(state().enabled)
    }

    @Test
    fun `disable deletes everything and stops recording`() {
        val (core, platform) = process()
        core.started()
        platform.record!!(Thread.currentThread(), RuntimeException("recorded"))
        assertEquals(1, core.claim(20).size)

        core.disable()
        platform.record!!(Thread.currentThread(), RuntimeException("not recorded"))

        assertEquals(listOf("state.json"), directory.tree())
        assertEquals("""{"enabled":false,"version":1}""", File(directory, "state.json").readText())
        assertEquals(emptyList<Map<String, Any>>(), core.claim(20))
    }

    @Test
    fun `claimed records cross the channel exactly as the contract describes`() {
        val (core, platform) = process()
        core.started()
        platform.record!!(Thread.currentThread(), IllegalStateException("boom"))
        val (next, _) = process(exits = listOf(exit(ExitReason.CRASH_NATIVE, now + 1, trace = Tombstones.realistic())))
        next.register()

        for (map in next.claim(20)) {
            assertTrue((NativeCrashRecord.CONTENT_KEYS + "recordId").containsAll(map.keys), map.keys.toString())
            assertFalse(map.containsKey("claimedUntilMs"))
            assertTrue(RecordRules.RECORD_ID.matches(map["recordId"] as String))
            assertEquals(1L, map["recordVersion"])
            assertTrue(map["occurredAtMs"] is Long)
            assertEquals(map["recordId"], StoredRecord.fromJson(map).record.recordId)
        }
        assertEquals(emptyList<Map<String, Any>>(), next.claim(20))
    }

    @Test
    fun `an exit reader that fails costs only that read, and start still replies`() {
        val (core, _) = process()
        core.started()
        val enabledAt = now
        now += 1_000
        val exits = listOf(exit(ExitReason.ANR, enabledAt + 10, pid = 7))
        val (failing, failingPlatform) = process(exits = exits)
        failingPlatform.exitsFailure = SecurityException("no exit info for you")

        assertEquals(0, failing.register())
        val started = failing.started()

        assertEquals(failing.runId, started.reply["runId"])
        assertEquals(enabledAt, state().exitWatermarkMs)
        assertTrue(failingPlatform.record != null)
        failingPlatform.exitsFailure = null
        assertEquals(1, failing.started().added)
        assertEquals(listOf(7), failing.claimAll().map { it.pid })
    }

    @Test
    fun `settle through the core deletes or rests a claimed record`() {
        val (core, platform) = process()
        core.started()
        platform.record!!(Thread.currentThread(), RuntimeException("one"))
        now += 1
        platform.now = now
        platform.record!!(Thread.currentThread(), RuntimeException("two"))
        val (delivered, queued) = core.claimAll()

        core.settle(delivered.recordId, delivered = true)
        core.settle(queued.recordId, delivered = false)

        val store = InboxStore(directory) { now }
        assertEquals(SeenSet(listOf(delivered.recordId), listOf(JvmCrash(platform.pid, core.runId))), store.readSeen())
        assertEquals(now + InboxStore.RETRY_LEASE_MS, store.stored().single().claimedUntilMs)
    }
}
