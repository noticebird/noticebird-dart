package dev.noticebird.nativecrashes.core

import dev.noticebird.nativecrashes.core.Tombstones.frame
import dev.noticebird.nativecrashes.core.Tombstones.thread
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class RecordNormalizerTest {
    private val normalizer = RecordNormalizer(appPaths)
    private val runId = "9f1c2b7e5a4d4c3b8a1f0e9d8c7b6a59"

    private fun tombstoneWith(frames: ProtoWriter.() -> Unit): Tombstone = TombstoneParser.parse(
        ProtoWriter().apply {
            varint(1, 1)
            varint(6, 1)
            message(10) { varint(1, 11) }
            thread(key = 1, id = 1, name = "main", frames = frames)
        }.toByteArray(),
    )!!

    private fun crash(tombstone: Tombstone?, strict: Boolean = false) =
        normalizer.nativeCrash(exit(ExitReason.CRASH_NATIVE, 1_000, runId = runId), tombstone, strict)

    @Test
    fun `strict never writes the abort message`() {
        val record = crash(TombstoneParser.parse(Tombstones.realistic()), strict = true)

        assertNull(record.exceptionMessage)
        assertEquals("SIGABRT", record.signal)
        assertFalse(Json.write(record.contentJson()).contains("jane.doe"))
    }

    @Test
    fun `nothing but the allowlisted fields leaves the tombstone`() {
        val written = Json.write(crash(TombstoneParser.parse(Tombstones.realistic()), strict = true).contentJson())

        for (secret in listOf("secret.db", "signed in", "untrusted_app", "google/sdk_gphone64", "1.raster", "raster_only")) {
            assertFalse(written.contains(secret), secret)
        }
        // No absolute pc (0x7a... + rel_pc) and no install path.
        assertFalse(written.contains((0x7a_0000_0000L + 0x5a5c4).toString()))
        assertFalse(written.contains("/data/app"))
    }

    @Test
    fun `a native crash without a tombstone (API 30) has kind and time only`() {
        val record = crash(tombstone = null)

        assertEquals(RecordKind.CRASH, record.kind)
        assertEquals(RecordSource.EXIT_INFO, record.source)
        assertEquals(1_000L, record.occurredAtMs)
        assertEquals(runId, record.runId)
        assertEquals(4312, record.pid)
        assertEquals(true, record.foreground)
        assertNull(record.signal)
        assertNull(record.code)
        assertEquals(emptyList<RecordFrame>(), record.frames)
    }

    @Test
    fun `resolves the signal from the table when the tombstone's name is not one`() {
        val tombstone = TombstoneParser.parse(
            ProtoWriter().message(10) {
                varint(1, 11)
                string(2, "<debuggerd signal>")
                varint(3, 1)
            }.toByteArray(),
        )
        val record = crash(tombstone)

        assertEquals("SIGSEGV", record.signal)
        assertEquals("0x1", record.code)
        assertNull(crash(TombstoneParser.parse(ProtoWriter().message(10) { varint(1, 40) }.toByteArray())).signal)
    }

    @Test
    fun `in-app images are those in the app's install or data directory, of any install`() {
        val earlierInstall = "/data/app/~~b2xkZXI=/${Tombstones.PACKAGE}-b2xkZXJpbnN0YWxs=="
        val record = crash(
            tombstoneWith {
                frame(1, fileName = "$earlierInstall/lib/arm64/libapp.so")
                frame(2, fileName = "/data/app/${Tombstones.PACKAGE}-2/lib/arm/libflutter.so")
                frame(3, fileName = "/data/data/${Tombstones.PACKAGE}/code_cache/libplugin.so")
                frame(4, fileName = "/data/user/10/${Tombstones.PACKAGE}/files/libdownloaded.so")
                frame(5, fileName = "/data/app/~~x==/${Tombstones.PACKAGE}.other-y==/lib/arm64/libother.so")
                frame(6, fileName = "/system/lib64/libhwui.so")
                frame(7, fileName = "/data/app/~~x==/com.attacker-y==/base.apk!libevil.so")
            },
        )

        assertEquals(
            listOf(true, true, true, true, false, false, false),
            record.images.map { it.inApp },
        )
    }

    @Test
    fun `image names are basenames, embedded libraries by their own name`() {
        val record = crash(
            tombstoneWith {
                frame(1, fileName = "${Tombstones.INSTALL_DIR}/split_config.arm64_v8a.apk!libflutter.so")
                frame(2, fileName = "${Tombstones.INSTALL_DIR}/base.apk")
                frame(3, fileName = "/system/lib64/lib weird(1).so")
                frame(4, fileName = "/data/local/tmp/libgone.so (deleted)")
                frame(5, fileName = "/system/lib64/" + "a".repeat(150) + ".so")
            },
        )

        assertEquals(
            listOf("libflutter.so", "base.apk", "lib_weird_1_.so", "libgone.so", "a".repeat(100)),
            record.images.map { it.name },
        )
    }

    @Test
    fun `a debug id is kept only as 32 to 40 lowercase hex digits`() {
        val record = crash(
            tombstoneWith {
                frame(1, fileName = "/system/lib64/liba.so", buildId = "ABCDEF0123456789ABCDEF0123456789")
                frame(2, fileName = "/system/lib64/libb.so", buildId = "0123456789abcdef")
                frame(3, fileName = "/system/lib64/libc.so", buildId = "0".repeat(41))
                frame(4, fileName = "/system/lib64/libd.so", buildId = "4c4c44e5-5555-3144-a13d-cc7994841aac")
            },
        )

        assertEquals(
            listOf("abcdef0123456789abcdef0123456789", null, null, null),
            record.images.map { it.debugId },
        )
        assertTrue(record.images.all { it.arch == ImageArch.ARM64 })
    }

    @Test
    fun `frames in no image, or beyond 2^48, are empty frames`() {
        val record = crash(
            tombstoneWith {
                frame(1, "jitted", "[anon:dalvik-jit-code-cache]")
                frame(2, "jitted", "/dev/ashmem/dalvik-jit-code-cache (deleted)")
                frame(3, "unknown", null)
                frame(RecordRules.MAX_OFFSET + 1, "far", "/system/lib64/libc.so")
                frame(-1, "negative", "/system/lib64/libc.so")
            },
        )

        assertEquals(List(5) { RecordFrame.unknown() }, record.frames)
        assertEquals(emptyList<RecordImage>(), record.images)
    }

    @Test
    fun `at most 32 images, indexed by first reference, all referenced`() {
        val record = crash(
            tombstoneWith {
                repeat(40) { index -> frame(index.toLong(), "f$index", "/system/lib64/lib$index.so") }
                frame(99, "again", "/system/lib64/lib0.so")
            },
        )

        assertEquals(32, record.images.size)
        assertEquals((0 until 32).map { "lib$it.so" }, record.images.map { it.name })
        assertEquals(RecordFrame.inImage(31, 31, "f31"), record.frames[31])
        assertEquals(RecordFrame.symbol("f32"), record.frames[32])
        assertEquals(RecordFrame.inImage(0, 99, "again"), record.frames[40])
    }

    @Test
    fun `symbols are sanitized and cut to 200 characters`() {
        val record = crash(
            tombstoneWith {
                frame(1, "operator new(unsigned long)", "/system/lib64/libc++.so")
                frame(2, "x".repeat(300), "/system/lib64/libc++.so")
                frame(3, "Ünïcödé😀", "/system/lib64/libc++.so")
            },
        )

        assertEquals(listOf("operator_new_unsigned_long_", "x".repeat(200), "_n_c_d__"), record.frames.map { it.symbol })
        assertEquals("libc++.so", record.images.single().name)
    }

    @Test
    fun `an ANR record carries the main thread's frames and no architecture`() {
        val record = normalizer.anr(
            exit(ExitReason.ANR, 2_000, importance = 100, runId = runId),
            AnrTraceParser.parse(AnrTraces.realistic.toByteArray()),
        )

        assertEquals(RecordKind.ANR, record.kind)
        assertEquals(listOf("libc.so", "libflutter.so", "libapp.so", "libart.so"), record.images.map { it.name })
        assertEquals(listOf(false, true, true, false), record.images.map { it.inApp })
        assertTrue(record.images.all { it.arch == null })
        assertEquals(RecordFrame.inImage(0, 0x9c5d4, "nanosleep"), record.frames[0])
        assertEquals(RecordFrame.unknown(), record.frames[4])
        assertEquals(RecordFrame.symbol("java.lang.Thread.sleep"), record.frames[6])
        assertEquals(RecordFrame.symbol("dev.example.MainActivity\$onCreate\$1._\$\$Nest\$mblock", 42), record.frames[8])
        assertEquals(13, record.frames.size)
    }

    @Test
    fun `an exit's run id is the summary only when it is one, foreground up to visible`() {
        val summaries = mapOf(
            runId to runId,
            runId.uppercase() to null,
            "short" to null,
            runId + "0" to null,
        )
        for ((summary, expected) in summaries) {
            assertEquals(expected, normalizer.memoryKill(exit(ExitReason.LOW_MEMORY, 1, runId = summary)).runId)
        }
        assertEquals(true, normalizer.memoryKill(exit(ExitReason.LOW_MEMORY, 1, importance = 200)).foreground)
        assertEquals(false, normalizer.memoryKill(exit(ExitReason.LOW_MEMORY, 1, importance = 230)).foreground)
        assertNull(normalizer.memoryKill(exit(ExitReason.LOW_MEMORY, 1, pid = 0)).pid)
    }

    @Test
    fun `a JVM throwable becomes class, message and symbol frames`() {
        val error = IllegalStateException("Fragment not attached").apply {
            stackTrace = arrayOf(
                StackTraceElement("com.example.Foo", "bar", "Foo.kt", 42),
                StackTraceElement("com.example.Foo\$Inner", "<init>", "Foo.kt", -1),
                StackTraceElement("java.lang.Thread", "sleep", null, -2),
                StackTraceElement("com.example.Foo", "-\$\$Nest\$mbaz", "Foo.kt", 7),
            )
        }
        val record = normalizer.jvmCrash(error, strict = false, runId = runId, pid = 4312, nowMs = 3_000)

        assertEquals(RecordKind.CRASH, record.kind)
        assertEquals(RecordSource.JVM, record.source)
        assertEquals(3_000L, record.occurredAtMs)
        assertEquals("java.lang.IllegalStateException", record.exceptionClass)
        assertEquals("Fragment not attached", record.exceptionMessage)
        assertEquals(
            listOf(
                RecordFrame.symbol("com.example.Foo.bar", 42),
                RecordFrame.symbol("com.example.Foo\$Inner.<init>"),
                RecordFrame.symbol("java.lang.Thread.sleep"),
                RecordFrame.symbol("com.example.Foo._\$\$Nest\$mbaz", 7),
            ),
            record.frames,
        )
        assertEquals(runId, record.runId)
        assertEquals(4312, record.pid)
        assertNull(record.foreground)
        assertEquals(emptyList<RecordImage>(), record.images)
    }

    @Test
    fun `a JVM record is bounded and strict drops the message`() {
        val error = StackOverflowError("é".repeat(2_000)).apply {
            stackTrace = Array(1_024) { StackTraceElement("com.example.Recursion", "call", "R.kt", it + 1) }
        }
        val record = normalizer.jvmCrash(error, strict = false, runId = runId, pid = 1, nowMs = 1)

        assertEquals(64, record.frames.size)
        assertEquals(1024, record.exceptionMessage!!.length)
        assertNull(normalizer.jvmCrash(error, strict = true, runId = runId, pid = 1, nowMs = 1).exceptionMessage)
        // A surrogate pair at the cut is not split.
        val emoji = RuntimeException("a" + "😀".repeat(600))
        val cut = normalizer.jvmCrash(emoji, strict = false, runId = runId, pid = 1, nowMs = 1).exceptionMessage!!
        assertEquals(1023, cut.length)
        assertFalse(Character.isHighSurrogate(cut.last()))
    }

    @Test
    fun `a hostile throwable still yields a record`() {
        val hostile = object : RuntimeException() {
            override val message: String get() = throw IllegalStateException("no message for you")

            override fun getStackTrace(): Array<StackTraceElement> = throw IllegalStateException("no trace")
        }
        val record = normalizer.jvmCrash(hostile, strict = false, runId = runId, pid = 1, nowMs = 1)

        assertNull(record.exceptionMessage)
        assertEquals(emptyList<RecordFrame>(), record.frames)
        assertTrue(RecordRules.EXCEPTION_CLASS.matches(record.exceptionClass!!))
        assertNull(normalizer.jvmCrash(RuntimeException(""), strict = false, runId = runId, pid = 1, nowMs = 1).exceptionMessage)
    }
}
