import 'dart:convert';
import 'dart:io';

import 'package:noticebird/noticebird.dart';
import 'package:noticebird_native/noticebird_native.dart';
import 'package:noticebird_native/src/native_crash_capture.dart'
    show
        nativeCrashCaptureWithPlatform,
        nativeEventChannelName,
        nativeMethodChannelName;
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _methods = MethodChannel('test/noticebird_native');
const _arrivals = EventChannel('test/noticebird_native/arrivals');

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

Map<String, Object?> _nativeRecord(
  String id, {
  int occurredAtMs = 1790325677000,
}) => {
  'recordVersion': 1,
  'recordId': id * 64,
  'kind': 'crash',
  'source': 'metricKit',
  'occurredAtMs': occurredAtMs,
  'machException': 'EXC_BAD_ACCESS',
  'signal': 'SIGBUS',
  'code': '0x32',
  'images': [
    {
      'name': 'Flutter',
      'debugId': '4c4c44e555553144a13dcc7994841aac',
      'arch': 'arm64',
      'inApp': true,
    },
  ],
  'frames': [
    <String, Object?>{},
    {'image': 0, 'offset': 10481952},
  ],
  'appVersion': '1.3.0',
  'appBuild': '130',
};

/// The native side, as far as the channel shows it.
final class _FakeNative {
  _FakeNative(this.directory);

  final Directory directory;
  final calls = <MethodCall>[];
  final inbox = <Map<String, Object?>>[];
  final settled = <(String, bool)>[];
  Object? claimReply;
  bool failStart = false;
  bool throwOnClaim = false;
  MockStreamHandlerEventSink? arrivalSink;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final arguments = (call.arguments as Map?)?.cast<String, Object?>();
    switch (call.method) {
      case 'start':
        if (failStart) throw PlatformException(code: 'boom');
        // Native code records the run at registration, before any start.
        writeRun('a' * 32, 1790330400000);
        return {'runId': 'a' * 32, 'directory': directory.path};
      case 'claim':
        if (throwOnClaim) throw PlatformException(code: 'boom');
        if (claimReply != null) return claimReply;
        final max = arguments!['max']! as int;
        final claimed = inbox.take(max).toList();
        inbox.removeRange(0, claimed.length);
        return claimed;
      case 'settle':
        settled.add((
          arguments!['recordId']! as String,
          arguments['delivered']! as bool,
        ));
        return null;
    }
    return null;
  }

  void writeRun(
    String runId,
    int startedAtMs, {
    List<Map<String, Object?>> engines = const [],
  }) {
    final dir = Directory('${directory.path}/runs/$runId')
      ..createSync(recursive: true);
    File('${dir.path}/run.json').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'runId': runId,
        'pid': 411,
        'startedAtMs': startedAtMs,
        'appVersion': '1.3.0',
        'appBuild': '130',
        'debugBuild': false,
      }),
    );
    for (final (index, engine) in engines.indexed) {
      File(
        '${dir.path}/engine-$index.json',
      ).writeAsStringSync(jsonEncode(engine));
    }
  }
}

final class _RecordingTransport implements CrashTransport {
  final events = <Map<String, dynamic>>[];

  @override
  Future<void> send(String eventJson) async {
    events.add(jsonDecode(eventJson) as Map<String, dynamic>);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late _FakeNative native;

  NativeRunInfo run({
    CrashPrivacyProfile profile = CrashPrivacyProfile.privacyDefault,
  }) => NativeRunInfo(
    sessionId: 'run_0000000000000001',
    app: _app,
    platform: _platform,
    privacyProfile: profile,
  );

  NativeCrashCapture capture({
    bool supported = true,
    bool debugBuild = false,
    bool includeDebugBuilds = false,
    bool hangs = false,
    bool diskWrites = false,
    bool Function()? bindingReady,
    DateTime Function()? clock,
  }) => nativeCrashCaptureWithPlatform(
    methods: _methods,
    arrivals: _arrivals,
    supported: supported,
    debugBuild: debugBuild,
    includeDebugBuilds: includeDebugBuilds,
    hangs: hangs,
    diskWrites: diskWrites,
    clock: clock ?? () => DateTime.utc(2026, 9, 25, 12),
    bindingReady: bindingReady,
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('crash-native-capture-');
    native = _FakeNative(root);
    messenger.setMockMethodCallHandler(_methods, native.handle);
    messenger.setMockStreamHandler(
      _arrivals,
      MockStreamHandler.inline(
        onListen: (arguments, sink) => native.arrivalSink = sink,
        onCancel: (arguments) => native.arrivalSink = null,
      ),
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_methods, null);
    messenger.setMockStreamHandler(_arrivals, null);
    root.deleteSync(recursive: true);
  });

