import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:noticebird/noticebird.dart';
import 'package:noticebird/src/protocol/crash_exception_type.dart';
import 'package:noticebird/src/protocol/host_mistakes.dart';
import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/privacy_matches.dart';

void main() {
  late _RecordingTransport transport;
  late NoticebirdClient reporter;
  var eventSequence = 0;

  NoticebirdConfig config({
    CrashPrivacyProfile profile = CrashPrivacyProfile.regulatedStrict,
    CrashOfflineStore? store,
    int maxPendingEvents = 3,
    String sessionId = 'random_session_123456',
    Duration deduplicationWindow = Duration.zero,
    CrashPiiConfig pii = const CrashPiiConfig(),
    bool Function(Object error)? shouldCapture,
  }) => NoticebirdConfig(
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
    sessionIdFactory: () => sessionId,
    maxPendingEvents: maxPendingEvents,
    offlineStore: store,
    deduplicationWindow: deduplicationWindow,
    pii: pii,
    shouldCapture: shouldCapture,
  );

  setUp(() {
    eventSequence = 0;
    transport = _RecordingTransport();
    reporter = NoticebirdClient(
      config: config(),
      transport: transport,
      clock: () => DateTime.utc(2026, 7, 11, 10, 15),
      eventIdFactory: () =>
          '0197f232-2bd8-7000-8000-${(++eventSequence).toString().padLeft(12, '0')}',
    );
  });

  test(
    'regulatedStrict never sends PII, tokens, health, or provider data',
    () async {
      reporter.setUser(
        const CrashUser(
          id: 'patient-123',
          email: 'strict-user@example.com',
          name: 'Strict User',
          ipAddress: '203.0.113.20',
        ),
      );
      reporter.addBreadcrumb(
        TypedBreadcrumb(
          occurredAt: DateTime.utc(2026, 7, 11),
          category: BreadcrumbCategory.bloc,
          action: 'bloc.change',
          data: const {
            AllowedTag.component: 'PatientCubit user@example.com',
            AllowedTag.operation: 'PatientLoaded glucose=12.4',
          },
        ),
      );

      await reporter.captureException(
        StateError(
          'user@example.com Bearer eyJabc.eyJdef.signature '
          'patient=0197f232-2bd8-7000-8000-000000000099 '
          'glucose=12.4 Fitbit Google',
        ),
        StackTrace.fromString(
          '#0 PatientCubit.load (package:app/patient_cubit.dart:42:7)\n'
          'raw user@example.com glucose=12.4',
        ),
        tags: const {AllowedTag.component: 'Bearer eyJabc.eyJdef.signature'},
        extra: const {
          'retry_count': 2,
          'heart_rate': 180,
          'nested': {'patient_id': 'patient-123', 'phase': 'load'},
        },
      );

      final payload = transport.bodies.single.toLowerCase();
      for (final canary in [
        'user@example.com',
        'eyjabc',
        '0197f232-2bd8-7000-8000-000000000099',
        'glucose=12.4',
      ]) {
        expect(payload, isNot(contains(canary)));
      }
      expect(
        transport.events.single['exception']['sanitizedMessage'],
        'StateError',
      );
      expect(transport.events.single['user'], isNull);
      expect(
        transport.events.single['breadcrumbs'].single['data']['component'],
        'PatientCubit [REDACTED]',
      );
      expect(
        transport.events.single,
        isNot(contains('extra')),
        reason: 'regulatedStrict must never transmit arbitrary context',
      );
      expect(payload, contains('[redacted]'));
    },
  );

  test(
    'privacyDefault sends consumer-supplied PII without extra opt-in',
    () async {
      reporter = NoticebirdClient(
        config: config(profile: CrashPrivacyProfile.privacyDefault),
        transport: transport,
        clock: () => DateTime.utc(2026, 7, 11, 10, 15),
        eventIdFactory: () => '0197f232-2bd8-7000-8000-00000000cafe',
      );
      reporter.setUser(
        const CrashUser(
          id: 'user-123',
          email: 'person@example.com',
          name: 'Must Not Leave Device',
          ipAddress: '203.0.113.10',
        ),
      );

      await reporter.captureException(
        StateError('failed'),
        StackTrace.fromString('#0 A.b (package:app/a.dart:1:2)'),
        extra: const {'http_status': 503, 'email_canary': 'other@example.com'},
      );

      final event = transport.events.single;
      expect(event['user'], {
        'id': 'user-123',
        'email': 'person@example.com',
        'name': 'Must Not Leave Device',
        'ipAddress': '203.0.113.10',
      });
      expect(event['extra']['http_status'], 503);
      expect(event['extra'], isNot(contains('email_canary')));
    },
  );

  test('consumer can explicitly disable PII', () async {
    reporter = NoticebirdClient(
      config: config(
        profile: CrashPrivacyProfile.privacyDefault,
        pii: const CrashPiiConfig(enabled: false),
      ),
      transport: transport,
      eventIdFactory: () => '0197f232-2bd8-7000-8000-00000000dead',
    );
    reporter.setUser(const CrashUser(email: 'person@example.com'));

    await reporter.captureException(StateError('failed'), StackTrace.empty);

    expect(transport.events.single['user'], isNull);
  });

  test('an over-long capture tag is shortened, not the report lost', () async {
    // The same rule breadcrumbs follow: a tag value past the protocol limit
    // used to fail validation at capture time and drop the whole event.
    final defaultReporter = NoticebirdClient(
      config: config(profile: CrashPrivacyProfile.privacyDefault),
      transport: transport,
      clock: () => DateTime.utc(2026, 7, 11, 10, 15),
      eventIdFactory: () => '0197f232-2bd8-7000-8000-00000000abcd',
    );
    final result = await defaultReporter.captureException(
      StateError('x'),
      StackTrace.current,
      tags: {AllowedTag.component: 'c' * (maxTagValueLength + 50)},
    );

    expect(result.outcome, CaptureOutcome.sent);
    final component = transport.events.single['tags']['component'];
    expect(component, isA<String>());
    expect((component as String).length, maxTagValueLength);
    expect(component, endsWith('…'));
  });

  // The rule the feedback trail follows: a breadcrumb the protocol refuses
  // used to fail validation at capture time and drop the whole event.
  for (final (name, refused) in [
    ('an action outside the pattern', _crumb('Route.Push')),
    (
      'an action over ${TypedBreadcrumb.maxActionLength} characters',
      _crumb('a' * (TypedBreadcrumb.maxActionLength + 1)),
    ),
    (
      'a NaN data value',
      _crumb('list.load', data: const {AllowedTag.operation: double.nan}),
    ),
  ]) {
    test('a breadcrumb the protocol refuses ($name) is left out alone, not '
        'the event lost', () async {
      reporter
        ..addBreadcrumb(_crumb('route.push'))
        ..addBreadcrumb(refused)
        ..addBreadcrumb(_crumb('route.pop'));

      final result = await reporter.captureException(
        StateError('boom'),
        StackTrace.fromString('#0 A.b (package:app/a.dart:1:1)'),
      );

      expect(result.outcome, CaptureOutcome.sent);
      expect(
        [
          for (final breadcrumb in transport.events.single['breadcrumbs'])
            breadcrumb['action'],
        ],
        ['route.push', 'route.pop'],
      );
    });
  }

  test('invalid or excessive free context cannot poison crash capture', () async {
    reporter = NoticebirdClient(
      config: config(profile: CrashPrivacyProfile.custom),
      transport: transport,
      clock: () => DateTime.utc(2026, 7, 11, 10, 15),
      eventIdFactory: () =>
          '0197f232-2bd8-7000-8000-${(++eventSequence).toString().padLeft(12, '0')}',
    );
    final result = await reporter.captureException(
      StateError('failed'),
      StackTrace.fromString('#0 A.b (package:app/a.dart:1:2)'),
      extra: {
        'retry_count': 2,
        'unsupported': DateTime.utc(2026),
        'non_finite': double.nan,
        'invalid key': true,
        'items': List<int>.generate(25, (index) => index),
        'nested': {
          'level_two': {
            'level_three': {'too_deep': true},
          },
        },
      },
    );

    expect(result.outcome, CaptureOutcome.sent);
    final extra = transport.events.single['extra'];
    expect(extra['retry_count'], 2);
    expect(extra, isNot(contains('unsupported')));
    expect(extra, isNot(contains('non_finite')));
    expect(extra, isNot(contains('invalid key')));
    expect(extra['items'], hasLength(CrashEvent.maxExtraEntries));
  });

  test('transport failures are bounded and never escape', () async {
    transport.failure = StateError('offline');
    for (var i = 0; i < 5; i++) {
      expect(
        (await reporter.captureException(
          StateError('failure $i'),
          StackTrace.fromString('#0 A.b (package:app/a.dart:$i:1)'),
        )).outcome,
        CaptureOutcome.queued,
      );
    }
    expect(reporter.pendingCount, 3);
  });

  test(
    'identical crashes inside the deduplication window are suppressed',
    () async {
      final dedupReporter = NoticebirdClient(
        config: config(deduplicationWindow: const Duration(minutes: 1)),
        transport: transport,
        clock: () => DateTime.utc(2026, 7, 11, 10, 15),
        eventIdFactory: () => '0197f232-2bd8-7000-8000-00000000abcd',
      );
      final stack = StackTrace.fromString('#0 A.b (package:app/a.dart:1:1)');
      expect(
        (await dedupReporter.captureException(StateError('x'), stack)).outcome,
        CaptureOutcome.sent,
      );
      expect(
        (await dedupReporter.captureException(StateError('x'), stack)).outcome,
        CaptureOutcome.deduplicated,
      );
      expect(transport.events, hasLength(1));
    },
  );

  test('deduplication state evicts the oldest errors', () async {
    final dedupReporter = NoticebirdClient(
      config: config(deduplicationWindow: const Duration(minutes: 1)),
      transport: transport,
      clock: () => DateTime.utc(2026, 7, 11, 10, 15),
      eventIdFactory: () =>
          '0197f232-2bd8-7000-8000-${(++eventSequence).toString().padLeft(12, '0')}',
    );
    for (var i = 0; i <= 100; i++) {
      expect(
        (await dedupReporter.captureException(
          StateError('unique-$i'),
          StackTrace.fromString('#0 A.b$i (package:app/a.dart:1:1)'),
        )).outcome,
        CaptureOutcome.sent,
      );
    }

    expect(
      (await dedupReporter.captureException(
        StateError('unique-0'),
        StackTrace.fromString('#0 A.b0 (package:app/a.dart:1:1)'),
      )).outcome,
      CaptureOutcome.sent,
      reason: 'the oldest error must be evicted at the hard cap',
    );
  });

  group('the event id of a capture', () {
    final stack = StackTrace.fromString('#0 A.b (package:app/a.dart:1:1)');

    NoticebirdClient dedupClient({
      int maxPendingEvents = 3,
    }) => NoticebirdClient(
      config: config(
        deduplicationWindow: const Duration(minutes: 1),
        maxPendingEvents: maxPendingEvents,
      ),
      transport: transport,
      clock: () => DateTime.utc(2026, 7, 11, 10, 15),
      eventIdFactory: () =>
          '0197f232-2bd8-7000-8000-${(++eventSequence).toString().padLeft(12, '0')}',
    );

    test('a sent event gives its id', () async {
      final result = await reporter.captureException(StateError('x'), stack);
      expect(
        result,
        CaptureResult(
          CaptureOutcome.sent,
          eventId: transport.events.single['eventId'],
        ),
      );
      expect(result.eventId, '0197f232-2bd8-7000-8000-000000000001');
    });

    test('a queued event gives its id, the one flush sends', () async {
      transport.failure = StateError('offline');
      final result = await reporter.captureException(StateError('x'), stack);
      expect(result.outcome, CaptureOutcome.queued);
      expect(result.eventId, '0197f232-2bd8-7000-8000-000000000001');

      transport.failure = null;
      await reporter.flush();
      expect(transport.events.single['eventId'], result.eventId);
    });

    test('a deduplicated event gives the id of the event it repeats', () async {
      final dedupReporter = dedupClient();
      final first = await dedupReporter.captureException(
        StateError('x'),
        stack,
      );
      final repeat = await dedupReporter.captureException(
        StateError('x'),
        stack,
      );
      expect(repeat.outcome, CaptureOutcome.deduplicated);
      expect(repeat.eventId, first.eventId);
      expect(repeat.eventId, transport.events.single['eventId']);
    });

    test('an event repeating a dropped one gives no id', () async {
      final dedupReporter = dedupClient(maxPendingEvents: 0);
      transport.failure = StateError('offline');
      final first = await dedupReporter.captureException(
        StateError('x'),
        stack,
      );
      expect(first, const CaptureResult(CaptureOutcome.dropped));

      transport.failure = null;
      final repeat = await dedupReporter.captureException(
        StateError('x'),
        stack,
      );
      expect(repeat, const CaptureResult(CaptureOutcome.deduplicated));
      expect(transport.events, isEmpty);
    });

    test('an ignored error gives no id', () async {
      final filtering = NoticebirdClient(
        config: config(shouldCapture: (error) => error is! StateError),
        transport: transport,
      );
      final result = await filtering.captureException(StateError('x'), stack);
      expect(result, const CaptureResult(CaptureOutcome.ignored));
      expect(result.eventId, isNull);
    });
  });

  test('fallback event ids are protocol-valid and unique', () async {
    final defaultReporter = NoticebirdClient(
      config: config(),
      transport: transport,
    );
    await defaultReporter.captureException(
      StateError('a'),
      StackTrace.fromString('#0 A.b (package:app/a.dart:1:1)'),
    );
    await defaultReporter.captureException(
      StateError('b'),
      StackTrace.fromString('#0 C.d (package:app/c.dart:2:2)'),
    );
    final ids = [
      for (final event in transport.events) event['eventId'] as String,
    ];
    expect(ids.toSet(), hasLength(2));
    for (final id in ids) {
      expect(RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(id), isTrue);
    }
  });

  test('close() leaves an injected http client open', () {
    final httpClient = _ClosableClient();
    CrashHttpTransport(
      apiUrl: Uri.parse('https://ingest.example.com'),
      publishableKey: 'crash_pk_test0000000000000000',
      httpClient: httpClient,
    ).close();
    expect(httpClient.closed, isFalse);
  });

  test('HTTP transport posts to the envelope route below the API URL, a '
      "proxy's path prefix kept", () async {
    for (final (apiUrl, envelope) in [
      (
        CrashHttpTransport.hostedApiUrl,
        'https://api.noticebird.com/v1/envelope',
      ),
      (
        Uri.parse('https://proxy.example.com/noticebird/'),
        'https://proxy.example.com/noticebird/v1/envelope',
      ),
      (Uri.parse('http://localhost:8080'), 'http://localhost:8080/v1/envelope'),
      (
        Uri.parse('https://proxy.example.com:8443/v1x//'),
        'https://proxy.example.com:8443/v1x/v1/envelope',
      ),
    ]) {
      final httpClient = _RequestRecordingClient();
      final reporter = NoticebirdClient(
        config: config(),
        transport: CrashHttpTransport(
          apiUrl: apiUrl,
          publishableKey: 'crash_pk_test0000000000000000',
          httpClient: httpClient,
        ),
      );

      await reporter.captureException(
        StateError('api url'),
        StackTrace.fromString('#0 A.b (package:app/a.dart:1:1)'),
      );

      expect(httpClient.requestUri, Uri.parse(envelope), reason: '$apiUrl');
    }
  });

  test('HTTP transport refuses an API URL it cannot send to, the envelope '
      'URL itself included', () {
    for (final apiUrl in [
      'https://api.noticebird.com/v1/envelope',
      'https://api.noticebird.com/v1/envelope/',
      'https://api.noticebird.com/v1',
      'https://api.noticebird.com/v1/feedback',
      'https://user:secret@api.noticebird.com',
      'ftp://api.noticebird.com',
      'https://api.noticebird.com?key=x',
      'https://api.noticebird.com#top',
      '/v1',
      '',
    ]) {
      expect(
        () => CrashHttpTransport(
          apiUrl: Uri.parse(apiUrl),
          publishableKey: 'crash_pk_test0000000000000000',
        ),
        throwsArgumentError,
        reason: apiUrl,
      );
    }
  });

  test('HTTP transport sends the key as a bearer token', () async {
    final httpClient = _RequestRecordingClient();
    final bearerReporter = NoticebirdClient(
      config: config(),
      transport: CrashHttpTransport(
        apiUrl: CrashHttpTransport.hostedApiUrl,
        publishableKey: 'crash_pk_test0000000000000000',
        httpClient: httpClient,
      ),
    );

    await bearerReporter.captureException(
      StateError('bearer'),
      StackTrace.fromString('#0 A.b (package:app/a.dart:1:1)'),
    );

    expect(
      httpClient.requestHeaders?['authorization'],
      'Bearer crash_pk_test0000000000000000',
    );
  });

  test('HTTP transport accepts a publishable key under any prefix', () {
    for (final key in [
      'crash_pk_test0000000000000000',
      // The prefix the platform issues.
      'noticebird_pk_test0000000000000000',
      'acme2_pk_test0000000000000000',
    ]) {
      expect(
        () => CrashHttpTransport(
          apiUrl: CrashHttpTransport.hostedApiUrl,
          publishableKey: key,
        ).close(),
        returnsNormally,
        reason: key,
      );
    }
  });

  test('HTTP transport rejects anything but a publishable key', () {
    for (final key in [
      'crash_sk_test0000',
      'noticebird_sk_test0000',
      'acme_sk_test0000',
      'pk_test0000000000000000',
      'crash_pk_',
      'Crash_pk_test0000000000000000',
      'crash_pk_test 0000000000000000',
      '',
    ]) {
      expect(
        () => CrashHttpTransport(
          apiUrl: CrashHttpTransport.hostedApiUrl,
          publishableKey: key,
        ),
        throwsArgumentError,
        reason: key,
      );
    }
  });

  test('strict mode rejects an unencrypted offline store', () {
    expect(
      () => config(store: _MemoryStore(isEncrypted: false)),
      throwsArgumentError,
    );
    expect(
      () => config(store: _MemoryStore(isEncrypted: true)),
      returnsNormally,
    );
  });

  test('raw identifier routes are rejected and templates are accepted', () {
    expect(
      () => reporter.setRouteTemplate(
        '/lists/0197f232-2bd8-7000-8000-000000000099',
      ),
      throwsArgumentError,
    );
    expect(() => reporter.setRouteTemplate('/lists/:listId'), returnsNormally);
  });

  test('a release build drops a raw route instead of throwing', () async {
    debugHostMistakesThrow = false;
    addTearDown(() => debugHostMistakesThrow = isDebugBuild);
    final release = NoticebirdClient(
      config: config(),
      transport: transport,
      clock: () => DateTime.utc(2026, 7, 11, 10, 15),
    )..setRouteTemplate('/lists/:listId');

    expect(
      () => release.setRouteTemplate(
        '/lists/0197f232-2bd8-7000-8000-000000000099',
      ),
      returnsNormally,
    );
    await release.captureException(StateError('boom'), StackTrace.empty);
    expect(transport.events.single, isNot(contains('routeTemplate')));
  });

  test(
    'offline flush must not duplicate events already pending in memory',
    () async {
      final store = _MemoryStore(isEncrypted: true);
      final flaky = _RecordingTransport()..failure = StateError('offline');
      final offlineReporter = NoticebirdClient(
        config: config(store: store),
        transport: flaky,
        clock: () => DateTime.utc(2026, 7, 11, 10, 15),
        eventIdFactory: () => '0197f232-2bd8-7000-8000-00000000abcd',
      );
      await offlineReporter.captureException(
        StateError('boom'),
        StackTrace.fromString('#0 A.b (package:app/a.dart:1:1)'),
      );
      expect(offlineReporter.pendingCount, 1);

      // Still offline: flushing must not merge the persisted copy back in as a
      // second queue entry.
      await offlineReporter.flush();
      expect(
        offlineReporter.pendingCount,
        1,
        reason: 'offline flush must not grow the queue',
      );

      flaky.failure = null;
      await offlineReporter.flush();
      expect(offlineReporter.pendingCount, 0);
      expect(
        flaky.events,
        hasLength(1),
        reason: 'each event is delivered exactly once',
      );
    },
  );

  test('a flush keeps the stored events in the store while it sends '
      'them', () async {
    final store = _MemoryStore(isEncrypted: true);
    await NoticebirdClient(
      config: config(store: store),
      transport: _RecordingTransport()..failure = StateError('offline'),
      clock: () => DateTime.utc(2026, 7, 11, 10, 15),
    ).captureException(
      StateError('boom'),
      StackTrace.fromString('#0 A.b (package:app/a.dart:1:1)'),
    );
    expect(store.values, hasLength(1));

    final blocking = _BlockingTransport();
    final flushing = NoticebirdClient(
      config: config(store: store),
      transport: blocking,
    ).flush();
    await pumpEventQueue();
    expect(blocking.started, 1);
    // A process killed during the send keeps what the store holds now.
    expect(store.values, hasLength(1));

    blocking.release();
    await flushing;
    expect(store.values, isEmpty);
  });

  test('a flush sends a stored event as the client wrote it', () async {
    final store = _MemoryStore(isEncrypted: true);
    await NoticebirdClient(
      config: config(store: store),
      transport: _RecordingTransport()..failure = StateError('offline'),
      clock: () => DateTime.utc(2026, 7, 11, 10, 15),
      eventIdFactory: () => '0197f232-2bd8-7000-8000-00000000abcd',
    ).captureException(
      StateError('boom'),
      StackTrace.fromString('#0 A.b (package:app/a.dart:1:1)'),
    );
    final written = store.values.single;

    final restarted = NoticebirdClient(
      config: config(store: store),
      transport: transport,
    );
    await restarted.flush();

    expect(transport.bodies, [written]);
    expect(restarted.pendingCount, 0);
  });

  test('a stored entry without an event id is discarded', () async {
    final store = _MemoryStore(isEncrypted: true)
      ..values = ['{not json', '[]', '{"eventId": "not-an-id"}'];

    final restarted = NoticebirdClient(
      config: config(store: store),
      transport: transport,
    );
    await restarted.flush();

    expect(transport.bodies, isEmpty);
    expect(restarted.pendingCount, 0);
    expect(store.values, isEmpty);
  });

  test(
    'a protocol-invalid session id drops the event without queueing',
    () async {
      final invalidReporter = NoticebirdClient(
        config: config(sessionId: 'short'),
        transport: transport,
        clock: () => DateTime.utc(2026, 7, 11, 10, 15),
        eventIdFactory: () => '0197f232-2bd8-7000-8000-00000000abcd',
      );
      final result = await invalidReporter.captureException(
        StateError('boom'),
        StackTrace.fromString('#0 A.b (package:app/a.dart:1:1)'),
      );
      expect(result.outcome, CaptureOutcome.dropped);
      expect(transport.events, isEmpty);
      expect(
        invalidReporter.pendingCount,
        0,
        reason: 'invalid events must be dropped, not queued as a poison pill',
      );
    },
  );

  test(
    'stack_trace friendly frames are kept and written like VM frames',
    () async {
      await reporter.captureException(
        StateError('vm format'),
        StackTrace.fromString(
          '#0 PatientCubit.load (package:app/patient_cubit.dart:42:7)',
        ),
      );
      await reporter.captureException(
        StateError('friendly format'),
        StackTrace.fromString(
          'package:app/patient_cubit.dart 42:7  PatientCubit.load',
        ),
      );

      expect(transport.events, hasLength(2));
      expect(
        transport.events[1]['exception']['stackTrace'],
        '#0 PatientCubit.load (package:app/patient_cubit.dart:42:7)',
      );
      expect(
        transport.events[1]['exception']['stackTrace'],
        transport.events[0]['exception']['stackTrace'],
      );
    },
  );

  test(
    'a package frame named like personal data keeps its words or is left out',
    () async {
      await reporter.captureException(
        StateError('credential-named frames'),
        StackTrace.fromString(
          '#0 AuthHeader.bearer (package:app/a.dart:1:2)\n'
          'package:app/b.dart 3:4  Session.bearer\n'
          '#2 person@example.com (package:app/c.dart:5:6)\n'
          '#3 PatientCubit.load (package:app/patient_cubit.dart:42:7)',
        ),
      );

      final event = transport.events.single;
      expect(
        event['exception']['stackTrace'],
        '#0 AuthHeader.bearer_ (package:app/a.dart:1:2)\n'
        '#1 Session.bearer_ (package:app/b.dart:3:4)\n'
        '#3 PatientCubit.load (package:app/patient_cubit.dart:42:7)',
      );
      expect(privacyMatches(event), isEmpty);
    },
  );

  group('dart2js frames', () {
    const host = 'https://app-stg.example.com';

    Future<Map<String, dynamic>> capture(String stack) async {
      await reporter.captureException(
        StateError('web'),
        StackTrace.fromString(stack),
      );
      return transport.events.last;
    }

    test(
      'V8 frames of the compiled script keep its file name, line and column',
      () async {
        final event = await capture(
          'Error: Bad state: web\n'
          '    at Object.t ($host/main.dart.js:4741:20)\n'
          '    at cOy.\$0 ($host/main.dart.js:375562:14)\n'
          '    at tear_off.<anonymous> ($host/main.dart.js:4894:79)\n'
          '    at $host/main.dart.js:1:2\n'
          '    at async Object.load ($host/main.dart.js:12:3)\n'
          '    at new Ab ($host/main.dart.js:13:4)\n'
          '    at Array.forEach (<anonymous>)\n'
          '    at Object.k ($host/canvaskit/canvaskit.js:1:1)\n'
          '    at Object.f ($host/flutter.js:2:2)\n'
          '    at chrome-extension://abc/content.js:3:3\n'
          '    at Object.l (https://cdn.example.org/lib.dart.min.js:4:4)',
        );

        expect(
          event['exception']['stackTrace'],
          '#0 Object.t (main.dart.js:4741:20)\n'
          '#1 cOy.\$0 (main.dart.js:375562:14)\n'
          '#2 tear_off.<anonymous> (main.dart.js:4894:79)\n'
          '#3 <anonymous> (main.dart.js:1:2)\n'
          '#4 Object.load (main.dart.js:12:3)\n'
          '#5 Ab (main.dart.js:13:4)',
        );
        expect(transport.bodies.last, isNot(contains('app-stg')));
        expect(privacyMatches(event), isEmpty);
      },
    );

    test(
      'Firefox and Safari frames and deferred parts are kept the same way',
      () async {
        final event = await capture(
          'cOy.\$0@$host/main.dart.js:375562:14\n'
          '@$host/main.dart.js:1:2\n'
          'async*Ab.load@$host/main.dart.js:5:6\n'
          't/<@$host/main.dart.js:7:8\n'
          'Bq.\$1@$host/main.dart.js_3.part.js:10:11\n'
          'global code@$host/app/main.dart.js?v=12#top:20:2\n'
          '[native code]\n'
          'Xy@$host/canvaskit/canvaskit.js:1:1\n'
          'Zz@moz-extension://abc/content.js:2:2',
        );

        expect(
          event['exception']['stackTrace'],
          '#0 cOy.\$0 (main.dart.js:375562:14)\n'
          '#1 <anonymous> (main.dart.js:1:2)\n'
          '#2 Ab.load (main.dart.js:5:6)\n'
          '#3 <anonymous> (main.dart.js:7:8)\n'
          '#4 Bq.\$1 (main.dart.js_3.part.js:10:11)\n'
          '#5 <anonymous> (main.dart.js:20:2)',
        );
        expect(privacyMatches(event), isEmpty);
      },
    );

    test(
      'a name the firewall would misread keeps its words, a script name drops the frame',
      () async {
        final event = await capture(
          '    at AuthHeader.bearer ($host/main.dart.js:1:2)\n'
          '    at Session.refreshToken ($host/main.dart.js:3:4)\n'
          '    at a1234567890 ($host/main.dart.js:5:6)\n'
          '    at eyJhbGciOi.eyJzdWIiOi.c2ln ($host/main.dart.js:7:8)\n'
          '    at Object.f ($host/0612345678.dart.js:9:9)',
        );

        expect(
          event['exception']['stackTrace'],
          '#0 AuthHeader.bearer_ (main.dart.js:1:2)\n'
          '#1 Session.refreshToken_ (main.dart.js:3:4)\n'
          '#2 a123456789 (main.dart.js:5:6)\n'
          '#3 eyJhbGciOi_eyJzdWIiOi_c2ln (main.dart.js:7:8)',
        );
        expect(privacyMatches(event), isEmpty);
      },
    );

    test('a trace with no compiled-script frame is <no-app-frames>', () async {
      final event = await capture(
        '    at Object.k ($host/canvaskit/canvaskit.js:1:1)\n'
        '    at Object.l (https://cdn.example.org/vendor.js:2:2)',
      );

      expect(event['exception']['stackTrace'], '<no-app-frames>');
    });

    test('VM and web frames mix', () async {
      final mixed = await capture(
        '#0 PatientCubit.load (package:app/patient_cubit.dart:42:7)\n'
        '    at cOy.\$0 ($host/main.dart.js:375562:14)',
      );

      expect(
        mixed['exception']['stackTrace'],
        '#0 PatientCubit.load (package:app/patient_cubit.dart:42:7)\n'
        '#1 cOy.\$0 (main.dart.js:375562:14)',
      );
    });

    test('at most 50 frames are kept', () async {
      final event = await capture(
        [
          for (var i = 0; i < 60; i++) '    at f$i ($host/main.dart.js:$i:1)',
        ].join('\n'),
      );

      final frames = event['exception']['stackTrace'].split('\n');
      expect(frames, hasLength(50));
      expect(frames.last, '#49 f49 (main.dart.js:49:1)');
    });
  });

  group('crashExceptionType', () {
    test('names a Dart core error by its core type in a minified build', () {
      final errors = <Object, String>{
        IndexError.withLength(3, 1): 'IndexError',
        RangeError('x'): 'RangeError',
        ArgumentError('x'): 'ArgumentError',
        UnimplementedError(): 'UnimplementedError',
        UnsupportedError('x'): 'UnsupportedError',
        StateError('x'): 'StateError',
        TypeError(): 'TypeError',
        NoSuchMethodError.withInvocation(
          Object(),
          Invocation.method(#missing, const []),
        ): 'NoSuchMethodError',
        AssertionError(): 'AssertionError',
        ConcurrentModificationError(): 'ConcurrentModificationError',
        const OutOfMemoryError(): 'OutOfMemoryError',
        const StackOverflowError(): 'StackOverflowError',
        const FormatException(): 'FormatException',
        TimeoutException('x'): 'TimeoutException',
      };

      for (final MapEntry(key: error, value: type) in errors.entries) {
        expect(crashExceptionType(error, 'minified:ib'), type);
      }
    });

    test('keeps the minified name of any other type', () {
      expect(crashExceptionType(_AppException(), 'minified:Zq'), 'minified:Zq');
    });

    test('passes a readable name through, cut to 160 characters', () {
      expect(
        crashExceptionType(StateError('x'), 'AppStateError'),
        'AppStateError',
      );
      expect(crashExceptionType(_AppException(), 'A' * 200), 'A' * 160);
    });
  });

  test(
    'setUserId sends the id as given, in the protocol\'s shape, and clears on null',
    () async {
      reporter = NoticebirdClient(
        config: config(
          profile: CrashPrivacyProfile.custom,
          pii: const CrashPiiConfig(
            enabled: true,
            allowedFields: {CrashPiiField.userId},
          ),
        ),
        transport: transport,
        eventIdFactory: () =>
            '0197f232-2bd8-7000-8000-${(++eventSequence).toString().padLeft(12, '0')}',
      );
      reporter.setUserId(' user 1!! ');
      await reporter.captureException(
        StateError('boom'),
        StackTrace.fromString('#0 A.b (package:app/a.dart:1:1)'),
      );
      expect(transport.events.single['user']['id'], 'user1');

      // An opaque id survives as it is: a UUID (every Supabase user id) and a
      // numeric id were once redacted by the free-text sanitizer.
      reporter.setUserId('19fda259-c28b-421b-ad04-979d2d0abbed');
      await reporter.captureException(
        StateError('uuid'),
        StackTrace.fromString('#0 A.b (package:app/a.dart:3:1)'),
      );
      expect(
        transport.events.last['user']['id'],
        '19fda259-c28b-421b-ad04-979d2d0abbed',
      );
      reporter.setUserId('12345678901');
      await reporter.captureException(
        StateError('numeric'),
        StackTrace.fromString('#0 A.b (package:app/a.dart:4:1)'),
      );
      expect(transport.events.last['user']['id'], '12345678901');

      reporter.setUserId(null);
      await reporter.captureException(
        StateError('boom again'),
        StackTrace.fromString('#0 A.b (package:app/a.dart:2:1)'),
      );
      expect(transport.events.last['user'], isNull);
    },
  );

  test('clearBreadcrumbs empties the ring buffer without capturing', () async {
    reporter.addBreadcrumb(
      TypedBreadcrumb(
        occurredAt: DateTime.utc(2026, 7, 11),
        category: BreadcrumbCategory.auth,
        action: 'auth.logout',
      ),
    );
    reporter.clearBreadcrumbs();
    await reporter.captureException(
      StateError('boom'),
      StackTrace.fromString('#0 A.b (package:app/a.dart:1:1)'),
    );
    expect(transport.events.single, isNot(contains('breadcrumbs')));
  });

  test('recentBreadcrumbs reflects the current ring buffer', () {
    expect(reporter.recentBreadcrumbs, isEmpty);
    reporter.addBreadcrumb(
      TypedBreadcrumb(
        occurredAt: DateTime.utc(2026, 7, 11),
        category: BreadcrumbCategory.navigation,
        action: 'route.push',
      ),
    );
    expect(reporter.recentBreadcrumbs, hasLength(1));
    expect(reporter.recentBreadcrumbs.single.action, 'route.push');
  });

  test(
    'a live debug session bypasses dedup and syncs breadcrumbs immediately',
    () async {
      final dedupReporter = NoticebirdClient(
        config: config(deduplicationWindow: const Duration(minutes: 1)),
        transport: transport,
        clock: () => DateTime.utc(2026, 7, 11, 10, 15),
        eventIdFactory: () =>
            '0197f232-2bd8-7000-8000-${(++eventSequence).toString().padLeft(12, '0')}',
      );
      final stack = StackTrace.fromString('#0 A.b (package:app/a.dart:1:1)');

      expect(dedupReporter.isLiveDebugSessionActive, isFalse);
      dedupReporter.startLiveDebugSession(
        sessionId: 'session-1',
        expiresAt: DateTime.utc(2026, 7, 11, 10, 20),
      );
      expect(dedupReporter.isLiveDebugSessionActive, isTrue);

      expect(
        (await dedupReporter.captureException(StateError('x'), stack)).outcome,
        CaptureOutcome.sent,
      );
      expect(
        (await dedupReporter.captureException(StateError('x'), stack)).outcome,
        CaptureOutcome.sent,
        reason: 'dedup is bypassed while a live session is active',
      );

      dedupReporter.addBreadcrumb(
        TypedBreadcrumb(
          occurredAt: DateTime.utc(2026, 7, 11, 10, 16),
          category: BreadcrumbCategory.navigation,
          action: 'route.push',
        ),
      );
      // addBreadcrumb fires the sync deliberately fire-and-forget (it must
      // stay synchronous/non-blocking for callers); flush pending microtasks
      // before asserting on the transport.
      await Future<void>.delayed(Duration.zero);
      expect(
        transport.events.where(
          (e) => e['exception']['type'] == 'LiveBreadcrumbSync',
        ),
        hasLength(1),
      );

      dedupReporter.stopLiveDebugSession();
      expect(dedupReporter.isLiveDebugSessionActive, isFalse);
    },
  );

  test('live debug coalesces breadcrumbs behind one in-flight send', () async {
    final blockingTransport = _BlockingTransport();
    final liveReporter = NoticebirdClient(
      config: config(),
      transport: blockingTransport,
      clock: () => DateTime.utc(2026, 7, 11, 10, 15),
      eventIdFactory: () =>
          '0197f232-2bd8-7000-8000-${(++eventSequence).toString().padLeft(12, '0')}',
    );
    liveReporter.startLiveDebugSession(
      sessionId: 'session-1',
      expiresAt: DateTime.utc(2026, 7, 11, 10, 20),
    );

    for (var i = 0; i < 25; i++) {
      liveReporter.addBreadcrumb(
        TypedBreadcrumb(
          occurredAt: DateTime.utc(2026, 7, 11, 10, 16),
          category: BreadcrumbCategory.navigation,
          action: 'route.$i',
        ),
      );
    }
    await Future<void>.delayed(Duration.zero);

    expect(blockingTransport.maxConcurrent, 1);
    expect(blockingTransport.started, 1);
    blockingTransport.release();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(
      blockingTransport.started,
      lessThanOrEqualTo(2),
      reason: 'a hot stream may schedule at most one coalesced follow-up',
    );
    blockingTransport.release();
  });

  test('an expired live debug session is treated as inactive', () {
    var now = DateTime.utc(2026, 7, 11, 10, 15);
    final expiringReporter = NoticebirdClient(
      config: config(),
      transport: transport,
      clock: () => now,
    );
    expiringReporter.startLiveDebugSession(
      sessionId: 'session-1',
      expiresAt: DateTime.utc(2026, 7, 11, 10, 16),
    );
    expect(expiringReporter.isLiveDebugSessionActive, isTrue);

    now = DateTime.utc(2026, 7, 11, 10, 17);
    expect(expiringReporter.isLiveDebugSessionActive, isFalse);
  });

  group('an event the platform refuses for good', () {
    /// A transport over the hosted API that answers [refusal] for the event
    /// [refusedEventId] and 202 for any other, recording the bodies.
    (CrashHttpTransport, List<String>) hostedApi(
      String refusedEventId, {
      (int, String) refusal = (422, '{"error":"privacy_rejected"}'),
    }) {
      final bodies = <String>[];
      final transport = CrashHttpTransport(
        apiUrl: CrashHttpTransport.hostedApiUrl,
        publishableKey: 'crash_pk_test_123456',
        httpClient: MockClient((request) async {
          bodies.add(request.body);
          final eventId = (jsonDecode(request.body) as Map)['eventId'];
          return eventId == refusedEventId
              ? http.Response(refusal.$2, refusal.$1)
              : http.Response('', 202);
        }),
      );
      return (transport, bodies);
    }

    const finalAnswers = [
      (413, '{"error":"payload_too_large"}'),
      (422, '{"error":"privacy_rejected","reason":"policyViolation"}'),
    ];
    const retryableAnswers = [
      (400, '{"error":"invalid_event"}'),
      (400, '<html>Bad Request</html>'),
      (413, '<html>Request Entity Too Large</html>'),
      (422, '<html>Unprocessable Entity</html>'),
      (503, '{"error":"api_container_unavailable"}'),
    ];

    for (final answer in finalAnswers) {
      test('${answer.$1} ${answer.$2}: a flush removes it and sends the '
          'next', () async {
        final refused = _v5Entry.replaceFirst('000000000005', '0000000000ff');
        final store = _MemoryStore(isEncrypted: true)
          ..values = [refused, _v5Entry];
        final (api, bodies) = hostedApi(
          '0197f232-2bd8-7000-8000-0000000000ff',
          refusal: answer,
        );
        final restarted = NoticebirdClient(
          config: config(store: store),
          transport: api,
        );

        await restarted.flush();

        expect(bodies, [refused, _v5Entry]);
        expect(restarted.pendingCount, 0);
        expect(store.values, isEmpty);
      });

      test('${answer.$1} ${answer.$2}: a capture is dropped, and nothing '
          'waits', () async {
        final (api, bodies) = hostedApi(
          '0197f232-2bd8-7000-8000-000000000001',
          refusal: answer,
        );
        final store = _MemoryStore(isEncrypted: true);
        final refusing = NoticebirdClient(
          config: config(store: store),
          transport: api,
          clock: () => DateTime.utc(2026, 7, 11, 10, 15),
          eventIdFactory: () => '0197f232-2bd8-7000-8000-000000000001',
        );

        final result = await refusing.captureException(
          StateError('boom'),
          StackTrace.fromString('#0 A.b (package:app/a.dart:1:1)'),
        );

        expect(result, const CaptureResult(CaptureOutcome.dropped));
        expect(bodies, hasLength(1));
        expect(refusing.pendingCount, 0);
        expect(store.values, isEmpty);
      });
    }

    for (final answer in retryableAnswers) {
      test('${answer.$1} ${answer.$2}: a capture is kept and sent again '
          'at the next flush', () async {
        const eventId = '0197f232-2bd8-7000-8000-000000000001';
        var refusing = true;
        final bodies = <String>[];
        final api = CrashHttpTransport(
          apiUrl: CrashHttpTransport.hostedApiUrl,
          publishableKey: 'crash_pk_test_123456',
          httpClient: MockClient((request) async {
            bodies.add(request.body);
            return refusing
                ? http.Response(answer.$2, answer.$1)
                : http.Response('', 202);
          }),
        );
        final store = _MemoryStore(isEncrypted: true);
        final client = NoticebirdClient(
          config: config(store: store),
          transport: api,
          clock: () => DateTime.utc(2026, 7, 11, 10, 15),
          eventIdFactory: () => eventId,
        );

        final result = await client.captureException(
          StateError('boom'),
          StackTrace.fromString('#0 A.b (package:app/a.dart:1:1)'),
        );
        expect(
          result,
          const CaptureResult(CaptureOutcome.queued, eventId: eventId),
        );
        await client.flush();
        expect(client.pendingCount, 1);

        refusing = false;
        await client.flush();

        expect(bodies, hasLength(3));
        expect(bodies.toSet(), hasLength(1));
        expect(client.pendingCount, 0);
        expect(store.values, isEmpty);
      });
    }

    test('a custom transport\'s CrashTransportException without '
        'refusedForGood keeps the event', () async {
      final scripted = _ScriptedTransport()
        ..failure = const CrashTransportException(422);
      final store = _MemoryStore(isEncrypted: true);
      final client = NoticebirdClient(
        config: config(store: store),
        transport: scripted,
        clock: () => DateTime.utc(2026, 7, 11, 10, 15),
        eventIdFactory: () => '0197f232-2bd8-7000-8000-000000000001',
      );

      final result = await client.captureException(
        StateError('boom'),
        StackTrace.fromString('#0 A.b (package:app/a.dart:1:1)'),
      );

      expect(result.outcome, CaptureOutcome.queued);
      expect(client.pendingCount, 1);
      expect(store.values, hasLength(1));
    });

    test('an entry as 0.2.0 stored it is sent byte for byte', () async {
      expect(
        _v5Entry,
        canonicalJsonEncode(
          jsonDecode(
            File(
              '../noticebird_protocol/test/fixtures/v5_event.json',
            ).readAsStringSync(),
          ),
        ),
      );
      final store = _MemoryStore(isEncrypted: true)..values = [_v5Entry];
      final (api, bodies) = hostedApi('none');
      final restarted = NoticebirdClient(
        config: config(store: store),
        transport: api,
      );

      await restarted.flush();

      expect(bodies, [_v5Entry]);
      expect(restarted.pendingCount, 0);
    });
  });

  test('a flush never drops an event a capture queued during its send, '
      'when the queue is full', () async {
    final scripted = _ScriptedTransport()..failure = StateError('offline');
    final reporter = NoticebirdClient(
      config: config(),
      transport: scripted,
      clock: () => DateTime.utc(2026, 7, 11, 10, 15),
      eventIdFactory: () =>
          '0197f232-2bd8-7000-8000-${(++eventSequence).toString().padLeft(12, '0')}',
    );
    Future<CaptureResult> capture(int line) => reporter.captureException(
      StateError('offline'),
      StackTrace.fromString('#0 A.b$line (package:app/a.dart:$line:1)'),
    );
    for (var line = 1; line <= 3; line++) {
      expect((await capture(line)).outcome, CaptureOutcome.queued);
    }
    expect(reporter.pendingCount, 3);

    // The flush's send of the head waits; meanwhile a capture whose send
    // fails is queued, which evicts that head.
    scripted
      ..failure = null
      ..gate = Completer<void>();
    final flushing = reporter.flush();
    await pumpEventQueue();
    scripted.failure = StateError('offline');
    final queued = await capture(4);
    expect(queued.outcome, CaptureOutcome.queued);
    scripted.failure = null;
    scripted.gate!.complete();
    await flushing;

    String id(int n) => '0197f232-2bd8-7000-8000-${'$n'.padLeft(12, '0')}';
    expect(
      [for (final body in scripted.bodies) jsonDecode(body)['eventId']],
      [id(1), id(2), id(3), id(4)],
      reason: 'the evicted head was sent already; none of the rest is lost',
    );
    expect(reporter.pendingCount, 0);
  });

  test('flush retries queued events', () async {
    transport.failure = TimeoutException('offline');
    await reporter.captureException(
      StateError('offline'),
      StackTrace.fromString('#0 A.b (package:app/a.dart:1:1)'),
    );
    expect(reporter.pendingCount, 1);

    transport.failure = null;
    await reporter.flush();
    expect(reporter.pendingCount, 0);
    expect(transport.events, hasLength(1));
  });
}

final class _AppException implements Exception {}

final class _RecordingTransport implements CrashTransport {
  /// What was sent, as the wire carries it.
  final bodies = <String>[];
  Object? failure;

  List<Map<String, dynamic>> get events => [
    for (final body in bodies) jsonDecode(body) as Map<String, dynamic>,
  ];

  @override
  Future<void> send(String eventJson) async {
    if (failure != null) throw failure!;
    bodies.add(eventJson);
  }
}

final class _BlockingTransport implements CrashTransport {
  var started = 0;
  var concurrent = 0;
  var maxConcurrent = 0;
  Completer<void> _gate = Completer<void>();

  @override
  Future<void> send(String eventJson) async {
    started++;
    concurrent++;
    if (concurrent > maxConcurrent) maxConcurrent = concurrent;
    await _gate.future;
    concurrent--;
  }

  void release() {
    if (!_gate.isCompleted) _gate.complete();
    _gate = Completer<void>();
  }
}

final class _ClosableClient extends http.BaseClient {
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(const Stream.empty(), 202);

  @override
  void close() {
    closed = true;
    super.close();
  }
}

final class _RequestRecordingClient extends http.BaseClient {
  Uri? requestUri;
  Map<String, String>? requestHeaders;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requestUri = request.url;
    requestHeaders = request.headers;
    return http.StreamedResponse(const Stream.empty(), 202);
  }
}

