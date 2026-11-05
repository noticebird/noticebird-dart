import 'dart:async';
import 'dart:convert';

import 'package:noticebird/noticebird.dart';
import 'package:test/test.dart';

/// The buffer is the host's trail; an event carries a bounded part of it.
///
/// A host keeps more breadcrumbs than one event may carry
/// ([NoticebirdConfig.breadcrumbBuffer]) and reads them whole
/// ([NoticebirdClient.recentBreadcrumbs]); every event still carries at
/// most [NoticebirdConfig.maxBreadcrumbs], sanitized to the protocol's
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

  List<String?> actions(Iterable<TypedBreadcrumb> crumbs) => [
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
      reporter.addBreadcrumb('Step', action: action);
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
        ..addBreadcrumb('Step', action: 'a.one')
        ..addBreadcrumb('Step', action: 'a.two');
      await capture(reporter, 'first');
      reporter.addBreadcrumb('Step', action: 'a.three');
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
      reporter.addBreadcrumb('Step', action: 'a.one');
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
      reporter.addBreadcrumb('Step', action: 'a.one');
      final gate = Completer<void>();
      transport.gate = gate;
      final first = capture(reporter, 'first');
      reporter.addBreadcrumb('Step', action: 'a.two');
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
      reporter.addBreadcrumb('Step', action: 'a.one');
      final gate = Completer<void>();
      transport.gate = gate;
      final first = capture(reporter, 'first');
      reporter
        ..clearBreadcrumbs()
        ..addBreadcrumb('Step', action: 'a.two');
      gate.complete();
      await first;
      transport.gate = null;

      expect(actions(reporter.recentBreadcrumbs), ['a.two']);
      await capture(reporter, 'second');
      expect(sentActions(transport.events.last), ['a.two']);
    },
  );

  test(
    'the buffer keeps a long message whole; the event shortens it',
    () async {
      final reporter = client(config(breadcrumbBuffer: 10));
      final long = 'x' * (TypedBreadcrumb.maxMessageLength + 50);
      final tooLong = 'y' * (NoticebirdClient.maxBufferedMessageLength + 50);
      reporter
        ..addBreadcrumb(long, action: 'a.long')
        ..addBreadcrumb(tooLong, action: 'a.too_long');

      final buffered = reporter.recentBreadcrumbs;
      expect(buffered.first.message, long);
      expect(
        buffered.last.message.length,
        NoticebirdClient.maxBufferedMessageLength,
      );

      await capture(reporter, 'boom');
      for (final sent in transport.events.single['breadcrumbs']) {
        expect(
          (sent['message'] as String).length,
          TypedBreadcrumb.maxMessageLength,
        );
      }
    },
  );

  test('a message cut for the buffer or the event never splits a pair, '
      'and the event goes', () async {
    final reporter = client(config(breadcrumbBuffer: 10));
    // 1201 code units: the 1000th, and the 200th, the first half of a pair.
    reporter.addBreadcrumb('a${'😀' * 600}', action: 'emoji.typed');

    final buffered = reporter.recentBreadcrumbs.single.message;
    expect(buffered, 'a${'😀' * 499}');
    expect(hasUnpairedSurrogate(buffered), isFalse);

    await capture(reporter, 'boom');
    final step = (transport.events.single['breadcrumbs'] as List).single;
    expect((step as Map)['message'], 'a${'😀' * 99}');
  });

  test('the buffer keeps a step as given; the event sanitizes it', () async {
    final reporter = client(config(breadcrumbBuffer: 10));
    final at = DateTime.utc(2026, 10, 13, 9, 59);
    reporter.addBreadcrumb(
      'Saved\nthe list',
      action: 'list.save',
      category: 'ui',
      level: BreadcrumbLevel.warning,
      details: const {'items.count': 3, 'userEmail': true},
      at: at,
    );

    final buffered = reporter.recentBreadcrumbs.single;
    expect(buffered.message, 'Saved\nthe list');
    expect(buffered.details, {'items.count': 3, 'userEmail': true});
    expect(buffered.at, at);

    await capture(reporter, 'boom');
    final event = transport.events.single;
    expect(event['breadcrumbs'], [
      {
        'at': '2026-10-13T09:59:00.000Z',
        'message': 'Saved the list',
        'action': 'list.save',
        'category': 'ui',
        'level': 'warning',
        'details': {'items.count': 3},
      },
    ]);
    expect(event['breadcrumbDrops'], {'detailsDropped': 1, 'stepsDropped': 0});
  });

  test('a step without a time is stamped by the clock', () async {
    final reporter = client(config());
    reporter.addBreadcrumb('Started');
    expect(
      reporter.recentBreadcrumbs.single.at,
      DateTime.utc(2026, 10, 13, 10),
    );
    await capture(reporter, 'boom');
    expect(transport.events.single['breadcrumbs'], [
      {'at': '2026-10-13T10:00:00.000Z', 'message': 'Started'},
    ]);
    expect(transport.events.single, isNot(contains('breadcrumbDrops')));
  });

  test('an event keeps the newest steps that fit 16 KiB, and counts the '
      'rest', () async {
    final reporter = client(config(maxBreadcrumbs: CrashEvent.maxBreadcrumbs));
    for (var i = 0; i < CrashEvent.maxBreadcrumbs; i++) {
      reporter.addBreadcrumb(
        '${'m' * 190} $i',
        action: 'a.step$i',
        details: {for (var e = 0; e < 3; e++) 'name$e': 'v' * 40},
      );
    }

    await capture(reporter, 'boom');
    final event = transport.events.single;
    final sent = sentActions(event);
    final kept = sent.length;
    expect(kept, lessThan(CrashEvent.maxBreadcrumbs));
    expect(sent.last, 'a.step${CrashEvent.maxBreadcrumbs - 1}');
    expect(sent.first, 'a.step${CrashEvent.maxBreadcrumbs - kept}');
    expect(
      utf8.encode(canonicalJsonEncode(event['breadcrumbs'])).length,
      lessThanOrEqualTo(CrashEvent.maxBreadcrumbsBytes),
    );
    expect(event['breadcrumbDrops'], {
      'detailsDropped': 0,
      'stepsDropped': CrashEvent.maxBreadcrumbs - kept,
    });
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
