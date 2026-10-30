package dev.noticebird.nativecrashes.core

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.security.MessageDigest

class NativeCrashRecordTest {
    private val runId = "9f1c2b7e5a4d4c3b8a1f0e9d8c7b6a59"

    /** The exact canonical JSON of the realistic tombstone's record, without `recordId`. */
    private val expectedNativeCrashJson =
        """{"code":"0xfffffffffffffffa",""" +
            """"exceptionMessage":"[FATAL:flutter/runtime/dart_vm.cc(42)] Check failed: vm. user=jane.doe@example.com",""" +
            """"foreground":true,""" +
            """"frames":[""" +
            """{"image":0,"offset":370116,"symbol":"abort"},""" +
            """{"image":1,"offset":1927704},""" +
            """{"image":2,"offset":192964,"symbol":"_kDartIsolateSnapshotInstructions"},""" +
            """{},""" +
            """{"image":3,"offset":2198360,"symbol":"art_quick_invoke_stub"},""" +
            """{},""" +
            """{"image":3,"offset":2767900,"symbol":"art::ArtMethod::Invoke_art::Thread___unsigned_int___unsigned_int__art::JValue___char_const__"},""" +
            """{"image":0,"offset":368640,"symbol":"raise"}],""" +
            """"images":[""" +
            """{"arch":"arm64","debugId":"a8c2b37a6f1e4d0c9b5e7f3a1d2c4b6e","inApp":false,"name":"libc.so"},""" +
            """{"arch":"arm64","debugId":"4c4c44e555553144a13dcc7994841aac0badf00d","inApp":true,"name":"libflutter.so"},""" +
            """{"arch":"arm64","debugId":"2f9e8d7c6b5a49382716051f2e3d4c5b","inApp":true,"name":"libapp.so"},""" +
            """{"arch":"arm64","debugId":"7d1c0b9a8f7e6d5c4b3a291807f6e5d4","inApp":false,"name":"libart.so"}],""" +
            """"kind":"crash","occurredAtMs":1758787277000,"pid":4312,"recordVersion":1,""" +
            """"runId":"9f1c2b7e5a4d4c3b8a1f0e9d8c7b6a59","signal":"SIGABRT","source":"exitInfo"}"""

    private fun nativeCrash(): NativeCrashRecord = RecordNormalizer(appPaths).nativeCrash(
        exit(ExitReason.CRASH_NATIVE, timestampMs = 1_758_787_277_000, runId = runId),
        TombstoneParser.parse(Tombstones.realistic()),
        strict = false,
    )

    @Test
    fun `a native crash has exactly the contract's canonical JSON`() {
        assertEquals(expectedNativeCrashJson, Json.write(nativeCrash().contentJson()))
    }

    @Test
    fun `the record id is the SHA-256 of the canonical JSON without it`() {
        val digest = MessageDigest.getInstance("SHA-256").digest(expectedNativeCrashJson.toByteArray(Charsets.UTF_8))
        val expected = digest.joinToString("") { "%02x".format(it) }

        assertEquals(expected, nativeCrash().recordId)
        assertTrue(RecordRules.RECORD_ID.matches(nativeCrash().recordId))
    }

    @Test
    fun `the inbox and channel form adds the id in key order`() {
        val record = nativeCrash()
        val channel = StoredRecord(record, claimedUntilMs = null).toJson()
        val written = Json.write(channel)

        assertTrue(written.contains(""""pid":4312,"recordId":"${record.recordId}","recordVersion":1,"""))
        assertEquals((NativeCrashRecord.CONTENT_KEYS + "recordId").containsAll(channel.keys), true)
    }

    @Test
    fun `the same report always gets the same id, any change another`() {
        val base = NativeCrashRecord(kind = RecordKind.ANR, source = RecordSource.EXIT_INFO, occurredAtMs = 1, pid = 7)

        assertEquals(base.recordId, base.copy().recordId)
        assertEquals(nativeCrash().recordId, nativeCrash().recordId)
        assertNotEquals(base.recordId, base.copy(occurredAtMs = 2).recordId)
        assertNotEquals(base.recordId, base.copy(pid = 8).recordId)
        assertNotEquals(base.recordId, base.copy(foreground = true).recordId)
        assertNotEquals(base.recordId, base.copy(kind = RecordKind.MEMORY_KILL).recordId)
    }