final class _MemoryStore implements CrashOfflineStore {
  _MemoryStore({required this.isEncrypted});

  @override
  final bool isEncrypted;
  List<String> values = [];

  @override
  Future<List<String>> read() async => values;

  @override
  Future<void> write(List<String> canonicalEnvelopes) async {
    values = [...canonicalEnvelopes];
  }
}

/// A transport whose next send waits for [gate] when one is set, and
/// otherwise throws [failure] when one is set; it records what it sent.
final class _ScriptedTransport implements CrashTransport {
  final bodies = <String>[];
  Object? failure;
  Completer<void>? gate;
  var _gateTaken = false;

  @override
  Future<void> send(String eventJson) async {
    if (gate case final waiting? when !_gateTaken) {
      _gateTaken = true;
      await waiting.future;
    } else if (failure != null) {
      throw failure!;
    }
    bodies.add(eventJson);
  }
}

/// `noticebird_protocol`'s `test/fixtures/v5_event.json` in its canonical
/// encoding: an entry of the offline store as 0.2.0 wrote it.
const _v5Entry =
    '{"app":{"build":"100","name":"justorganize",'
    '"release":"justorganize@1.0.0+100","version":"1.0.0"},'
    '"breadcrumbs":[{"action":"route.push","category":"navigation",'
    '"data":{"component":"list-detail"},"level":"info",'
    '"occurredAt":"2026-07-11T10:14:59.000Z"}],'
    '"eventId":"0197f232-2bd8-7000-8000-000000000005",'
    '"exception":{"sanitizedMessage":"Refused: 23505 on collections",'
    '"stackTrace":"#0 SyncWriter.push (package:app_sync/sync_writer.dart:88:5)",'
    '"type":"SyncRefused"},"extra":{"retry_count":2},'
    '"groupingKey":["sync-refusal","23505","collections"],"handled":false,'
    '"occurredAt":"2026-07-11T10:15:00.000Z",'
    '"platform":{"deviceClass":"desktop","name":"macos","osVersion":"15.5"},'
    '"routeTemplate":"/lists/:listId","schemaVersion":5,'
    '"sessionId":"random_session_123456","severity":"error",'
    '"tags":{"feature":"lists","foreground":true},'
    '"user":{"id":"user_abc123"}}';

TypedBreadcrumb _crumb(String action, {Map<AllowedTag, TagScalar>? data}) =>
    TypedBreadcrumb(
      occurredAt: DateTime.utc(2026, 7, 11),
      category: BreadcrumbCategory.navigation,
      action: action,
      data: data ?? const {},
    );
