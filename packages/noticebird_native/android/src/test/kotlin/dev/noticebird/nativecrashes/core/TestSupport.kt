package dev.noticebird.nativecrashes.core

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream

/** A protobuf writer for test inputs: the wire format, field by field. */
internal class ProtoWriter {
    private val out = ByteArrayOutputStream()

    fun varint(field: Int, value: Long) = apply {
        tag(field, ProtoReader.VARINT)
        rawVarint(value)
    }

    fun fixed64(field: Int, value: Long) = apply {
        tag(field, ProtoReader.FIXED64)
        for (shift in 0 until 64 step 8) out.write((value ushr shift).toInt() and 0xff)
    }

    fun fixed32(field: Int, value: Int) = apply {
        tag(field, ProtoReader.FIXED32)
        for (shift in 0 until 32 step 8) out.write((value ushr shift) and 0xff)
    }

    fun bytes(field: Int, value: ByteArray) = apply {
        tag(field, ProtoReader.LENGTH_DELIMITED)
        rawVarint(value.size.toLong())
        out.write(value)
    }

    fun string(field: Int, value: String) = bytes(field, value.toByteArray(Charsets.UTF_8))

    fun message(field: Int, block: ProtoWriter.() -> Unit) = bytes(field, ProtoWriter().apply(block).toByteArray())

    fun tag(field: Int, wireType: Int) = apply { rawVarint((field.toLong() shl 3) or wireType.toLong()) }

    fun rawVarint(value: Long) = apply {
        var remaining = value
        while (true) {
            if (remaining and 0x7fL.inv() == 0L) {
                out.write(remaining.toInt())
                return@apply
            }
            out.write(((remaining and 0x7f) or 0x80).toInt())
            remaining = remaining ushr 7
        }
    }

    fun raw(bytes: ByteArray) = apply { out.write(bytes) }

    fun size() = out.size()

    fun toByteArray(): ByteArray = out.toByteArray()
}

/**
 * Tombstones as `debuggerd` writes them, built field by field after
 * `system/core/debuggerd/proto/tombstone.proto` — including the fields the
 * collector must skip (registers, memory maps, log buffers, open files).
 */
internal object Tombstones {
    const val PACKAGE = "dev.noticebird.noticebird_native_example"
    const val INSTALL_DIR = "/data/app/~~Qm9vdEEAAAAAAAAAAAAAAA==/$PACKAGE-ZXhhbXBsZUFBQUFBQUFBQUFBQQ=="
    const val LIBC_BUILD_ID = "a8c2b37a6f1e4d0c9b5e7f3a1d2c4b6e"
    const val FLUTTER_BUILD_ID = "4C4C44E555553144A13DCC7994841AAC0BADF00D"
    const val APP_BUILD_ID = "2f9e8d7c6b5a49382716051f2e3d4c5b"
    const val ART_BUILD_ID = "7d1c0b9a8f7e6d5c4b3a291807f6e5d4"
    const val ABORT_MESSAGE = "[FATAL:flutter/runtime/dart_vm.cc(42)] Check failed: vm. user=jane.doe@example.com"

    /** One `BacktraceFrame`, with the absolute `pc` and `sp` we must never keep. */
    fun ProtoWriter.frame(
        relPc: Long,
        functionName: String? = null,
        fileName: String? = null,
        buildId: String? = null,
    ) = message(4) {
        varint(1, relPc)
        varint(2, 0x7a_0000_0000L + relPc)
        varint(3, 0x7f_fe00_0000L)
        functionName?.let { string(4, it) }
        varint(5, 164)
        fileName?.let { string(6, it) }
        varint(7, 0)
        buildId?.let { string(8, it) }
    }

    fun ProtoWriter.thread(key: Long, id: Long, name: String, frames: ProtoWriter.() -> Unit) = message(16) {
        varint(1, key)
        message(2) {
            varint(1, id)
            string(2, name)
            message(3) {
                string(1, "x0")
                varint(2, 0x7a12345678L)
            }
            message(3) {
                string(1, "lr")
                varint(2, 0x7a87654321L)
            }
            string(7, "backtrace note")
            frames()
            message(5) {
                string(1, "x0")
                varint(2, 0x7a12345678L)
                bytes(4, ByteArray(32) { it.toByte() })
            }
            varint(6, 1)
        }
    }

