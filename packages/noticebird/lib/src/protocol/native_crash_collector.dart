import 'package:noticebird_protocol/noticebird_protocol.dart';

import 'noticebird_config.dart';

/// Collects the crash reports the operating system keeps about earlier runs
/// of this process — MetricKit diagnostics on iOS, `ApplicationExitInfo` and
/// a chaining JVM handler on Android.
///
/// Implemented by the `noticebird_native` package; the core only asks.
/// Collection is process-wide and native; every engine whose client has a
/// collector records its run; only an engine that calls
/// [NoticebirdClient.reportNativeCrashes] delivers.
///
/// Every member must be safe to call from any engine and must never throw
/// into the host: the client guards each call as well, but an implementation
/// that throws loses the report it was handling.
abstract interface class NativeCrashCollector {
  /// Starts collection in this process (idempotent across engines) and
  /// records [run] in the run ledger under the process's native run id.
  Future<void> start(NativeRunInfo run);

  /// The route or trail of this engine's run changed. The collector persists
  /// a debounced snapshot, so a native crash of this run can carry it. Never
  /// blocks.
  void update(NativeRunState state);

  /// Claims reports of earlier runs for delivery by this engine, which the
  /// ledger then records as the delivering one.
  ///
  /// The first batch holds the reports waiting at the call — possibly none,
  /// and at most [max]; each later batch holds reports that arrived since
  /// (a MetricKit payload delivered later in this run). Every batch carries
  /// the ledger to attribute its reports against. A claimed report stays
  /// invisible to other claims until it is settled or its lease runs out.
  Stream<NativeCrashBatch> claimed({int max = 10});

  /// Ends the claim on [recordId]: [delivered] deletes the report; otherwise
  /// it becomes claimable again once its lease runs out.
  Future<void> settle(String recordId, {required bool delivered});
}

/// This engine's run, as the collector records it in the run ledger.
final class NativeRunInfo {
  const NativeRunInfo({
    required this.sessionId,
    required this.app,
    required this.platform,
    required this.privacyProfile,
  });

  /// The session id this engine's events carry; a native report of this run
  /// carries it too, so it links to the run's other events.
  final String sessionId;
  final AppMetadata app;
  final PlatformMetadata platform;

  /// Under [CrashPrivacyProfile.regulatedStrict] the collector persists no
  /// trail and writes no exception message.
  final CrashPrivacyProfile privacyProfile;
}

/// What a native report of this run would carry of its context: the route
/// template and the breadcrumb trail as they are now.
final class NativeRunState {
  const NativeRunState({this.routeTemplate, this.breadcrumbs = const []});

  final String? routeTemplate;

  /// Empty under [CrashPrivacyProfile.regulatedStrict].
  final List<TypedBreadcrumb> breadcrumbs;
}

/// A report the operating system kept about an earlier run: bounded and
/// allowlisted by the collector before it was ever stored, so no raw OS data
/// reaches the core.
final class NativeCrashRecord {
  const NativeCrashRecord({
    required this.recordId,
    required this.kind,
    required this.source,
    required this.occurredAt,
    this.machException,
    this.signal,
    this.code,
    this.terminationCode,
    this.exceptionClass,
    this.exceptionMessage,
    this.durationMs,
    this.bytesWritten,
    this.images = const [],
    this.frames = const [],
    this.runId,
    this.pid,
    this.appVersion,
    this.appBuild,
    this.foreground,
  });

  /// SHA-256 over the normalized report: the same report always has the same
  /// id, which is what makes a resend a replay on the platform.
  final String recordId;
  final NativeCrashKind kind;
  final NativeReportSource source;
  final DateTime occurredAt;
  final String? machException;
  final String? signal;
  final String? code;
  final String? terminationCode;

  /// The uncaught JVM or Objective-C exception's class name.
  final String? exceptionClass;

  /// Its message, unsanitized; null under `regulatedStrict`.
  final String? exceptionMessage;
  final int? durationMs;
  final int? bytesWritten;
  final List<NativeImage> images;
  final List<NativeFrame> frames;

  /// The crashed run's native run id when the OS reported it (Android's
  /// process state summary, or the JVM handler of that run).
  final String? runId;

  /// The crashed process's id (iOS 17+, Android).
  final int? pid;

  /// The app version and build the report names.
  final String? appVersion;
  final String? appBuild;

  /// Whether the app was in the foreground when it died, when the OS says.
  final bool? foreground;
}

/// One claimed batch: the reports and the run ledger they are attributed
/// against.
final class NativeCrashBatch {
  const NativeCrashBatch({required this.records, required this.runs});

  final List<NativeCrashRecord> records;
  final List<NativeRecordedRun> runs;
}

/// One run of the process in the ledger: what native code recorded at
/// startup, plus each engine that recorded itself.
final class NativeRecordedRun {
  const NativeRecordedRun({
    required this.runId,
    required this.startedAt,
    this.pid,
    this.appVersion,
    this.appBuild,
    this.isCurrent = false,
    this.reportable = true,
    this.engines = const [],
  });

  final String runId;
  final DateTime startedAt;
  final int? pid;

  /// The version and build of the app bundle that ran.
  final String? appVersion;
  final String? appBuild;

  /// Whether this is the run that is delivering now. A report never belongs
  /// to it unless the OS names it exactly.
  final bool isCurrent;

  /// False for a run whose reports the collector's policy excludes — a debug
  /// build, unless the host opted in. A report attributed to it is dropped:
  /// attributing first keeps it from landing on another run.
  final bool reportable;
  final List<NativeEngineRecord> engines;
}

/// One engine's record of its run: the context a native report of the run
/// carries.
final class NativeEngineRecord {
  const NativeEngineRecord({
    required this.sessionId,
    required this.app,
    required this.platform,
    this.delivers = false,
    this.routeTemplate,
    this.foreground,
    this.breadcrumbs = const [],
  });

  final String sessionId;
  final AppMetadata app;
  final PlatformMetadata platform;

  /// Whether this engine claimed reports — the UI engine. Its session wins
  /// over a headless engine's in the same run.
  final bool delivers;
  final String? routeTemplate;
  final bool? foreground;
  final List<TypedBreadcrumb> breadcrumbs;
}
