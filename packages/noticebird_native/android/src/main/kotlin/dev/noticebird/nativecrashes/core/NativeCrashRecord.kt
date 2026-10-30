package dev.noticebird.nativecrashes.core

import java.security.MessageDigest

/** `kind` of a record (the native contract). */
internal enum class RecordKind(val wire: String) {
    CRASH("crash"),
    WATCHDOG_KILL("watchdogKill"),
    ANR("anr"),
    MEMORY_KILL("memoryKill"),
    HANG("hang"),
    DISK_WRITE_EXCEPTION("diskWriteException"),
    ;

    companion object {
        fun fromWire(value: Any?): RecordKind? = entries.firstOrNull { it.wire == value }
    }
}

/** `source` of a record. */
internal enum class RecordSource(val wire: String) {
    METRIC_KIT("metricKit"),
    EXIT_INFO("exitInfo"),
    JVM("jvm"),
    ;

    companion object {
        fun fromWire(value: Any?): RecordSource? = entries.firstOrNull { it.wire == value }
    }
}

/** `arch` of an image. */
internal enum class ImageArch(val wire: String) {
    ARM64("arm64"),
    ARM64E("arm64e"),
    ARMV7("armv7"),
    X86_64("x86_64"),
    X86("x86"),
    ;

    companion object {
        fun fromWire(value: Any?): ImageArch? = entries.firstOrNull { it.wire == value }
    }
}

/** One binary image a frame points into: a basename, never a path. */
internal data class RecordImage(
    val name: String,
    val inApp: Boolean,
    val debugId: String? = null,
    val arch: ImageArch? = null,
) {
    init {
        require(RecordRules.IMAGE_NAME.matches(name)) { "image name" }
        require(debugId == null || RecordRules.DEBUG_ID.matches(debugId)) { "image debugId" }
    }

    fun toJson(): Map<String, Any> = buildMap {
        put("name", name)
        put("inApp", inApp)
        debugId?.let { put("debugId", it) }
        arch?.let { put("arch", it.wire) }
    }
}

/**
 * One frame, in one of the contract's shapes: `{image, offset, symbol?}`,
 * `{symbol, line?}`, or `{}` for a frame in no known image. Never an
 * absolute address.
 */
internal data class RecordFrame private constructor(
    val image: Int?,
    val offset: Long?,
    val symbol: String?,
    val line: Int?,
) {
    init {
        require((image == null) == (offset == null)) { "image and offset require each other" }
        require(image == null || image >= 0) { "image index" }
        require(offset == null || offset in 0..RecordRules.MAX_OFFSET) { "offset" }
        require(symbol == null || RecordRules.SYMBOL.matches(symbol)) { "symbol" }
        require(line == null || (line in 1..RecordRules.MAX_LINE && symbol != null && image == null)) { "line" }
    }

    fun toJson(): Map<String, Any> = buildMap {
        image?.let { put("image", it.toLong()) }
        offset?.let { put("offset", it) }
        symbol?.let { put("symbol", it) }
        line?.let { put("line", it.toLong()) }
    }

    companion object {
        fun inImage(image: Int, offset: Long, symbol: String? = null) = RecordFrame(image, offset, symbol, null)

        fun symbol(symbol: String, line: Int? = null) = RecordFrame(null, null, symbol, line)

        fun unknown() = RecordFrame(null, null, null, null)
    }
}

/**
 * One inbox record (the native contract, "The record"). Construction enforces
 * every value rule of the contract — the Dart codec rejects a record that
 * breaks any of them — so an invalid record cannot be written.
 */
