import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:noticebird/noticebird.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'native_crash_record_codec.dart';
import 'run_ledger.dart';

/// The method channel of the native contract, shared with the Swift and
/// Kotlin sides. Not exported.
const nativeMethodChannelName = 'noticebird_native';

/// The event channel of the native contract, on which the native side tells
/// of reports that arrive during the run. Not exported.
const nativeEventChannelName = 'noticebird_native/arrivals';

/// A capture with its platform seams replaced, for tests. Not exported.
@visibleForTesting
NativeCrashCapture nativeCrashCaptureWithPlatform({
  required MethodChannel methods,
  required EventChannel arrivals,
  required bool supported,
  required bool debugBuild,
  bool hangs = false,
  bool diskWrites = false,
  bool includeDebugBuilds = false,
  DateTime Function()? clock,
  bool Function()? bindingReady,
}) => NativeCrashCapture._withPlatform(
  methods: methods,
  arrivals: arrivals,
  supported: supported,
  debugBuild: debugBuild,
  hangs: hangs,
  diskWrites: diskWrites,
  includeDebugBuilds: includeDebugBuilds,
  clock: clock,
  bindingReady: bindingReady,
);

/// Captures the crash reports the operating system keeps about earlier runs
/// and hands them to the Noticebird client, which delivers them as events:
///
/// - **iOS 15+** — MetricKit crash diagnostics: signal and Mach-exception
///   crashes, uncaught Objective-C and Swift exceptions, watchdog kills; with
///   [hangs] and [diskWrites], hang and disk-write diagnostics too.
/// - **Android 11+ (API 30)** — `ApplicationExitInfo`: native crashes (with
///   the tombstone's frames from API 31), ANR kills, foreground low-memory
///   kills; on every API level, uncaught JVM exceptions through a handler
///   that chains to whatever handler was installed before.
///
/// Nothing of it runs inside a crashing process except that JVM handler: the
/// operating system keeps the report and the collector reads it on a later
/// launch. It is inert on the web and on desktop, and in debug builds unless
/// [includeDebugBuilds] — a debug build run outside the debugger crashes on
/// JIT code by design, and those reports are noise.
///
/// ```dart
/// NoticebirdConfig(
///   // …
///   nativeCrashes: NativeCrashCapture(),
/// );
/// ```
final class NativeCrashCapture implements NativeCrashCollector {
  NativeCrashCapture({
    this.hangs = false,
    this.diskWrites = false,
    this.includeDebugBuilds = false,
  }) : _methods = const MethodChannel(nativeMethodChannelName),
       _arrivals = const EventChannel(nativeEventChannelName),
       _supported =
           !kIsWeb &&
           (defaultTargetPlatform == TargetPlatform.iOS ||
               defaultTargetPlatform == TargetPlatform.android),
       _debugBuild = kDebugMode,
       _clock = DateTime.now,
       _bindingReady = _servicesBindingReady;

  NativeCrashCapture._withPlatform({
    required MethodChannel methods,
    required EventChannel arrivals,
    required bool supported,
    required bool debugBuild,
    this.hangs = false,
    this.diskWrites = false,
    this.includeDebugBuilds = false,
    DateTime Function()? clock,
    bool Function()? bindingReady,
  }) : _methods = methods,
       _arrivals = arrivals,
       _supported = supported,
       _debugBuild = debugBuild,
       _clock = clock ?? DateTime.now,
       _bindingReady = bindingReady ?? _servicesBindingReady;

  /// Report iOS hang diagnostics (the main thread hung; the app lived on).
  final bool hangs;

  /// Report iOS disk-write exceptions (the app wrote more than allowed).
  final bool diskWrites;

  /// Report native crashes of debug builds and deliver from them.
  final bool includeDebugBuilds;

  final MethodChannel _methods;
  final EventChannel _arrivals;
  final bool _supported;
  final bool _debugBuild;
  final DateTime Function() _clock;
  final bool Function() _bindingReady;
  final String _engineId = _randomHex(16);

  /// How long [start] waits for the Flutter binding, polling every
  /// [_bindingPoll].
  static const _bindingWait = Duration(seconds: 10);
  static const _bindingPoll = Duration(milliseconds: 50);
  RunLedger? _ledger;
  AppLifecycleListener? _lifecycle;

