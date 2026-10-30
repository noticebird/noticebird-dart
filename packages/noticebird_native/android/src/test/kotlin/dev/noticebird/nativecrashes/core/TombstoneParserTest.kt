package dev.noticebird.nativecrashes.core

import dev.noticebird.nativecrashes.core.Tombstones.frame
import dev.noticebird.nativecrashes.core.Tombstones.thread
import org.junit.jupiter.api.Assertions.assertDoesNotThrow
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.Timeout
import java.util.concurrent.TimeUnit

class TombstoneParserTest {
    @Test
    fun `reads the allowlisted fields of a realistic tombstone`() {
        val parsed = TombstoneParser.parse(Tombstones.realistic())
        assertNotNull(parsed)
        val tombstone = parsed!!

        assertEquals(ImageArch.ARM64, tombstone.arch)
        assertEquals(4312L, tombstone.pid)
        assertEquals(4312L, tombstone.tid)
        assertEquals(6, tombstone.signalNumber)
        assertEquals("SIGABRT", tombstone.signalName)
        assertEquals(-6L, tombstone.signalCode)
        assertEquals(Tombstones.ABORT_MESSAGE, tombstone.abortMessage)
        assertEquals(
            listOf(
                TombstoneFrame(0x5a5c4, "abort", "/apex/com.android.runtime/lib64/bionic/libc.so", Tombstones.LIBC_BUILD_ID),
                TombstoneFrame(0x1d6a18, null, "${Tombstones.INSTALL_DIR}/base.apk!libflutter.so", Tombstones.FLUTTER_BUILD_ID),
            ),
            tombstone.frames.take(2),
        )
        assertEquals(8, tombstone.frames.size)
    }

    @Test
    fun `keeps only the crashing thread's frames`() {
        val tombstone = TombstoneParser.parse(Tombstones.realistic())!!

        assertTrue(tombstone.frames.none { it.functionName == "raster_only_function" })
    }

    @Test
    fun `maps every architecture, an absent one being ARM32 as proto3 defines`() {
        assertEquals(ImageArch.ARMV7, TombstoneParser.parse(Tombstones.realistic(arch = null))!!.arch)
        assertEquals(ImageArch.ARMV7, TombstoneParser.parse(Tombstones.realistic(arch = 0))!!.arch)
        assertEquals(ImageArch.X86, TombstoneParser.parse(Tombstones.realistic(arch = 2))!!.arch)
        assertEquals(ImageArch.X86_64, TombstoneParser.parse(Tombstones.realistic(arch = 3))!!.arch)
        assertNull(TombstoneParser.parse(Tombstones.realistic(arch = 4))!!.arch)
    }

    @Test
    fun `an empty message is a valid tombstone without content`() {
        val tombstone = TombstoneParser.parse(ByteArray(0))!!

        assertNull(tombstone.tid)
        assertNull(tombstone.signalNumber)
        assertEquals(emptyList<TombstoneFrame>(), tombstone.frames)
    }

    @Test
    fun `a thread whose id contradicts its map key yields no frames`() {
        val bytes = ProtoWriter().apply {
            varint(6, 100)
            thread(key = 100, id = 101, name = "impostor") { frame(0x10, "f", "/system/lib64/libc.so", null) }
        }.toByteArray()

        assertEquals(emptyList<TombstoneFrame>(), TombstoneParser.parse(bytes)!!.frames)
    }

    @Test
    fun `keeps at most 64 frames of a very deep backtrace`() {
        val bytes = ProtoWriter().apply {
            varint(6, 7)
            thread(key = 7, id = 7, name = "deep") {
                repeat(10_000) { index -> frame(index.toLong(), "f$index", "/system/lib64/libc.so", null) }
            }
        }.toByteArray()

        val frames = TombstoneParser.parse(bytes)!!.frames
        assertEquals(64, frames.size)
        assertEquals(0L, frames.first().relPc)
        assertEquals(63L, frames.last().relPc)
    }

    @Test
    fun `no prefix of a tombstone throws, and a cut inside a field is rejected`() {
        val bytes = Tombstones.realistic()
        for (length in 0 until bytes.size) {
            assertDoesNotThrow { TombstoneParser.parse(bytes, length) }
        }
        // The last field is a 4-byte fixed32: cutting into it truncates it.
        assertNull(TombstoneParser.parse(bytes, bytes.size - 1))
        assertNull(TombstoneParser.parse(bytes.copyOf(bytes.size - 3)))
    }

    @Test
    fun `rejects a known field with the wrong wire type`() {
        val cases = listOf(
            ProtoWriter().string(5, "4312"),
            ProtoWriter().varint(16, 1),
            ProtoWriter().fixed32(10, 6),
            ProtoWriter().varint(14, 1),
            ProtoWriter().message(10) { string(3, "-6") },
            ProtoWriter().apply {
                varint(6, 1)
                message(16) {
                    varint(1, 1)
                    message(2) { message(4) { string(1, "0x10") } }
                }
            },
            ProtoWriter().apply {
                varint(6, 1)
                message(16) {
                    varint(1, 1)
                    message(2) { message(4) { varint(6, 3) } }
                }
            },
            ProtoWriter().apply { message(16) { string(1, "key") } },
        )
        for (case in cases) assertNull(TombstoneParser.parse(case.toByteArray()))
    }

