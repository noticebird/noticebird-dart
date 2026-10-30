import 'dart:convert';

import 'package:noticebird/noticebird.dart';
import 'package:test/test.dart';

void main() {
  late _RecordingTransport transport;
  late NoticebirdClient reporter;

  NoticebirdConfig config() => NoticebirdConfig(
    privacyProfile: CrashPrivacyProfile.regulatedStrict,
    app: const AppMetadata(
      name: 'test-app',
      version: '1.0.0',
      build: '1',
      release: 'test-app@1.0.0+1',
    ),
    platform: const PlatformMetadata(
      platform: CrashPlatform.macos,
      osVersion: '15.5',
      deviceClass: 'desktop',
    ),
    sessionIdFactory: () => 'random_session_123456',
    deduplicationWindow: Duration.zero,
  );

  setUp(() {
    transport = _RecordingTransport();
    reporter = NoticebirdClient(
      config: config(),
      transport: transport,
      clock: () => DateTime.utc(2026, 7, 11, 10, 15),
      eventIdFactory: () => '0197f232-2bd8-7000-8000-000000000001',
    );
  });

  tearDown(() {
    Noticebird.detach();
  });

  test('is a no-op when nothing has been attached', () async {
    expect(Noticebird.instance, isNull);
    expect(
      await Noticebird.captureException(Exception('boom'), StackTrace.empty),
      isNull,
    );
    Noticebird.addBreadcrumb(
      TypedBreadcrumb(
        occurredAt: DateTime.utc(2026, 7, 11),
        category: BreadcrumbCategory.bloc,
        action: 'noop',
      ),
    );
    Noticebird.clearBreadcrumbs();
    Noticebird.setUserId('user-1');
    Noticebird.setRouteTemplate('/lists/:listId');
    Noticebird.startLiveDebugSession(
      sessionId: 's1',
      expiresAt: DateTime.utc(2026, 7, 11, 11),
    );
    Noticebird.stopLiveDebugSession();
    expect(Noticebird.recentBreadcrumbs, isEmpty);
    expect(Noticebird.isLiveDebugSessionActive, isFalse);
    expect(Noticebird.eventIdOf(StateError('boom')), isNull);
    expect(Noticebird.feedbackMoment(), isNull);
    expect(Noticebird.reportedContext, isNull);
  });

  test('answers the event id of an error the attached client '
      'captured', () async {
    Noticebird.attach(reporter);
    final error = StateError('boom');
    final result = await Noticebird.captureException(error, StackTrace.empty);

    expect(await Noticebird.eventIdOf(error), result!.eventId);
  });

  test('delegates every call to the attached client', () async {
    Noticebird.attach(reporter);
    expect(Noticebird.instance, same(reporter));
    expect(Noticebird.reportedContext?.app, same(config().app));

    final result = await Noticebird.captureException(
      Exception('boom'),
      StackTrace.empty,
      groupingKey: const ['boom', 'E42'],
    );
    expect(result?.outcome, CaptureOutcome.sent);
    expect(transport.sent, hasLength(1));
    expect(transport.sent.single['groupingKey'], ['boom', 'E42']);

    Noticebird.setRouteTemplate('/lists/:listId');
    Noticebird.startLiveDebugSession(
      sessionId: 's1',
      expiresAt: DateTime.utc(2026, 7, 11, 11),
    );
    expect(Noticebird.isLiveDebugSessionActive, isTrue);
    expect(reporter.isLiveDebugSessionActive, isTrue);

    Noticebird.stopLiveDebugSession();
    expect(Noticebird.isLiveDebugSessionActive, isFalse);

    Noticebird.setUserId('user-1');
  });

  test('reverts to a no-op after detach', () async {
    Noticebird.attach(reporter);
    Noticebird.detach();
    expect(Noticebird.instance, isNull);
    expect(
      await Noticebird.captureException(Exception('boom'), StackTrace.empty),
      isNull,
    );
    expect(transport.sent, isEmpty);
  });
}

class _RecordingTransport implements CrashTransport {
  final sent = <Map<String, dynamic>>[];

  @override
  Future<void> send(String eventJson) async {
    sent.add(jsonDecode(eventJson) as Map<String, dynamic>);
  }
}
