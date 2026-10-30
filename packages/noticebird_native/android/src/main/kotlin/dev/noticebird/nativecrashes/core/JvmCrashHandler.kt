package dev.noticebird.nativecrashes.core

import java.util.concurrent.atomic.AtomicBoolean

/**
 * The JVM uncaught-exception handler: records the crash through [record],
 * then always hands the exception to [previous] — the system's handler or
 * another crash SDK's — so the process dies exactly as it would have.
 *
 * Nothing of ours escapes: [record] is guarded against every [Throwable],
 * and a failure costs only the record. What [previous] does, including
 * throwing, is left untouched.
 */
internal class ChainingExceptionHandler(
    private val previous: Thread.UncaughtExceptionHandler?,
    private val record: (Thread, Throwable) -> Unit,
) : Thread.UncaughtExceptionHandler {
    override fun uncaughtException(thread: Thread, error: Throwable) {
        try {
            record(thread, error)
        } catch (_: Throwable) {
            // Recording must never change how the process dies.
        }
        if (previous != null) {
            previous.uncaughtException(thread, error)
        } else {
            // What ThreadGroup does without a default handler. Calling the
            // group itself would look the default handler up again: us.
            try {
                System.err.print("Exception in thread \"${thread.name}\" ")
                error.printStackTrace(System.err)
            } catch (_: Throwable) {
                // Nothing left to report to.
            }
        }
    }
}

/**
 * Installs one [ChainingExceptionHandler] as the default handler, chaining
 * to the handler installed before it. Idempotent: [process] is the one
 * instance per process.
 */
internal class JvmHandlerInstaller {
    private val installed = AtomicBoolean(false)

    /** True when this call installed the handler. */
    fun install(record: (Thread, Throwable) -> Unit): Boolean {
        if (!installed.compareAndSet(false, true)) return false
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler(ChainingExceptionHandler(previous, record))
        return true
    }

    companion object {
        val process = JvmHandlerInstaller()
    }
}
