package dev.noticebird.nativecrashes.core

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock

/** `state.json` (the native contract). */
internal data class CaptureState(
    val enabled: Boolean,
    val strict: Boolean = false,
    val hangs: Boolean = false,
    val diskWrites: Boolean = false,
    val unconfirmedRuns: Int = 0,
    val exitWatermarkMs: Long? = null,
) {
    /** A disabled state is written as `{"version":1,"enabled":false}` exactly. */
    fun toJson(): Map<String, Any> = if (!enabled) {
        mapOf("version" to VERSION, "enabled" to false)
    } else {
        buildMap {
            put("version", VERSION)
            put("enabled", true)
            put("strict", strict)
            put("hangs", hangs)
            put("diskWrites", diskWrites)
            put("unconfirmedRuns", unconfirmedRuns.toLong())
            exitWatermarkMs?.let { put("exitWatermarkMs", it) }
        }
    }

    companion object {
        const val VERSION = 1L
        val DISABLED = CaptureState(enabled = false)

        fun fromJson(json: Map<String, Any>): CaptureState {
            require(json["version"] == VERSION) { "version" }
            val allowed = setOf("version", "enabled", "strict", "hangs", "diskWrites", "unconfirmedRuns", "exitWatermarkMs")
            require((json.keys - allowed).isEmpty()) { "unknown keys" }
            val unconfirmedRuns = json.optional<Long>("unconfirmedRuns") ?: 0L
            require(unconfirmedRuns in 0..Int.MAX_VALUE) { "unconfirmedRuns" }
            return CaptureState(
                enabled = requireNotNull(json.optional<Boolean>("enabled")) { "enabled" },
                strict = json.optional<Boolean>("strict") ?: false,
                hangs = json.optional<Boolean>("hangs") ?: false,
                diskWrites = json.optional<Boolean>("diskWrites") ?: false,
                unconfirmedRuns = unconfirmedRuns.toInt(),
                exitWatermarkMs = json.optional<Long>("exitWatermarkMs"),
            )
        }
    }
}

/** `runs/<runId>/run.json`. */
internal data class RunRecord(
    val runId: String,
    val pid: Int,
    val startedAtMs: Long,
    val appVersion: String?,
    val appBuild: String?,
    val debugBuild: Boolean,
) {
    init {
        require(RecordRules.RUN_ID.matches(runId)) { "runId" }
    }

    fun toJson(): Map<String, Any> = buildMap {
        put("version", 1L)
        put("runId", runId)
        put("pid", pid.toLong())
        put("startedAtMs", startedAtMs)
        appVersion?.takeIf { it.isNotEmpty() }?.let { put("appVersion", it) }
        appBuild?.takeIf { it.isNotEmpty() }?.let { put("appBuild", it) }
        put("debugBuild", debugBuild)
    }
}

/**
 * An inbox record, its id and its claim state, which never crosses the
 * channel. The id is fixed when the record is created ([NativeCrashRecord.recordId]),
 * so it survives a later strip of the message.
 */
internal data class StoredRecord(
    val record: NativeCrashRecord,
    val claimedUntilMs: Long?,
    val recordId: String = record.recordId,
) {
    init {
        require(RecordRules.RECORD_ID.matches(recordId)) { "recordId" }
    }

    /** The record as it crosses the channel: its content and its id. */
    fun toJson(): Map<String, Any> = record.contentJson() + ("recordId" to recordId)

    /** The inbox file: the channel form and the claim state. */
    fun toInboxJson(): Map<String, Any> = claimedUntilMs?.let { toJson() + ("claimedUntilMs" to it) } ?: toJson()

    /** This record without `exceptionMessage`, for a switch to strict: same id, same claim state. */
    fun withoutMessage(): StoredRecord = copy(record = record.copy(exceptionMessage = null))

    companion object {
        /**
         * Reads the channel or the inbox form, rejecting — by throwing — a
         * malformed id or claim state and anything [NativeCrashRecord.fromContentJson]
         * rejects. The id is kept as stored and only its shape is checked:
         * it was fixed when the record was created, and a stripped record no
         * longer hashes to it.
         */
        fun fromJson(json: Map<String, Any>): StoredRecord {
            val recordId = json["recordId"]
            require(recordId is String) { "recordId" }
            val claimedUntilMs = json["claimedUntilMs"]
            require(claimedUntilMs == null || claimedUntilMs is Long) { "claimedUntilMs" }
            val record = NativeCrashRecord.fromContentJson(json - "recordId" - "claimedUntilMs")
            return StoredRecord(record, claimedUntilMs, recordId)
        }
    }
}

