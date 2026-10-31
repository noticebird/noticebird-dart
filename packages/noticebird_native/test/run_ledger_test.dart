import 'dart:convert';
import 'dart:io';

import 'package:noticebird/noticebird.dart';
import 'package:noticebird_native/src/run_ledger.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

const _app = AppMetadata(
  name: 'test-app',
  version: '1.4.0',
  build: '140',
  release: 'test-app@1.4.0+140',
);
const _platform = PlatformMetadata(
  platform: CrashPlatform.ios,
  osVersion: '26.5.2',
  deviceClass: 'mobile',
);

NativeRunInfo _run({
  CrashPrivacyProfile profile = CrashPrivacyProfile.privacyDefault,
}) => NativeRunInfo(
  sessionId: 'run_0000000000000001',
  app: _app,
  platform: _platform,
  privacyProfile: profile,
);

TypedBreadcrumb _crumb(int index) => TypedBreadcrumb(
  occurredAt: DateTime.utc(2026, 9, 25, 8, 0, index),
  category: BreadcrumbCategory.ui,
  action: 'tap.button_$index',
  data: {
    AllowedTag.feature: 'f' * 100,
    AllowedTag.operation: 'o' * 100,
    AllowedTag.component: 'c' * 100,
  },
);

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('crash-native-ledger-');
  });

  tearDown(() => root.deleteSync(recursive: true));

  void writeRun(
    String runId, {
    required int startedAtMs,
    bool debugBuild = false,
    String appVersion = '1.4.0',
    String appBuild = '140',
  }) {
    final file = File('${root.path}/runs/$runId/run.json')
      ..parent.createSync(recursive: true);
    file.writeAsStringSync(
      jsonEncode({
        'version': 1,
        'runId': runId,
        'pid': 4312,
        'startedAtMs': startedAtMs,
        'appVersion': appVersion,
        'appBuild': appBuild,
        'debugBuild': debugBuild,
      }),
    );
  }

  Map<String, Object?> engineJson(String runId, String engineId) =>
      jsonDecode(
            File(
              '${root.path}/runs/$runId/engine-$engineId.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;

  RunLedger ledger({
    String runId = 'run-current',
    CrashPrivacyProfile profile = CrashPrivacyProfile.privacyDefault,
  }) => RunLedger(
    directory: root,
    runId: runId,
    engineId: 'e1',
    run: _run(profile: profile),
    clock: () => DateTime.utc(2026, 9, 25, 9),
  );

  test('start writes the engine record at once, atomically', () {
    ledger().recordStart(foreground: true);

    final json = engineJson('run-current', 'e1');
    expect(json['version'], 1);
    expect(json['sessionId'], 'run_0000000000000001');
    expect(json['app'], _app.toJson());
    expect(json['platform'], _platform.toJson());
    expect(json['foreground'], isTrue);
    expect(json['delivers'], isFalse);
    expect(
      json['updatedAtMs'],
      DateTime.utc(2026, 9, 25, 9).millisecondsSinceEpoch,
    );
    final leftovers = Directory(
      '${root.path}/runs/run-current',
    ).listSync().where((entry) => entry.path.endsWith('.tmp'));
    expect(leftovers, isEmpty);
  });

  test('updates are debounced for 500 ms, trailing', () {
    fakeAsync((async) {
      final entry = ledger()..recordStart();
      entry.update(
        NativeRunState(routeTemplate: '/a', breadcrumbs: [_crumb(1)]),
      );
      async.elapse(const Duration(milliseconds: 300));
      entry.update(
        NativeRunState(
          routeTemplate: '/b',
          breadcrumbs: [_crumb(1), _crumb(2)],
        ),
      );
      async.elapse(const Duration(milliseconds: 499));
      expect(engineJson('run-current', 'e1')['routeTemplate'], isNull);

      async.elapse(const Duration(milliseconds: 1));
      final json = engineJson('run-current', 'e1');
      expect(json['routeTemplate'], '/b');
      expect(json['breadcrumbs'], hasLength(2));
    });
  });

  test('a lifecycle change and delivery are written at once', () {
    fakeAsync((async) {
      final entry = ledger()..recordStart(foreground: true);
      entry.update(const NativeRunState(routeTemplate: '/pending'));
      entry.setForeground(false);
      var json = engineJson('run-current', 'e1');
      expect(json['foreground'], isFalse);
      expect(json['routeTemplate'], '/pending');

      entry.markDelivering();
      json = engineJson('run-current', 'e1');
      expect(json['delivers'], isTrue);
    });
  });

  test('the engine file stays under 16 KB by dropping the oldest crumbs', () {
    final entry = ledger()..recordStart();
    entry
      ..update(
        NativeRunState(breadcrumbs: [for (var i = 0; i < 50; i++) _crumb(i)]),
      )
      ..flush();
    final file = File('${root.path}/runs/run-current/engine-e1.json');
    final json = engineJson('run-current', 'e1');
    final crumbs = json['breadcrumbs']! as List;

    expect(file.lengthSync(), lessThanOrEqualTo(RunLedger.maxEngineFileBytes));
    expect(crumbs.length, lessThan(50));
    expect((crumbs.last as Map)['action'], 'tap.button_49');
  });

  test('regulatedStrict never persists a trail', () {
    final entry = ledger(profile: CrashPrivacyProfile.regulatedStrict)
      ..recordStart();
    entry
      ..update(NativeRunState(routeTemplate: '/home', breadcrumbs: [_crumb(1)]))
      ..flush();

    final json = engineJson('run-current', 'e1');
    expect(json['breadcrumbs'], isEmpty);
    expect(json['routeTemplate'], '/home');
  });

  test('the reader returns every run, ordered, with engines and flags', () {
    writeRun('run-old', startedAtMs: 1000, debugBuild: true, appBuild: '139');
    writeRun('run-current', startedAtMs: 2000);
    ledger(runId: 'run-old').recordStart(foreground: false);
    ledger()
      ..recordStart()
      ..markDelivering();

    final runs = ledger().readRuns(includeDebugBuilds: false);
    expect(runs.map((run) => run.runId), ['run-old', 'run-current']);
    expect(runs.first.reportable, isFalse);
    expect(runs.first.isCurrent, isFalse);
    expect(runs.first.appBuild, '139');
    expect(runs.first.engines.single.foreground, isFalse);
    expect(runs.last.isCurrent, isTrue);
    expect(runs.last.reportable, isTrue);
    expect(runs.last.engines.single.delivers, isTrue);
    expect(
      runs.last.startedAt,
      DateTime.fromMillisecondsSinceEpoch(2000, isUtc: true),
    );

    expect(
      ledger().readRuns(includeDebugBuilds: true).first.reportable,
      isTrue,
    );
  });

  test('unreadable ledger files are skipped, not fatal', () {
    writeRun('run-good', startedAtMs: 1000);
    Directory('${root.path}/runs/run-no-json').createSync(recursive: true);
    File('${root.path}/runs/run-garbage/run.json')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('{not json');
    File('${root.path}/runs/run-good/engine-bad.json').writeAsStringSync('[]');
    File('${root.path}/runs/run-good/engine-worse.json').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'sessionId': 's',
        'app': {'name': 1},
      }),
    );
    ledger(runId: 'run-good').recordStart();
    // A crumb that no longer reads or that the protocol refuses, such as an
    // action outside its pattern, costs only itself.
    final file = File('${root.path}/runs/run-good/engine-e1.json');
    final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    json['breadcrumbs'] = [
      _crumb(1).toJson(),
      {'occurredAt': 'yesterday'},
      {..._crumb(2).toJson(), 'action': 'Route.Push'},
    ];
    file.writeAsStringSync(jsonEncode(json));

    final runs = readRunLedger(
      root,
      currentRunId: 'x',
      includeDebugBuilds: false,
    );
    expect(runs.single.runId, 'run-good');
    expect(
      runs.single.engines.single.breadcrumbs.single.action,
      'tap.button_1',
    );
  });

  test('no ledger directory yet reads as no runs', () {
    expect(
      readRunLedger(root, currentRunId: 'x', includeDebugBuilds: false),
      isEmpty,
    );
  });
}
