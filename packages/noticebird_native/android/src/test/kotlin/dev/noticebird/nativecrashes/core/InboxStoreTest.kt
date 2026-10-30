package dev.noticebird.nativecrashes.core

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File

class InboxStoreTest {
    @TempDir
    lateinit var root: File

    private var now = 1_758_787_200_000L
    private val directory get() = File(root, "v1")
    private val store by lazy { InboxStore(directory, clock = { now }) }

    private fun record(occurredAtMs: Long, pid: Int = 1) =
        NativeCrashRecord(kind = RecordKind.ANR, source = RecordSource.EXIT_INFO, occurredAtMs = occurredAtMs, pid = pid)

    private fun jvm(pid: Int, runId: String? = null, message: String? = "user@example.com") = NativeCrashRecord(
        kind = RecordKind.CRASH,
        source = RecordSource.JVM,
        occurredAtMs = now,
        exceptionClass = "java.lang.IllegalStateException",
        exceptionMessage = message,
        runId = runId,
        pid = pid,
    )

    private fun inboxIds() = store.stored().map { it.recordId }.toSet()

    private fun claim(max: Int) = store.claim(max).map { it.record }

    @Test
    fun `adds a record once, as its own atomically written file`() {
        val record = record(now)

        assertTrue(store.add(record))
        assertFalse(store.add(record))
        assertEquals(listOf("inbox/${record.recordId}.json"), directory.tree())
        assertEquals(StoredRecord(record, null), store.stored().single())
    }

    @Test
    fun `keeps at most 20 records, the newest`() {
        val records = (1..25).map { record(now - 1_000L * (25 - it)) }
        records.forEach { store.add(it) }

        assertEquals(records.takeLast(20).map { it.recordId }.toSet(), inboxIds())
        // A record older than all 20 kept does not displace one.
        assertFalse(store.add(record(now - 1_000_000)))
        assertEquals(20, store.stored().size)
    }

    @Test
    fun `expires records older than 30 days`() {
        val old = record(now - InboxStore.MAX_AGE_MS - 1)
        val recent = record(now - InboxStore.MAX_AGE_MS + 1)

        assertFalse(store.add(old))
        assertTrue(store.add(recent))
        now += 2
        assertEquals(emptyList<NativeCrashRecord>(), claim(10))
        assertEquals(emptySet<String>(), inboxIds())
    }

    @Test
    fun `claims the oldest unclaimed records for 10 minutes`() {
        val (first, second, third) = (1..3).map { record(now - 100L + it) }
        listOf(third, first, second).forEach { store.add(it) }

        assertEquals(listOf(first, second), claim(2))
        assertEquals(listOf(third), claim(2))
        assertEquals(emptyList<NativeCrashRecord>(), claim(2))

        now += InboxStore.CLAIM_LEASE_MS - 1
        assertEquals(emptyList<NativeCrashRecord>(), claim(5))
        now += 1
        assertEquals(listOf(first, second, third), claim(5))
        assertEquals(emptyList<NativeCrashRecord>(), claim(0))
    }

    @Test
    fun `the claim state lives in the file and never in the record`() {
        val record = record(now)
        store.add(record)
        store.claim(1)

        val text = File(directory, "inbox/${record.recordId}.json").readText()
        assertEquals(
            """{"claimedUntilMs":${now + InboxStore.CLAIM_LEASE_MS},"kind":"anr","occurredAtMs":$now,"pid":1,""" +
                """"recordId":"${record.recordId}","recordVersion":1,"source":"exitInfo"}""",
            text,
        )
        assertEquals(record, store.stored().single().record)
    }

    @Test
    fun `settling delivered deletes the record and remembers its id`() {
        val record = record(now)
        store.add(record)
        store.claim(1)

        store.settle(record.recordId, delivered = true)

        assertEquals(emptySet<String>(), inboxIds())
        assertEquals(SeenSet(ids = listOf(record.recordId)), store.readSeen())
        assertFalse(store.add(record))
    }

    @Test
    fun `settling undelivered rests the record for 24 hours`() {
        val record = record(now)
        store.add(record)
        store.claim(1)

        store.settle(record.recordId, delivered = false)

        now += InboxStore.CLAIM_LEASE_MS
        assertEquals(emptyList<NativeCrashRecord>(), claim(1))
        now += InboxStore.RETRY_LEASE_MS - InboxStore.CLAIM_LEASE_MS
        assertEquals(listOf(record), claim(1))
    }

    @Test
    fun `settling an unknown or malformed id changes nothing`() {
        val record = record(now)
        store.add(record)
        File(root, "outside.json").writeText("{}")
        val before = root.tree()

        store.settle("a".repeat(64), delivered = true)
        store.settle("../outside", delivered = true)
        store.settle("../../outside.json", delivered = false)

        assertEquals(before, root.tree())
        assertEquals(SeenSet(), store.readSeen())
    }