internal data class NativeCrashRecord(
    val kind: RecordKind,
    val source: RecordSource,
    val occurredAtMs: Long,
    val machException: String? = null,
    val signal: String? = null,
    val code: String? = null,
    val terminationCode: String? = null,
    val exceptionClass: String? = null,
    val exceptionMessage: String? = null,
    val durationMs: Long? = null,
    val bytesWritten: Long? = null,
    val images: List<RecordImage> = emptyList(),
    val frames: List<RecordFrame> = emptyList(),
    val runId: String? = null,
    val pid: Int? = null,
    val appVersion: String? = null,
    val appBuild: String? = null,
    val foreground: Boolean? = null,
) {
    init {
        require(machException == null || RecordRules.MACH_EXCEPTION.matches(machException)) { "machException" }
        require(signal == null || RecordRules.SIGNAL.matches(signal)) { "signal" }
        require(code == null || RecordRules.HEX_CODE.matches(code)) { "code" }
        require(terminationCode == null || RecordRules.HEX_CODE.matches(terminationCode)) { "terminationCode" }
        require(exceptionClass == null || RecordRules.EXCEPTION_CLASS.matches(exceptionClass)) { "exceptionClass" }
        require(
            exceptionMessage == null ||
                (exceptionMessage.isNotEmpty() && exceptionMessage.length <= RecordRules.MAX_MESSAGE_LENGTH),
        ) { "exceptionMessage" }
        require(durationMs == null || (kind == RecordKind.HANG && durationMs in 0..RecordRules.MAX_HANG_MS)) {
            "durationMs"
        }
        require(
            bytesWritten == null ||
                (kind == RecordKind.DISK_WRITE_EXCEPTION && bytesWritten in 0..RecordRules.MAX_BYTES_WRITTEN),
        ) { "bytesWritten" }
        require(images.size <= RecordRules.MAX_IMAGES) { "images" }
        require(frames.size <= RecordRules.MAX_FRAMES) { "frames" }
        require(frames.all { frame -> frame.image == null || frame.image < images.size }) { "frame image index" }
        val referenced = frames.mapNotNullTo(HashSet()) { it.image }
        require(images.indices.all { it in referenced }) { "every image must be referenced by a frame" }
        require(runId == null || RecordRules.RUN_ID.matches(runId)) { "runId" }
        require(appVersion == null || appVersion.isNotEmpty()) { "appVersion" }
        require(appBuild == null || appBuild.isNotEmpty()) { "appBuild" }
    }

    /**
     * The id this record is created with: SHA-256 (lowercase hex) of its
     * canonical JSON without `recordId`. The inbox keeps it for the record's
     * life ([StoredRecord.recordId]), also after its message is stripped.
     */
    val recordId: String by lazy { sha256Hex(Json.write(contentJson())) }

    /**
     * The record's keys except `recordId`, unknown ones omitted. Every
     * integer is a `Long`, as [Json.parse] reads it back.
     */
    fun contentJson(): Map<String, Any> = buildMap {
        put("recordVersion", RECORD_VERSION.toLong())
        put("kind", kind.wire)
        put("source", source.wire)
        put("occurredAtMs", occurredAtMs)
        machException?.let { put("machException", it) }
        signal?.let { put("signal", it) }
        code?.let { put("code", it) }
        terminationCode?.let { put("terminationCode", it) }
        exceptionClass?.let { put("exceptionClass", it) }
        exceptionMessage?.let { put("exceptionMessage", it) }
        durationMs?.let { put("durationMs", it) }
        bytesWritten?.let { put("bytesWritten", it) }
        if (images.isNotEmpty()) put("images", images.map { it.toJson() })
        if (frames.isNotEmpty()) put("frames", frames.map { it.toJson() })
        runId?.let { put("runId", it) }
        pid?.let { put("pid", it.toLong()) }
        appVersion?.let { put("appVersion", it) }
        appBuild?.let { put("appBuild", it) }
        foreground?.let { put("foreground", it) }
    }

    companion object {
        const val RECORD_VERSION = 1

        /** The keys [contentJson] may write: the record's keys except `recordId`. */
        val CONTENT_KEYS = setOf(
            "recordVersion", "kind", "source", "occurredAtMs", "machException", "signal", "code",
            "terminationCode", "exceptionClass", "exceptionMessage", "durationMs", "bytesWritten", "images",
            "frames", "runId", "pid", "appVersion", "appBuild", "foreground",
        )

        /**
         * Reads a record from the form [contentJson] writes, rejecting — by
         * throwing — any key outside [CONTENT_KEYS], a wrong type or a broken
         * rule.
         */
        fun fromContentJson(json: Map<String, Any>): NativeCrashRecord {
            val unknown = json.keys - CONTENT_KEYS
            require(unknown.isEmpty()) { "unknown keys $unknown" }
            require(json.long("recordVersion") == RECORD_VERSION.toLong()) { "recordVersion" }
            return NativeCrashRecord(
                kind = requireNotNull(RecordKind.fromWire(json["kind"])) { "kind" },
                source = requireNotNull(RecordSource.fromWire(json["source"])) { "source" },
                occurredAtMs = requireNotNull(json.long("occurredAtMs")) { "occurredAtMs" },
                machException = json.string("machException"),
                signal = json.string("signal"),
                code = json.string("code"),
                terminationCode = json.string("terminationCode"),
                exceptionClass = json.string("exceptionClass"),
                exceptionMessage = json.string("exceptionMessage"),
                durationMs = json.long("durationMs"),
                bytesWritten = json.long("bytesWritten"),
                images = json.list("images").map { readImage(it) },
                frames = json.list("frames").map { readFrame(it) },
                runId = json.string("runId"),
                pid = json.long("pid")?.let { value ->
                    require(value in Int.MIN_VALUE..Int.MAX_VALUE) { "pid" }
                    value.toInt()
                },
                appVersion = json.string("appVersion"),
                appBuild = json.string("appBuild"),
                foreground = json.boolean("foreground"),
            )
        }

        private fun readImage(value: Any): RecordImage {
            val json = value.asObject()
            require((json.keys - setOf("name", "inApp", "debugId", "arch")).isEmpty()) { "image keys" }
            return RecordImage(
                name = requireNotNull(json.string("name")) { "image name" },
                inApp = requireNotNull(json.boolean("inApp")) { "image inApp" },
                debugId = json.string("debugId"),
                arch = json["arch"]?.let { requireNotNull(ImageArch.fromWire(it)) { "image arch" } },
            )
        }

        private fun readFrame(value: Any): RecordFrame {
            val json = value.asObject()
            require((json.keys - setOf("image", "offset", "symbol", "line")).isEmpty()) { "frame keys" }
            val image = json.long("image")
            val offset = json.long("offset")
            val symbol = json.string("symbol")
            val line = json.long("line")
            return when {
                image != null && offset != null -> {
                    require(line == null && image <= Int.MAX_VALUE) { "image frame" }
                    RecordFrame.inImage(image.toInt(), offset, symbol)
                }
                image != null || offset != null -> throw IllegalArgumentException("image and offset require each other")
                symbol != null -> {
                    require(line == null || line in 1..RecordRules.MAX_LINE) { "line" }
                    RecordFrame.symbol(symbol, line?.toInt())
                }
                else -> {
                    require(line == null) { "line without symbol" }
                    RecordFrame.unknown()
                }
            }
        }

        private fun Any.asObject(): Map<String, Any> {
            require(this is Map<*, *>) { "expected an object" }
            @Suppress("UNCHECKED_CAST")
            return this as Map<String, Any>
        }

        private fun Map<String, Any>.string(key: String): String? {
            val value = this[key] ?: return null
            require(value is String) { key }
            return value
        }

        private fun Map<String, Any>.long(key: String): Long? {
            val value = this[key] ?: return null
            require(value is Long) { key }
            return value
        }

        private fun Map<String, Any>.boolean(key: String): Boolean? {
            val value = this[key] ?: return null
            require(value is Boolean) { key }
            return value
        }

        private fun Map<String, Any>.list(key: String): List<Any> {
            val value = this[key] ?: return emptyList()
            require(value is List<*>) { key }
            @Suppress("UNCHECKED_CAST")
            return value as List<Any>
        }
    }
}

