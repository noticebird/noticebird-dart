// The crash queue as the client keeps it: a discarding transport makes no
// event, the event id of an error once its capture settles, the offline
// store written one call at a time and on disk, a flush asked during a
// flush, and the feedback drained by the client itself when it is due.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:noticebird/feedback.dart';
import 'package:noticebird/noticebird.dart';

import 'support/fake_feedback_transport.dart';

const _app = AppMetadata(
  name: 'test-app',
  version: '1.0.0',
  build: '1',
  release: 'test-app@1.0.0+1',
);
const _platform = PlatformMetadata(
  platform: CrashPlatform.macos,
  osVersion: '15.5',
  deviceClass: 'desktop',
);
final _stack = StackTrace.fromString('#0 A.b (package:app/a.dart:1:1)');

NoticebirdClient _client({
  CrashTransport transport = const DiscardingCrashTransport(),
  CrashOfflineStore? store,
  FeedbackConfig? feedback,
  DateTime Function()? clock,
}) => NoticebirdClient(
  config: NoticebirdConfig(
    privacyProfile: CrashPrivacyProfile.privacyDefault,
    app: _app,
    platform: _platform,
    sessionIdFactory: () => 'random_session_123456',
    deduplicationWindow: Duration.zero,
    offlineStore: store,
    feedback: feedback,
  ),
  transport: transport,
  clock: clock,
);