  @override
  Future<void> start(NativeRunInfo run) async {
    if (!_supported || _ledger != null) return;
    try {
      // A host that builds its client before runApp — the `client.run(...)`
      // pattern — starts native capture before the binding exists, and a
      // platform channel needs it. runApp creates it moments later; wait for
      // that rather than initialize it here, in a zone that is not the app's.
      if (!await _awaitBinding()) return;
      // Every engine calls start, debug builds too: it tells the native side
      // that the host still has native capture configured.
      final reply = await _methods.invokeMapMethod<String, Object?>('start', {
        'strict': run.privacyProfile == CrashPrivacyProfile.regulatedStrict,
        'hangs': hangs,
        'diskWrites': diskWrites,
      });
      final runId = reply?['runId'];
      final directory = reply?['directory'];
      if (runId is! String || directory is! String || runId.isEmpty) return;
      final ledger = RunLedger(
        directory: Directory(directory),
        runId: runId,
        engineId: _engineId,
        run: run,
        clock: _clock,
      );
      _ledger = ledger;
      ledger.recordStart(foreground: _currentForeground());
      _observeLifecycle(ledger);
    } catch (_) {
      // Reporting must never affect the host application.
    }
  }

  @override
  void update(NativeRunState state) {
    try {
      _ledger?.update(state);
    } catch (_) {
      // Reporting must never affect the host application.
    }
  }

  @override
  Stream<NativeCrashBatch> claimed({int max = 10}) {
    final ledger = _ledger;
    if (ledger == null || (_debugBuild && !includeDebugBuilds)) {
      return Stream.value(const NativeCrashBatch(records: [], runs: []));
    }
    ledger.markDelivering();
    late final StreamController<NativeCrashBatch> controller;
    StreamSubscription<Object?>? arrivals;
    var claiming = false;
    var claimAgain = false;
    var first = true;

    Future<void> claim() async {
      if (claiming) {
        claimAgain = true;
        return;
      }
      claiming = true;
      try {
        do {
          claimAgain = false;
          final batch = await _claimBatch(ledger, max);
          if ((first || batch.records.isNotEmpty) && !controller.isClosed) {
            controller.add(batch);
          }
          first = false;
        } while (claimAgain && !controller.isClosed);
      } finally {
        claiming = false;
      }
    }

    controller = StreamController<NativeCrashBatch>(
      onListen: () {
        unawaited(claim());
        try {
          arrivals = _arrivals.receiveBroadcastStream().listen(
            (_) => unawaited(claim()),
            onError: (Object _) {},
          );
        } catch (_) {
          // Without arrivals, later reports wait for the next launch.
        }
      },
      onCancel: () => arrivals?.cancel(),
    );
    return controller.stream;
  }

  Future<NativeCrashBatch> _claimBatch(RunLedger ledger, int max) async {
    try {
      final reply =
          await _methods.invokeListMethod<Object?>('claim', {'max': max}) ??
          const [];
      final records = <NativeCrashRecord>[];
      for (final value in reply.take(max)) {
        final record = decodeNativeCrashRecord(value);
        if (record != null) {
          records.add(record);
          continue;
        }
        // A record this version cannot read never will: settle it away.
        final recordId = nativeCrashRecordIdOf(value);
        if (recordId != null) await settle(recordId, delivered: true);
      }
      return NativeCrashBatch(
        records: List.unmodifiable(records),
        runs: ledger.readRuns(includeDebugBuilds: includeDebugBuilds),
      );
    } catch (_) {
      return const NativeCrashBatch(records: [], runs: []);
    }
  }

  @override
  Future<void> settle(String recordId, {required bool delivered}) async {
    try {
      await _methods.invokeMethod<void>('settle', {
        'recordId': recordId,
        'delivered': delivered,
      });
    } catch (_) {
      // An unsettled claim expires with its lease.
    }
  }

  Future<bool> _awaitBinding() async {
    final deadline = _clock().add(_bindingWait);
    while (!_bindingReady()) {
      if (_clock().isAfter(deadline)) return false;
      await Future<void>.delayed(_bindingPoll);
    }
    return true;
  }

  static bool _servicesBindingReady() {
    try {
      ServicesBinding.instance;
      return true;
    } catch (_) {
      return false;
    }
  }

  void _observeLifecycle(RunLedger ledger) {
    try {
      _lifecycle ??= AppLifecycleListener(
        onStateChange: (state) => ledger.setForeground(_isForeground(state)),
      );
    } catch (_) {
      // No widgets binding in this engine: no lifecycle to follow.
    }
  }

  static bool? _currentForeground() {
    try {
      final state = WidgetsBinding.instance.lifecycleState;
      return state == null ? null : _isForeground(state);
    } catch (_) {
      return null;
    }
  }

  static bool _isForeground(AppLifecycleState state) =>
      state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;

  static String _randomHex(int length) {
    final random = Random.secure();
    return List.generate(
      length,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
  }
}
