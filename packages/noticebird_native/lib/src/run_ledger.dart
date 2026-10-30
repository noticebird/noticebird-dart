import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:noticebird/noticebird.dart';

/// This engine's entry in the run ledger (the native contract), and the reader
/// of the whole ledger.
///
/// The native side writes each run's `run.json` at plugin registration; every
/// engine writes its own `engine-<id>.json` beside it: at start, debounced on
/// every change of route or trail, and at once when the app's lifecycle state
/// changes or the engine starts delivering — the moments a process is most
/// likely to be killed next.
final class RunLedger {
  RunLedger({
    required Directory directory,
    required this.runId,
    required this.engineId,
    required NativeRunInfo run,
    DateTime Function()? clock,
  }) : _directory = directory,
       _run = run,
       _clock = clock ?? DateTime.now;

  static const debounce = Duration(milliseconds: 500);
  static const maxEngineFileBytes = 16 * 1024;
  static const _version = 1;

  final Directory _directory;
  final String runId;
  final String engineId;
  final NativeRunInfo _run;
  final DateTime Function() _clock;
  NativeRunState _state = const NativeRunState();
  bool? _foreground;
  bool _delivers = false;
  Timer? _pending;

  bool get _strict =>
      _run.privacyProfile == CrashPrivacyProfile.regulatedStrict;

  File get _engineFile =>
      File('${_directory.path}/runs/$runId/engine-$engineId.json');

  /// Writes this engine's record now.
  void recordStart({bool? foreground}) {
    _foreground = foreground;
    _writeNow();
  }

  /// Keeps [state] and writes it once changes have settled for [debounce].
  void update(NativeRunState state) {
    _state = state;
    _pending?.cancel();
    _pending = Timer(debounce, _writeNow);
  }

  /// A lifecycle change is written at once, with whatever state is pending.
  void setForeground(bool? foreground) {
    if (foreground == _foreground) return;
    _foreground = foreground;
    _writeNow();
  }

  /// This engine claims reports: it is the one that speaks for the run.
  void markDelivering() {
    if (_delivers) return;
    _delivers = true;
    _writeNow();
  }

  void _writeNow() {
    _pending?.cancel();
    _pending = null;
    try {
      final file = _engineFile;
      file.parent.createSync(recursive: true);
      final temporary = File('${file.path}.tmp');
      temporary.writeAsStringSync(_encode(), flush: true);
      temporary.renameSync(file.path);
    } catch (_) {
      // A ledger that cannot be written costs the next report its trail.
    }
  }

  String _encode() {
    final breadcrumbs = _strict
        ? <TypedBreadcrumb>[]
        : [..._state.breadcrumbs.take(CrashEvent.maxBreadcrumbs)];
    while (true) {
      final encoded = jsonEncode({
        'version': _version,
        'sessionId': _run.sessionId,
        'app': _run.app.toJson(),
        'platform': _run.platform.toJson(),
        'delivers': _delivers,
        if (_state.routeTemplate != null) 'routeTemplate': _state.routeTemplate,
        if (_foreground != null) 'foreground': _foreground,
        'breadcrumbs': [for (final crumb in breadcrumbs) crumb.toJson()],
        'updatedAtMs': _clock().toUtc().millisecondsSinceEpoch,
      });
      if (utf8.encode(encoded).length <= maxEngineFileBytes ||
          breadcrumbs.isEmpty) {
        return encoded;
      }
      breadcrumbs.removeAt(0);
    }
  }

  /// Every run the ledger holds, this one marked current. A run of a debug
  /// build is not [NativeRecordedRun.reportable] unless [includeDebugBuilds].
  /// Unreadable files are skipped.
  List<NativeRecordedRun> readRuns({required bool includeDebugBuilds}) =>
      readRunLedger(
        _directory,
        currentRunId: runId,
        includeDebugBuilds: includeDebugBuilds,
      );

  /// Writes anything pending now; for tests and shutdown.
  void flush() {
    if (_pending != null) _writeNow();
  }
}

/// Reads the run ledger under [directory] (the `v1/` directory).
List<NativeRecordedRun> readRunLedger(
  Directory directory, {
  required String currentRunId,
  required bool includeDebugBuilds,
}) {
  final runsDirectory = Directory('${directory.path}/runs');
  if (!runsDirectory.existsSync()) return const [];
  final runs = <NativeRecordedRun>[];
  for (final entry in runsDirectory.listSync().whereType<Directory>()) {
    final run = _readRun(
      entry,
      currentRunId: currentRunId,
      includeDebugBuilds: includeDebugBuilds,
    );
    if (run != null) runs.add(run);
  }
  runs.sort((a, b) => a.startedAt.compareTo(b.startedAt));
  return List.unmodifiable(runs);
}

