import 'dart:convert';

import 'package:bloc/bloc.dart';
import 'package:noticebird/noticebird.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

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

final class _FailingCubit extends Cubit<int> {
  _FailingCubit() : super(0);
}

/// One capture filter, set once on the config, that every channel honours —
/// an explicit capture, the bloc observer, the global handlers and the zone of
/// `run` — so a host that reports some errors at a single report point of its
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

  tearDown(() => reporter.uninstallGlobalHandlers());

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

  test('the bloc observer honours the filter', () async {
    final observer = ProtocolNoticebirdBlocObserver(reporter);
    final cubit = _FailingCubit();
    addTearDown(cubit.close);

    observer.onError(cubit, const _ReportedElsewhere(), StackTrace.current);
    observer.onError(cubit, StateError('boom'), StackTrace.current);
    await pumpEventQueue();

    expect(transport.events, hasLength(1));
    expect(transport.events.single['exception']['type'], 'StateError');
  });

  test('FlutterError.onError honours the filter', () async {
    final previous = FlutterError.onError;
    FlutterError.onError = (_) {};
    addTearDown(() => FlutterError.onError = previous);
    reporter.installGlobalHandlers();

    FlutterError.onError!(
      FlutterErrorDetails(exception: const _ReportedElsewhere()),
    );
    FlutterError.onError!(FlutterErrorDetails(exception: StateError('boom')));
    await pumpEventQueue();

    expect(transport.events, hasLength(1));
    expect(transport.events.single['exception']['type'], 'StateError');
  });

  test('the platform dispatcher handler honours the filter', () async {
    final previous = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = null;
    addTearDown(() => PlatformDispatcher.instance.onError = previous);
    reporter.installGlobalHandlers();

    final handled = PlatformDispatcher.instance.onError!(
      const _ReportedElsewhere(),
      StackTrace.current,
    );
    await pumpEventQueue();

    expect(handled, isTrue);
    expect(transport.events, isEmpty);
  });

  test('the zone of run honours the filter', () async {
    final previousFlutter = FlutterError.onError;
    final previousPlatform = PlatformDispatcher.instance.onError;
    addTearDown(() {
      FlutterError.onError = previousFlutter;
      PlatformDispatcher.instance.onError = previousPlatform;
    });

    await reporter.run(() {
      Future<void>.error(const _ReportedElsewhere());
      Future<void>.error(StateError('boom'));
    });
    await pumpEventQueue();

    expect(transport.events, hasLength(1));
    expect(transport.events.single['exception']['type'], 'StateError');
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
