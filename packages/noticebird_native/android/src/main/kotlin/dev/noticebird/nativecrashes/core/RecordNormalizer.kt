package dev.noticebird.nativecrashes.core

/**
 * Builds a record's `images` and `frames` under the contract's bounds:
 * at most [RecordRules.MAX_FRAMES] frames, top first; at most
 * [RecordRules.MAX_IMAGES] images, each referenced by a frame and indexed in
 * order of first reference; offsets relative to the image, never absolute.
 */
internal class FrameAssembler(private val appPaths: AppPaths, private val arch: ImageArch?) {
    private val images = ArrayList<RecordImage>()
    private val imageIndexes = HashMap<String, Int>()
    private val frames = ArrayList<RecordFrame>()

    val isFull: Boolean get() = frames.size >= RecordRules.MAX_FRAMES

    /**
     * A frame at [relPc] in the file at [path]. A frame in no file — JIT code,
     * an anonymous mapping, a `memfd` — or with an offset beyond 2^48 is `{}`.
     */
    fun addImageFrame(path: String?, relPc: Long, functionName: String?, buildId: String?) {
        if (isFull) return
        val symbol = Sanitize.symbol(functionName)
        val name = path?.takeIf { isImagePath(it) }?.let { Sanitize.imageName(it) }
        if (name == null || relPc !in 0..RecordRules.MAX_OFFSET) {
            frames.add(RecordFrame.unknown())
            return
        }
        val debugId = buildId?.lowercase()?.takeIf { RecordRules.DEBUG_ID.matches(it) }
        val key = Sanitize.stripDeleted(path) + '\u0000' + (debugId ?: "")
        val index = imageIndexes[key] ?: if (images.size < RecordRules.MAX_IMAGES) {
            images.add(RecordImage(name = name, inApp = appPaths.isInApp(path), debugId = debugId, arch = arch))
            (images.size - 1).also { imageIndexes[key] = it }
        } else {
            null
        }
        frames.add(
            when {
                index != null -> RecordFrame.inImage(index, relPc, symbol)
                symbol != null -> RecordFrame.symbol(symbol)
                else -> RecordFrame.unknown()
            },
        )
    }

    /** A JVM or system frame without an image. */
    fun addSymbolFrame(rawSymbol: String, line: Int?) {
        if (isFull) return
        val symbol = Sanitize.symbol(rawSymbol)
        frames.add(
            if (symbol == null) {
                RecordFrame.unknown()
            } else {
                RecordFrame.symbol(symbol, line?.takeIf { it in 1..RecordRules.MAX_LINE })
            },
        )
    }

    fun images(): List<RecordImage> = images.toList()

    fun frames(): List<RecordFrame> = frames.toList()

    private fun isImagePath(path: String): Boolean =
        path.startsWith("/") && !path.startsWith("/memfd:") && !path.startsWith("/dev/")
}

/**
 * Turns an exit (with its tombstone or ANR trace) or a JVM throwable into a
 * contract record. Only allowlisted fields survive; nothing raw is kept.
 */
internal class RecordNormalizer(private val appPaths: AppPaths) {
    /** A `REASON_CRASH_NATIVE` exit, with its tombstone from API 31. */
    fun nativeCrash(exit: ExitReport, tombstone: Tombstone?, strict: Boolean): NativeCrashRecord {
        val assembler = FrameAssembler(appPaths, tombstone?.arch)
        tombstone?.frames?.forEach { frame ->
            assembler.addImageFrame(frame.fileName, frame.relPc, frame.functionName, frame.buildId)
        }
        val signal = tombstone?.let { SignalNames.resolve(it.signalNumber, it.signalName) }
        return exitRecord(
            exit,
            RecordKind.CRASH,
            assembler,
            signal = signal,
            code = if (signal != null) tombstone?.signalCode?.let(::hexCode) else null,
            exceptionMessage = if (strict) null else Sanitize.message(tombstone?.abortMessage),
        )
    }

    /** A `REASON_ANR` exit, with its trace's main thread. */
    fun anr(exit: ExitReport, frames: List<AnrFrame>): NativeCrashRecord {
        val assembler = FrameAssembler(appPaths, arch = null)
        for (frame in frames) {
            when (frame) {
                is AnrFrame.Native -> assembler.addImageFrame(frame.path, frame.relPc, frame.functionName, frame.buildId)
                is AnrFrame.Managed -> assembler.addSymbolFrame(frame.symbol, frame.line)
            }
        }
        return exitRecord(exit, RecordKind.ANR, assembler)
    }

    /** A `REASON_LOW_MEMORY` exit of a foreground or visible process. */
    fun memoryKill(exit: ExitReport): NativeCrashRecord =
        exitRecord(exit, RecordKind.MEMORY_KILL, FrameAssembler(appPaths, arch = null))

    /** A `REASON_CRASH` exit without a JVM record: kind and time only. */
    fun jvmCrashExit(exit: ExitReport): NativeCrashRecord =
        exitRecord(exit, RecordKind.CRASH, FrameAssembler(appPaths, arch = null))

    /**
     * The JVM handler's record: class, message unless [strict], the throwing
     * thread's frames as `{symbol: "<class>.<method>", line?}`.
     */
    fun jvmCrash(error: Throwable, strict: Boolean, runId: String, pid: Int, nowMs: Long): NativeCrashRecord {
        val assembler = FrameAssembler(appPaths, arch = null)
        val trace = try {
            error.stackTrace
        } catch (_: Throwable) {
            emptyArray()
        }
        for (element in trace) {
            if (assembler.isFull) break
            assembler.addSymbolFrame("${element.className}.${element.methodName}", element.lineNumber)
        }
        val message = if (strict) {
            null
        } else {
            try {
                Sanitize.message(error.message)
            } catch (_: Throwable) {
                null
            }
        }
        return NativeCrashRecord(
            kind = RecordKind.CRASH,
            source = RecordSource.JVM,
            occurredAtMs = nowMs,
            exceptionClass = Sanitize.exceptionClass(error.javaClass.name),
            exceptionMessage = message,
            frames = assembler.frames(),
            runId = runId.takeIf { RecordRules.RUN_ID.matches(it) },
            pid = pid.takeIf { it > 0 },
        )
    }

    private fun exitRecord(
        exit: ExitReport,
        kind: RecordKind,
        assembler: FrameAssembler,
        signal: String? = null,
        code: String? = null,
        exceptionMessage: String? = null,
    ) = NativeCrashRecord(
        kind = kind,
        source = RecordSource.EXIT_INFO,
        occurredAtMs = exit.timestampMs,
        signal = signal,
        code = code,
        exceptionMessage = exceptionMessage,
        images = assembler.images(),
        frames = assembler.frames(),
        runId = exit.runId,
        pid = exit.pid.takeIf { it > 0 },
        foreground = exit.foreground,
    )
}