NativeRecordedRun? _readRun(
  Directory directory, {
  required String currentRunId,
  required bool includeDebugBuilds,
}) {
  try {
    final json = _readJson(File('${directory.path}/run.json'));
    if (json == null || json['version'] != 1) return null;
    final runId = json['runId'];
    final startedAtMs = json['startedAtMs'];
    if (runId is! String || startedAtMs is! int) return null;
    final pid = json['pid'];
    final appVersion = json['appVersion'];
    final appBuild = json['appBuild'];
    final debugBuild = json['debugBuild'];
    final engines = <NativeEngineRecord>[];
    for (final file in directory.listSync().whereType<File>()) {
      final name = file.uri.pathSegments.last;
      if (!name.startsWith('engine-') || !name.endsWith('.json')) continue;
      final engine = _readEngine(file);
      if (engine != null) engines.add(engine);
    }
    return NativeRecordedRun(
      runId: runId,
      startedAt: DateTime.fromMillisecondsSinceEpoch(startedAtMs, isUtc: true),
      pid: pid is int ? pid : null,
      appVersion: appVersion is String ? appVersion : null,
      appBuild: appBuild is String ? appBuild : null,
      isCurrent: runId == currentRunId,
      reportable: debugBuild != true || includeDebugBuilds,
      engines: List.unmodifiable(engines),
    );
  } catch (_) {
    return null;
  }
}

NativeEngineRecord? _readEngine(File file) {
  try {
    final json = _readJson(file);
    if (json == null || json['version'] != 1) return null;
    final sessionId = json['sessionId'];
    if (sessionId is! String) return null;
    final routeTemplate = json['routeTemplate'];
    final foreground = json['foreground'];
    final breadcrumbs = json['breadcrumbs'];
    return NativeEngineRecord(
      sessionId: sessionId,
      app: _readApp(json['app']),
      platform: _readPlatform(json['platform']),
      delivers: json['delivers'] == true,
      routeTemplate: routeTemplate is String ? routeTemplate : null,
      foreground: foreground is bool ? foreground : null,
      breadcrumbs: breadcrumbs is List
          ? List.unmodifiable(
              breadcrumbs
                  .take(CrashEvent.maxBreadcrumbs)
                  .map(_readBreadcrumb)
                  .nonNulls,
            )
          : const [],
    );
  } catch (_) {
    return null;
  }
}

/// The app metadata an engine file holds, as `AppMetadata.toJson` wrote it,
/// checked by the protocol; throws for anything else.
AppMetadata _readApp(Object? value) {
  if (value case {
    'name': final String name,
    'version': final String version,
    'build': final String build,
    'release': final String release,
  }) {
    return AppMetadata(
      name: name,
      version: version,
      build: build,
      release: release,
    )..check();
  }
  throw const FormatException('Invalid app metadata');
}

/// The platform metadata an engine file holds, as `PlatformMetadata.toJson`
/// wrote it, checked by the protocol; throws for anything else.
PlatformMetadata _readPlatform(Object? value) {
  if (value case {
    'name': final String name,
    'osVersion': final String osVersion,
    'deviceClass': final String deviceClass,
  }) {
    return PlatformMetadata(
      platform: CrashPlatform.values.byName(name),
      osVersion: osVersion,
      deviceClass: deviceClass,
    )..check();
  }
  throw const FormatException('Invalid platform metadata');
}

/// One breadcrumb, as `TypedBreadcrumb.toJson` wrote it, or null when it no
/// longer reads or the protocol refuses it: a bad crumb costs only itself,
/// not the engine's record.
TypedBreadcrumb? _readBreadcrumb(Object? value) {
  try {
    if (value case {
      'occurredAt': final String occurredAt,
      'category': final String category,
      'action': final String action,
      'level': final String level,
    }) {
      final data = value['data'] as Map? ?? const {};
      return TypedBreadcrumb(
        occurredAt: DateTime.parse(occurredAt).toUtc(),
        category: BreadcrumbCategory.values.byName(category),
        action: action,
        level: CrashSeverity.values.byName(level),
        data: {
          for (final MapEntry(:key, :value) in data.entries)
            AllowedTag.values.byName(key as String): value as TagScalar,
        },
      )..check();
    }
  } catch (_) {
    // Refused below.
  }
  return null;
}

Map<String, Object?>? _readJson(File file) {
  if (!file.existsSync()) return null;
  final decoded = jsonDecode(file.readAsStringSync());
  return decoded is Map ? Map<String, Object?>.from(decoded) : null;
}