    /** A realistic `SIGABRT` from the engine on the main thread. */
    fun realistic(arch: Long? = 1, signalCode: Long = -6): ByteArray = ProtoWriter().apply {
        arch?.let { varint(1, it) }
        string(2, "google/sdk_gphone64_arm64/emu64a:14/UE1A.230829.036/10000000:userdebug/dev-keys")
        string(3, "0")
        string(4, "2026-09-25 10:01:17.000000000+0200")
        varint(5, 4312)
        varint(6, 4312)
        varint(7, 10190)
        string(8, "u:r:untrusted_app:s0:c190,c256,c512,c768")
        string(9, PACKAGE)
        varint(20, 12)
        message(10) {
            varint(1, 6)
            string(2, "SIGABRT")
            varint(3, signalCode)
            string(4, "SI_TKILL")
            varint(5, 1)
            varint(6, 10190)
            varint(7, 4312)
        }
        string(14, ABORT_MESSAGE)
        message(15) { string(1, "cause: abort") }
        thread(key = 4330, id = 4330, name = "1.raster") {
            frame(0x1234, "raster_only_function", "$INSTALL_DIR/base.apk!libflutter.so", FLUTTER_BUILD_ID)
        }
        thread(key = 4312, id = 4312, name = "ample.example") {
            frame(0x5a5c4, "abort", "/apex/com.android.runtime/lib64/bionic/libc.so", LIBC_BUILD_ID)
            frame(0x1d6a18, null, "$INSTALL_DIR/base.apk!libflutter.so", FLUTTER_BUILD_ID)
            frame(0x2f1c4, "_kDartIsolateSnapshotInstructions", "$INSTALL_DIR/lib/arm64/libapp.so", APP_BUILD_ID)
            frame(0x100, "com.example.Jitted.method", "/memfd:jit-cache (deleted)", null)
            frame(0x218b58, "art_quick_invoke_stub", "/apex/com.android.art/lib64/libart.so", ART_BUILD_ID)
            frame(0x44, null, "", null)
            frame(
                0x2a3c1c,
                "art::ArtMethod::Invoke(art::Thread*, unsigned int*, unsigned int, art::JValue*, char const*)",
                "/apex/com.android.art/lib64/libart.so",
                ART_BUILD_ID,
            )
            frame(0x5a000, "raise", "/apex/com.android.runtime/lib64/bionic/libc.so", LIBC_BUILD_ID)
        }
        message(17) {
            varint(1, 0x7a00000000L)
            varint(2, 0x7a00100000L)
            varint(4, 1)
            string(7, "$INSTALL_DIR/base.apk")
            string(8, FLUTTER_BUILD_ID)
        }
        message(18) {
            string(1, "main")
            message(2) {
                string(5, "flutter")
                string(6, "signed in as jane.doe@example.com")
            }
        }
        message(19) {
            varint(1, 42)
            string(2, "/data/user/0/$PACKAGE/databases/secret.db")
        }
        varint(22, 4096)
        fixed64(999, 0x0123456789abcdefL)
        fixed32(998, 0x01020304)
    }.toByteArray()
}

/** The platform seam, faked at its plain-data boundary. */
internal class FakePlatform(var now: Long, override val pid: Int = 5000) : CapturePlatform {
    var exits: List<ExitReport> = emptyList()
    var exitsFailure: Exception? = null
    val summaries = mutableListOf<String>()
    var installs = 0
    var record: ((Thread, Throwable) -> Unit)? = null

    override fun nowMs() = now

    override fun describeApp() = AppDescription(
        appVersion = "1.4.0",
        appBuild = "140",
        debugBuild = false,
        paths = AppPaths(Tombstones.PACKAGE, listOf(Tombstones.INSTALL_DIR, "/data/user/0/${Tombstones.PACKAGE}")),
    )

    override fun setProcessStateSummary(runId: String) {
        summaries += runId
    }

    override fun historicalExits(): List<ExitReport> = exitsFailure?.let { throw it } ?: exits

    override fun installUncaughtExceptionHandler(record: (Thread, Throwable) -> Unit) {
        installs++
        if (this.record == null) this.record = record
    }
}

internal fun exit(
    reason: ExitReason,
    timestampMs: Long,
    pid: Int = 4312,
    importance: Int = 100,
    runId: String? = null,
    trace: ByteArray? = null,
) = ExitReport(
    reason = reason,
    importance = importance,
    pid = pid,
    timestampMs = timestampMs,
    processStateSummary = runId?.toByteArray(Charsets.UTF_8),
    openTrace = trace?.let { bytes -> { ByteArrayInputStream(bytes) as InputStream } },
)

internal fun runIdOf(index: Int) = index.toString(16).padStart(32, '0')

internal fun File.tree(): List<String> =
    walkTopDown().filter { it.isFile }.map { it.relativeTo(this).path }.sorted().toList()

internal val appPaths = AppPaths(Tombstones.PACKAGE, listOf(Tombstones.INSTALL_DIR, "/data/user/0/${Tombstones.PACKAGE}"))