    @Test
    fun `the seen-set keeps the last 256 ids, newest last`() {
        val records = (1..300).map { record(now, pid = it) }
        for (record in records) {
            store.add(record)
            store.settle(record.recordId, delivered = true)
        }

        assertEquals(records.takeLast(256).map { it.recordId }, store.readSeen().ids)
        assertTrue(store.add(records.first()))
        assertFalse(store.add(records.last()))
    }

    @Test
    fun `a delivered JVM record is remembered by its process, its run id only when known`() {
        val withRun = jvm(pid = 4312, runId = runIdOf(1))
        val withoutRun = jvm(pid = 4313)
        val exitRecord = record(now, pid = 4314)
        val undelivered = jvm(pid = 4315, runId = runIdOf(2))
        listOf(withRun, withoutRun, exitRecord, undelivered).forEach { store.add(it) }

        store.settle(withRun.recordId, delivered = true)
        store.settle(withoutRun.recordId, delivered = true)
        store.settle(exitRecord.recordId, delivered = true)
        store.settle(undelivered.recordId, delivered = false)

        assertEquals(
            """{"ids":["${withRun.recordId}","${withoutRun.recordId}","${exitRecord.recordId}"],""" +
                """"jvmCrashes":[{"pid":4312,"runId":"${runIdOf(1)}"},{"pid":4313}],"version":1}""",
            File(directory, "seen.json").readText(),
        )
        assertEquals(listOf(JvmCrash(4312, runIdOf(1)), JvmCrash(4313, null)), store.readSeen().jvmCrashes)
    }

    @Test
    fun `the seen-set remembers the last 16 JVM crashes, newest last`() {
        val records = (1..20).map { jvm(pid = it, runId = runIdOf(it)) }
        for (record in records) {
            store.add(record)
            store.settle(record.recordId, delivered = true)
        }

        assertEquals(records.takeLast(16).map { JvmCrash(it.pid!!, it.runId) }, store.readSeen().jvmCrashes)
        assertEquals(records.map { it.recordId }, store.readSeen().ids)
        val written = Json.parse(File(directory, "seen.json").readText()) as Map<*, *>
        assertEquals(16, (written["jvmCrashes"] as List<*>).size)
    }

    @Test
    fun `keys another writer added to the seen-set do not cost it, a malformed known key does`() {
        directory.mkdirs()
        val seen = File(directory, "seen.json")
        val id = "a".repeat(64)
        seen.writeText(
            """{"version":1,"ids":["$id"],"jvmCrashes":[{"pid":7,"runId":"${runIdOf(1)}","tid":9},{"pid":8}],""" +
                """"hangs":{"ids":[]}}""",
        )

        assertEquals(SeenSet(listOf(id), listOf(JvmCrash(7, runIdOf(1)), JvmCrash(8, null))), store.readSeen())
        assertTrue(seen.exists())

        seen.writeText("""{"version":1,"ids":["$id"],"jvmCrashes":[{"pid":"7"}]}""")
        assertEquals(SeenSet(), store.readSeen())
        assertFalse(seen.exists())
    }

    @Test
    fun `stripping messages keeps each record's id and claim state`() {
        val claimed = jvm(pid = 1, message = "claimed secret")
        val unclaimed = jvm(pid = 2, message = "unclaimed secret")
        val withoutMessage = record(now, pid = 3)
        listOf(claimed, unclaimed, withoutMessage).forEach { store.add(it) }
        store.claim(1)
        val before = store.stored().associateBy { it.recordId }
        val untouched = File(directory, "inbox/${withoutMessage.recordId}.json").readText()

        store.stripMessages()

        // Read back from the files by another store, as the next process would.
        val after = InboxStore(directory) { now }.stored()
        assertEquals(before.keys, after.map { it.recordId }.toSet())
        for (stored in after) {
            val original = before.getValue(stored.recordId)
            assertEquals(original.record.copy(exceptionMessage = null), stored.record)
            assertEquals(original.claimedUntilMs, stored.claimedUntilMs)
        }
        assertEquals(now + InboxStore.CLAIM_LEASE_MS, after.single { it.recordId == claimed.recordId }.claimedUntilMs)
        assertEquals(untouched, File(directory, "inbox/${withoutMessage.recordId}.json").readText())
        assertFalse(directory.walkTopDown().filter { it.isFile }.any { it.readText().contains("secret") })
        // The stripped records keep ids their content no longer hashes to, and are settled by them.
        assertEquals(
            setOf(claimed.recordId, unclaimed.recordId),
            after.filter { it.recordId != it.record.recordId }.map { it.recordId }.toSet(),
        )
        store.settle(unclaimed.recordId, delivered = true)
        assertEquals(listOf(unclaimed.recordId), store.readSeen().ids)
        assertEquals(listOf(JvmCrash(2, null)), store.readSeen().jvmCrashes)
    }

