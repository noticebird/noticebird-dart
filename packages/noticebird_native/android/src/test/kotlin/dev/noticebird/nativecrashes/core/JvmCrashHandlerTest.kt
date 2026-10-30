package dev.noticebird.nativecrashes.core

import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertSame
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.PrintStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class JvmCrashHandlerTest {
    @TempDir
    lateinit var root: File

    private var originalDefault: Thread.UncaughtExceptionHandler? = null

    /** The previous handler: records every call, as the system's would kill the process. */
    private class RecordingHandler : Thread.UncaughtExceptionHandler {
        val calls = mutableListOf<Pair<Thread, Throwable>>()
        val called = CountDownLatch(1)

        override fun uncaughtException(thread: Thread, error: Throwable) {
            calls += thread to error
            called.countDown()
        }
    }

    @BeforeEach
    fun rememberDefault() {
        originalDefault = Thread.getDefaultUncaughtExceptionHandler()
    }

    @AfterEach
    fun restoreDefault() {
        Thread.setDefaultUncaughtExceptionHandler(originalDefault)
    }

    @Test
    fun `records first, then always calls the previous handler`() {
        val order = mutableListOf<String>()
        val previous = Thread.UncaughtExceptionHandler { _, _ -> order += "previous" }
        val handler = ChainingExceptionHandler(previous) { _, _ -> order += "record" }

        handler.uncaughtException(Thread.currentThread(), RuntimeException("boom"))

        assertEquals(listOf("record", "previous"), order)
    }

    @Test
    fun `the previous handler is called even when recording throws anything`() {
        val failures = listOf<Throwable>(
            RuntimeException("write failed"),
            java.io.IOException("disk full"),
            StackOverflowError(),
            OutOfMemoryError("no memory to record"),
        )
        for (failure in failures) {
            val previous = RecordingHandler()
            val error = IllegalStateException("original")
            val handler = ChainingExceptionHandler(previous) { _, _ -> throw failure }

            handler.uncaughtException(Thread.currentThread(), error)

            assertEquals(1, previous.calls.size, failure.toString())
            assertSame(error, previous.calls.single().second)
        }
    }

    @Test
    fun `without a previous handler it prints like the JVM and does not recurse`() {
        var records = 0
        val handler = ChainingExceptionHandler(previous = null) { _, _ -> records++ }
        Thread.setDefaultUncaughtExceptionHandler(handler)
        val captured = ByteArrayOutputStream()
        val originalErr = System.err
        System.setErr(PrintStream(captured, true))
        try {
            handler.uncaughtException(Thread.currentThread(), RuntimeException("unhandled"))
        } finally {
            System.setErr(originalErr)
        }

        assertEquals(1, records)
        assertTrue(captured.toString().contains("RuntimeException: unhandled"))
    }

    @Test
    fun `installs once, chaining to the handler that was there`() {
        val previous = RecordingHandler()
        Thread.setDefaultUncaughtExceptionHandler(previous)
        val installer = JvmHandlerInstaller()
        val recorded = mutableListOf<Throwable>()

        assertTrue(installer.install { _, error -> recorded += error })
        val installed = Thread.getDefaultUncaughtExceptionHandler()
        assertFalse(installer.install { _, _ -> throw AssertionError("second install must not replace the first") })
        assertSame(installed, Thread.getDefaultUncaughtExceptionHandler())

        val error = IllegalStateException("thread died")
        val thread = Thread { throw error }
        thread.start()
        thread.join(5_000)

        assertTrue(previous.called.await(5, TimeUnit.SECONDS))
        assertEquals(listOf<Throwable>(error), recorded)
        assertSame(error, previous.calls.single().second)
        assertSame(thread, previous.calls.single().first)
    }

    @Test
    fun `a real crash is written as one record, and chained even when the write fails`() {
        val directory = File(root, "v1")
        val platform = FakePlatform(now = 1_758_787_200_000L, pid = 4312)
        val core = CaptureCore(directory, platform, runIdOf(1))
        core.start(strict = false, hangs = false, diskWrites = false)
        val previous = RecordingHandler()
        val handler = ChainingExceptionHandler(previous, platform.record!!)

        handler.uncaughtException(Thread.currentThread(), IllegalArgumentException("bad argument"))

        val record = InboxStore(directory) { platform.now }.stored().single().record
        assertEquals(RecordSource.JVM, record.source)
        assertEquals("java.lang.IllegalArgumentException", record.exceptionClass)
        assertEquals("bad argument", record.exceptionMessage)
        assertEquals(runIdOf(1), record.runId)
        assertEquals(4312, record.pid)
        assertEquals(1, previous.calls.size)

        // The inbox cannot be written: the record is lost, the chain is not.
        File(directory, "inbox").deleteRecursively()
        File(directory, "inbox").writeText("not a directory")
        platform.now += 1
        handler.uncaughtException(Thread.currentThread(), IllegalStateException("second"))

        assertEquals(2, previous.calls.size)
        assertEquals("second", previous.calls.last().second.message)
    }
}