  test('the capture an app makes speaks on the native contract\'s '
      'channels', () async {
    // The names the Swift and Kotlin sides answer on.
    expect(nativeMethodChannelName, 'noticebird_native');
    expect(nativeEventChannelName, 'noticebird_native/arrivals');
    const contract = MethodChannel('noticebird_native');
    final calls = <String>[];
    messenger.setMockMethodCallHandler(contract, (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(contract, null));
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final collector = NativeCrashCapture();
    debugDefaultTargetPlatformOverride = null;

    await collector.start(run());

    expect(calls, ['start']);
  });

  test(
    'start sends the options and records this engine in the ledger',
    () async {
      final collector = capture(hangs: true);
      await collector.start(run(profile: CrashPrivacyProfile.regulatedStrict));

      final start = native.calls.single;
      expect(start.method, 'start');
      expect(start.arguments, {
        'strict': true,
        'hangs': true,
        'diskWrites': false,
      });
      final engines = Directory('${root.path}/runs/${'a' * 32}')
          .listSync()
          .whereType<File>()
          .where((file) => file.path.contains('engine-'));
      expect(engines, hasLength(1));
      final json = jsonDecode(engines.single.readAsStringSync()) as Map;
      expect(json['sessionId'], 'run_0000000000000001');
    },
  );

  test(
    'start waits for the binding a client built before runApp lacks',
    () async {
      var polls = 0;
      final collector = capture(bindingReady: () => ++polls > 3);
      await collector.start(run());

      expect(polls, 4);
      expect(native.calls.single.method, 'start');
    },
  );

  test('start gives up when no binding ever appears', () {
    fakeAsync((async) {
      var now = DateTime.utc(2026, 9, 25, 12);
      final collector = capture(bindingReady: () => false, clock: () => now);
      var done = false;
      collector.start(run()).then((_) => done = true);
      for (var tick = 0; tick < 250 && !done; tick++) {
        now = now.add(const Duration(milliseconds: 50));
        async.elapse(const Duration(milliseconds: 50));
      }

      expect(done, isTrue);
      expect(native.calls, isEmpty);
    });
  });

  test('a second start of the same capture is a no-op', () async {
    final collector = capture();
    await collector.start(run());
    await collector.start(run());
    expect(native.calls.where((call) => call.method == 'start'), hasLength(1));
  });

  test('on the web and desktop nothing crosses the channel', () async {
    final collector = capture(supported: false);
    await collector.start(run());
    collector.update(const NativeRunState(routeTemplate: '/x'));
    final batches = await collector.claimed().toList();

    expect(native.calls, isEmpty);
    expect(batches.single.records, isEmpty);
  });

  test('a debug build still starts, but never delivers', () async {
    native.inbox.add(_nativeRecord('1'));
    final collector = capture(debugBuild: true);
    await collector.start(run());
    final batches = await collector.claimed().toList();

    expect(native.calls.map((call) => call.method), ['start']);
    expect(batches.single.records, isEmpty);
  });

  test('a debug build delivers when the host opts in', () async {
    native.inbox.add(_nativeRecord('1'));
    final collector = capture(debugBuild: true, includeDebugBuilds: true);
    await collector.start(run());
    final batch = await collector.claimed().first;
    expect(batch.records.single.recordId, '1' * 64);
  });

  test(
    'claims decode records, attach the ledger and mark the engine',
    () async {
      native.writeRun('b' * 32, 1790323200000);
      native.inbox.addAll([_nativeRecord('1'), _nativeRecord('2')]);
      final collector = capture();
      await collector.start(run());

      final batch = await collector.claimed(max: 1).first;

      expect(native.calls[1].arguments, {'max': 1});
      expect(batch.records.single.recordId, '1' * 64);
      expect(
        batch.runs.map((run) => run.runId),
        containsAll(['b' * 32, 'a' * 32]),
      );
      expect(
        batch.runs.singleWhere((run) => run.isCurrent).engines.single.delivers,
        isTrue,
      );
    },
  );

  test(
    'an undecodable record is settled away, a hopeless one skipped',
    () async {
      native.claimReply = [
        {..._nativeRecord('1'), 'threads': <Object?>[]},
        'garbage',
        _nativeRecord('3'),
      ];
      final collector = capture();
      await collector.start(run());

      final batch = await collector.claimed().first;

      expect(batch.records.single.recordId, '3' * 64);
      expect(native.settled, [('1' * 64, true)]);
    },
  );

  test('a malformed or failing claim reply is an empty batch', () async {
    final collector = capture();
    await collector.start(run());
    native.claimReply = {'not': 'a list'};
    expect((await collector.claimed().first).records, isEmpty);

    final second = capture();
    native
      ..claimReply = null
      ..throwOnClaim = true;
    await second.start(run());
    expect((await second.claimed().first).records, isEmpty);
  });

  test('a failing start leaves the capture inert', () async {
    native.failStart = true;
    final collector = capture();
    await collector.start(run());
    collector.update(const NativeRunState(routeTemplate: '/x'));
    final batches = await collector.claimed().toList();
    expect(batches.single.records, isEmpty);
    expect(root.listSync(), isEmpty);
  });

  test(
    'a report arriving later is claimed and delivered as a new batch',
    () async {
      final collector = capture();
      await collector.start(run());
      final batches = <NativeCrashBatch>[];
      final subscription = collector.claimed().listen(batches.add);
      await pumpEventQueue();
      expect(batches.single.records, isEmpty);

      native.inbox.add(_nativeRecord('4'));
      native.arrivalSink!.success(1);
      await pumpEventQueue();

      expect(batches, hasLength(2));
      expect(batches.last.records.single.recordId, '4' * 64);
      await subscription.cancel();
    },
  );

  test('settle passes the outcome through', () async {
    final collector = capture();
    await collector.start(run());
    await collector.settle('9' * 64, delivered: false);
    expect(native.settled, [('9' * 64, false)]);
  });

  test(
    'end to end: a native report becomes one event of the crashed run',
    () async {
      native.writeRun(
        'b' * 32,
        1790323200000,
        engines: [
          {
            'version': 1,
            'sessionId': 'run_crashedsession0001',
            'app': const AppMetadata(
              name: 'test-app',
              version: '1.3.0',
              build: '130',
              release: 'test-app@1.3.0+130',
            ).toJson(),
            'platform': _platform.toJson(),
            'delivers': true,
            'routeTemplate': '/lists/:listId',
            'foreground': true,
            'breadcrumbs': [
              TypedBreadcrumb(
                occurredAt: DateTime.utc(2026, 9, 25, 8, 40),
                category: BreadcrumbCategory.navigation,
                action: 'route.push',
              ).toJson(),
            ],
            'updatedAtMs': 1790325600000,
          },
        ],
      );
      native.inbox.add(_nativeRecord('5'));
      final transport = _RecordingTransport();
      final client = NoticebirdClient(
        config: NoticebirdConfig(
          privacyProfile: CrashPrivacyProfile.privacyDefault,
          app: _app,
          platform: _platform,
          sessionIdFactory: () => 'run_currentsession0001',
          nativeCrashes: capture(),
        ),
        transport: transport,
      );

      final results = await client.reportNativeCrashes();

      expect(results.map((result) => result.outcome), [CaptureOutcome.sent]);
      final event = transport.events.single;
      expect(event['sessionId'], 'run_crashedsession0001');
      expect(event['app']['release'], 'test-app@1.3.0+130');
      expect(event['exception']['type'], 'EXC_BAD_ACCESS/SIGBUS');
      expect(event['routeTemplate'], '/lists/:listId');
      expect(event['breadcrumbs'].single['action'], 'route.push');
      expect(event['native']['frames'], hasLength(2));
      expect(native.settled, [('5' * 64, true)]);
    },
  );
}
