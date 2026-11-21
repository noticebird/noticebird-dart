// A declared dependency failure (schema 7) as a client builds it.

import 'package:noticebird_protocol/noticebird_protocol.dart';
import 'package:test/test.dart';

import 'support/crash_events.dart';

void main() {
  test('the dependency is written with its name, failure and code', () {
    expect(v7Event().toJson()['dependency'], {
      'name': 'database',
      'failure': 'unavailable',
      'code': '25P02',
    });
  });

  test('a dependency without a code writes none', () {
    expect(
      v7Event(
        dependency: const CrashDependency(
          name: 'auth',
          failure: DependencyFailure.timeout,
        ),
      ).toJson()['dependency'],
      {'name': 'auth', 'failure': 'timeout'},
    );
  });

  test('an event without a dependency writes none', () {
    expect(v7Event(dependency: null).toJson(), isNot(contains('dependency')));
  });

  test('a failure is written by its name, of a closed set of five', () {
    expect(
      [for (final failure in DependencyFailure.values) failure.name],
      ['timeout', 'unavailable', 'connection', 'rateLimited', 'error'],
    );
    for (final failure in DependencyFailure.values) {
      expect(
        (v7Event(
              dependency: CrashDependency(name: 'payments', failure: failure),
            ).toJson()['dependency']!
            as Map)['failure'],
        failure.name,
      );
    }
  });

  test('a name is a lowercase letter, then at most 47 of a-z, 0-9, _, . '
      'and -', () {
    for (final name in ['database', 'a', 'edge.fn-sync_2', 'd' * 48]) {
      expect(
        () => CrashDependency(
          name: name,
          failure: DependencyFailure.error,
        ).check(),
        returnsNormally,
        reason: name,
      );
    }
    for (final name in [
      '',
      'Database',
      '2fa',
      '_db',
      'pay ments',
      'jan@example.com',
      'd' * 49,
    ]) {
      expect(
        () => CrashDependency(
          name: name,
          failure: DependencyFailure.error,
        ).check(),
        refusedWith(ProtocolViolation.invalidValue, r'$.dependency.name'),
        reason: name,
      );
      expectRefused(
        v7Event(
          dependency: CrashDependency(
            name: name,
            failure: DependencyFailure.error,
          ),
        ),
        ProtocolViolation.invalidValue,
        r'$.dependency.name',
      );
    }
  });

  test('a code is 1 to 8 letters and digits', () {
    for (final code in ['503', '25P02', '57014', 'ECONNRST', 'a']) {
      expect(
        () => CrashDependency(
          name: 'database',
          failure: DependencyFailure.error,
          code: code,
        ).check(),
        returnsNormally,
        reason: code,
      );
    }
    for (final code in ['', '31612345678', '25P-02', 'HTTP 503', '+31612']) {
      expect(
        () => CrashDependency(
          name: 'database',
          failure: DependencyFailure.error,
          code: code,
        ).check(),
        refusedWith(ProtocolViolation.invalidValue, r'$.dependency.code'),
        reason: code,
      );
      expectRefused(
        v7Event(
          dependency: CrashDependency(
            name: 'database',
            failure: DependencyFailure.error,
            code: code,
          ),
        ),
        ProtocolViolation.invalidValue,
        r'$.dependency.code',
      );
    }
  });
}