    @Test
    fun `purge leaves only the disabled state`() {
        store.add(record(now))
        store.writeState(CaptureState(enabled = true, exitWatermarkMs = now))
        store.writeRun(RunRecord(runIdOf(1), 1, now, "1.0", "1", false))

        store.purge()

        assertEquals(listOf("state.json"), directory.tree())
        assertEquals("""{"enabled":false,"version":1}""", File(directory, "state.json").readText())
        assertEquals(CaptureState.DISABLED, store.readState())
    }

    @Test
    fun `the state round-trips, and an enabled one carries every key`() {
        val state = CaptureState(true, strict = true, hangs = true, diskWrites = false, unconfirmedRuns = 2, exitWatermarkMs = now)
        store.writeState(state)

        assertEquals(state, store.readState())
        assertEquals(
            """{"diskWrites":false,"enabled":true,"exitWatermarkMs":$now,"hangs":true,"strict":true,"unconfirmedRuns":2,"version":1}""",
            File(directory, "state.json").readText(),
        )
    }

    @Test
    fun `unreadable files are skipped and deleted`() {
        val kept = record(now)
        store.add(kept)
        val inbox = File(directory, "inbox")
        val keptJson = StoredRecord(kept, null).toJson()
        val files = mapOf(
            "${"b".repeat(64)}.json" to "{not json",
            "${"c".repeat(64)}.json" to Json.write(keptJson + ("recordId" to "C".repeat(64))),
            "${"d".repeat(64)}.json" to Json.write(keptJson),
            "${"e".repeat(64)}.json" to Json.write(keptJson + ("unknown" to true)),
            "notes.txt" to "hello",
        )
        files.forEach { (name, text) -> File(inbox, name).writeText(text) }
        File(directory, "state.json").writeText("""{"version":2,"enabled":true}""")
        File(directory, "seen.json").writeText("""{"version":1,"ids":["short"]}""")

        assertEquals(listOf(kept), store.stored().map { it.record })
        assertEquals(listOf("${kept.recordId}.json"), inbox.list()!!.toList())
        assertEquals(CaptureState.DISABLED, store.readState())
        assertEquals(SeenSet(), store.readSeen())
        assertFalse(File(directory, "state.json").exists())
        assertFalse(File(directory, "seen.json").exists())
    }

    @Test
    fun `temporary files of an interrupted write are removed, not read`() {
        val record = record(now)
        store.add(record)
        File(directory, "state.json.tmp").writeText("{")
        File(directory, "inbox/${"f".repeat(64)}.json.tmp").writeText("{")

        assertEquals(listOf(record), store.stored().map { it.record })
        store.removeTemporaryFiles()

        assertEquals(listOf("inbox/${record.recordId}.json"), directory.tree())
    }

    @Test
    fun `keeps the 5 newest runs, the current one always, unreadable ones first to go`() {
        val runs = File(directory, "runs")
        for (index in 1..6) {
            store.writeRun(RunRecord(runIdOf(index), index, now + index, "1.0", "1", false))
            File(runs, "${runIdOf(index)}/engine-0123456789abcdef.json").writeText("{}")
        }
        File(runs, "unreadable").mkdirs()
        File(runs, "unreadable/run.json").writeText("{broken")

        // The current run started before every other one (a clock change).
        store.writeRun(RunRecord(runIdOf(99), 99, now - 1_000, null, null, true))

        assertEquals(
            listOf(runIdOf(3), runIdOf(4), runIdOf(5), runIdOf(6), runIdOf(99)).sorted(),
            runs.list()!!.sorted(),
        )
        assertEquals(
            """{"debugBuild":true,"pid":99,"runId":"${runIdOf(99)}","startedAtMs":${now - 1_000},"version":1}""",
            File(runs, "${runIdOf(99)}/run.json").readText(),
        )
        assertTrue(File(runs, "${runIdOf(6)}/engine-0123456789abcdef.json").exists())
        assertTrue(store.hasRun(runIdOf(99)))
    }

    @Test
    fun `run json carries versions when known`() {
        store.writeRun(RunRecord(runIdOf(1), 4312, now, "1.4.0", "140", false))

        assertEquals(
            """{"appBuild":"140","appVersion":"1.4.0","debugBuild":false,"pid":4312,"runId":"${runIdOf(1)}","startedAtMs":$now,"version":1}""",
            File(directory, "runs/${runIdOf(1)}/run.json").readText(),
        )
    }
}
