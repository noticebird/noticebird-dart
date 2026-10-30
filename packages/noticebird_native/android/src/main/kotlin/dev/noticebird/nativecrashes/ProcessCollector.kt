package dev.noticebird.nativecrashes

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import dev.noticebird.nativecrashes.core.CaptureCore
import dev.noticebird.nativecrashes.core.RecordRules
import dev.noticebird.nativecrashes.core.toHex
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.SecureRandom
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The one collector of this process, shared by every engine that registers
 * the plugin (a headless engine registers it again). The first registration
 * creates the run; every channel call runs on one serial thread, and every
 * reply and arrival goes back on the main thread. Nothing here throws into
 * the host: each entry point catches [Throwable], and a failure replies with
 * an empty result.
 *
 * It holds only the application context, which lives as long as the process.
 */
@SuppressLint("StaticFieldLeak")
internal object ProcessCollector {
    private const val DIRECTORY = "noticebird_native/v1"

    private val registered = AtomicBoolean(false)
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { task ->
        Thread(task, "noticebird_native").apply { isDaemon = true }
    }
    private val main by lazy { Handler(Looper.getMainLooper()) }

    /**
     * The application context — a process singleton, so holding it here leaks
     * nothing. Written at registration, read on the executor.
     */
    @Volatile
    private var context: Context? = null

    /** Executor thread only. */
    private var core: CaptureCore? = null

    /** Main thread only: one sink per listening engine. */
    private val sinks = LinkedHashSet<EventChannel.EventSink>()

    /**
     * At every engine's registration; only the first one registers the run.
     * The context is kept before that, so a call from any engine finds it.
     */
    fun attach(context: Context) {
        if (this.context == null) this.context = context.applicationContext ?: context
        if (registered.compareAndSet(false, true)) execute { ensureCore() }
    }

    fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> reply(result, fallback = emptyMap<String, Any>()) {
                val arguments = call.arguments as? Map<*, *>
                val started = ensureCore()?.start(
                    strict = arguments?.get("strict") == true,
                    hangs = arguments?.get("hangs") == true,
                    diskWrites = arguments?.get("diskWrites") == true,
                ) ?: return@reply emptyMap<String, Any>()
                emit(started.added)
                started.reply
            }
            "claim" -> reply(result, fallback = emptyList<Any>()) {
                val max = ((call.arguments as? Map<*, *>)?.get("max") as? Number)?.toLong() ?: 0L
                ensureCore()?.claim(max.coerceIn(0L, Int.MAX_VALUE.toLong()).toInt()) ?: emptyList<Any>()
            }
            "settle" -> reply(result, fallback = null) {
                val arguments = call.arguments as? Map<*, *>
                val recordId = arguments?.get("recordId") as? String
                val delivered = arguments?.get("delivered") as? Boolean
                if (recordId != null && delivered != null && RecordRules.RECORD_ID.matches(recordId)) {
                    ensureCore()?.settle(recordId, delivered)
                }
                null
            }
            "disable" -> reply(result, fallback = null) {
                ensureCore()?.disable()
                null
            }
            else -> result.notImplemented()
        }
    }

    fun addSink(sink: EventChannel.EventSink) {
        sinks.add(sink)
    }

    fun removeSink(sink: EventChannel.EventSink) {
        sinks.remove(sink)
    }

    /** The core, created and registered at the first need. Executor thread only. */
    private fun ensureCore(): CaptureCore? {
        core?.let { return it }
        val context = context ?: return null
        val created = CaptureCore(
            directory = File(context.noBackupFilesDir, DIRECTORY),
            platform = AndroidCapturePlatform(context),
            runId = newRunId(),
        )
        core = created
        try {
            emit(created.register())
        } catch (_: Throwable) {
            // A failed registration leaves the run unrecorded; `start` still
            // enables capture.
        }
        return created
    }

    /** Runs [work] on the executor and replies its value, or [fallback], on the main thread. */
    private fun reply(result: MethodChannel.Result, fallback: Any?, work: () -> Any?) {
        val submitted = execute {
            val value = try {
                work()
            } catch (_: Throwable) {
                fallback
            }
            onMain { result.success(value) }
        }
        if (!submitted) onMain { result.success(fallback) }
    }

    /** Tells every listening engine that [count] records arrived. */
    private fun emit(count: Int) {
        if (count <= 0) return
        onMain {
            for (sink in sinks.toList()) {
                try {
                    sink.success(count)
                } catch (_: Throwable) {
                    // A sink of a detached engine: nothing to tell.
                }
            }
        }
    }

    private fun execute(work: () -> Unit): Boolean = try {
        executor.execute {
            try {
                work()
            } catch (_: Throwable) {
                // Reporting must never affect the host application.
            }
        }
        true
    } catch (_: Throwable) {
        false
    }

    private fun onMain(work: () -> Unit) {
        try {
            main.post {
                try {
                    work()
                } catch (_: Throwable) {
                    // Reporting must never affect the host application.
                }
            }
        } catch (_: Throwable) {
            // No main looper to post to: nothing to reply on.
        }
    }

    private fun newRunId(): String = ByteArray(16).also { SecureRandom().nextBytes(it) }.toHex()
}
