package dev.noticebird.nativecrashes.core

/** One frame of the ANR trace's main thread. */
internal sealed interface AnrFrame {
    /** `native: #NN pc <hex> <path> (<function>+<offset>) (BuildId: <hex>)`. */
    data class Native(
        val relPc: Long,
        val path: String,
        val functionName: String?,
        val buildId: String?,
    ) : AnrFrame

    /** `at <class>.<method>(<File>:<line>)`. */
    data class Managed(val symbol: String, val line: Int?) : AnrFrame
}

/**
 * Reads the `"main"` thread's frames from an ANR trace
 * (`ApplicationExitInfo.getTraceInputStream()` of `REASON_ANR`), top first,
 * at most [RecordRules.MAX_FRAMES]. Every other thread and every other line
 * — locks, registers, the header — is ignored.
 *
 * The trace is line-oriented and ART dumps the main thread first, so only
 * the first [MAX_INPUT_BYTES] are read; a line cut off at that limit is
 * dropped rather than half-parsed.
 */
internal object AnrTraceParser {
    const val MAX_INPUT_BYTES = 1 shl 20

    private val nativeLine = Regex("""^native: #\d{1,4} pc ([0-9a-fA-F]{1,16}) +(\S+)(.*)$""")
    private val buildIdSuffix = Regex("""\(BuildId: ([0-9a-fA-F]{1,128})\)\s*$""")
    private val offsetPrefix = Regex("""^\(offset 0x[0-9a-fA-F]{1,16}\)\s*""")
    private val deletedPrefix = Regex("""^\(deleted\)\s*""")
    private val functionOffset = Regex("""^(.*)\+\d{1,20}$""")
    private val managedLine = Regex("""^at ([^\s(]{1,1000})\((.{0,1000})\)$""")
    private val lineNumber = Regex(""":(\d{1,7})$""")

    fun parse(bytes: ByteArray, length: Int = bytes.size): List<AnrFrame> {
        val available = minOf(length, bytes.size, MAX_INPUT_BYTES)
        if (available <= 0) return emptyList()
        var text = String(bytes, 0, available, Charsets.UTF_8)
        if (length > MAX_INPUT_BYTES) {
            val lastBreak = text.lastIndexOf('\n')
            text = if (lastBreak < 0) "" else text.substring(0, lastBreak)
        }
        val frames = ArrayList<AnrFrame>()
        var inMain = false
        for (rawLine in text.lineSequence()) {
            if (!inMain) {
                if (rawLine.startsWith("\"main\" ")) inMain = true
                continue
            }
            if (rawLine.isBlank() || rawLine.startsWith("\"") || rawLine.startsWith("-----")) break
            val line = rawLine.trim()
            val frame = parseNative(line) ?: parseManaged(line) ?: continue
            frames.add(frame)
            if (frames.size == RecordRules.MAX_FRAMES) break
        }
        return frames
    }

    private fun parseNative(line: String): AnrFrame.Native? {
        val match = nativeLine.matchEntire(line) ?: return null
        val relPc = parseHex(match.groupValues[1])
        val path = match.groupValues[2]
        var rest = match.groupValues[3].trim()
        val buildId = buildIdSuffix.find(rest)?.let { found ->
            rest = rest.substring(0, found.range.first).trim()
            found.groupValues[1]
        }
        rest = deletedPrefix.replaceFirst(rest, "")
        rest = offsetPrefix.replaceFirst(rest, "").trim()
        val functionName = if (rest.length >= 2 && rest.startsWith("(") && rest.endsWith(")")) {
            val inner = rest.substring(1, rest.length - 1)
            (functionOffset.matchEntire(inner)?.groupValues?.get(1) ?: inner).takeIf { it.isNotEmpty() }
        } else {
            null
        }
        return AnrFrame.Native(relPc, path, functionName, buildId)
    }

    /** Up to 16 hex digits as the unsigned 64-bit value's bits (`Long.parseUnsignedLong` needs API 26). */
    private fun parseHex(digits: String): Long {
        var value = 0L
        for (digit in digits) value = (value shl 4) or Character.digit(digit, 16).toLong()
        return value
    }

    private fun parseManaged(line: String): AnrFrame.Managed? {
        val match = managedLine.matchEntire(line) ?: return null
        val location = match.groupValues[2]
        val lineValue = lineNumber.find(location)?.groupValues?.get(1)?.toIntOrNull()
        return AnrFrame.Managed(match.groupValues[1], lineValue?.takeIf { it in 1..RecordRules.MAX_LINE })
    }
}
