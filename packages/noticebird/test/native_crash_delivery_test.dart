import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noticebird/noticebird.dart';
import 'package:noticebird/src/protocol/native_crash_event.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/privacy_matches.dart';

const _app = AppMetadata(
  name: 'test-app',
  version: '1.4.0',
  build: '140',
  release: 'test-app@1.4.0+140',
);
const _crashedApp = AppMetadata(
  name: 'test-app',
  version: '1.3.0',
  build: '130',
  release: 'test-app@1.3.0+130',
);
const _platform = PlatformMetadata(
  platform: CrashPlatform.ios,
  osVersion: '26.5.2',
  deviceClass: 'mobile',
);
const _crashedPlatform = PlatformMetadata(
  platform: CrashPlatform.ios,
  osVersion: '26.4',
  deviceClass: 'mobile',
);

final _t0 = DateTime.utc(2026, 9, 25, 8);

TypedBreadcrumb _crumb(String action, {int minute = 0}) => TypedBreadcrumb(
  occurredAt: _t0.add(Duration(minutes: minute)),
  category: BreadcrumbCategory.navigation,
  action: action,
);

NativeCrashRecord _record({
  String recordId =
      'aaaa0000000000000000000000000000000000000000000000000000000000aa',
  NativeCrashKind kind = NativeCrashKind.crash,
  NativeReportSource source = NativeReportSource.metricKit,
  DateTime? occurredAt,
  String? machException = 'EXC_BAD_ACCESS',
  String? signal = 'SIGBUS',
  String? code = '0x32',
  String? terminationCode,
  String? exceptionClass,
  String? exceptionMessage,
  int? durationMs,
  int? bytesWritten,
  List<NativeImage> images = const [
    NativeImage(
      name: 'Flutter',
      inApp: true,
      debugId: '4c4c44e555553144a13dcc7994841aac',
      arch: NativeArch.arm64,
    ),
  ],
  List<NativeFrame> frames = const [
    NativeFrame.unknown(),
    NativeFrame.inImage(0, 10481952),
  ],
  String? runId,
  int? pid,
  String? appVersion = '1.3.0',
  String? appBuild = '130',
  bool? foreground,
}) => NativeCrashRecord(
  recordId: recordId,
  kind: kind,
  source: source,
  occurredAt: occurredAt ?? _t0.add(const Duration(minutes: 30)),
  machException: machException,
  signal: signal,
  code: code,
  terminationCode: terminationCode,
  exceptionClass: exceptionClass,
  exceptionMessage: exceptionMessage,
  durationMs: durationMs,
  bytesWritten: bytesWritten,
  images: images,
  frames: frames,
  runId: runId,
  pid: pid,
  appVersion: appVersion,
  appBuild: appBuild,
  foreground: foreground,
);

/// [buildNativeCrashEvent]'s event for [record], after the test fails
/// unless the event is one the client can write: the builder leaves the
/// check to the client's writer.
CrashEvent? _build(
  NativeCrashRecord record,
  List<NativeRecordedRun> runs, {
  required CrashPrivacyProfile privacyProfile,
}) {
  final event = buildNativeCrashEvent(
    record,
    runs,
    privacyProfile: privacyProfile,
  );
  event?.toCanonicalJson();
  return event;
}

/// The ledger of a crashed run (headless and UI engine) and the current run.
List<NativeRecordedRun> _ledger({
  bool crashedRunHasEngines = true,
  String crashedVersion = '1.3.0',
  String crashedBuild = '130',
  String uiRoute = '/lists/:listId',
  List<TypedBreadcrumb>? uiTrail,
}) => [
  NativeRecordedRun(
    runId: 'run-crashed',
    startedAt: _t0,
    pid: 411,
    appVersion: crashedVersion,
    appBuild: crashedBuild,
    engines: crashedRunHasEngines
        ? [
            NativeEngineRecord(
              sessionId: 'headless_session_000001',
              app: _crashedApp,
              platform: _crashedPlatform,
              routeTemplate: '/background',
              foreground: false,
              breadcrumbs: [_crumb('work.start')],
            ),
            NativeEngineRecord(
              sessionId: 'ui_session_0000000001',
              app: _crashedApp,
              platform: _crashedPlatform,
              delivers: true,
              routeTemplate: uiRoute,
              foreground: true,
              breadcrumbs:
                  uiTrail ??
                  [_crumb('route.push'), _crumb('list.open', minute: 1)],
            ),
          ]
        : const [],
  ),
  NativeRecordedRun(
    runId: 'run-current',
    startedAt: _t0.add(const Duration(hours: 2)),
    pid: 512,
    appVersion: '1.4.0',
    appBuild: '140',
    isCurrent: true,
    engines: const [
      NativeEngineRecord(
        sessionId: 'current_session_000001',
        app: _app,
        platform: _platform,
        delivers: true,
      ),
    ],
  ),
];

