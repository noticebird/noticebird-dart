package dev.noticebird.nativecrashes

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Native crash capture for `noticebird` (the native contract): the method
 * channel `noticebird_native` and the event channel
 * `noticebird_native/arrivals` of one engine, over the process-wide
 * [ProcessCollector]. Every engine gets its own instance; the collector,
 * the run and the JVM handler exist once per process.
 */
class NoticebirdNativePlugin : FlutterPlugin {
    private var methods: MethodChannel? = null
    private var arrivals: EventChannel? = null
    private var sink: EventChannel.EventSink? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        try {
            ProcessCollector.attach(binding.applicationContext)
            methods = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    try {
                        ProcessCollector.onMethodCall(call, result)
                    } catch (_: Throwable) {
                        // The Dart side guards every call; an unanswered one
                        // must still not reach the host.
                    }
                }
            }
            arrivals = EventChannel(binding.binaryMessenger, EVENT_CHANNEL).also { channel ->
                channel.setStreamHandler(ArrivalsHandler())
            }
        } catch (_: Throwable) {
            // Reporting must never affect the host application.
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        try {
            methods?.setMethodCallHandler(null)
            arrivals?.setStreamHandler(null)
            sink?.let(ProcessCollector::removeSink)
        } catch (_: Throwable) {
            // Reporting must never affect the host application.
        } finally {
            methods = null
            arrivals = null
            sink = null
        }
    }

    private inner class ArrivalsHandler : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            try {
                sink?.let(ProcessCollector::removeSink)
                sink = events
                events?.let(ProcessCollector::addSink)
            } catch (_: Throwable) {
                // Without arrivals, later records wait for the next claim.
            }
        }

        override fun onCancel(arguments: Any?) {
            try {
                sink?.let(ProcessCollector::removeSink)
                sink = null
            } catch (_: Throwable) {
                // Reporting must never affect the host application.
            }
        }
    }

    private companion object {
        const val METHOD_CHANNEL = "noticebird_native"
        const val EVENT_CHANNEL = "noticebird_native/arrivals"
    }
}