/**
 * A settled JVM record's process (`seen.json`'s `jvmCrashes`): its
 * `REASON_CRASH` exit, read after the record was delivered, is the same crash.
 */
internal data class JvmCrash(val pid: Int, val runId: String?) {
    init {
        require(runId == null || RecordRules.RUN_ID.matches(runId)) { "runId" }
    }

    fun toJson(): Map<String, Any> = buildMap {
        put("pid", pid.toLong())
        runId?.let { put("runId", it) }
    }

    companion object {
        /** The process of [record] when it is a JVM record with a pid; null otherwise. */
        fun of(record: NativeCrashRecord): JvmCrash? =
            record.pid?.takeIf { record.source == RecordSource.JVM }?.let { JvmCrash(it, record.runId) }

        /** Reads one entry; keys another writer added are ignored. */
        fun fromJson(value: Any?): JvmCrash {
            require(value is Map<*, *>) { "jvmCrash" }
            val pid = value["pid"]
            require(pid is Long && pid in Int.MIN_VALUE..Int.MAX_VALUE) { "pid" }
            val runId = value["runId"]
            require(runId == null || runId is String) { "runId" }
            return JvmCrash(pid.toInt(), runId)
        }
    }
}

/** `seen.json`: what was settled recently, newest last. */
internal data class SeenSet(val ids: List<String> = emptyList(), val jvmCrashes: List<JvmCrash> = emptyList()) {
    /** This set with [recordId] and, when given, [jvmCrash] added as the newest, each list capped. */
    fun adding(recordId: String, jvmCrash: JvmCrash?): SeenSet = SeenSet(
        ids = (ids - recordId + recordId).takeLast(MAX_IDS),
        jvmCrashes = jvmCrash?.let { (jvmCrashes - it + it).takeLast(MAX_JVM_CRASHES) } ?: jvmCrashes,
    )

    /** `jvmCrashes` is optional: written only when it holds an entry. */
    fun toJson(): Map<String, Any> = buildMap {
        put("version", VERSION)
        put("ids", ids)
        if (jvmCrashes.isNotEmpty()) put("jvmCrashes", jvmCrashes.map { it.toJson() })
    }

    companion object {
        const val VERSION = 1L
        const val MAX_IDS = 256
        const val MAX_JVM_CRASHES = 16

        /**
         * Reads the set, rejecting — by throwing — another version or a
         * malformed `ids` or `jvmCrashes`. Keys another writer added are
         * ignored, so they never cost the set.
         */
        fun fromJson(json: Map<String, Any>): SeenSet {
            require(json["version"] == VERSION) { "version" }
            val ids = json["ids"]
            require(ids is List<*> && ids.all { it is String && RecordRules.RECORD_ID.matches(it) }) { "ids" }
            val jvmCrashes = json["jvmCrashes"] ?: emptyList<Any>()
            require(jvmCrashes is List<*>) { "jvmCrashes" }
            return SeenSet(
                ids = ids.map { it as String }.takeLast(MAX_IDS),
                jvmCrashes = jvmCrashes.map(JvmCrash::fromJson).takeLast(MAX_JVM_CRASHES),
            )
        }
    }
}

/**
 * The collector's files under `v1/` (the native contract, "Storage"): the
 * state, the seen-set, the inbox and the native half of the run ledger.
 *
 * Every write is atomic (`<name>.tmp`, then a rename over `<name>`); a file
 * that cannot be parsed is deleted. Compound operations hold [lock]; the
 * collector serializes its own calls on one thread and the JVM handler
 * takes the lock with a timeout.
 */
internal class InboxStore(val directory: File, private val clock: () -> Long) {
    val lock = ReentrantLock()

    private val inbox get() = File(directory, "inbox")
    private val runs get() = File(directory, "runs")
    private val stateFile get() = File(directory, "state.json")
    private val seenFile get() = File(directory, "seen.json")

    inline fun <T> locked(action: () -> T): T {
        lock.lock()
        try {
            return action()
        } finally {
            lock.unlock()
        }
    }