final class _FakeCollector implements NativeCrashCollector {
  _FakeCollector({this.batches = const []});

  final List<NativeCrashBatch> batches;
  final starts = <NativeRunInfo>[];
  final updates = <NativeRunState>[];
  final settled = <(String, bool)>[];
  final arrivals = StreamController<NativeCrashBatch>();
  var claims = 0;
  int? lastMax;
  Future<void> Function()? onStart;
  Object? throwOnClaim;
  Object? throwOnSettle;
  Object? throwOnUpdate;

  @override
  Future<void> start(NativeRunInfo run) async {
    starts.add(run);
    await onStart?.call();
  }

  @override
  void update(NativeRunState state) {
    if (throwOnUpdate != null) throw throwOnUpdate!;
    updates.add(state);
  }

  @override
  Stream<NativeCrashBatch> claimed({int max = 10}) {
    claims++;
    lastMax = max;
    if (throwOnClaim != null) throw throwOnClaim!;
    return _claimed();
  }

  Stream<NativeCrashBatch> _claimed() async* {
    yield* Stream.fromIterable(batches);
    yield* arrivals.stream;
  }

  @override
  Future<void> settle(String recordId, {required bool delivered}) async {
    settled.add((recordId, delivered));
    if (throwOnSettle != null) throw throwOnSettle!;
  }
}

final class _RecordingTransport implements CrashTransport {
  /// Every body the client tried to send, delivered or not.
  final canonical = <String>[];
  final events = <Map<String, dynamic>>[];
  Object? failure;

  @override
  Future<void> send(String eventJson) async {
    canonical.add(eventJson);
    if (failure != null) throw failure!;
    events.add(jsonDecode(eventJson) as Map<String, dynamic>);
  }
}

/// [privacyMatches] of [event] as the wire carries it.
List<String> _privacyMatches(CrashEvent event) =>
    privacyMatches(jsonDecode(event.toCanonicalJson()) as Map<String, dynamic>);