void main() {
  group('a discarding transport', () {
    test('makes no event, keeps none, and claims no native report', () async {
      final collector = _Collector();
      final reporter = NoticebirdClient(
        config: NoticebirdConfig(
          privacyProfile: CrashPrivacyProfile.privacyDefault,
          app: _app,
          platform: _platform,
          nativeCrashes: collector,
        ),
        transport: const DiscardingCrashTransport(),
      );

      expect(
        await reporter.captureException(StateError('boom'), _stack),
        const CaptureResult(CaptureOutcome.discarded),
      );
      expect(await reporter.reportNativeCrashes(), isEmpty);
      expect(collector.claims, 0);
      expect(collector.started, isTrue);
    });

    test('leaves what an earlier run kept in the store', () async {
      final store = _SlowStore()..values = ['{"eventId":"kept"}'];
      final reporter = _client(store: store);

      await reporter.flush();

      expect(store.values, ['{"eventId":"kept"}']);
    });
  });

  test('a native delivery stops at close', () async {
    final collector = _Collector();
    final reporter = NoticebirdClient(
      config: NoticebirdConfig(
        privacyProfile: CrashPrivacyProfile.privacyDefault,
        app: _app,
        platform: _platform,
        nativeCrashes: collector,
      ),
      transport: _Transport(),
    );
    unawaited(reporter.reportNativeCrashes());
    await pumpEventQueue();
    expect(collector.listened, isTrue);

    reporter.close();
    await pumpEventQueue();

    expect(collector.cancelled, isTrue);
  });

  group('eventIdOf', () {
    test('answers the id of a capture nobody awaited, once it '
        'settles', () async {
      final transport = _Transport();
      final reporter = _client(transport: transport);
      final error = StateError('boom');

      unawaited(reporter.captureException(error, _stack));
      final id = await reporter.eventIdOf(error);

      expect(id, isNotNull);
      expect(jsonDecode(transport.bodies.single)['eventId'], id);
    });

    test('answers null for an error never captured, one discarded, and one '
        'that cannot be told apart', () async {
      final transport = _Transport();
      final reporter = _client(transport: transport);
      await reporter.captureException('a string', _stack);

      expect(await reporter.eventIdOf(StateError('other')), isNull);
      expect(await reporter.eventIdOf('a string'), isNull);

      // An error no Expando takes still captures, and has no id.
      final pointer = Pointer<Void>.fromAddress(1);
      expect(
        (await reporter.captureException(pointer, _stack)).outcome,
        CaptureOutcome.sent,
      );
      expect(await reporter.eventIdOf(pointer), isNull);

      final discarding = _client();
      final error = StateError('boom');
      await discarding.captureException(error, _stack);
      expect(await discarding.eventIdOf(error), isNull);
    });
  });

  group('the offline store', () {
    test('holds the newest queue when an older write is slower', () async {
      final transport = _Transport()..failing = true;
      final store = _SlowStore();
      final reporter = _client(transport: transport, store: store);

      final first = reporter.captureException(StateError('first'), _stack);
      final second = reporter.captureException(StateError('second'), _stack);
      await Future.wait([first, second]);
      await store.idle;

      expect(store.values, hasLength(2));
    });

    test('is written back after a read, so a read keeps what it '
        'read', () async {
      final transport = _Transport()..failing = true;
      final store = _SlowStore();
      final reporter = _client(transport: transport, store: store);
      await reporter.captureException(StateError('first'), _stack);
      await store.idle;
      final restarted = _client(transport: transport, store: store);

      await restarted.flush();
      await store.idle;

      expect(store.values, hasLength(1));
      expect(restarted.pendingCount, 1);
    });
  });

  group('FileCrashOfflineStore', () {
    late Directory directory;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('noticebird_crash_');
      addTearDown(() => directory.delete(recursive: true));
    });

    test('reads what it wrote, and keeps it', () async {
      final store = FileCrashOfflineStore(directory);
      await store.write(['{"eventId":"a"}', '{"eventId":"b"}']);

      expect(await store.read(), ['{"eventId":"a"}', '{"eventId":"b"}']);
      expect(await store.read(), hasLength(2));
      expect(store.isEncrypted, isFalse);
    });

    test('an empty write leaves no file, and a missing one reads '
        'empty', () async {
      final store = FileCrashOfflineStore(Directory('${directory.path}/new'));
      expect(await store.read(), isEmpty);

      await store.write(['{}']);
      await store.write(const []);

      expect(Directory('${directory.path}/new').listSync(), isEmpty);
    });

    test('an empty write also removes what an unfinished write left', () async {
      File('${directory.path}/events.json.tmp').writeAsStringSync('[');
      await FileCrashOfflineStore(directory).write(const []);
      expect(directory.listSync(), isEmpty);
    });

    test('a file it cannot read is deleted, and read as empty', () async {
      File('${directory.path}/events.json').writeAsStringSync('[1, 2');
      final store = FileCrashOfflineStore(directory);

      expect(await store.read(), isEmpty);
      expect(directory.listSync(), isEmpty);
    });

    test('a queue survives a new client on the same directory', () async {
      final transport = _Transport()..failing = true;
      await _client(
        transport: transport,
        store: FileCrashOfflineStore(directory),
      ).captureException(StateError('boom'), _stack);

      transport.failing = false;
      final restarted = _client(
        transport: transport,
        store: FileCrashOfflineStore(directory),
      );
      await restarted.flush();

      expect(transport.bodies, hasLength(1));
      expect(await FileCrashOfflineStore(directory).read(), isEmpty);
    });
  });

  test('a flush asked during a flush runs once more after it', () async {
    final transport = _Transport()..failing = true;
    final reporter = _client(transport: transport);
    await reporter.captureException(StateError('first'), _stack);
    final gate = Completer<void>();
    transport
      ..failing = false
      ..gate = gate;

    final running = reporter.flush();
    await pumpEventQueue();
    transport.failing = true;
    await reporter.captureException(StateError('second'), _stack);
    transport.failing = false;
    final again = reporter.flush();
    gate.complete();
    await Future.wait([running, again]);

    expect(transport.bodies, hasLength(2));
    expect(reporter.pendingCount, 0);
  });

  group('the feedback drained by the client', () {
    test('a report kept for later is sent when it is due, without a '
        'flush', () {
      fakeAsync((async) {
        var now = DateTime.utc(2026, 10, 30, 12);
        final transport = FakeFeedbackTransport()
          ..submitAnswers.add(const FeedbackTransient());
        final settled = <FeedbackSettled>[];
        final reporter = _client(
          clock: () => now,
          feedback: FeedbackConfig(
            transport: transport,
            offlineStore: _FeedbackStore(),
            onSettled: settled.add,
          ),
        );
        reporter.captureFeedback(kind: FeedbackKind.bug, message: 'Broken');
        async.flushMicrotasks();
        expect(transport.requests, ['submit']);

        now = now.add(FeedbackOfflineStore.firstRetryDelay);
        async.elapse(FeedbackOfflineStore.firstRetryDelay);

        expect(transport.requests, ['submit', 'submit']);
        expect(settled.single.outcome, isA<FeedbackDelivered>());
      });
    });

    test('close stops it', () {
      fakeAsync((async) {
        var now = DateTime.utc(2026, 10, 30, 12);
        final transport = FakeFeedbackTransport()
          ..submitAnswers.add(const FeedbackTransient());
        final reporter = _client(
          clock: () => now,
          feedback: FeedbackConfig(
            transport: transport,
            offlineStore: _FeedbackStore(),
          ),
        );
        reporter.captureFeedback(kind: FeedbackKind.bug, message: 'Broken');
        async.flushMicrotasks();

        reporter.close();
        now = now.add(FeedbackOfflineStore.firstRetryDelay);
        async.elapse(FeedbackOfflineStore.firstRetryDelay);

        expect(transport.requests, ['submit']);
        expect(async.pendingTimers, isEmpty);
      });
    });
  });
}

