// The feedback offline store as the client uses it: a report that did not
// get through is kept and answered queued, a flush sends the reports that
// are due and tells their end to FeedbackConfig.onSettled, the schedule and the
// delivery's state survive a new client on the same store, and the store
// stays within its bounds. The store here keeps each report as its JSON
// form and its attachment apart, as a store on disk does.

import 'dart:async';
import 'dart:convert';

import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:noticebird/feedback.dart';
import 'package:noticebird/noticebird.dart';

import 'support/fake_feedback_transport.dart';

const _assertionA = 'eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJhIn0.c2lnbmF0dXJlLWE';
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

final _capturedAt = DateTime.utc(2026, 10, 30, 12);

Uint8List _png(int length) =>
    Uint8List(length)
      ..setAll(0, const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

void main() {
  late FakeFeedbackTransport transport;
  late _MemoryStore store;
  late DateTime now;
  late List<FeedbackSettled> settled;

  setUp(() {
    transport = FakeFeedbackTransport();
    store = _MemoryStore();
    now = _capturedAt;
    settled = [];
  });

  NoticebirdClient client({
    FeedbackOfflineStore? offlineStore,
    Future<String?> Function()? reporterAssertion,
    bool requireVerified = false,
    CrashTransport? crashTransport,
  }) => NoticebirdClient(
    config: NoticebirdConfig(
      privacyProfile: CrashPrivacyProfile.privacyDefault,
      app: _app,
      platform: _platform,
      sessionIdFactory: () => 'random_session_123456',
      feedback: FeedbackConfig(
        transport: transport,
        reporterAssertion: reporterAssertion,
        requireVerified: requireVerified,
        offlineStore: offlineStore ?? store,
        onSettled: settled.add,
      ),
    ),
    transport: crashTransport,
    clock: () => now,
  );

  Future<FeedbackOutcome> capture(
    NoticebirdClient reporter, {
    Uint8List? screenshot,
  }) => reporter.captureFeedback(
    kind: FeedbackKind.bug,
    message: 'The list does not load',
    screenshot: screenshot,
  );

  Future<String> queued(NoticebirdClient reporter, {Uint8List? screenshot}) =>
      capture(
        reporter,
        screenshot: screenshot,
      ).then((outcome) => (outcome as FeedbackQueued).reportId);

  /// The ends [reporter]'s config was told, in order.
  List<FeedbackSettled> settledOf(NoticebirdClient reporter) => settled;

  Future<PendingFeedback> kept() async => (await store.pending()).single;

  group('offline, then online', () {
    for (final withScreenshot in [false, true]) {
      test('a report ${withScreenshot ? 'with' : 'without'} a screenshot is '
          'queued, and delivered by a flush once it is due', () async {
        final reporter = client();
        final settled = settledOf(reporter);
        final screenshot = withScreenshot ? _png(64) : null;
        if (withScreenshot) {
          transport.slotAnswers.add(const FeedbackTransient());
        } else {
          transport.submitAnswers.add(const FeedbackTransient());
        }

        final reportId = await queued(reporter, screenshot: screenshot);
        expect(await reporter.pendingFeedbackCount, 1);

        await reporter.flush();
        expect(transport.requests, [withScreenshot ? 'slot' : 'submit']);

        now = (await kept()).nextAttemptAt;
        await reporter.flush();
        await pumpEventQueue();

        expect(settled, [
          FeedbackSettled(
            reportId,
            const FeedbackDelivered(ticket: fakeTicket, verified: false),
          ),
        ]);
        expect(transport.requests, [
          if (withScreenshot) ...['slot', 'slot', 'upload'] else 'submit',
          'submit',
        ]);
        if (withScreenshot) expect(transport.uploaded.single, screenshot);
        expect(transport.submitted.last['reportId'], reportId);
        expect(await reporter.pendingFeedbackCount, 0);
        expect(await store.pending(), isEmpty);
      });
    }

    test('a flush of a new client delivers what an earlier one '
        'queued', () async {
      transport.submitAnswers.add(const FeedbackTransient());
      final reportId = await queued(client());
      now = now.add(FeedbackOfflineStore.firstRetryDelay);

      final restarted = client();
      final settled = settledOf(restarted);
      await restarted.flush();

      expect(settled.single.reportId, reportId);
      expect(settled.single.outcome, isA<FeedbackDelivered>());
    });

    test('without a store a report that did not get through is '
        'noStore', () async {
      final reporter = NoticebirdClient(
        config: NoticebirdConfig(
          privacyProfile: CrashPrivacyProfile.privacyDefault,
          app: _app,
          platform: _platform,
          feedback: FeedbackConfig(transport: transport),
        ),
      );
      transport.submitAnswers.add(const FeedbackTransient());

      expect(
        await capture(reporter),
        const FeedbackRejected(FeedbackRejection.noStore),
      );
      expect(await reporter.pendingFeedbackCount, 0);
    });
  });

  group('the schedule', () {
    test('a Retry-After of an hour survives a new client on the same '
        'store', () async {
      transport.submitAnswers.add(const FeedbackRetryAfter(Duration(hours: 1)));
      await queued(client());

      final restarted = client();
      now = _capturedAt.add(const Duration(minutes: 59));
      await restarted.flush();
      expect(transport.submitted, hasLength(1));

      now = _capturedAt.add(const Duration(hours: 1));
      await restarted.flush();
      expect(transport.submitted, hasLength(2));
      expect(await restarted.pendingFeedbackCount, 0);
    });

    test('a Retry-After longer than a report lives waits until it '
        'expires', () async {
      transport.submitAnswers.add(
        const FeedbackRetryAfter(Duration(days: 80000000)),
      );
      await queued(client());

      expect(
        (await kept()).nextAttemptAt,
        _capturedAt.add(FeedbackReport.maxAge),
      );
    });

    test('the backoff doubles from 30 seconds, less up to a quarter, and '
        'stops at 6 hours', () async {
      transport.submitAnswers.addAll(
        List.filled(16, const FeedbackTransient()),
      );
      final reporter = client();
      await queued(reporter);

      final waits = <Duration>[];
      for (var attempt = 1; attempt <= 15; attempt++) {
        final report = await kept();
        expect(report.attempts, attempt);
        waits.add(report.nextAttemptAt.difference(now));
        now = report.nextAttemptAt;
        await reporter.flush();
      }

      const first = FeedbackOfflineStore.firstRetryDelay;
      const cap = FeedbackOfflineStore.maxRetryDelay;
      expect(
        waits.first,
        allOf(greaterThanOrEqualTo(first * 0.75), lessThanOrEqualTo(first)),
      );
      for (var index = 1; index <= 10; index++) {
        expect(waits[index], greaterThan(waits[index - 1]));
      }
      for (final wait in waits.skip(10)) {
        expect(
          wait,
          allOf(greaterThanOrEqualTo(cap * 0.75), lessThanOrEqualTo(cap)),
        );
      }
    });

    test('a report that keeps returning to the slot is sent once per '
        'attempt, and backs off', () async {
      transport.submitAnswers.addAll(
        List.filled(30, const FeedbackBackToSlot()),
      );
      final reporter = client();
      await queued(reporter, screenshot: _png(64));
      const round = ['slot', 'upload', 'submit'];
      expect(transport.requests, [...round, ...round, ...round]);

      for (var flush = 0; flush < 5; flush++) {
        await reporter.flush();
      }
      expect(transport.requests, hasLength(9));

      now = (await kept()).nextAttemptAt;
      await reporter.flush();
      await reporter.flush();
      expect(transport.requests, hasLength(18));
      expect((await kept()).attempts, 2);
    });
  });

  group('the bounds', () {
    test('an eleventh report evicts the oldest', () async {
      transport.submitAnswers.addAll(
        List.filled(11, const FeedbackTransient()),
      );
      final reporter = client();
      final settled = settledOf(reporter);
      final reportIds = <String>[];
      for (var index = 0; index < 11; index++) {
        now = _capturedAt.add(Duration(seconds: index));
        reportIds.add(await queued(reporter));
      }
      await pumpEventQueue();

      expect(settled, [
        FeedbackSettled(
          reportIds.first,
          const FeedbackRejected(FeedbackRejection.evicted),
        ),
      ]);
      expect(
        await reporter.pendingFeedbackCount,
        FeedbackOfflineStore.maxReports,
      );
      expect({
        for (final report in await store.pending()) report.reportId,
      }, reportIds.skip(1).toSet());
    });

    test('a report past 20 MiB in all evicts the oldest', () async {
      transport.slotAnswers.addAll(List.filled(4, const FeedbackTransient()));
      final reporter = client();
      final settled = settledOf(reporter);
      final reportIds = <String>[];
      for (var index = 0; index < 4; index++) {
        now = _capturedAt.add(Duration(seconds: index));
        reportIds.add(
          await queued(
            reporter,
            screenshot: _png(FeedbackAttachmentRef.maxByteLength),
          ),
        );
      }
      await pumpEventQueue();

      expect(settled, [
        FeedbackSettled(
          reportIds.first,
          const FeedbackRejected(FeedbackRejection.evicted),
        ),
      ]);
      expect({
        for (final report in await store.pending()) report.reportId,
      }, reportIds.skip(1).toSet());
    });

    test('a report 7 days old is removed unsent, as expired', () async {
      transport.submitAnswers.add(const FeedbackTransient());
      final reporter = client();
      final settled = settledOf(reporter);
      final reportId = await queued(reporter);

      now = _capturedAt.add(FeedbackReport.maxAge);
      await reporter.flush();
      await pumpEventQueue();

      expect(settled, [
        FeedbackSettled(
          reportId,
          const FeedbackRejected(FeedbackRejection.expired),
        ),
      ]);
      expect(transport.submitted, hasLength(1));
      expect(await reporter.pendingFeedbackCount, 0);
    });

    test('a new report removes one 7 days old, as expired', () async {
      transport.submitAnswers.addAll(List.filled(2, const FeedbackTransient()));
      final reporter = client();
      final settled = settledOf(reporter);
      final old = await queued(reporter);

      now = _capturedAt.add(FeedbackReport.maxAge);
      final fresh = await queued(reporter);
      await pumpEventQueue();

      expect(settled, [
        FeedbackSettled(old, const FeedbackRejected(FeedbackRejection.expired)),
      ]);
      expect((await kept()).reportId, fresh);
    });
  });

  group('the delivery state survives a new client', () {
    test('a queued report whose assertion was refused is resent as '
        'rewritten, without it, the provider not asked', () async {
      var asked = 0;
      Future<String?> provider() async {
        asked++;
        return _assertionA;
      }

      transport.submitAnswers.addAll(const [
        FeedbackAssertionRefused(),
        FeedbackTransient(),
      ]);
      await queued(client(reporterAssertion: provider));
      final [first, rewritten] = transport.submitted;
      expect(first['reporterAssertion'], _assertionA);
      expect(rewritten, {...first}..remove('reporterAssertion'));
      expect((await kept()).reportJson, isNot(contains('reporterAssertion')));
      expect(asked, 1);

      final restarted = client(reporterAssertion: provider);
      final settled = settledOf(restarted);
      now = (await kept()).nextAttemptAt;
      await restarted.flush();
      await pumpEventQueue();

      expect(transport.submitted, hasLength(3));
      expect(transport.submitted[2], rewritten);
      expect(asked, 1);
      expect(
        settled.single.outcome,
        const FeedbackDelivered(ticket: fakeTicket, verified: false),
      );
    });

    test('requireVerified rejects a queued report without an assertion at '
        'the flush', () async {
      transport.submitAnswers.add(const FeedbackTransient());
      final reportId = await queued(client());

      final restarted = client(
        reporterAssertion: () async => _assertionA,
        requireVerified: true,
      );
      final settled = settledOf(restarted);
      now = (await kept()).nextAttemptAt;
      await restarted.flush();
      await pumpEventQueue();

      expect(settled, [
        FeedbackSettled(
          reportId,
          const FeedbackRejected(FeedbackRejection.unverified),
        ),
      ]);
      expect(transport.submitted, hasLength(1));
      expect(await restarted.pendingFeedbackCount, 0);
    });

    test('a screenshot the store lost fails the report at the flush, '
        'before any request', () async {
      transport.slotAnswers.add(const FeedbackTransient());
      final reporter = client();
      final settled = settledOf(reporter);
      final reportId = await queued(reporter, screenshot: _png(64));

      store.loseAttachments = true;
      now = (await kept()).nextAttemptAt;
      await reporter.flush();
      await pumpEventQueue();

      expect(settled, [
        FeedbackSettled(
          reportId,
          const FeedbackRejected(FeedbackRejection.failed),
        ),
      ]);
      expect(transport.requests, ['slot']);
    });

    test('a stored form whose report is no report is no pending '
        'report', () {
      for (final report in ['{"not": "a report"}', '[]', 'not JSON']) {
        expect(
          () => PendingFeedback.fromJson({
            'format': 1,
            'report': report,
            'next': 'submit',
            'attempts': 0,
            'nextAttemptAt': '2026-10-30T12:00:00.000Z',
          }),
          throwsFormatException,
          reason: report,
        );
      }
    });
  });

  test('a final refusal at the flush removes the report, and tells '
      'it', () async {
    transport.submitAnswers.addAll(const [
      FeedbackTransient(),
      FeedbackFinalRefusal(code: 'feedback_disabled'),
    ]);
    final reporter = client();
    final settled = settledOf(reporter);
    final reportId = await queued(reporter);

    now = (await kept()).nextAttemptAt;
    await reporter.flush();
    await pumpEventQueue();

    expect(settled, [
      FeedbackSettled(
        reportId,
        const FeedbackRejected(
          FeedbackRejection.notAccepted,
          code: 'feedback_disabled',
        ),
      ),
    ]);
    expect(await reporter.pendingFeedbackCount, 0);
  });

  group('a drain', () {
    test('stops at the first report that is postponed', () async {
      transport.submitAnswers.addAll(List.filled(3, const FeedbackTransient()));
      final reporter = client();
      final reportIds = <String>[];
      for (var index = 0; index < 2; index++) {
        now = _capturedAt.add(Duration(seconds: index));
        reportIds.add(await queued(reporter));
      }
      now = _capturedAt.add(const Duration(minutes: 1));

      await reporter.flush();

      expect(transport.submitted, hasLength(3));
      expect(transport.submitted.last['reportId'], reportIds.first);
    });

    test('a capture during a drain of 10 evicts the oldest, not the '
        'capture', () async {
      transport.submitAnswers.addAll(
        List.filled(10, const FeedbackTransient()),
      );
      final reporter = client();
      final settled = settledOf(reporter);
      final reportIds = <String>[];
      for (var index = 0; index < 10; index++) {
        now = _capturedAt.add(Duration(seconds: index));
        reportIds.add(await queued(reporter));
      }
      now = _capturedAt.add(const Duration(minutes: 1));
      transport.submitAnswers.addAll(
        List.filled(10, const FeedbackTransient()),
      );
      late String captured;
      transport.beforeSubmit = () async {
        transport.beforeSubmit = null;
        captured = await queued(reporter);
      };

      await reporter.flush();
      await pumpEventQueue();

      expect(settled, [
        FeedbackSettled(
          reportIds.first,
          const FeedbackRejected(FeedbackRejection.evicted),
        ),
      ]);
      expect(
        {for (final report in await store.pending()) report.reportId},
        {...reportIds.skip(1), captured},
      );
    });

    test('does not hold up a flush of the crash events', () async {
      transport.submitAnswers.add(const FeedbackTransient());
      final crashes = _CrashTransport();
      final reporter = client(crashTransport: crashes);
      await queued(reporter);
      now = (await kept()).nextAttemptAt;
      final gate = Completer<void>();
      transport.beforeSubmit = () => gate.future;
      final draining = reporter.flush();
      await pumpEventQueue();
      expect(transport.requests, ['submit', 'submit']);

      crashes.offline = true;
      await reporter.captureException(
        StateError('boom'),
        StackTrace.fromString('#0 A.b (package:app/a.dart:1:1)'),
      );
      expect(reporter.pendingCount, 1);
      crashes.offline = false;
      final again = reporter.flush();
      await pumpEventQueue();

      expect(crashes.sent, 1);
      expect(reporter.pendingCount, 0);
      gate.complete();
      await draining;
      await again;
    });

    // A report id is the client's own UUID v4 from a secure random source:
    // a report stored under it is this client's earlier delivery of it.
    for (final (name, submitAnswer, delivered) in [
      (
        'a replay, delivered with its ticket',
        const FeedbackAccepted(ticket: fakeTicket, verified: false),
        const FeedbackDelivered(ticket: fakeTicket, verified: false),
      ),
      (
        'report_conflict again after a slot conflict: '
            'delivered without a ticket',
        const FeedbackFinalRefusal(code: 'report_conflict'),
        const FeedbackDelivered(verified: false),
      ),
    ]) {
      test('report_conflict at the slot submits the report, which answers '
          '$name', () async {
        transport.slotAnswers.add(const FeedbackTransient());
        final reporter = client();
        final settled = settledOf(reporter);
        final reportId = await queued(reporter, screenshot: _png(64));

        transport.slotAnswers.add(
          const FeedbackFinalRefusal(code: 'report_conflict'),
        );
        transport.submitAnswers.add(submitAnswer);
        now = (await kept()).nextAttemptAt;
        await reporter.flush();
        await pumpEventQueue();

        expect(transport.requests, ['slot', 'slot', 'submit']);
        expect(settled, [FeedbackSettled(reportId, delivered)]);
        expect(await store.pending(), isEmpty);
      });
    }

    test('a submit postponed after report_conflict at the slot still knows '
        'the report is stored, in a later run too', () async {
      transport.slotAnswers.add(const FeedbackTransient());
      final reportId = await queued(client(), screenshot: _png(64));

      transport.slotAnswers.add(
        const FeedbackFinalRefusal(code: 'report_conflict'),
      );
      transport.submitAnswers.add(const FeedbackTransient());
      now = (await kept()).nextAttemptAt;
      await client().flush();
      expect(transport.requests, ['slot', 'slot', 'submit']);

      // A later run, on the same store.
      final restarted = client();
      final settled = settledOf(restarted);
      transport.submitAnswers.add(
        const FeedbackFinalRefusal(code: 'report_conflict'),
      );
      now = (await kept()).nextAttemptAt;
      await restarted.flush();
      await pumpEventQueue();

      expect(transport.requests, ['slot', 'slot', 'submit', 'submit']);
      expect(settled, [
        FeedbackSettled(reportId, const FeedbackDelivered(verified: false)),
      ]);
      expect(await store.pending(), isEmpty);
    });
  });

  test('concurrent flushes send each report once', () async {
    transport.submitAnswers.addAll(List.filled(3, const FeedbackTransient()));
    final reporter = client();
    final reportIds = <String>[];
    for (var index = 0; index < 3; index++) {
      now = _capturedAt.add(Duration(seconds: index));
      reportIds.add(await queued(reporter));
    }
    now = _capturedAt.add(const Duration(minutes: 1));

    await Future.wait([reporter.flush(), reporter.flush(), reporter.flush()]);
    await reporter.flush();

    expect(
      transport.submitted.skip(3).map((report) => report['reportId']),
      reportIds,
    );
  });

  group('a store that fails', () {
    // A store of its own, or `FileFeedbackOfflineStore` on the web, where
    // every call of `dart:io` throws an UnsupportedError.
    for (final (name, failure) in [
      ('of its own', const _StoreFailure()),
      ('without a file system', UnsupportedError('No file system')),
    ]) {
      test('$name at the capture makes the report noStore, and nothing '
          'throws', () async {
        final reporter = client(offlineStore: _FailingStore(failure));
        transport.submitAnswers.add(const FeedbackTransient());

        expect(
          await capture(reporter),
          const FeedbackRejected(FeedbackRejection.noStore),
        );
        await reporter.flush();
        expect(await reporter.pendingFeedbackCount, 0);
      });
    }

    test('to remove a delivered report keeps it, and tells its end once it '
        'is removed', () async {
      transport.submitAnswers.add(const FeedbackTransient());
      final reporter = client();
      final settled = settledOf(reporter);
      final reportId = await queued(reporter);

      store.failRemove = true;
      now = (await kept()).nextAttemptAt;
      await reporter.flush();
      await pumpEventQueue();
      expect(settled, isEmpty);
      expect(await reporter.pendingFeedbackCount, 1);

      store.failRemove = false;
      await reporter.flush();
      await pumpEventQueue();
      expect(settled.single.reportId, reportId);
      expect(transport.submitted, hasLength(3));
    });
  });

  group('the config', () {
    NoticebirdConfig config(
      CrashPrivacyProfile profile,
      FeedbackOfflineStore store,
    ) => NoticebirdConfig(
      privacyProfile: profile,
      app: _app,
      platform: _platform,
      feedback: FeedbackConfig(transport: transport, offlineStore: store),
    );

    test('regulatedStrict refuses an unencrypted store', () {
      expect(
        () => config(CrashPrivacyProfile.regulatedStrict, _MemoryStore()),
        throwsArgumentError,
      );
    });

    test('regulatedStrict takes an encrypted store', () {
      expect(
        config(
          CrashPrivacyProfile.regulatedStrict,
          _MemoryStore(isEncrypted: true),
        ).feedback?.offlineStore?.isEncrypted,
        isTrue,
      );
    });

    test('any other profile takes an unencrypted store', () {
      expect(
        config(CrashPrivacyProfile.privacyDefault, _MemoryStore()).feedback,
        isNotNull,
      );
    });
  });

  test('the facade answers null without a client', () async {
    Noticebird.detach();
    expect(Noticebird.pendingFeedbackCount, isNull);

    transport.submitAnswers.add(const FeedbackTransient());
    final reporter = client();
    Noticebird.attach(reporter);
    addTearDown(Noticebird.detach);
    await queued(reporter);

    expect(await Noticebird.pendingFeedbackCount, 1);
  });

  test('an onSettled that throws costs the store nothing', () async {
    transport.submitAnswers.add(const FeedbackTransient());
    final reporter = NoticebirdClient(
      config: NoticebirdConfig(
        privacyProfile: CrashPrivacyProfile.privacyDefault,
        app: _app,
        platform: _platform,
        sessionIdFactory: () => 'random_session_123456',
        feedback: FeedbackConfig(
          transport: transport,
          offlineStore: store,
          onSettled: (_) => throw StateError('host bug'),
        ),
      ),
      clock: () => now,
    );
    await queued(reporter);

    now = (await kept()).nextAttemptAt;
    await reporter.flush();

    expect(await store.pending(), isEmpty);
    expect(transport.requests, ['submit', 'submit']);
  });
}

/// A [FeedbackOfflineStore] that keeps each report as its JSON text and
/// its attachment apart, and reads them back with
/// [PendingFeedback.fromJson], as a store on disk does.
final class _MemoryStore implements FeedbackOfflineStore {
  _MemoryStore({this.isEncrypted = false});

  @override
  final bool isEncrypted;

  final _json = <String, String>{};
  final _attachments = <String, Uint8List>{};
  bool failRemove = false;

  /// Whether [attachment] answers `null`, as for a screenshot lost.
  bool loseAttachments = false;

  @override
  Future<void> put(PendingFeedback report) async {
    _json[report.reportId] = jsonEncode(report.toJson());
    switch (report.attachment) {
      case final attachment?:
        _attachments[report.reportId] = Uint8List.fromList(attachment);
      case null:
        _attachments.remove(report.reportId);
    }
  }

  @override
  Future<List<PendingFeedback>> pending() async => [
    for (final json in _json.values)
      PendingFeedback.fromJson(jsonDecode(json) as Map<String, Object?>),
  ];

  @override
  Future<Uint8List?> attachment(String reportId) async =>
      loseAttachments ? null : _attachments[reportId];

  @override
  Future<void> remove(String reportId) async {
    if (failRemove) throw const _StoreFailure();
    _json.remove(reportId);
    _attachments.remove(reportId);
  }
}

/// A [CrashTransport] that counts what it sends, and fails while
/// [offline].
final class _CrashTransport implements CrashTransport {
  bool offline = false;
  int sent = 0;

  @override
  Future<void> send(String eventJson) async {
    if (offline) throw StateError('offline');
    sent++;
  }
}

final class _StoreFailure implements Exception {
  const _StoreFailure();
}

/// A [FeedbackOfflineStore] whose every call throws [failure].
final class _FailingStore implements FeedbackOfflineStore {
  _FailingStore(this.failure);

  final Object failure;

  @override
  bool get isEncrypted => false;

  @override
  Future<void> put(PendingFeedback report) async => throw failure;

  @override
  Future<List<PendingFeedback>> pending() async => throw failure;

  @override
  Future<Uint8List?> attachment(String reportId) async => throw failure;

  @override
  Future<void> remove(String reportId) async => throw failure;
}
