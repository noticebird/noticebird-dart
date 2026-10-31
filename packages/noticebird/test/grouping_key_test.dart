import 'dart:convert';

import 'package:noticebird/noticebird.dart';
import 'package:test/test.dart';

import 'support/privacy_matches.dart';

/// A host's own grouping key ([NoticebirdClient.captureException]'s
/// `groupingKey`) reaches the event as the protocol allows it, and decides
/// the client's deduplication.
void main() {
  const uuid = '7d3f1c2a-9b4e-4f6a-8c1d-2e3f4a5b6c7d';
  late _RecordingTransport transport;
  var eventSequence = 0;

  NoticebirdClient client({
    CrashPrivacyProfile profile = CrashPrivacyProfile.privacyDefault,
    Duration deduplicationWindow = Duration.zero,
  }) => NoticebirdClient(
    config: NoticebirdConfig(
      privacyProfile: profile,
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
      deduplicationWindow: deduplicationWindow,
    ),
    transport: transport,
    clock: () => DateTime.utc(2026, 10, 27, 10),
    eventIdFactory: () =>
        '0197f232-2bd8-7000-8000-${(++eventSequence).toString().padLeft(12, '0')}',
  );

  final stack = StackTrace.fromString(
    '#0 Sync.push (package:app/sync.dart:1:2)',
  );

  setUp(() {
    transport = _RecordingTransport();
    eventSequence = 0;
  });

  test('the key reaches the event', () async {
    final reporter = client();
    await reporter.captureException(
      StateError('refused'),
      stack,
      groupingKey: const ['sync-refusal', '23505'],
    );

    expect(transport.events.single['groupingKey'], ['sync-refusal', '23505']);
  });

  test('without a key the event carries none', () async {
    await client().captureException(StateError('refused'), stack);

    expect(transport.events.single, isNot(contains('groupingKey')));
  });

  test('the key decides deduplication', () async {
    final reporter = client(deduplicationWindow: const Duration(minutes: 1));

    expect(
      (await reporter.captureException(
        StateError('refused'),
        stack,
        groupingKey: const ['sync-refusal', '23505'],
      )).outcome,
      CaptureOutcome.sent,
    );
    // The same stack under another key is another issue.
    expect(
      (await reporter.captureException(
        StateError('refused'),
        stack,
        groupingKey: const ['sync-refusal', '42501'],
      )).outcome,
      CaptureOutcome.sent,
    );
    // Another error under the same key is the same issue.
    expect(
      (await reporter.captureException(
        ArgumentError('other'),
        StackTrace.fromString('#0 Other.call (package:app/other.dart:9:9)'),
        groupingKey: const ['sync-refusal', '23505'],
      )).outcome,
      CaptureOutcome.deduplicated,
    );
    expect(transport.events, hasLength(2));
  });

  test(
    'a part a redaction pattern matches is redacted, not the report lost',
    () async {
      await client().captureException(
        StateError('refused'),
        stack,
        groupingKey: const [
          'sync-refusal',
          'row $uuid',
          'by person@example.com',
        ],
      );

      final event = transport.events.single;
      final key = event['groupingKey'] as List;
      expect(key, hasLength(3));
      expect(key.first, 'sync-refusal');
      expect(key.skip(1).join(), isNot(contains(uuid)));
      expect(key.join(), isNot(contains('person@example.com')));
      expect(privacyMatches(event), isEmpty);
    },
  );

  test('a key past the protocol\'s bounds is cut to fit', () async {
    await client().captureException(
      StateError('refused'),
      stack,
      groupingKey: [
        'p' * (CrashEvent.maxGroupingKeyPartLength + 20),
        '',
        for (var i = 0; i < CrashEvent.maxGroupingKeyParts + 2; i++) 'part$i',
      ],
    );

    final key = transport.events.single['groupingKey'] as List;
    expect(key, hasLength(CrashEvent.maxGroupingKeyParts));
    expect(key.first, hasLength(CrashEvent.maxGroupingKeyPartLength));
    expect(key, isNot(contains('')));
    expect(key.last, 'part${CrashEvent.maxGroupingKeyParts - 2}');
  });

  test('a key with no part left is no key', () async {
    final result = await client().captureException(
      StateError('refused'),
      stack,
      groupingKey: const ['', ''],
    );

    expect(result.outcome, CaptureOutcome.sent);
    expect(transport.events.single, isNot(contains('groupingKey')));
  });

  test('regulatedStrict keeps the key, as it keeps tags', () async {
    await client(profile: CrashPrivacyProfile.regulatedStrict).captureException(
      StateError('refused'),
      stack,
      groupingKey: const ['sync-refusal', '23505'],
    );

    expect(transport.events.single['groupingKey'], ['sync-refusal', '23505']);
  });

  // As 0.2.0 deduplicated: by the type, the app's name and the top 8 lines
  // that name a `package:`, each without its frame number, line and column.
  group('without a key, the type and the top app frames decide '
      'deduplication', () {
    Future<List<CaptureOutcome>> outcomes(
      List<(Object, String)> captures,
    ) async {
      final reporter = client(deduplicationWindow: const Duration(minutes: 1));
      return [
        for (final (error, stack) in captures)
          (await reporter.captureException(
            error,
            StackTrace.fromString(stack),
          )).outcome,
      ];
    }

    test('the same type at two lines of one function is one error', () async {
      expect(
        await outcomes([
          (StateError('a'), '#0 Sync.push (package:app/sync.dart:10:3)'),
          (StateError('b'), '#0 Sync.push (package:app/sync.dart:14:7)'),
          // Another function is another error.
          (StateError('c'), '#0 Sync.pull (package:app/sync.dart:14:7)'),
        ]),
        [CaptureOutcome.sent, CaptureOutcome.deduplicated, CaptureOutcome.sent],
      );
    });

    test('frame numbers do not count', () async {
      expect(
        await outcomes([
          (StateError('a'), '#3 Sync.push (package:app/sync.dart:10:3)'),
          (StateError('a'), '#5 Sync.push (package:app/sync.dart:10:3)'),
        ]),
        [CaptureOutcome.sent, CaptureOutcome.deduplicated],
      );
    });

    test('the frames below the top 8 do not count', () async {
      String stack(String below) => [
        for (var i = 0; i < 8; i++)
          '#$i Step$i.run (package:app/step$i.dart:${i + 1}:1)',
        '#8 $below (package:app/below.dart:1:1)',
      ].join('\n');

      expect(
        await outcomes([
          (StateError('a'), stack('First.call')),
          (StateError('a'), stack('Second.call')),
        ]),
        [CaptureOutcome.sent, CaptureOutcome.deduplicated],
      );
    });

    test('a dart2js stack, with no package: frame, is deduplicated by its '
        'type alone', () async {
      expect(
        await outcomes([
          (
            StateError('a'),
            'at cOy.\$0 (https://app.example.com/main.dart.js:375562:14)',
          ),
          (
            StateError('b'),
            'at dPz.\$1 (https://app.example.com/main.dart.js:1200:2)',
          ),
          (
            ArgumentError('c'),
            'at dPz.\$1 (https://app.example.com/main.dart.js:1200:2)',
          ),
        ]),
        [CaptureOutcome.sent, CaptureOutcome.deduplicated, CaptureOutcome.sent],
      );
    });
  });
}

final class _RecordingTransport implements CrashTransport {
  final events = <Map<String, dynamic>>[];

  @override
  Future<void> send(String eventJson) async {
    events.add(jsonDecode(eventJson) as Map<String, dynamic>);
  }
}