    @Test
    fun `reads its own JSON back, and rejects anything else`() {
        val stored = StoredRecord(nativeCrash(), claimedUntilMs = 1_758_787_300_000)
        @Suppress("UNCHECKED_CAST")
        val json = Json.parse(Json.write(stored.toInboxJson())) as Map<String, Any>

        assertEquals(stored, StoredRecord.fromJson(json))
        assertEquals(stored.record, NativeCrashRecord.fromContentJson(stored.record.contentJson()))
        assertThrows(IllegalArgumentException::class.java) { NativeCrashRecord.fromContentJson(stored.toJson()) }
        // The id is fixed at creation: read as stored, its shape checked, never recomputed.
        assertEquals(stored.copy(recordId = "0".repeat(64)), StoredRecord.fromJson(json + ("recordId" to "0".repeat(64))))
        val rejected = listOf(
            json + ("extra" to 1L),
            json - "recordId",
            json + ("recordId" to "0".repeat(63)),
            json + ("recordId" to "A".repeat(64)),
            json + ("recordId" to 7L),
            json + ("claimedUntilMs" to "soon"),
            json + ("recordVersion" to 2L),
            json + ("kind" to "freeze"),
            json + ("pid" to "4312"),
            json + ("signal" to "sigabrt"),
            json + ("frames" to listOf(mapOf("image" to 9L, "offset" to 1L))),
            json - "occurredAtMs",
        )
        for (candidate in rejected) {
            assertThrows(IllegalArgumentException::class.java) { StoredRecord.fromJson(candidate) }
        }
    }

    @Test
    fun `construction enforces the contract's value rules`() {
        val base = NativeCrashRecord(kind = RecordKind.CRASH, source = RecordSource.JVM, occurredAtMs = 1)
        val image = RecordImage(name = "libapp.so", inApp = true)
        val invalid = listOf(
            { base.copy(signal = "SIGSEGV!") },
            { base.copy(code = "0X32") },
            { base.copy(code = "0x" + "f".repeat(17)) },
            { base.copy(exceptionClass = "java.lang.Error<T>") },
            { base.copy(exceptionMessage = "") },
            { base.copy(exceptionMessage = "x".repeat(1025)) },
            { base.copy(durationMs = 10) },
            { base.copy(bytesWritten = 10) },
            { base.copy(images = listOf(image)) },
            { base.copy(images = listOf(image), frames = listOf(RecordFrame.inImage(1, 0))) },
            { base.copy(frames = List(65) { RecordFrame.unknown() }) },
            { base.copy(runId = "ABC") },
            { base.copy(appVersion = "") },
            { RecordFrame.inImage(0, RecordRules.MAX_OFFSET + 1) },
            { RecordFrame.symbol("a b") },
            { RecordFrame.symbol("a", line = 0) },
            { RecordImage(name = "lib/app.so", inApp = true) },
            { RecordImage(name = "libapp.so", inApp = true, debugId = "4c4c44e5-5555-3144-a13d-cc7994841aac") },
        )
        for (build in invalid) assertThrows(IllegalArgumentException::class.java) { build() }
    }
}

class JsonTest {
    @Test
    fun `writes canonically - keys sorted at every depth, no whitespace`() {
        val value = mapOf(
            "b" to listOf(mapOf("z" to 1L, "a" to true), emptyMap<String, Any>()),
            "a" to "x",
            "B" to 2,
        )

        assertEquals("""{"B":2,"a":"x","b":[{"a":true,"z":1},{}]}""", Json.write(value))
    }

    @Test
    fun `escapes like Dart's jsonEncode`() {
        assertEquals(""""q\"b\\n\nt\tc\u0001é😀\ud800"""", Json.write("q\"b\\n\nt\tc\u0001é😀\ud800"))
    }

    @Test
    fun `parses its subset and round-trips`() {
        val text = """{ "a": [1, -2, true, false, "sé\n"], "b": {} }"""

        assertEquals(mapOf("a" to listOf(1L, -2L, true, false, "sé\n"), "b" to emptyMap<String, Any>()), Json.parse(text))
    }

    @Test
    fun `rejects everything outside its subset`() {
        val invalid = listOf(
            "", "null", "1.5", "1e3", "01", "[1,]", "{\"a\":1,}", "{\"a\":1,\"a\":2}", "\"unterminated",
            "\"tab\there\"", "{} x", "[" .repeat(20) + "]".repeat(20), "99999999999999999999", "{'a':1}",
        )
        for (text in invalid) {
            assertThrows(JsonFormatException::class.java, { Json.parse(text) }, text)
        }
    }
}