/** The contract's value rules, shared by the record model and the normalizer. */
internal object RecordRules {
    const val MAX_FRAMES = 64
    const val MAX_IMAGES = 32
    const val MAX_MESSAGE_LENGTH = 1024
    const val MAX_SYMBOL_LENGTH = 200
    const val MAX_IMAGE_NAME_LENGTH = 100
    const val MAX_EXCEPTION_CLASS_LENGTH = 160
    const val MAX_LINE = 1_000_000
    const val MAX_HANG_MS = 600_000L

    /** 2^48: beyond any image's text segment. */
    const val MAX_OFFSET = 281_474_976_710_656L

    /** 2^53. */
    const val MAX_BYTES_WRITTEN = 9_007_199_254_740_992L

    val MACH_EXCEPTION = Regex("^EXC_[A-Z_]{1,30}$")
    val SIGNAL = Regex("^SIG[A-Z0-9]{2,8}$")
    val HEX_CODE = Regex("^0x[0-9a-f]{1,16}$")
    val EXCEPTION_CLASS = Regex("^[A-Za-z0-9_$.]{1,160}$")
    val IMAGE_NAME = Regex("^[A-Za-z0-9_.+-]{1,100}$")
    val DEBUG_ID = Regex("^[0-9a-f]{32,40}$")
    val SYMBOL = Regex("^[A-Za-z0-9_$.<>:~]{1,200}$")
    val RUN_ID = Regex("^[0-9a-f]{32}$")
    val RECORD_ID = Regex("^[0-9a-f]{64}$")
}

internal fun sha256Hex(text: String): String =
    MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8)).toHex()

internal fun ByteArray.toHex(): String {
    val digits = "0123456789abcdef"
    val out = CharArray(size * 2)
    forEachIndexed { index, byte ->
        val value = byte.toInt() and 0xff
        out[index * 2] = digits[value ushr 4]
        out[index * 2 + 1] = digits[value and 0x0f]
    }
    return String(out)
}