final class _Transport implements CrashTransport {
  final bodies = <String>[];
  bool failing = false;
  Completer<void>? gate;

  @override
  Future<void> send(String eventJson) async {
    final waiting = gate;
    if (waiting != null) {
      gate = null;
      await waiting.future;
    }
    if (failing) throw const CrashTransportException(503);
    bodies.add(eventJson);
  }
}

/// A store whose first write takes longer than the ones after it.
final class _SlowStore implements CrashOfflineStore {
  List<String> values = [];
  var _writes = 0;
  final _running = <Future<void>>[];

  Future<void> get idle => Future.wait(_running);

  @override
  bool get isEncrypted => false;

  @override
  Future<List<String>> read() async => values;

  @override
  Future<void> write(List<String> canonicalEnvelopes) {
    final delay = _writes++ == 0
        ? const Duration(milliseconds: 20)
        : Duration.zero;
    final write = Future<void>.delayed(
      delay,
      () => values = [...canonicalEnvelopes],
    );
    _running.add(write);
    return write;
  }
}

final class _FeedbackStore implements FeedbackOfflineStore {
  final _json = <String, String>{};

  @override
  bool get isEncrypted => false;

  @override
  Future<void> put(PendingFeedback report) async =>
      _json[report.reportId] = jsonEncode(report.toJson());

  @override
  Future<List<PendingFeedback>> pending() async => [
    for (final json in _json.values)
      PendingFeedback.fromJson(jsonDecode(json) as Map<String, Object?>),
  ];

  @override
  Future<Uint8List?> attachment(String reportId) async => null;

  @override
  Future<void> remove(String reportId) async => _json.remove(reportId);
}

final class _Collector implements NativeCrashCollector {
  bool started = false;
  int claims = 0;
  bool listened = false;
  bool cancelled = false;

  @override
  Future<void> start(NativeRunInfo run) async => started = true;

  @override
  void update(NativeRunState state) {}

  @override
  Stream<NativeCrashBatch> claimed({int max = 10}) {
    claims++;
    late final StreamController<NativeCrashBatch> batches;
    batches = StreamController(
      onListen: () => listened = true,
      onCancel: () => cancelled = true,
    );
    return batches.stream;
  }

  @override
  Future<void> settle(String recordId, {required bool delivered}) async {}
}
