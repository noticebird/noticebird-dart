package dev.noticebird.noticebird_native_example

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The crash lab's native triggers. Deliberate, and only in this example app:
 * an uncaught JVM exception, and a main thread blocked long enough for an ANR
 * kill once the screen is touched.
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "noticebird_native_example/lab")
            .setMethodCallHandler { call, result ->
                val main = Handler(Looper.getMainLooper())
                when (call.method) {
                    "jvmException" -> {
                        result.success(null)
                        main.post { throw IllegalStateException("Deliberate JVM crash from the native crash lab") }
                    }
                    "blockMainThread" -> {
                        result.success(null)
                        main.post { Thread.sleep(30_000) }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
