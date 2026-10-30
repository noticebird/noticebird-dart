package dev.noticebird.nativecrashes.core

import org.junit.jupiter.api.Assertions.assertDoesNotThrow
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.Timeout
import java.util.concurrent.TimeUnit

internal object AnrTraces {
    const val LIBC = "/apex/com.android.runtime/lib64/bionic/libc.so"

    /** A trace as ART's signal catcher dumps it for an ANR kill. */
    val realistic = """
        |
        |----- pid 4312 at 2026-09-25 10:01:17.123456789+0200 -----
        |Cmd line: ${Tombstones.PACKAGE}
        |Build fingerprint: 'google/sdk_gphone64_arm64/emu64a:14/UE1A.230829.036/10000000:userdebug/dev-keys'
        |ABI: 'arm64'
        |Build type: optimized
        |suspend all histogram:	Sum: 101us 99% C.I. 1us-26us Avg: 5.050us Max: 26us
        |DALVIK THREADS (17):
        |"Signal Catcher" daemon prio=10 tid=5 Runnable
        |  | group="system" sCount=0 ucsCount=0 flags=0 obj=0x13040260 self=0xb400007a1c01d000
        |  | sysTid=4320 nice=-20 cgrp=top-app sched=0/0 handle=0x78d6a8dcb0
        |  native: #00 pc 00000000005374cc  /apex/com.android.art/lib64/libart.so (art::DumpNativeStack(std::__1::basic_ostream<char, std::__1::char_traits<char> >&, int, BacktraceMap*, char const*, art::ArtMethod*, void*, bool)+128) (BuildId: e24a1818231cfb1649cb83a5d2869598)
        |  (no managed stack frames)
        |
        |"main" prio=5 tid=1 Sleeping
        |  | group="main" sCount=1 ucsCount=0 flags=1 obj=0x72a3b9d8 self=0xb400007a1c010800
        |  | sysTid=4312 nice=-10 cgrp=top-app sched=0/0 handle=0x7b5a6c34f8
        |  | state=S schedstat=( 1234567 7654321 90 ) utm=12 stm=3 core=4 HZ=100
        |  | stack=0x7fe3a4c000-0x7fe3a4e000 stackSize=8188KB
        |  | held mutexes=
        |  native: #00 pc 000000000009c5d4  $LIBC (nanosleep+4) (BuildId: 5f7d0d8f3b1c2e4a6b8d9f0a1c2e3b4d)
        |  native: #01 pc 00000000000a1b2c  $LIBC (sleep+44) (BuildId: 5f7d0d8f3b1c2e4a6b8d9f0a1c2e3b4d)
        |  native: #02 pc 00000000001d6a18  ${Tombstones.INSTALL_DIR}/base.apk!libflutter.so (offset 0x9e4000) (BuildId: ${Tombstones.FLUTTER_BUILD_ID})
        |  native: #03 pc 000000000002f1c4  ${Tombstones.INSTALL_DIR}/lib/arm64/libapp.so (_kDartIsolateSnapshotInstructions+192964)
        |  native: #04 pc 0000000000001234  /memfd:jit-cache (deleted) (offset 0x2000000) (com.example.Jitted.run+36)
        |  native: #05 pc 0000000000218b58  /apex/com.android.art/lib64/libart.so (art_quick_invoke_stub+584) (BuildId: ${Tombstones.ART_BUILD_ID})
        |  at java.lang.Thread.sleep(Native method)
        |  - sleeping on <0x0a1b2c3d> (a java.lang.Object)
        |  at java.lang.Thread.sleep(Thread.java:450)
        |  - locked <0x0a1b2c3d> (a java.lang.Object)
        |  at dev.example.MainActivity${'$'}onCreate${'$'}1.-${'$'}${'$'}Nest${'$'}mblock(MainActivity.kt:42)
        |  at android.os.Handler.handleCallback(Handler.java:958)
        |  at android.app.ActivityThread.main(ActivityThread.java:8177)
        |  at java.lang.reflect.Method.invoke(Native method)
        |  at com.android.internal.os.RuntimeInit${'$'}MethodAndArgsCaller.run(Unknown Source:12)
        |
        |"FinalizerDaemon" daemon prio=5 tid=10 Waiting
        |  at java.lang.Object.wait(Native method)
        |  at java.lang.Daemons${'$'}FinalizerDaemon.runInternal(Daemons.java:292)
        |
        |----- end 4312 -----
        |""".trimMargin()
}

