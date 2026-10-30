import 'dart:async';
import 'dart:convert';

import 'package:noticebird/noticebird.dart';
import 'package:flutter_test/flutter_test.dart';

/// The buffer is the host's trail; an event carries a bounded part of it.
///
/// A host keeps more breadcrumbs than one event may carry
/// ([NoticebirdConfig.breadcrumbBuffer]) and reads them whole
/// ([NoticebirdClient.recentBreadcrumbs]); every event still carries at
/// most [NoticebirdConfig.maxBreadcrumbs], shortened to the protocol's
/// limits, and never the breadcrumbs an earlier sent event carried.
void main() {
  late _RecordingTransport transport;

  NoticebirdConfig config({int maxBreadcrumbs = 3, int? breadcrumbBuffer}) =>
      NoticebirdConfig(
        privacyProfile: CrashPrivacyProfile.privacyDefault,
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
        maxBreadcrumbs: maxBreadcrumbs,
        breadcrumbBuffer: breadcrumbBuffer,
      );

  var eventSequence = 0;
  NoticebirdClient client(NoticebirdConfig config) => NoticebirdClient(
    config: config,
    transport: transport,
    clock: () => DateTime.utc(2026, 10, 13, 10),
    eventIdFactory: () =>
        '0197f232-2bd8-7000-8000-${(++eventSequence).toString().padLeft(12, '0')}',
  );

  TypedBreadcrumb crumb(String action, {String? operation}) => TypedBreadcrumb(
    occurredAt: DateTime.utc(2026, 10, 13),
    category: BreadcrumbCategory.navigation,
    action: action,
    data: {if (operation != null) AllowedTag.operation: operation},
  );

  List<String> actions(Iterable<TypedBreadcrumb> crumbs) => [
    for (final crumb in crumbs) crumb.action,
  ];

  /// The actions of the breadcrumbs [event] carries.
  List<String> sentActions(Map<String, dynamic> event) => [
    for (final crumb in event['breadcrumbs'] as List) crumb['action'] as String,
  ];

  Future<void> capture(NoticebirdClient reporter, String message) =>
      reporter.captureException(StateError(message), StackTrace.empty);

  setUp(() {
    eventSequence = 0;
    transport = _RecordingTransport();
  });

  group('config', () {
    test('the buffer defaults to what one event carries', () {
      expect(config(maxBreadcrumbs: 7).breadcrumbBuffer, 7);
      expect(
        NoticebirdConfig(
          privacyProfile: CrashPrivacyProfile.privacyDefault,
          app: const AppMetadata(
            name: 'test-app',
            version: '1.0.0',
            build: '1',
            release: 'test-app@1.0.0+1',
          ),
        ).breadcrumbBuffer,
        CrashEvent.maxBreadcrumbs,
      );
    });

    test('an event carries no more than the protocol allows', () {
      expect(
        () => config(maxBreadcrumbs: CrashEvent.maxBreadcrumbs + 1),
        throwsArgumentError,
      );
    });

    test('the buffer is at least one event and at most its maximum', () {
      expect(
        () => config(maxBreadcrumbs: 5, breadcrumbBuffer: 4),
        throwsArgumentError,
      );
      expect(
        () =>
            config(breadcrumbBuffer: NoticebirdConfig.maxBreadcrumbBuffer + 1),
        throwsArgumentError,
      );
      expect(
        config(
          breadcrumbBuffer: NoticebirdConfig.maxBreadcrumbBuffer,
        ).breadcrumbBuffer,
        NoticebirdConfig.maxBreadcrumbBuffer,
      );
    });
  });

  test('the buffer keeps more than an event carries', () async {
    final reporter = client(config(maxBreadcrumbs: 2, breadcrumbBuffer: 4));
    for (final action in ['a.one', 'a.two', 'a.three', 'a.four', 'a.five']) {
      reporter.addBreadcrumb(crumb(action));
    }

    expect(actions(reporter.recentBreadcrumbs), [
      'a.two',
      'a.three',
      'a.four',
      'a.five',
    ]);

    await capture(reporter, 'boom');
    expect(sentActions(transport.events.single), ['a.four', 'a.five']);
  });

  test(
    'a sent event keeps the trail, and the next event starts after it',
    () async {
      final reporter = client(config(breadcrumbBuffer: 10));
      reporter
        ..addBreadcrumb(crumb('a.one'))
        ..addBreadcrumb(crumb('a.two'));
      await capture(reporter, 'first');
      reporter.addBreadcrumb(crumb('a.three'));
      await capture(reporter, 'second');

      expect(actions(reporter.recentBreadcrumbs), [
        'a.one',
        'a.two',
        'a.three',
      ]);
      expect(sentActions(transport.events.first), ['a.one', 'a.two']);
      expect(sentActions(transport.events.last), ['a.three']);
    },
  );

  test(
    'an event that could not be sent leaves its breadcrumbs unsent',
    () async {
      final reporter = client(config(breadcrumbBuffer: 10));
      reporter.addBreadcrumb(crumb('a.one'));
      transport.failNext = true;
      expect(
        (await reporter.captureException(
          StateError('x'),
          StackTrace.empty,
        )).outcome,
        CaptureOutcome.queued,
      );

      await capture(reporter, 'again');
      expect(sentActions(transport.events.single), ['a.one']);
    },
  );

  test(
    'a breadcrumb recorded while an event is in flight is not sent with it',
    () async {
      final reporter = client(config(breadcrumbBuffer: 10));
      reporter.addBreadcrumb(crumb('a.one'));
      final gate = Completer<void>();
      transport.gate = gate;
      final first = capture(reporter, 'first');
      reporter.addBreadcrumb(crumb('a.two'));
      gate.complete();
      await first;
      transport.gate = null;

      await capture(reporter, 'second');
      expect(sentActions(transport.events.first), ['a.one']);
      expect(sentActions(transport.events.last), ['a.two']);
    },
  );

  test(
    'clearBreadcrumbs forgets the trail, also for an event in flight',
    () async {
      final reporter = client(config(breadcrumbBuffer: 10));
      reporter.addBreadcrumb(crumb('a.one'));
      final gate = Completer<void>();
      transport.gate = gate;
      final first = capture(reporter, 'first');
      reporter
        ..clearBreadcrumbs()
        ..addBreadcrumb(crumb('a.two'));
      gate.complete();
      await first;
      transport.gate = null;

      expect(actions(reporter.recentBreadcrumbs), ['a.two']);
      await capture(reporter, 'second');
      expect(sentActions(transport.events.last), ['a.two']);
    },
  );

  test('the buffer keeps a long label whole; the event shortens it', () async {
    final reporter = client(config(breadcrumbBuffer: 10));
    final long = 'x' * (maxTagValueLength + 50);
    final tooLong = 'y' * (NoticebirdClient.maxBufferedTagValueLength + 50);
    reporter
      ..addBreadcrumb(crumb('a.long', operation: long))
      ..addBreadcrumb(crumb('a.too_long', operation: tooLong));

    final buffered = reporter.recentBreadcrumbs;
    expect(buffered.first.data[AllowedTag.operation], long);
    final bounded = buffered.last.data[AllowedTag.operation]! as String;
    expect(bounded.length, NoticebirdClient.maxBufferedTagValueLength);
    expect(bounded, endsWith('…'));

    await capture(reporter, 'boom');
    for (final sent in transport.events.single['breadcrumbs']) {
      final value = sent['data']['operation'] as String;
      expect(value.length, maxTagValueLength);
      expect(value, endsWith('…'));
    }
  });
}

final class _RecordingTransport implements CrashTransport {
  final events = <Map<String, dynamic>>[];
  bool failNext = false;
  Completer<void>? gate;

  @override
  Future<void> send(String eventJson) async {
    await gate?.future;
    if (failNext) {
      failNext = false;
      throw StateError('offline');
    }
    events.add(jsonDecode(eventJson) as Map<String, dynamic>);
  }
}
