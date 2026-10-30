/// Native crash capture for `noticebird`: the crash reports iOS
/// (MetricKit) and Android (`ApplicationExitInfo`, a chaining JVM handler)
/// keep about earlier runs, delivered as protocol events.
library;

export 'src/native_crash_capture.dart' show NativeCrashCapture;