class AnrTraceParserTest {
    @Test
    fun `reads a real ANR trace recorded on an API 36 emulator`() {
        // The crash lab's "block the main thread" on 2026-09-25: the app's own
        // section of /data/anr (header, then every thread of pid 2195).
        val bytes = javaClass.getResourceAsStream("/anr_api36_emulator.txt")!!.use { it.readBytes() }

        val frames = AnrTraceParser.parse(bytes)

        assertEquals(16, frames.size)
        assertEquals(AnrFrame.Managed("java.lang.Thread.sleep", null), frames[0])
        assertEquals(AnrFrame.Managed("java.lang.Thread.sleep0", 681), frames[1])
        assertEquals(
            AnrFrame.Managed(
                "dev.noticebird.noticebird_native_example.MainActivity.configureFlutterEngine${'$'}lambda${'$'}0${'$'}1",
                27,
            ),
            frames[4],
        )
        // `(unavailable:0)` and `(D8$${'$'}SyntheticClass:0)` carry no usable line.
        assertEquals(null, (frames[5] as AnrFrame.Managed).line)
        assertEquals(null, (frames[6] as AnrFrame.Managed).line)
        assertEquals(AnrFrame.Managed("com.android.internal.os.ZygoteInit.main", 929), frames.last())
    }

    @Test
    fun `reads the main thread's native and managed frames, top first`() {
        val frames = AnrTraceParser.parse(AnrTraces.realistic.toByteArray())

        assertEquals(
            listOf(
                AnrFrame.Native(0x9c5d4, AnrTraces.LIBC, "nanosleep", "5f7d0d8f3b1c2e4a6b8d9f0a1c2e3b4d"),
                AnrFrame.Native(0xa1b2c, AnrTraces.LIBC, "sleep", "5f7d0d8f3b1c2e4a6b8d9f0a1c2e3b4d"),
                AnrFrame.Native(
                    0x1d6a18,
                    "${Tombstones.INSTALL_DIR}/base.apk!libflutter.so",
                    null,
                    Tombstones.FLUTTER_BUILD_ID,
                ),
                AnrFrame.Native(
                    0x2f1c4,
                    "${Tombstones.INSTALL_DIR}/lib/arm64/libapp.so",
                    "_kDartIsolateSnapshotInstructions",
                    null,
                ),
                AnrFrame.Native(0x1234, "/memfd:jit-cache", "com.example.Jitted.run", null),
                AnrFrame.Native(
                    0x218b58,
                    "/apex/com.android.art/lib64/libart.so",
                    "art_quick_invoke_stub",
                    Tombstones.ART_BUILD_ID,
                ),
                AnrFrame.Managed("java.lang.Thread.sleep", null),
                AnrFrame.Managed("java.lang.Thread.sleep", 450),
                AnrFrame.Managed("dev.example.MainActivity\$onCreate\$1.-\$\$Nest\$mblock", 42),
                AnrFrame.Managed("android.os.Handler.handleCallback", 958),
                AnrFrame.Managed("android.app.ActivityThread.main", 8177),
                AnrFrame.Managed("java.lang.reflect.Method.invoke", null),
                AnrFrame.Managed("com.android.internal.os.RuntimeInit\$MethodAndArgsCaller.run", 12),
            ),
            frames,
        )
    }

