// NoticebirdConfig.beforeBreadcrumb: the app's own look at every breadcrumb
// before the client keeps it — change it, leave it out, or fail and leave it
// out — and what an event then carries.

import 'package:noticebird/noticebird.dart';
import 'package:noticebird/testing.dart';
import 'package:test/test.dart';

void main() {
  late RecordingCrashTransport transport;

  NoticebirdClient client(
    TypedBreadcrumb? Function(TypedBreadcrumb breadcrumb) beforeBreadcrumb,
  ) => NoticebirdClient(
    config: NoticebirdConfig(
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
      beforeBreadcrumb: beforeBreadcrumb,
    ),
    transport: transport,
  );

  setUp(() => transport = RecordingCrashTransport());

  test('sees every breadcrumb, and what it answers is kept and sent, '
      'sanitized', () async {
    final seen = <String>[];
    final reporter = client((step) {
      seen.add(step.message);
      return TypedBreadcrumb(
        at: step.at,
        message: step.message.replaceAll('Ada', 'someone'),
        category: step.category,
        details: {...step.details, 'scrubbed': true},
      );
    })..addBreadcrumb('Ada opened the list', category: 'ui');

    expect(seen, ['Ada opened the list']);
    expect(
      reporter.recentBreadcrumbs.single.message,
      'someone opened the list',
    );

    await reporter.captureException(StateError('boom'), StackTrace.empty);
    final step = (transport.events.single['breadcrumbs'] as List).single;
    expect(step, {
      'at': (step as Map)['at'],
      'message': 'someone opened the list',
      'category': 'ui',
      'details': {'scrubbed': true},
    });
  });

  test('null leaves the breadcrumb out, and no count says so', () async {
    final reporter = client((step) => step.category == 'noise' ? null : step)
      ..addBreadcrumb('Ticked', category: 'noise')
      ..addBreadcrumb('List opened', category: 'ui');

    expect(
      [for (final step in reporter.recentBreadcrumbs) step.message],
      ['List opened'],
    );
    await reporter.captureException(StateError('boom'), StackTrace.empty);
    final event = transport.events.single;
    expect((event['breadcrumbs'] as List).length, 1);
    expect(event, isNot(contains('breadcrumbDrops')));
  });

  test('a hook that throws leaves the breadcrumb out and costs the app '
      'nothing', () {
    final reporter = client(
      (step) => step.message == 'bad' ? throw StateError('hook') : step,
    );

    expect(() => reporter.addBreadcrumb('bad'), returnsNormally);
    reporter.addBreadcrumb('good');

    expect(
      [for (final step in reporter.recentBreadcrumbs) step.message],
      ['good'],
    );
  });
}