void main() {
  late _RecordingTransport transport;

  NoticebirdClient client(
    NativeCrashCollector? collector, {
    CrashPrivacyProfile profile = CrashPrivacyProfile.privacyDefault,
    bool Function(Object error)? shouldCapture,
    Duration deduplicationWindow = const Duration(minutes: 1),
    int maxPendingEvents = 10,
    CrashTransport? via,
  }) => NoticebirdClient(
    config: NoticebirdConfig(
      privacyProfile: profile,
      app: _app,
      platform: _platform,
      sessionIdFactory: () => 'current_session_000001',
      nativeCrashes: collector,
      shouldCapture: shouldCapture,
      deduplicationWindow: deduplicationWindow,
      maxPendingEvents: maxPendingEvents,
    ),
    transport: via ?? transport,
    clock: () => DateTime.utc(2026, 9, 25, 12),
  );

  setUp(() {
    transport = _RecordingTransport();
  });

  group('event per kind', () {
    final cases = <NativeCrashRecord, (CrashSeverity, bool, String, String)>{
      _record(): (
        CrashSeverity.fatal,
        false,
        'EXC_BAD_ACCESS/SIGBUS',
        'EXC_BAD_ACCESS (SIGBUS) code 0x32',
      ),
      _record(
        source: NativeReportSource.exitInfo,
        machException: null,
        signal: 'SIGSEGV',
        code: '0x1',
      ): (
        CrashSeverity.fatal,
        false,
        'SIGSEGV',
        'SIGSEGV code 0x1',
      ),
      _record(
        kind: NativeCrashKind.watchdogKill,
        machException: null,
        signal: null,
        code: null,
        terminationCode: '0x8badf00d',
      ): (
        CrashSeverity.fatal,
        false,
        'WatchdogTermination',
        'Watchdog termination (0x8badf00d)',
      ),
      _record(
        kind: NativeCrashKind.anr,
        machException: null,
        signal: null,
        code: null,
      ): (
        CrashSeverity.fatal,
        false,
        'ApplicationNotResponding',
        'Application not responding',
      ),
      _record(
        kind: NativeCrashKind.memoryKill,
        machException: null,
        signal: null,
        code: null,
        images: const [],
        frames: const [],
      ): (
        CrashSeverity.fatal,
        false,
        'LowMemoryKill',
        'Killed for memory in the foreground',
      ),
      _record(
        kind: NativeCrashKind.hang,
        machException: null,
        signal: null,
        code: null,
        durationMs: 2500,
      ): (
        CrashSeverity.warning,
        true,
        'Hang',
        'Main thread hung for 2.5 s',
      ),
      _record(
        kind: NativeCrashKind.diskWriteException,
        machException: null,
        signal: null,
        code: null,
        bytesWritten: 4300000000,
      ): (
        CrashSeverity.warning,
        true,
        'DiskWriteException',
        'Wrote 4.3 GB to disk',
      ),
      _record(
        source: NativeReportSource.jvm,
        machException: null,
        signal: null,
        code: null,
        exceptionClass: 'java.lang.IllegalStateException',
        exceptionMessage: 'Fragment not attached; user person@example.com',
        images: const [],
        frames: const [NativeFrame.symbol('com.example.Foo.bar', line: 42)],
      ): (
        CrashSeverity.fatal,
        false,
        'java.lang.IllegalStateException',
        'Fragment not attached; user [REDACTED]',
      ),
    };

    for (final entry in cases.entries) {
      test('${entry.value.$3} → ${entry.value.$1.name}', () {
        final event = _build(
          entry.key,
          _ledger(),
          privacyProfile: CrashPrivacyProfile.privacyDefault,
        )!;
        expect(event.severity, entry.value.$1);
        expect(event.handled, entry.value.$2);
        expect(event.exception.type, entry.value.$3);
        expect(event.exception.sanitizedMessage, entry.value.$4);
        expect(event.exception.stackTrace, nativeStackTraceMarker);
        expect(event.nativeCrash!.kind, entry.key.kind);
        expect(event.toJson()['schemaVersion'], CrashEvent.schemaVersion);
      });
    }

    test('messages never carry a run of ten digits', () {
      final event = _build(
        _record(code: '0x1234567890'),
        _ledger(),
        privacyProfile: CrashPrivacyProfile.privacyDefault,
      )!;
      expect(event.exception.sanitizedMessage, 'EXC_BAD_ACCESS (SIGBUS)');
      expect(event.nativeCrash!.code, '0x1234567890');
    });
  });

  group('privacy profiles', () {
    test('regulatedStrict carries the type as message and no trail', () {
      final event = _build(
        _record(
          exceptionClass: 'java.lang.IllegalStateException',
          exceptionMessage: 'detail',
        ),
        _ledger(),
        privacyProfile: CrashPrivacyProfile.regulatedStrict,
      )!;
      expect(event.exception.sanitizedMessage, event.exception.type);
      expect(event.breadcrumbs, isEmpty);
      expect(event.user, isNull);
      expect(event.userId, isNull);
      expect(event.extra, isEmpty);
    });

    for (final profile in [
      CrashPrivacyProfile.privacyDefault,
      CrashPrivacyProfile.custom,
    ]) {
      test(
        '${profile.name} carries the crashed run\'s trail, never identity',
        () {
          final event = _build(_record(), _ledger(), privacyProfile: profile)!;
          expect(event.breadcrumbs.map((crumb) => crumb.action), [
            'route.push',
            'list.open',
          ]);
          expect(event.user, isNull);
          expect(event.extra, isEmpty);
        },
      );
    }
  });

  test('a trail recorded with ids reaches the event without them', () {
    const id = '7d3f1c2a-9b4e-4f6a-8c1d-2e3f4a5b6c7d';
    final event = _build(
      _record(),
      _ledger(
        uiTrail: [
          TypedBreadcrumb(
            occurredAt: _t0,
            category: BreadcrumbCategory.navigation,
            action: 'route.push',
            data: const {AllowedTag.component: '/lists/$id'},
          ),
        ],
      ),
      privacyProfile: CrashPrivacyProfile.privacyDefault,
    )!;

    expect(
      event.breadcrumbs.single.data[AllowedTag.component],
      '/lists/[REDACTED]',
    );
  });

  group('attribution', () {
    test('the delivering engine of the crashed run speaks for it', () {
      final event = _build(
        _record(),
        _ledger(),
        privacyProfile: CrashPrivacyProfile.privacyDefault,
      )!;
      expect(event.sessionId, 'ui_session_0000000001');
      expect(event.app, same(_crashedApp));
      expect(event.platform, same(_crashedPlatform));
      expect(event.routeTemplate, '/lists/:listId');
      expect(event.tags, {AllowedTag.foreground: true});
    });

    test('a headless-only run is attributed to its headless session', () {
      final ledger = _ledger();
      final crashed = ledger.first;
      final headlessOnly = [
        NativeRecordedRun(
          runId: crashed.runId,
          startedAt: crashed.startedAt,
          appVersion: crashed.appVersion,
          appBuild: crashed.appBuild,
          engines: [crashed.engines.first],
        ),
        ledger.last,
      ];
      final event = _build(
        _record(),
        headlessOnly,
        privacyProfile: CrashPrivacyProfile.privacyDefault,
      )!;
      expect(event.sessionId, 'headless_session_000001');
      expect(event.tags, {AllowedTag.foreground: false});
      expect(event.breadcrumbs.single.action, 'work.start');
    });

    test('the OS-reported foreground state wins over the ledger', () {
      final event = _build(
        _record(foreground: false),
        _ledger(),
        privacyProfile: CrashPrivacyProfile.privacyDefault,
      )!;
      expect(event.tags, {AllowedTag.foreground: false});
    });

    test('an exact run id wins over the time window', () {
      final event = _build(
        _record(
          runId: 'run-crashed',
          occurredAt: _t0.add(const Duration(hours: 5)),
        ),
        _ledger(),
        privacyProfile: CrashPrivacyProfile.privacyDefault,
      )!;
      expect(event.sessionId, 'ui_session_0000000001');
      // Clamped into the crashed run's window: before the next run started.
      expect(event.occurredAt, _t0.add(const Duration(hours: 2)));
    });

    test('a process id finds its run', () {
      final event = _build(
        _record(pid: 411, appVersion: null, appBuild: null),
        _ledger(),
        privacyProfile: CrashPrivacyProfile.privacyDefault,
      )!;
      expect(event.sessionId, 'ui_session_0000000001');
    });

    test('the time window finds the run without id or pid', () {
      final event = _build(
        _record(appVersion: null, appBuild: null),
        _ledger(),
        privacyProfile: CrashPrivacyProfile.privacyDefault,
      )!;
      expect(event.sessionId, 'ui_session_0000000001');
      expect(event.occurredAt, _t0.add(const Duration(minutes: 30)));
    });

    test('a crash before Dart started borrows metadata of the same build', () {
      final ledger = [
        ..._ledger(crashedRunHasEngines: false),
        NativeRecordedRun(
          runId: 'run-older',
          startedAt: _t0.subtract(const Duration(days: 1)),
          appVersion: '1.3.0',
          appBuild: '130',
          engines: [
            NativeEngineRecord(
              sessionId: 'older_session_0000001',
              app: _crashedApp,
              platform: _crashedPlatform,
              delivers: true,
              routeTemplate: '/older',
              breadcrumbs: [_crumb('older.trail')],
            ),
          ],
        ),
      ];
      final event = _build(
        _record(),
        ledger,
        privacyProfile: CrashPrivacyProfile.privacyDefault,
      )!;
      expect(event.app, same(_crashedApp));
      expect(event.sessionId, startsWith('native_'));
      expect(event.sessionId, isNot('older_session_0000001'));
      expect(event.routeTemplate, isNull);
      expect(event.breadcrumbs, isEmpty);
    });

    test('a report that matches no known build is dropped', () {
      expect(
        _build(
          _record(
            appVersion: '0.9.0',
            appBuild: '90',
            occurredAt: _t0.subtract(const Duration(days: 3)),
          ),
          _ledger(),
          privacyProfile: CrashPrivacyProfile.privacyDefault,
        ),
        isNull,
      );
      expect(
        _build(
          _record(),
          _ledger(crashedRunHasEngines: false),
          privacyProfile: CrashPrivacyProfile.privacyDefault,
        ),
        isNull,
        reason: 'no engine of build 130 anywhere to lend metadata',
      );
    });

    test('a report of a run the collector excludes is dropped', () {
      final ledger = _ledger();
      final crashed = ledger.first;
      final excluded = [
        NativeRecordedRun(
          runId: crashed.runId,
          startedAt: crashed.startedAt,
          appVersion: crashed.appVersion,
          appBuild: crashed.appBuild,
          reportable: false,
          engines: crashed.engines,
        ),
        NativeRecordedRun(
          runId: 'run-release',
          startedAt: _t0.subtract(const Duration(days: 1)),
          appVersion: crashed.appVersion,
          appBuild: crashed.appBuild,
          engines: crashed.engines,
        ),
        ledger.last,
      ];
      expect(
        _build(
          _record(),
          excluded,
          privacyProfile: CrashPrivacyProfile.privacyDefault,
        ),
        isNull,
        reason: 'the debug run is matched and dropped, not re-attributed',
      );
    });

    test('an abort message follows the composed message', () {
      final event = _build(
        _record(
          source: NativeReportSource.exitInfo,
          machException: null,
          signal: 'SIGABRT',
          code: null,
          exceptionMessage: 'Check failed: token=abc123 ok',
        ),
        _ledger(),
        privacyProfile: CrashPrivacyProfile.privacyDefault,
      )!;
      expect(
        event.exception.sanitizedMessage,
        'SIGABRT: Check failed: [REDACTED] ok',
      );
      expect(
        _build(
          _record(signal: 'SIGABRT', exceptionMessage: 'Check failed'),
          _ledger(),
          privacyProfile: CrashPrivacyProfile.regulatedStrict,
        )!.exception.sanitizedMessage,
        'EXC_BAD_ACCESS/SIGABRT',
      );
    });

    test('a report in the current run\'s window is not guessed onto it', () {
      final event = _build(
        _record(
          appVersion: null,
          appBuild: null,
          occurredAt: _t0.add(const Duration(hours: 3)),
        ),
        _ledger(),
        privacyProfile: CrashPrivacyProfile.privacyDefault,
      );
      expect(event, isNull);
    });
  });

  group('what the platform firewall would reject', () {
    test('compiler hash suffixes and long digit runs leave symbols', () {
      final event = _build(
        _record(
          images: const [
            NativeImage(name: 'libart.so', inApp: false),
            NativeImage(name: 'libvendor1234567890.so', inApp: false),
          ],
          frames: const [
            NativeFrame.inImage(
              0,
              3950128,
              symbol:
                  'art::interpreter::Execute_art::Thread___bool___.__uniq.112435418011751916792819755956732575238.llvm.15926011731833139376_',
            ),
            NativeFrame.inImage(1, 16, symbol: 'call_31612345678'),
            NativeFrame.symbol('auth::token::Parse'),
          ],
        ),
        _ledger(),
        privacyProfile: CrashPrivacyProfile.privacyDefault,
      )!;
      final native = event.nativeCrash!;
      expect(
        native.frames[0].symbol,
        'art::interpreter::Execute_art::Thread___bool____',
      );
      expect(native.frames[1].symbol, 'call_316123456');
      expect(native.frames[2].symbol, 'auth..token..Parse');
      expect(native.images[1].name, 'libvendor123456789.so');
      expect(_privacyMatches(event), isEmpty);
    });

    group('a symbol that reads as personal data keeps its words', () {
      final cases = <String, (List<String>, List<String>)>{
        'an IPv4 address in a version': (
          ['Codec.1.2.3.4.decode'],
          ['Codec.1_2_3_4.decode'],
        ),
        'a JWT-shaped name': (
          ['eyJhbGciOi.eyJzdWIiOi.c2ln'],
          ['eyJhbGciOi_eyJzdWIiOi_c2ln'],
        ),
        'bearer at the end, before the next value': (
          ['AuthHeader.bearer'],
          ['AuthHeader.bearer_'],
        ),
        'a credential word before a symbol from the root namespace': (
          ['Session.refreshToken', '::alloc'],
          ['Session.refreshToken_', '::alloc'],
        ),
        'bearer at the end of the longest symbol': (
          ['${'x' * 194}bearer'],
          ['${'x' * 194}beare_'],
        ),
      };

      for (final MapEntry(key: name, value: (symbols, safe)) in cases.entries) {
        test(name, () {
          final event = _build(
            _record(
              images: const [],
              frames: [for (final s in symbols) NativeFrame.symbol(s)],
            ),
            _ledger(),
            privacyProfile: CrashPrivacyProfile.privacyDefault,
          )!;
          expect(event.nativeCrash!.frames.map((frame) => frame.symbol), safe);
          expect(_privacyMatches(event), isEmpty);
        });
      }
    });

    test('image names lose IPv4 addresses, UUIDs and phone numbers', () {
      final event = _build(
        _record(
          images: const [
            NativeImage(name: 'libhost-10.0.0.12.so', inApp: false),
            NativeImage(
              name: 'Plugin-7d3f1c2a-9b4e-4f6a-8c1d-2e3f4a5b6c7d',
              inApp: true,
            ),
            NativeImage(name: 'libcall-555-123-4567.so', inApp: false),
          ],
          frames: const [
            NativeFrame.inImage(0, 16),
            NativeFrame.inImage(1, 32),
            NativeFrame.inImage(2, 48),
          ],
        ),
        _ledger(),
        privacyProfile: CrashPrivacyProfile.privacyDefault,
      )!;
      expect(event.nativeCrash!.images.map((image) => image.name), [
        'libhost-redacted.so',
        'Plugin-redacted',
        'libcall-redacted.so',
      ]);
      expect(_privacyMatches(event), isEmpty);
    });

    test('a route an earlier version recorded with an address is redacted', () {
      final event = _build(
        _record(),
        _ledger(uiRoute: '/invite/person@example.com'),
        privacyProfile: CrashPrivacyProfile.privacyDefault,
      )!;
      expect(event.routeTemplate, '/invite/[REDACTED]');
      expect(_privacyMatches(event), isEmpty);
    });

    test('messages lose phone-like digit runs and IPv4 addresses', () {
      final event = _build(
        _record(
          exceptionClass: 'java.lang.IllegalArgumentException',
          exceptionMessage: 'Index 1234567890 out of range for 10.0.0.12',
        ),
        _ledger(),
        privacyProfile: CrashPrivacyProfile.privacyDefault,
      )!;
      expect(
        event.exception.sanitizedMessage,
        'Index [REDACTED] out of range for [REDACTED]',
      );
      expect(_privacyMatches(event), isEmpty);
    });
  });

  group('event id', () {
    test('is deterministic, UUID-shaped version 8, and per report', () {
      final first = nativeCrashEventId('a' * 64);
      expect(nativeCrashEventId('a' * 64), first);
      expect(nativeCrashEventId('b' * 64), isNot(first));
      expect(
        first,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
    });
  });

  group('delivery', () {
    test(
      'an engine that never asks delivers nothing but records its run',
      () async {
        final collector = _FakeCollector(
          batches: [
            NativeCrashBatch(records: [_record()], runs: _ledger()),
          ],
        );
        client(collector).addBreadcrumb(_crumb('home.open'));
        await Future<void>.delayed(Duration.zero);

        expect(collector.starts.single.sessionId, 'current_session_000001');
        expect(collector.starts.single.app, same(_app));
        expect(collector.claims, 0);
        expect(transport.events, isEmpty);
      },
    );

    test(
      'reports are delivered, settled per outcome, and the live trail kept',
      () async {
        final collector = _FakeCollector(
          batches: [
            NativeCrashBatch(
              records: [
                _record(),
                _record(
                  recordId: 'b' * 64,
                  appVersion: '0.1.0',
                  appBuild: '1',
                  occurredAt: _t0.subtract(const Duration(days: 9)),
                ),
                _record(
                  recordId: 'c' * 64,
                  kind: NativeCrashKind.hang,
                  machException: null,
                  signal: null,
                  code: null,
                  durationMs: 900,
                ),
              ],
              runs: _ledger(),
            ),
          ],
        );
        final reporter = client(
          collector,
          shouldCapture: (error) =>
              error is! NativeCrashRecord || error.kind != NativeCrashKind.hang,
        )..addBreadcrumb(_crumb('home.open'));

        final results = await reporter.reportNativeCrashes();

        expect(results.map((result) => result.outcome), [
          CaptureOutcome.sent,
          CaptureOutcome.dropped,
          CaptureOutcome.ignored,
        ]);
        expect(collector.settled, [
          (_record().recordId, true),
          ('b' * 64, true),
          ('c' * 64, true),
        ]);
        expect(
          transport.events.single['eventId'],
          nativeCrashEventId(_record().recordId),
        );
        expect(reporter.recentBreadcrumbs.single.action, 'home.open');
        expect(collector.lastMax, NoticebirdClient.maxNativeCrashesPerBatch);
      },
    );

    test('a failed send queues the event and keeps the claim', () async {
      transport.failure = StateError('offline');
      final collector = _FakeCollector(
        batches: [
          NativeCrashBatch(records: [_record()], runs: _ledger()),
        ],
      );
      final reporter = client(collector);

      expect(
        (await reporter.reportNativeCrashes()).map((result) => result.outcome),
        [CaptureOutcome.queued],
      );
      expect(collector.settled.single.$2, isFalse);
      expect(reporter.pendingCount, 1);

      transport.failure = null;
      await reporter.flush();
      expect(
        transport.events.single['eventId'],
        nativeCrashEventId(_record().recordId),
      );
    });

    test('a resend of the same report is the same event', () async {
      for (var launch = 0; launch < 2; launch++) {
        final collector = _FakeCollector(
          batches: [
            NativeCrashBatch(records: [_record()], runs: _ledger()),
          ],
        );
        await client(collector).reportNativeCrashes();
      }
      expect(transport.events, hasLength(2));
      expect(
        transport.events.first['eventId'],
        transport.events.last['eventId'],
      );
      expect(transport.canonical.first, transport.canonical.last);
    });

    test('native reports bypass the deduplication window', () async {
      final collector = _FakeCollector(
        batches: [
          NativeCrashBatch(
            records: [
              for (final id in ['1', '2', '3']) _record(recordId: id * 64),
            ],
            runs: _ledger(),
          ),
        ],
      );
      final results = await client(
        collector,
        deduplicationWindow: const Duration(hours: 1),
      ).reportNativeCrashes();
      expect(
        results.map((result) => result.outcome),
        List.filled(3, CaptureOutcome.sent),
      );
    });

    test('at most ten reports are delivered per batch', () async {
      final collector = _FakeCollector(
        batches: [
          NativeCrashBatch(
            records: [
              for (var index = 0; index < 12; index++)
                _record(recordId: index.toRadixString(16).padLeft(64, '0')),
            ],
            runs: _ledger(),
          ),
        ],
      );
      final results = await client(collector).reportNativeCrashes();
      expect(results, hasLength(10));
      expect(collector.settled, hasLength(10));
    });

    test('a report arriving later in the run is delivered too', () async {
      final collector = _FakeCollector(
        batches: [const NativeCrashBatch(records: [], runs: [])],
      );
      final reporter = client(collector);
      expect(await reporter.reportNativeCrashes(), isEmpty);

      collector.arrivals.add(
        NativeCrashBatch(records: [_record()], runs: _ledger()),
      );
      await _drain();

      expect(transport.events.single['native'], isNotNull);
      expect(collector.settled.single, (_record().recordId, true));
    });

    test('a second call delivers nothing more', () async {
      final collector = _FakeCollector(
        batches: [
          NativeCrashBatch(records: [_record()], runs: _ledger()),
        ],
      );
      final reporter = client(collector);
      await reporter.reportNativeCrashes();
      expect(await reporter.reportNativeCrashes(), isEmpty);
      expect(collector.claims, 1);
    });

    test('without a collector nothing happens', () async {
      expect(await client(null).reportNativeCrashes(), isEmpty);
    });

    test('a record the platform refuses for good is dropped, settled as '
        'delivered and not queued', () async {
      final bodies = <String>[];
      final api = CrashHttpTransport(
        publishableKey: 'crash_pk_test_123456',
        httpClient: MockClient((request) async {
          bodies.add(request.body);
          return http.Response('{"error":"privacy_rejected"}', 422);
        }),
      );
      final collector = _FakeCollector(
        batches: [
          NativeCrashBatch(records: [_record()], runs: _ledger()),
        ],
      );
      final reporter = client(collector, via: api);

      expect(
        (await reporter.reportNativeCrashes()).map((result) => result.outcome),
        [CaptureOutcome.dropped],
      );
      expect(bodies, hasLength(1));
      expect(collector.settled.single, (_record().recordId, true));
      expect(reporter.pendingCount, 0);
    });

    test('a malformed record is dropped and settled, never thrown', () async {
      final collector = _FakeCollector(
        batches: [
          NativeCrashBatch(
            records: [
              _record(frames: const [NativeFrame.inImage(5, 12)]),
            ],
            runs: _ledger(),
          ),
        ],
      );
      expect(
        (await client(
          collector,
        ).reportNativeCrashes()).map((result) => result.outcome),
        [CaptureOutcome.dropped],
      );
      expect(collector.settled.single.$2, isTrue);
      expect(transport.events, isEmpty);
    });

    test('the facade delegates', () async {
      final collector = _FakeCollector(
        batches: [
          NativeCrashBatch(records: [_record()], runs: _ledger()),
        ],
      );
      Noticebird.attach(client(collector));
      addTearDown(Noticebird.detach);
      expect(
        (await Noticebird.reportNativeCrashes())!.map(
          (result) => result.outcome,
        ),
        [CaptureOutcome.sent],
      );
    });
  });

  group('run state', () {
    test(
      'breadcrumbs, route changes and a clear reach the collector',
      () async {
        final collector = _FakeCollector();
        final reporter = client(collector);
        await Future<void>.delayed(Duration.zero);
        reporter
          ..addBreadcrumb(_crumb('home.open'))
          ..setRouteTemplate('/lists/:listId')
          ..clearBreadcrumbs();

        final latest = collector.updates.last;
        expect(latest.routeTemplate, '/lists/:listId');
        expect(latest.breadcrumbs, isEmpty);
        expect(
          collector.updates.any((state) => state.breadcrumbs.isNotEmpty),
          isTrue,
        );
      },
    );

    test('the collector keeps the trail without ids', () async {
      const id = '7d3f1c2a-9b4e-4f6a-8c1d-2e3f4a5b6c7d';
      final collector = _FakeCollector();
      final reporter = client(collector);
      await Future<void>.delayed(Duration.zero);
      reporter.addBreadcrumb(
        TypedBreadcrumb(
          occurredAt: _t0,
          category: BreadcrumbCategory.navigation,
          action: 'route.push',
          data: const {AllowedTag.component: '/lists/$id'},
        ),
      );

      expect(
        collector.updates.last.breadcrumbs.single.data[AllowedTag.component],
        '/lists/[REDACTED]',
      );
      expect(
        reporter.recentBreadcrumbs.single.data[AllowedTag.component],
        '/lists/$id',
      );
    });

    test('regulatedStrict hands over no trail', () async {
      final collector = _FakeCollector();
      client(collector, profile: CrashPrivacyProfile.regulatedStrict)
        ..addBreadcrumb(_crumb('home.open'))
        ..setRouteTemplate('/home');
      await Future<void>.delayed(Duration.zero);

      expect(
        collector.starts.single.privacyProfile,
        CrashPrivacyProfile.regulatedStrict,
      );
      expect(
        collector.updates.every((state) => state.breadcrumbs.isEmpty),
        isTrue,
      );
      expect(collector.updates.last.routeTemplate, '/home');
    });

    test('a sent Dart event clears the trail the collector holds', () async {
      final collector = _FakeCollector();
      final reporter = client(collector)..addBreadcrumb(_crumb('home.open'));
      await reporter.captureException(StateError('x'), StackTrace.empty);
      expect(collector.updates.last.breadcrumbs, isEmpty);
    });
  });

  group('fault injection', () {
    test('a collector that throws everywhere never escapes', () async {
      final collector = _FakeCollector()
        ..onStart = (() async => throw StateError('start'))
        ..throwOnClaim = StateError('claim')
        ..throwOnUpdate = StateError('update');
      final reporter = client(collector)..addBreadcrumb(_crumb('home.open'));
      expect(await reporter.reportNativeCrashes(), isEmpty);
      reporter.setRouteTemplate('/home');
      expect(reporter.recentBreadcrumbs, hasLength(1));
    });

    test('a failing settle costs nothing but the claim', () async {
      final collector = _FakeCollector(
        batches: [
          NativeCrashBatch(records: [_record()], runs: _ledger()),
        ],
      )..throwOnSettle = StateError('settle');
      expect(
        (await client(
          collector,
        ).reportNativeCrashes()).map((result) => result.outcome),
        [CaptureOutcome.sent],
      );
    });

    test('a collector that never answers does not block run()', () {
      fakeAsync((async) {
        final never = Completer<void>();
        final collector = _FakeCollector()..onStart = () => never.future;
        final reporter = client(collector);
        var bodyRan = false;

        unawaited(reporter.run(() => bodyRan = true));
        async.flushMicrotasks();

        expect(bodyRan, isTrue);
        reporter.uninstallGlobalHandlers();
      });
    });

    test('a collector that never answers does not block the caller', () {
      fakeAsync((async) {
        final never = Completer<void>();
        final collector = _FakeCollector()..onStart = () => never.future;
        List<CaptureResult>? results;

        client(
          collector,
        ).reportNativeCrashes().then((value) => results = value);
        async.elapse(const Duration(seconds: 30));

        expect(results, isEmpty);
      });
    });

    test('a claim stream that never emits gives up on the first batch', () {
      fakeAsync((async) {
        final collector = _NeverClaims();
        List<CaptureResult>? results;
        client(
          collector,
        ).reportNativeCrashes().then((value) => results = value);
        async.elapse(const Duration(seconds: 30));
        expect(results, isEmpty);
      });
    });
  });
}

Future<void> _drain() async {
  for (var turn = 0; turn < 20; turn++) {
    await Future<void>.delayed(Duration.zero);
  }
}

final class _NeverClaims implements NativeCrashCollector {
  @override
  Future<void> start(NativeRunInfo run) async {}

  @override
  void update(NativeRunState state) {}

  @override
  Stream<NativeCrashBatch> claimed({int max = 10}) =>
      StreamController<NativeCrashBatch>().stream;

  @override
  Future<void> settle(String recordId, {required bool delivered}) async {}
}
