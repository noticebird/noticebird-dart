// A declared dependency failure on the client: the explicit argument of
// captureException, NoticebirdConfig.dependencyOf on every capture, a
// dependency the protocol refuses or a redaction pattern matches left out
// but never the event, and a queued event that keeps it.

import 'dart:convert';
import 'dart:io';

import 'package:noticebird/noticebird.dart';
import 'package:noticebird/src/protocol/host_mistakes.dart';
import 'package:test/test.dart';

import 'support/privacy_matches.dart';

/// A timeout of the app's database client.
final class _DatabaseTimeout implements Exception {
  const _DatabaseTimeout();
}

const _timeout = CrashDependency(
  name: 'database',
  failure: DependencyFailure.timeout,
  code: '57014',
);

const _aborted = CrashDependency(
  name: 'database',
  failure: DependencyFailure.unavailable,
  code: '25P02',
);

final _stack = StackTrace.fromString('#0 Lists.load (package:app/a.dart:1:1)');

void main() {
  late _Transport transport;
  var eventSequence = 0;

  NoticebirdClient client({
    CrashDependency? Function(Object error)? dependencyOf,
    CrashOfflineStore? store,
    Duration deduplicationWindow = Duration.zero,
  }) => NoticebirdClient(
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
      deduplicationWindow: deduplicationWindow,
      offlineStore: store,
      dependencyOf: dependencyOf,
    ),
    transport: transport,
    eventIdFactory: () =>
        '0197f232-2bd8-7000-8000-${(++eventSequence).toString().padLeft(12, '0')}',
  );

  CrashDependency? databaseTimeouts(Object error) =>
      error is _DatabaseTimeout ? _timeout : null;

  setUp(() {
    transport = _Transport();
    eventSequence = 0;
  });

  test('a dependency passed to captureException reaches the event', () async {
    await client().captureException(
      StateError('aborted'),
      _stack,
      dependency: _aborted,
    );

    expect(transport.events.single['dependency'], {
      'name': 'database',
      'failure': 'unavailable',
      'code': '25P02',
    });
  });

  test('without one the event carries none', () async {
    await client().captureException(StateError('boom'), _stack);

    expect(transport.events.single, isNot(contains('dependency')));
  });

  test('dependencyOf declares one for a capture without its own', () async {
    final reporter = client(dependencyOf: databaseTimeouts);

    await reporter.captureException(const _DatabaseTimeout(), _stack);
    await reporter.captureException(StateError('own bug'), _stack);

    expect(transport.events.first['dependency'], {
      'name': 'database',
      'failure': 'timeout',
      'code': '57014',
    });
    expect(transport.events.last, isNot(contains('dependency')));
  });

  test('dependencyOf is asked when the filter is bypassed too', () async {
    await client(
      dependencyOf: databaseTimeouts,
    ).captureException(const _DatabaseTimeout(), _stack, filtered: false);

    expect(
      (transport.events.single['dependency']! as Map)['failure'],
      'timeout',
    );
  });

  test('the argument of captureException wins over dependencyOf', () async {
    await client(
      dependencyOf: databaseTimeouts,
    ).captureException(const _DatabaseTimeout(), _stack, dependency: _aborted);

    expect(
      (transport.events.single['dependency']! as Map)['failure'],
      'unavailable',
    );
  });

  test('the facade passes the dependency on', () async {
    Noticebird.attach(client());
    addTearDown(Noticebird.detach);

    await Noticebird.captureException(
      StateError('aborted'),
      _stack,
      dependency: _aborted,
    );

    expect((transport.events.single['dependency']! as Map)['code'], '25P02');
  });

  test('a dependencyOf that throws gives none, and the event goes', () async {
    final result = await client(
      dependencyOf: (_) => throw StateError('mapping bug'),
    ).captureException(const _DatabaseTimeout(), _stack);

    expect(result.outcome, CaptureOutcome.sent);
    expect(transport.events.single, isNot(contains('dependency')));
  });

  test('a dependency dependencyOf answers that the protocol refuses is left '
      'out, and the event goes', () async {
    final result = await client(
      dependencyOf: (_) => const CrashDependency(
        name: 'Supabase DB',
        failure: DependencyFailure.timeout,
      ),
    ).captureException(const _DatabaseTimeout(), _stack);

    expect(result.outcome, CaptureOutcome.sent);
    expect(transport.events.single, isNot(contains('dependency')));
  });

  group('a dependency passed to captureException that the protocol '
      'refuses', () {
    const invalid = CrashDependency(
      name: 'database',
      failure: DependencyFailure.unavailable,
      code: '31612345678',
    );
    tearDown(() => debugHostMistakesThrow = isDebugBuild);

    test('throws in a debug build, where someone looks', () {
      debugHostMistakesThrow = true;

      expect(
        () => client().captureException(
          StateError('aborted'),
          _stack,
          dependency: invalid,
        ),
        throwsArgumentError,
      );
      expect(transport.events, isEmpty);
    });

    test('is left out in a release build, as if none was passed, and the '
        'event goes', () async {
      debugHostMistakesThrow = false;
      final reporter = client(dependencyOf: databaseTimeouts);

      final result = await reporter.captureException(
        StateError('aborted'),
        _stack,
        dependency: invalid,
      );
      await reporter.captureException(
        const _DatabaseTimeout(),
        _stack,
        dependency: invalid,
      );

      expect(result.outcome, CaptureOutcome.sent);
      expect(transport.events.first, isNot(contains('dependency')));
      expect(
        (transport.events.last['dependency']! as Map)['failure'],
        'timeout',
      );
    });
  });

  test('a dependency whose name or code a redaction pattern matches is left '
      'out, and the event goes', () async {
    final reporter = client();
    for (final dependency in const [
      CrashDependency(
        name: 'user31612345678',
        failure: DependencyFailure.error,
      ),
      CrashDependency(name: 'db.10.0.0.1', failure: DependencyFailure.error),
      CrashDependency(name: 'vault.token', failure: DependencyFailure.error),
    ]) {
      final result = await reporter.captureException(
        StateError('boom'),
        _stack,
        dependency: dependency,
      );
      expect(result.outcome, CaptureOutcome.sent, reason: dependency.name);
    }

    expect(transport.events, hasLength(3));
    for (final event in transport.events) {
      expect(event, isNot(contains('dependency')));
      expect(privacyMatches(event), isEmpty);
    }
  });

  test('the dependency is no part of the client\'s deduplication', () async {
    final reporter = client(deduplicationWindow: const Duration(minutes: 1));

    await reporter.captureException(StateError('boom'), _stack);
    final again = await reporter.captureException(
      StateError('boom'),
      _stack,
      dependency: _aborted,
    );

    expect(again.outcome, CaptureOutcome.deduplicated);
  });

  test('a live breadcrumb sync is no error dependencyOf is asked '
      'about', () async {
    final asked = <Object>[];
    final reporter =
        client(
          dependencyOf: (error) {
            asked.add(error);
            return null;
          },
        )..startLiveDebugSession(
          sessionId: 'live',
          expiresAt: DateTime.now().add(const Duration(minutes: 5)),
        );

    reporter.addBreadcrumb('Opened page');
    await Future<void>.delayed(Duration.zero);

    expect(transport.events, isNotEmpty);
    expect(asked, isEmpty);
  });

  test('a queued event keeps its dependency across a restart', () async {
    final directory = await Directory.systemTemp.createTemp(
      'noticebird_dependency_',
    );
    addTearDown(() => directory.delete(recursive: true));
    transport.failing = true;
    final queued = await client(
      store: FileCrashOfflineStore(directory),
    ).captureException(StateError('aborted'), _stack, dependency: _aborted);
    expect(queued.outcome, CaptureOutcome.queued);

    transport.failing = false;
    await client(store: FileCrashOfflineStore(directory)).flush();

    expect(transport.events.single['dependency'], {
      'name': 'database',
      'failure': 'unavailable',
      'code': '25P02',
    });
  });
}

final class _Transport implements CrashTransport {
  final events = <Map<String, Object?>>[];
  bool failing = false;

  @override
  Future<void> send(String eventJson) async {
    if (failing) throw const CrashTransportException(503);
    events.add(jsonDecode(eventJson) as Map<String, Object?>);
  }
}