    @Test
    fun `rejects varints that overflow`() {
        val elevenBytes = ProtoWriter().tag(5, ProtoReader.VARINT)
            .raw(ByteArray(10) { 0xff.toByte() } + byteArrayOf(0x01)).toByteArray()
        val tenthByteTooLarge = ProtoWriter().tag(5, ProtoReader.VARINT)
            .raw(ByteArray(9) { 0xff.toByte() } + byteArrayOf(0x02)).toByteArray()
        val endlessTag = ByteArray(64) { 0x80.toByte() }

        assertNull(TombstoneParser.parse(elevenBytes))
        assertNull(TombstoneParser.parse(tenthByteTooLarge))
        assertNull(TombstoneParser.parse(endlessTag))
        // The largest valid varint: -1 as a sign-extended int32 code.
        val maximal = ProtoWriter().message(10) {
            varint(1, 11)
            varint(3, -1)
        }.toByteArray()
        assertEquals(-1L, TombstoneParser.parse(maximal)!!.signalCode)
    }

    @Test
    fun `rejects length prefixes beyond the input`() {
        val cases = listOf(
            ProtoWriter().tag(17, ProtoReader.LENGTH_DELIMITED).rawVarint(0x7fff_ffffL).raw(ByteArray(16)),
            ProtoWriter().tag(17, ProtoReader.LENGTH_DELIMITED).rawVarint(1L shl 62).raw(ByteArray(16)),
            ProtoWriter().tag(17, ProtoReader.LENGTH_DELIMITED).rawVarint(-1L).raw(ByteArray(16)),
            ProtoWriter().tag(10, ProtoReader.LENGTH_DELIMITED).rawVarint(17).raw(ByteArray(16)),
            ProtoWriter().message(10) { tag(2, ProtoReader.LENGTH_DELIMITED).rawVarint(100).raw(ByteArray(4)) },
        )
        for (case in cases) assertNull(TombstoneParser.parse(case.toByteArray()))
    }

    @Test
    fun `rejects groups, unknown wire types and field number 0`() {
        val cases = listOf(
            ProtoWriter().tag(3, 3).tag(3, 4),
            ProtoWriter().tag(3, 6),
            ProtoWriter().tag(3, 7),
            ProtoWriter().tag(0, ProtoReader.VARINT).rawVarint(1),
            ProtoWriter().rawVarint(0xFFFF_FFFFL shl 3),
        )
        for (case in cases) assertNull(TombstoneParser.parse(case.toByteArray()))
    }

    @Test
    fun `rejects invalid UTF-8 in a string it reads, not in one it skips`() {
        val invalid = byteArrayOf(0xC3.toByte(), 0x28)
        assertNull(TombstoneParser.parse(ProtoWriter().bytes(14, invalid).toByteArray()))
        assertNotNull(TombstoneParser.parse(ProtoWriter().bytes(2, invalid).toByteArray()))
    }

    @Test
    @Timeout(value = 5, unit = TimeUnit.SECONDS)
    fun `rejects an input over 1 MiB without reading it`() {
        val fiveMegabytes = ProtoWriter().apply {
            varint(6, 1)
            bytes(18, ByteArray(5 * 1024 * 1024))
        }.toByteArray()

        assertNull(TombstoneParser.parse(fiveMegabytes))
        assertNull(TombstoneParser.parse(ByteArray(TombstoneParser.MAX_INPUT_BYTES + 1)))
    }

    @Test
    @Timeout(value = 5, unit = TimeUnit.SECONDS)
    fun `skips deeply nested unknown content without descending into it`() {
        var nested = ByteArray(0)
        repeat(5_000) { nested = ProtoWriter().bytes(1, nested).toByteArray() }
        val bytes = ProtoWriter().apply {
            bytes(18, nested)
            varint(5, 9)
        }.toByteArray()

        assertEquals(9L, TombstoneParser.parse(bytes)!!.pid)
    }

    @Test
    fun `the reader refuses nesting deeper than its cap`() {
        var nested = ProtoWriter().varint(1, 1).toByteArray()
        repeat(ProtoReader.MAX_DEPTH + 1) { nested = ProtoWriter().bytes(1, nested).toByteArray() }

        assertThrows(MalformedProtobufException::class.java) {
            var reader = ProtoReader.of(nested)
            while (reader.nextField() && reader.wireType == ProtoReader.LENGTH_DELIMITED) reader = reader.message()
        }
    }

    @Test
    fun `hostile random inputs never throw`() {
        val random = java.util.Random(20260925)
        repeat(2_000) {
            val bytes = ByteArray(random.nextInt(512)).also(random::nextBytes)
            assertDoesNotThrow { TombstoneParser.parse(bytes) }
        }
        val valid = Tombstones.realistic()
        repeat(2_000) {
            val mutated = valid.copyOf()
            repeat(1 + random.nextInt(4)) { mutated[random.nextInt(mutated.size)] = random.nextInt(256).toByte() }
            assertDoesNotThrow { TombstoneParser.parse(mutated) }
        }
    }
}
