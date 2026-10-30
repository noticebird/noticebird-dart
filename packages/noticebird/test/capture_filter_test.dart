import 'dart:convert';

import 'package:noticebird/noticebird.dart';
import 'package:test/test.dart';

final class _RecordingTransport implements CrashTransport {
  final events = <Map<String, dynamic>>[];

  @override
  Future<void> send(String eventJson) async {
    events.add(jsonDecode(eventJson) as Map<String, dynamic>);
  }
}

/// An error the host reports at a report point of its own, and nowhere else.
final class _ReportedElsewhere implements Exception {
  const _ReportedElsewhere();
}

/// One capture filter, set once on the config, that every channel honours —
/// an explicit capture here, and the channels of `noticebird_flutter`
/// (tested there) — so a host that reports some errors at a single report point of its
/// own cannot have them reported a second time by a channel it forgot.
void main() {
  late _RecordingTransport transport;
  late NoticebirdClient reporter;
  var eventSequence = 0;

  NoticebirdClient client({
    bool Function(Object error)? shouldCapture,
  }) => NoticebirdClient(
    config: NoticebirdConfig(
      privacyProfile: CrashPrivacyProfile.privacyDefault,
      app: const AppMetadata(
        name: 'test',
        version: '1.0.0',
        build: '1',
        release: 'test@1.0.0+1',
      ),
      platform: const PlatformMetadata(
        platform: CrashPlatform.unknown,
        osVersion: 'test',
        deviceClass: 'test',
      ),
      sessionIdFactory: () => 'test_session_1234567890',
      deduplicationWindow: Duration.zero,
      shouldCapture: shouldCapture,
    ),
    transport: transport,
    eventIdFactory: () =>
        '0197f232-2bd8-7000-8000-${(++eventSequence).toString().padLeft(12, '0')}',
  );

  setUp(() {
    eventSequence = 0;
    transport = _RecordingTransport();
    reporter = client(shouldCapture: (error) => error is! _ReportedElsewhere);
  });

  test('an explicit capture of a filtered error is ignored', () async {
    final result = await reporter.captureException(
      const _ReportedElsewhere(),
      StackTrace.current,
    );

    expect(result.outcome, CaptureOutcome.ignored);
    expect(transport.events, isEmpty);
  });

  test('other errors are captured as before', () async {
    final result = await reporter.captureException(
      StateError('boom'),
      StackTrace.current,
    );

    expect(result.outcome, CaptureOutcome.sent);
    expect(transport.events, hasLength(1));
  });

  test('the report point bypasses the filter with filtered: false', () async {
    final result = await reporter.captureException(
      const _ReportedElsewhere(),
      StackTrace.current,
      handled: true,
      filtered: false,
    );

    expect(result.outcome, CaptureOutcome.sent);
    expect(transport.events.single['handled'], isTrue);
  });

  test('the facade forwards filtered: false', () async {
    Noticebird.attach(reporter);
    addTearDown(Noticebird.detach);

    expect(
      (await Noticebird.captureException(
        const _ReportedElsewhere(),
        StackTrace.current,
      ))?.outcome,
      CaptureOutcome.ignored,
    );
    expect(
      (await Noticebird.captureException(
        const _ReportedElsewhere(),
        StackTrace.current,
        filtered: false,
      ))?.outcome,
      CaptureOutcome.sent,
    );
  });

  test('a filter that throws costs no report', () async {
    reporter = client(shouldCapture: (_) => throw StateError('filter bug'));

    final result = await reporter.captureException(
      StateError('boom'),
      StackTrace.current,
    );

    expect(result.outcome, CaptureOutcome.sent);
  });

  test('without a filter every error is captured', () async {
    reporter = client();

    final result = await reporter.captureException(
      const _ReportedElsewhere(),
      StackTrace.current,
    );

    expect(result.outcome, CaptureOutcome.sent);
  });
}