    @Test
    fun `ignores every other thread`() {
        val frames = AnrTraceParser.parse(AnrTraces.realistic.toByteArray())

        assertEquals(
            emptyList<AnrFrame>(),
            frames.filter {
                it is AnrFrame.Managed && it.symbol.contains("FinalizerDaemon") ||
                    it is AnrFrame.Native && it.functionName.orEmpty().contains("DumpNativeStack")
            },
        )
    }

    @Test
    fun `a trace without a main thread has no frames`() {
        val trace = AnrTraces.realistic.replace("\"main\" prio", "\"mainly\" prio")

        assertEquals(emptyList<AnrFrame>(), AnrTraceParser.parse(trace.toByteArray()))
        assertEquals(emptyList<AnrFrame>(), AnrTraceParser.parse(ByteArray(0)))
    }

    @Test
    fun `keeps at most 64 frames`() {
        val trace = buildString {
            appendLine("\"main\" prio=5 tid=1 Native")
            repeat(500) { appendLine("  at dev.example.Deep.level$it(Deep.kt:${it + 1})") }
        }
        val frames = AnrTraceParser.parse(trace.toByteArray())

        assertEquals(64, frames.size)
        assertEquals(AnrFrame.Managed("dev.example.Deep.level63", 64), frames.last())
    }

    @Test
    fun `a 16-digit pc keeps its unsigned bits and becomes an empty frame`() {
        val trace = "\"main\" prio=5 tid=1 Native\n  native: #00 pc ffffffffffffffff  /system/lib64/libc.so (abort+4)\n"
        val frames = AnrTraceParser.parse(trace.toByteArray())

        assertEquals(listOf(AnrFrame.Native(-1L, "/system/lib64/libc.so", "abort", null)), frames)
        val record = RecordNormalizer(appPaths).anr(exit(ExitReason.ANR, 1), frames)
        assertEquals(listOf(RecordFrame.unknown()), record.frames)
    }

    @Test
    fun `out-of-range line numbers are dropped`() {
        val trace = "\"main\" prio=5 tid=1 Native\n  at a.B.c(B.kt:0)\n  at a.B.d(B.kt:9999999)\n"

        assertEquals(
            listOf(AnrFrame.Managed("a.B.c", null), AnrFrame.Managed("a.B.d", null)),
            AnrTraceParser.parse(trace.toByteArray()),
        )
    }

    @Test
    @Timeout(value = 5, unit = TimeUnit.SECONDS)
    fun `reads only the first MiB of a 5 MB trace, where the main thread is`() {
        val filler = "\"Thread-7\" prio=5 tid=99 Waiting\n" + "  at dev.example.Filler.idle(Filler.kt:1)\n".repeat(130_000)
        val huge = (AnrTraces.realistic + filler).toByteArray()
        assertEquals(true, huge.size > 5 * 1024 * 1024)

        assertEquals(13, AnrTraceParser.parse(huge).size)
    }

    @Test
    @Timeout(value = 5, unit = TimeUnit.SECONDS)
    fun `a main thread beyond the first MiB is not read`() {
        val filler = "\"Thread-7\" prio=5 tid=99 Waiting\n" + "  at dev.example.Filler.idle(Filler.kt:1)\n".repeat(30_000)
        val late = (filler + AnrTraces.realistic).toByteArray()

        assertEquals(emptyList<AnrFrame>(), AnrTraceParser.parse(late))
    }

    @Test
    @Timeout(value = 5, unit = TimeUnit.SECONDS)
    fun `hostile input never throws`() {
        val random = java.util.Random(20260925)
        repeat(500) {
            val bytes = ByteArray(random.nextInt(4096)).also(random::nextBytes)
            assertDoesNotThrow { AnrTraceParser.parse(bytes) }
        }
        val longLine = "\"main\" prio=5\n  native: #00 pc 0000000000001234  /system/lib64/libc.so (" +
            "(".repeat(500_000) + "+1)\n  at " + "a".repeat(500_000) + "(X.kt:1)\n"
        assertDoesNotThrow { AnrTraceParser.parse(longLine.toByteArray()) }
    }
}
