package dev.noticebird.nativecrashes.core

/** The allowlisted content of an Android tombstone. */
internal data class Tombstone(
    val arch: ImageArch?,
    val pid: Long?,
    val tid: Long?,
    val signalNumber: Int?,
    val signalName: String?,
    /** The signal code, the `int32` sign-extended to 64 bits. */
    val signalCode: Long?,
    val abortMessage: String?,
    /** The crashing thread's frames, top first, at most [RecordRules.MAX_FRAMES]. */
    val frames: List<TombstoneFrame>,
)

/** One `BacktraceFrame` of the crashing thread: never its absolute `pc`. */
internal data class TombstoneFrame(
    val relPc: Long,
    val functionName: String?,
    val fileName: String?,
    val buildId: String?,
)

/**
 * Reads the handful of `tombstone.proto` fields the contract uses from a
 * tombstone protobuf (`ApplicationExitInfo.getTraceInputStream()` of a
 * native crash, API 31+), skipping every other field by its wire type:
 *
 * - `Tombstone`: `arch` 1, `pid` 5, `tid` 6, `signal_info` 10,
 *   `abort_message` 14, `threads` 16 (`map<uint32, Thread>`).
 * - `Signal`: `number` 1, `name` 2, `code` 3.
 * - `Thread`: `id` 1, `current_backtrace` 4.
 * - `BacktraceFrame`: `rel_pc` 1, `function_name` 4, `file_name` 6,
 *   `build_id` 8.
 *
 * The whole tombstone is rejected (null) when it is larger than
 * [MAX_INPUT_BYTES] or malformed in any way.
 */
internal object TombstoneParser {
    const val MAX_INPUT_BYTES = 1 shl 20

    fun parse(bytes: ByteArray, length: Int = bytes.size): Tombstone? {
        if (length < 0 || length > MAX_INPUT_BYTES || length > bytes.size) return null
        return try {
            parseTombstone(ProtoReader.of(bytes, length))
        } catch (error: MalformedProtobufException) {
            null
        }
    }

    private fun parseTombstone(reader: ProtoReader): Tombstone {
        // proto3: an absent enum is its zero value, ARM32.
        var arch = 0L
        var pid: Long? = null
        var tid: Long? = null
        var signal: SignalInfo? = null
        var abortMessage: String? = null
        val threads = ArrayList<Pair<Long, ProtoReader>>()
        while (reader.nextField()) {
            when (reader.fieldNumber) {
                1 -> arch = reader.varint()
                5 -> pid = reader.varint() and 0xFFFFFFFFL
                6 -> tid = reader.varint() and 0xFFFFFFFFL
                10 -> signal = parseSignal(reader.message())
                14 -> abortMessage = reader.string()
                16 -> threads.add(parseThreadEntry(reader.message()))
                else -> reader.skip()
            }
        }
        val crashing = tid?.let { crashedTid ->
            threads.firstOrNull { (key, _) -> key == crashedTid }
        }
        val frames = crashing?.let { (key, thread) -> parseThread(thread, key) } ?: emptyList()
        return Tombstone(
            arch = when (arch) {
                0L -> ImageArch.ARMV7
                1L -> ImageArch.ARM64
                2L -> ImageArch.X86
                3L -> ImageArch.X86_64
                else -> null
            },
            pid = pid,
            tid = tid,
            signalNumber = signal?.number,
            signalName = signal?.name,
            signalCode = signal?.code,
            abortMessage = abortMessage,
            frames = frames,
        )
    }

    private class SignalInfo(val number: Int, val name: String?, val code: Long)

    private fun parseSignal(reader: ProtoReader): SignalInfo {
        var number = 0L
        var name: String? = null
        var code = 0L
        while (reader.nextField()) {
            when (reader.fieldNumber) {
                1 -> number = reader.varint()
                2 -> name = reader.string()
                3 -> code = reader.varint()
                else -> reader.skip()
            }
        }
        // int32 fields: the low 32 bits, sign-extended, as every protobuf
        // runtime reads them.
        return SignalInfo(number.toInt(), name, code.toInt().toLong())
    }

    /** A map entry: `key` 1 (the thread id), `value` 2 (the `Thread`), kept unparsed. */
    private fun parseThreadEntry(reader: ProtoReader): Pair<Long, ProtoReader> {
        var key = 0L
        var value: ProtoReader? = null
        while (reader.nextField()) {
            when (reader.fieldNumber) {
                1 -> key = reader.varint() and 0xFFFFFFFFL
                2 -> value = reader.message()
                else -> reader.skip()
            }
        }
        return key to (value ?: ProtoReader.of(ByteArray(0)))
    }

    private fun parseThread(reader: ProtoReader, key: Long): List<TombstoneFrame> {
        var id: Long? = null
        val frames = ArrayList<TombstoneFrame>()
        while (reader.nextField()) {
            when (reader.fieldNumber) {
                1 -> id = reader.varint() and 0xFFFFFFFFL
                4 -> {
                    val frame = parseFrame(reader.message())
                    if (frames.size < RecordRules.MAX_FRAMES) frames.add(frame)
                }
                else -> reader.skip()
            }
        }
        // The map key names the thread. A Thread.id that contradicts it means
        // the entry cannot be trusted to be the crashing thread: no frames
        // rather than another thread's.
        return if (id == null || id == key) frames else emptyList()
    }

    private fun parseFrame(reader: ProtoReader): TombstoneFrame {
        var relPc = 0L
        var functionName: String? = null
        var fileName: String? = null
        var buildId: String? = null
        while (reader.nextField()) {
            when (reader.fieldNumber) {
                1 -> relPc = reader.varint()
                4 -> functionName = reader.string()
                6 -> fileName = reader.string()
                8 -> buildId = reader.string()
                else -> reader.skip()
            }
        }
        return TombstoneFrame(relPc, functionName, fileName, buildId)
    }
}
