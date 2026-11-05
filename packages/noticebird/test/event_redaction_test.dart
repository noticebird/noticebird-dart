import 'dart:convert';

import 'package:noticebird/noticebird.dart';
import 'package:test/test.dart';

import 'support/privacy_matches.dart';

/// An event the client builds holds no match of the protocol's
/// [PrivacyPatterns] in a field the client redacts. A host's trail holds such
/// values on purpose (a route with a list's id, a bloc state's ids): the
/// buffer keeps them for [NoticebirdClient.recentBreadcrumbs], and the event
/// carries a message redacted and leaves out a detail entry, an action or a
/// category that holds one, and counts what it left out.
void main() {
  const uuid = '7d3f1c2a-9b4e-4f6a-8c1d-2e3f4a5b6c7d';
  late _RecordingTransport transport;

  NoticebirdClient client({
    CrashPrivacyProfile profile = CrashPrivacyProfile.privacyDefault,
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
      deduplicationWindow: Duration.zero,
      breadcrumbBuffer: 100,
    ),
    transport: transport,
    clock: () => DateTime.utc(2026, 10, 13, 10),
    eventIdFactory: () => '0197f232-2bd8-7000-8000-000000000001',
  );

  setUp(() => transport = _RecordingTransport());

  test('a trail with ids reaches the event without them, and the buffer '
      'keeps them', () async {
    final reporter = client()
      ..addBreadcrumb(
        'Opened /collections/$uuid',
        action: 'route.push',
        details: const {
          'route': '/collections/:id',
          'from': '/collections/$uuid',
        },
      )
      ..addBreadcrumb(
        'CollectionCubit changed',
        action: 'collectionCubit.change',
        details: const {'status': 'ready', 'id': uuid},
      );

    final result = await reporter.captureException(
      StateError('boom'),
      StackTrace.empty,
    );

    expect(result.outcome, CaptureOutcome.sent);
    final event = transport.events.single;
    expect(privacyMatches(event), isEmpty);
    expect(
      event['breadcrumbs'].first['message'],
      'Opened /collections/[REDACTED]',
    );
    expect(event['breadcrumbs'].first['details'], {
      'route': '/collections/:id',
    });
    expect(event['breadcrumbs'].last['details'], {'status': 'ready'});
    expect(event['breadcrumbDrops'], {'detailsDropped': 2, 'stepsDropped': 0});
    expect(
      reporter.recentBreadcrumbs.first.message,
      'Opened /collections/$uuid',
    );
    expect(reporter.recentBreadcrumbs.last.details['id'], uuid);
  });

  test('the canary corpus: no name or value that reads as a credential, a '
      'health value or an identifier leaves, and the event does', () async {
    final reporter = client()
      ..addBreadcrumb(
        'Signed in',
        action: 'auth.sign_in',
        details: const {
          'password': 'x',
          'heartRate': 80,
          'userEmail': true,
          'contact': 31612345678,
          'row': uuid,
          // Nine digits pass every pattern: only the name gives them away.
          'bsn': 123456789,
          // 0612345678 as an int: nine digits, below the phone pattern.
          'phone': 612345678,
          'payoutIban': 'NL91ABNA0417164300',
          'phase': 'load',
          'attempt': 2,
        },
      );

    final result = await reporter.captureException(
      StateError('boom'),
      StackTrace.empty,
    );

    expect(result.outcome, CaptureOutcome.sent);
    final event = transport.events.single;
    expect(privacyMatches(event), isEmpty);
    expect(event['breadcrumbs'].single['details'], {
      'phase': 'load',
      'attempt': 2,
    });
    expect(event['breadcrumbDrops'], {'detailsDropped': 8, 'stepsDropped': 0});
  });

  group('every value a redaction pattern matches is redacted', () {
    final values = <String, String>{
      'uuid': 'open $uuid',
      'e-mail': 'invite person@example.com',
      'jwt': 'session eyJhbGciOi.eyJzdWIiOi.c2lnbmF0dXJl',
      'bearer with a tab': 'header Bearer\tabc123',
      'authorization assignment': 'Authorization: abc123',
      'api key assignment': 'api-key=abc123',
      'phone number': 'call +31 6 1234 5678',
      'ipv4 address': 'host 10.20.30.40',
      'a uuid the clamp cuts loose from a word': '${'x' * 62} $uuid${'y' * 20}',
      'an address the clamp cuts loose from a word':
          '${'x' * 91} 1.2.3.4${'z' * 10}',
      'a uuid behind an address': 'at 1.2.3.4a${uuid.substring(1)}',
      'a value ending in bearer': 'header bearer',
      'a value ending in an assignment': 'refresh token:',
    };

    for (final MapEntry(key: name, value: value) in values.entries) {
      test('$name, in a breadcrumb message and a tag', () async {
        final reporter = client()
          ..addBreadcrumb(value, details: const {'next': 'next'});

        final result = await reporter.captureException(
          StateError('boom'),
          StackTrace.empty,
          tags: {AllowedTag.feature: value, AllowedTag.component: 'next'},
        );

        expect(result.outcome, CaptureOutcome.sent);
        expect(privacyMatches(transport.events.single), isEmpty);
        expect(transport.events.single['breadcrumbs'].single['details'], {
          'next': 'next',
        });
        expect(reporter.recentBreadcrumbs.single.message, value);
      });
    }
  });

  group('a route template with what a redaction pattern matches', () {
    for (final MapEntry(key: route, value: redacted) in {
      '/invite/person@example.com': '/invite/[REDACTED]',
      '/hosts/1.2.3.4/status': '/hosts/[REDACTED]/status',
    }.entries) {
      test('$route reaches the event redacted', () async {
        final reporter = client()..setRouteTemplate(route);

        final result = await reporter.captureException(
          StateError('boom'),
          StackTrace.empty,
        );

        expect(result.outcome, CaptureOutcome.sent);
        final event = transport.events.single;
        expect(privacyMatches(event), isEmpty);
        expect(event['routeTemplate'], redacted);
      });
    }

    test('stays within the protocol\'s length once redacted', () async {
      // 193 characters, which the redaction grows past 200.
      final reporter = client()..setRouteTemplate('/${'1.2.3.4/' * 24}');

      final result = await reporter.captureException(
        StateError('boom'),
        StackTrace.empty,
      );

      expect(result.outcome, CaptureOutcome.sent);
      final event = transport.events.single;
      expect(privacyMatches(event), isEmpty);
      expect(
        event['routeTemplate'].length,
        lessThanOrEqualTo(CrashEvent.maxRouteTemplateLength),
      );
    });
  });

  test('an action or a category that names an id or a credential is left '
      'out, and the step kept', () async {
    final reporter = client()
      ..addBreadcrumb('Opened', action: 'open.$uuid', category: 'ui')
      ..addBreadcrumb('Opened', action: 'open.list', category: 'token');

    await reporter.captureException(StateError('boom'), StackTrace.empty);

    final event = transport.events.single;
    expect(privacyMatches(event), isEmpty);
    expect(event['breadcrumbs'], [
      {'at': '2026-10-13T10:00:00.000Z', 'message': 'Opened', 'category': 'ui'},
      {
        'at': '2026-10-13T10:00:00.000Z',
        'message': 'Opened',
        'action': 'open.list',
      },
    ]);
    expect(event['breadcrumbDrops'], {'detailsDropped': 2, 'stepsDropped': 0});
    expect(reporter.recentBreadcrumbs.first.action, 'open.$uuid');
  });

  test('under regulatedStrict a detail string never leaves', () async {
    final reporter = client(profile: CrashPrivacyProfile.regulatedStrict)
      ..addBreadcrumb(
        'Loaded',
        details: const {'status': 'loaded', 'items.count': 3, 'busy': false},
      );

    await reporter.captureException(StateError('boom'), StackTrace.empty);

    final event = transport.events.single;
    expect(event['breadcrumbs'].single['details'], {
      'items.count': 3,
      'busy': false,
    });
    expect(event['breadcrumbDrops'], {'detailsDropped': 1, 'stepsDropped': 0});
  });

  test('a message with a health value or a credential is redacted', () async {
    final reporter = client();
    for (final message in [
      'observation: 5',
      'electrocardiogram=abnormal',
      'glucose: ,12',
      'Authorization: abc123',
      // Cut at the message's 512 characters right after the keyword.
      '${'x' * 495}bearerZZZ',
    ]) {
      await reporter.captureException(StateError(message), StackTrace.empty);
    }

    expect(transport.events, hasLength(5));
    for (final event in transport.events) {
      expect(privacyMatches(event), isEmpty);
    }
  });

  test('an extra key that names health data is dropped', () async {
    final reporter = client();
    await reporter.captureException(
      StateError('boom'),
      StackTrace.empty,
      extra: const {
        'observationCount': 1,
        'spo2': 1,
        'blood_pressure': 1,
        'diagnosisCode': 1,
        'electrocardiogram': 1,
        'phase': 'load',
      },
    );

    final event = transport.events.single;
    expect(privacyMatches(event), isEmpty);
    expect(event['extra'], {'phase': 'load'});
  });
}

final class _RecordingTransport implements CrashTransport {
  final events = <Map<String, dynamic>>[];

  @override
  Future<void> send(String eventJson) async {
    events.add(jsonDecode(eventJson) as Map<String, dynamic>);
  }
}
