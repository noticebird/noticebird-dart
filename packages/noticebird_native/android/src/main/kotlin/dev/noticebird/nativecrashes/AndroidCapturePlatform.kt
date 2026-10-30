package dev.noticebird.nativecrashes

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Process
import android.os.StrictMode
import androidx.annotation.RequiresApi
import dev.noticebird.nativecrashes.core.AppDescription
import dev.noticebird.nativecrashes.core.AppPaths
import dev.noticebird.nativecrashes.core.CapturePlatform
import dev.noticebird.nativecrashes.core.ExitReason
import dev.noticebird.nativecrashes.core.ExitReport
import dev.noticebird.nativecrashes.core.JvmHandlerInstaller
import java.io.File
import java.io.InputStream

/**
 * The framework side of [CapturePlatform]: thin reads of `ActivityManager`,
 * `PackageManager` and `ApplicationInfo` into plain data, each guarded by
 * the API level it needs.
 */
internal class AndroidCapturePlatform(private val context: Context) : CapturePlatform {
    override val pid: Int = Process.myPid()

    override fun nowMs(): Long = System.currentTimeMillis()

    override fun describeApp(): AppDescription {
        val info = context.applicationInfo
        val packageInfo = try {
            packageInfo()
        } catch (_: Exception) {
            null
        }
        val directories = buildList {
            info.sourceDir?.let { File(it).parent }?.let(::add)
            info.splitSourceDirs?.forEach { split -> File(split).parent?.let(::add) }
            info.nativeLibraryDir?.let(::add)
            info.dataDir?.let(::add)
            info.deviceProtectedDataDir?.let(::add)
        }
        return AppDescription(
            appVersion = packageInfo?.versionName?.takeIf { it.isNotEmpty() },
            appBuild = packageInfo?.let { versionCode(it).toString() },
            debugBuild = (info.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0,
            paths = AppPaths(context.packageName, directories),
        )
    }

    override fun setProcessStateSummary(runId: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        activityManager()?.setProcessStateSummary(runId.toByteArray(Charsets.UTF_8))
    }

    override fun historicalExits(): List<ExitReport> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return emptyList()
        val manager = activityManager() ?: return emptyList()
        return manager.getHistoricalProcessExitReasons(context.packageName, 0, 0).map(::toReport)
    }

    override fun installUncaughtExceptionHandler(record: (Thread, Throwable) -> Unit) {
        JvmHandlerInstaller.process.install { thread, error ->
            // The record is written on the crashing thread, often the main
            // thread: a host's StrictMode disk policy must not stop it.
            val policy = StrictMode.allowThreadDiskWrites()
            try {
                record(thread, error)
            } finally {
                StrictMode.setThreadPolicy(policy)
            }
        }
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun toReport(info: ApplicationExitInfo): ExitReport {
        val reason = when (info.reason) {
            ApplicationExitInfo.REASON_CRASH_NATIVE -> ExitReason.CRASH_NATIVE
            ApplicationExitInfo.REASON_ANR -> ExitReason.ANR
            ApplicationExitInfo.REASON_LOW_MEMORY -> ExitReason.LOW_MEMORY
            ApplicationExitInfo.REASON_CRASH -> ExitReason.CRASH
            else -> ExitReason.OTHER
        }
        // A native crash carries its tombstone from API 31; an ANR its trace
        // from API 30. Opened lazily: only exits that become records are read.
        val hasTrace = when (reason) {
            ExitReason.CRASH_NATIVE -> Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
            ExitReason.ANR -> true
            else -> false
        }
        val openTrace: (() -> InputStream?)? = if (hasTrace) {
            { info.traceInputStream }
        } else {
            null
        }
        return ExitReport(
            reason = reason,
            importance = info.importance,
            pid = info.pid,
            timestampMs = info.timestamp,
            processStateSummary = info.processStateSummary,
            openTrace = openTrace,
        )
    }

    private fun activityManager(): ActivityManager? = context.getSystemService(ActivityManager::class.java)

    private fun packageInfo(): PackageInfo {
        val manager = context.packageManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            manager.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            manager.getPackageInfo(context.packageName, 0)
        }
    }

    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
}