    /**
     * Runs [action] holding the lock when it can be had within [timeoutMs],
     * and without it otherwise: for the JVM handler, which must not wait on
     * a stuck thread while the process dies. Every file write is atomic, so
     * the worst an unlocked add can do is miss a cap until the next trim.
     */
    inline fun <T> lockedOrNot(timeoutMs: Long, action: () -> T): T {
        val acquired = try {
            lock.tryLock(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        try {
            return action()
        } finally {
            if (acquired) lock.unlock()
        }
    }

    // --- state.json ---------------------------------------------------------

    /** The state; [CaptureState.DISABLED] when there is none or it is unreadable. */
    fun readState(): CaptureState = readJsonObject(stateFile)?.let { json ->
        try {
            CaptureState.fromJson(json)
        } catch (_: IllegalArgumentException) {
            stateFile.delete()
            null
        }
    } ?: CaptureState.DISABLED

    fun writeState(state: CaptureState) = writeAtomic(stateFile, Json.write(state.toJson()))

    /** Deletes `v1/` entirely and writes the disabled state. */
    fun purge() {
        directory.deleteRecursively()
        writeState(CaptureState.DISABLED)
    }

    // --- seen.json ----------------------------------------------------------

    /** What was settled recently; empty when there is no seen-set or it is unreadable. */
    fun readSeen(): SeenSet = readJsonObject(seenFile)?.let { json ->
        try {
            SeenSet.fromJson(json)
        } catch (_: IllegalArgumentException) {
            seenFile.delete()
            null
        }
    } ?: SeenSet()

    private fun addSeen(recordId: String, jvmCrash: JvmCrash?) =
        writeAtomic(seenFile, Json.write(readSeen().adding(recordId, jvmCrash).toJson()))

    // --- inbox --------------------------------------------------------------

    /**
     * Adds [record] unless the inbox holds it or it was settled recently, then
     * trims the inbox. True when the record is in the inbox afterwards.
     */
    fun add(record: NativeCrashRecord): Boolean {
        val id = record.recordId
        val file = recordFile(id)
        if (file.exists() || id in readSeen().ids) return false
        writeRecord(StoredRecord(record, claimedUntilMs = null))
        trim()
        return file.exists()
    }

    /** Every readable inbox record; unreadable ones are deleted. */
    fun stored(): List<StoredRecord> {
        val files = inbox.listFiles() ?: return emptyList()
        val records = ArrayList<StoredRecord>()
        for (file in files) {
            if (file.name.endsWith(TEMPORARY_SUFFIX)) continue
            val stored = readRecord(file)
            if (stored != null) records.add(stored) else file.delete()
        }
        return records
    }

    /** Deletes records older than 30 days, then keeps the newest [MAX_RECORDS]. */
    fun trim() {
        val oldest = clock() - MAX_AGE_MS
        val kept = stored().filter { stored ->
            (stored.record.occurredAtMs >= oldest).also { keep ->
                if (!keep) recordFile(stored.recordId).delete()
            }
        }
        kept.sortedWith(compareByDescending<StoredRecord> { it.record.occurredAtMs }.thenBy { it.recordId })
            .drop(MAX_RECORDS)
            .forEach { recordFile(it.recordId).delete() }
    }

    /**
     * Expires old records, then claims up to [max] of the oldest unclaimed
     * ones (no lease, or one in the past) for [CLAIM_LEASE_MS]. A record whose
     * lease cannot be written is not claimed.
     */
    fun claim(max: Int): List<StoredRecord> {
        if (max <= 0) return emptyList()
        trim()
        val now = clock()
        return stored()
            .filter { it.claimedUntilMs == null || it.claimedUntilMs <= now }
            .sortedWith(compareBy<StoredRecord> { it.record.occurredAtMs }.thenBy { it.recordId })
            .take(max)
            .mapNotNull { stored ->
                val claimed = stored.copy(claimedUntilMs = now + CLAIM_LEASE_MS)
                try {
                    writeRecord(claimed)
                    claimed
                } catch (_: IOException) {
                    null
                }
            }
    }

    /**
     * Ends a claim: [delivered] deletes the record and remembers its id —
     * and, for a JVM record, its process — else the record rests for
     * [RETRY_LEASE_MS]. An unknown id changes nothing.
     */
    fun settle(recordId: String, delivered: Boolean) {
        if (!RecordRules.RECORD_ID.matches(recordId)) return
        val file = recordFile(recordId)
        if (!file.exists()) return
        if (delivered) {
            addSeen(recordId, readRecord(file)?.let { JvmCrash.of(it.record) })
            file.delete()
            return
        }
        val stored = readRecord(file)
        if (stored == null) {
            file.delete()
            return
        }
        writeRecord(stored.copy(claimedUntilMs = clock() + RETRY_LEASE_MS))
    }

    /**
     * Removes `exceptionMessage` from every inbox record, for a switch to
     * strict. Each record keeps its id and claim state, and is rewritten
     * atomically; one that cannot be rewritten is deleted, so no message
     * outlives the switch.
     */
    fun stripMessages() {
        for (stored in stored()) {
            if (stored.record.exceptionMessage == null) continue
            try {
                writeRecord(stored.withoutMessage())
            } catch (_: IOException) {
                recordFile(stored.recordId).delete()
            }
        }
    }

    private fun recordFile(recordId: String) = File(inbox, "$recordId.json")

    private fun writeRecord(stored: StoredRecord) =
        writeAtomic(recordFile(stored.recordId), Json.write(stored.toInboxJson()))

    private fun readRecord(file: File): StoredRecord? {
        if (!RECORD_FILE_NAME.matches(file.name)) return null
        val json = readJsonObject(file) ?: return null
        return try {
            StoredRecord.fromJson(json).also { require(file.name == "${it.recordId}.json") { "file name" } }
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    // --- runs ---------------------------------------------------------------

    fun hasRun(runId: String): Boolean = File(runs, "$runId/run.json").isFile

    /**
     * Writes [run]'s `run.json`, then keeps the [MAX_RUNS] run directories with
     * the newest `startedAtMs` — [run]'s always among them — and deletes the
     * rest. A directory without a readable `run.json` counts as oldest.
     */
    fun writeRun(run: RunRecord) {
        writeAtomic(File(runs, "${run.runId}/run.json"), Json.write(run.toJson()))
        val others = (runs.listFiles() ?: return)
            .filter { it.isDirectory && it.name != run.runId }
            .sortedWith(compareByDescending<File> { startedAtMs(it) ?: Long.MIN_VALUE }.thenBy { it.name })
        others.drop(MAX_RUNS - 1).forEach { it.deleteRecursively() }
    }

    private fun startedAtMs(runDirectory: File): Long? {
        val json = readJsonObject(File(runDirectory, "run.json"), deleteUnreadable = false) ?: return null
        return (json["startedAtMs"] as? Long)?.takeIf { json["version"] == 1L }
    }

    // --- files --------------------------------------------------------------

    /** Removes temporary files a killed write left behind in `v1/` and the inbox. */
    fun removeTemporaryFiles() {
        for (folder in listOf(directory, inbox)) {
            folder.listFiles()?.filter { it.isFile && it.name.endsWith(TEMPORARY_SUFFIX) }?.forEach { it.delete() }
        }
    }

    private fun readJsonObject(file: File, deleteUnreadable: Boolean = true): Map<String, Any>? {
        if (!file.isFile) return null
        val parsed = try {
            if (file.length() > MAX_FILE_BYTES) throw JsonFormatException("oversized")
            Json.parse(file.readBytes().toString(Charsets.UTF_8))
        } catch (_: JsonFormatException) {
            null
        } catch (_: IOException) {
            return null
        }
        if (parsed !is Map<*, *>) {
            if (deleteUnreadable) file.delete()
            return null
        }
        @Suppress("UNCHECKED_CAST")
        return parsed as Map<String, Any>
    }

    private fun writeAtomic(target: File, text: String) {
        val folder = target.parentFile ?: throw IOException("no parent")
        if (!folder.isDirectory && !folder.mkdirs() && !folder.isDirectory) throw IOException("cannot create $folder")
        val temporary = File(folder, target.name + TEMPORARY_SUFFIX)
        try {
            FileOutputStream(temporary).use { out ->
                out.write(text.toByteArray(Charsets.UTF_8))
                out.fd.sync()
            }
            if (!temporary.renameTo(target)) throw IOException("cannot rename to $target")
        } catch (error: IOException) {
            temporary.delete()
            throw error
        }
    }

    companion object {
        const val MAX_RECORDS = 20
        const val MAX_RUNS = 5
        const val MAX_AGE_MS = 30L * 24 * 60 * 60 * 1000
        const val CLAIM_LEASE_MS = 10L * 60 * 1000
        const val RETRY_LEASE_MS = 24L * 60 * 60 * 1000
        private const val MAX_FILE_BYTES = 256L * 1024
        private const val TEMPORARY_SUFFIX = ".tmp"
        private val RECORD_FILE_NAME = Regex("^[0-9a-f]{64}\\.json$")
    }
}

private inline fun <reified T> Map<String, Any>.optional(key: String): T? {
    val value = this[key] ?: return null
    require(value is T) { key }
    return value
}
