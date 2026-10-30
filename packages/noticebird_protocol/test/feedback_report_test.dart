// The FeedbackReport model as a client builds it: its validating writer
// against the rules of the feedback report v1 schema and the rules the schema
// cannot express, the checks of a single value, and the checks of a host's
// user context and diagnostics.

import 'dart:convert';

import 'package:noticebird_protocol/feedback.dart';
import 'package:noticebird_protocol/noticebird_protocol.dart';
import 'package:test/test.dart';

import 'support/feedback_reports.dart';

Matcher _refusedWith(ProtocolViolation violation, String path) => throwsA(
  isA<ProtocolException>()
      .having((e) => e.violation, 'violation', violation)
      .having((e) => e.path, 'path', path),
);

/// [report] refused by both writers with [violation] at [path].
void _expectRefused(
  FeedbackReport report,
  ProtocolViolation violation,
  String path,
) {
  expect(report.toJson, _refusedWith(violation, path), reason: path);
  expect(report.toJsonString, _refusedWith(violation, path), reason: path);
}

TypedBreadcrumb _crumb({
  DateTime? at,
  String action = 'record.toggle',
  Map<AllowedTag, TagScalar> data = const {},
}) => TypedBreadcrumb(
  occurredAt: at ?? DateTime.utc(2026, 10, 29, 14, 3, 1, 903),
  category: BreadcrumbCategory.ui,
  action: action,
  data: data,
);

void main() {
  group('toJson', () {
    test('writes every field, and toJsonString encodes the same', () {
      final report = fullReport();
      final json = report.toJson();
      expect(json.keys.toSet(), {
        'schemaVersion',
        'reportId',
        'createdAt',
        'kind',
        'trigger',
        'message',
        'contact',
        'app',
        'platform',
        'routeTemplate',
        'sessionId',
        'relatedEventId',
        'user',
        'userContext',
        'reporterAssertion',
        'trail',
        'diagnostics',
        'attachments',
      });
      expect(json['contact'], {'email': 'reporter@example.com'});
      expect(json['platform'], {
        'name': 'android',
        'osVersion': '16',
        'deviceClass': 'phone',
        'locale': 'en-GB',
      });
      expect((json['diagnostics']! as Map)['sync'], {
        'lastPullAt': '2026-10-29T14:01:55.000Z',
        'outboxPending': 3,
        'ratio': 0.25,
        'realtimeConnected': true,
        'spaceId': '0b6a4f1e-1c2d-4e3f-8a9b-0c1d2e3f4a5b',
      });
      expect(jsonDecode(report.toJsonString()), json);
    });

    test('a report of the required fields writes only those', () {
      expect(minimalReport().toJson().keys.toSet(), {
        'schemaVersion',
        'reportId',
        'createdAt',
        'kind',
        'message',
        'app',
        'platform',
        'sessionId',
      });
    });

    test('writes createdAt in UTC', () {
      final local = DateTime(2026, 10, 29, 15, 3, 12, 418);
      expect(
        minimalReport(createdAt: local).toJson()['createdAt'],
        local.toUtc().toIso8601String(),
      );
    });

    test('built JSON holds no null', () {
      void expectNoNull(Object? value, String path) {
        expect(value, isNotNull, reason: path);
        switch (value) {
          case Map():
            for (final MapEntry(:key, value: child) in value.entries) {
              expectNoNull(child, '$path.$key');
            }
          case List():
            for (final (index, child) in value.indexed) {
              expectNoNull(child, '$path[$index]');
            }
        }
      }

      for (final report in [
        fullReport(),
        minimalReport(),
        // Optional parts of a part left out.
        fullReport(user: const FeedbackUser(id: 'u1')),
      ]) {
        expectNoNull(report.toJson(), r'$');
        expectNoNull(jsonDecode(report.toJsonString()), r'$');
      }
    });
  });

  group('limits, at the limit and one over', () {
    String text(int length) => 'a' * length;

    void limit(
      String name, {
      required FeedbackReport Function(int) report,
      required int max,
      required ProtocolViolation violation,
      required String path,
    }) {
      test('$name: $max accepted, ${max + 1} refused', () {
        report(max).toJson();
        _expectRefused(report(max + 1), violation, path);
      });
    }

    final full = fullReport();

    limit(
      'message',
      report: (n) => replaced(full, message: text(n)),
      max: FeedbackReport.maxMessageLength,
      violation: ProtocolViolation.invalidValue,
      path: r'$.message',
    );
    test('message counts code points, not UTF-16 units', () {
      replaced(full, message: '😀' * 4000).toJson();
    });
    limit(
      'routeTemplate',
      report: (n) => replaced(full, routeTemplate: '/${text(n - 1)}'),
      max: FeedbackReport.maxRouteTemplateLength,
      violation: ProtocolViolation.invalidValue,
      path: r'$.routeTemplate',
    );
    limit(
      'contact.email',
      report: (n) => replaced(full, contactEmail: '${text(n - 10)}@b.example'),
      max: FeedbackReport.maxContactEmailLength,
      violation: ProtocolViolation.invalidValue,
      path: r'$.contact.email',
    );
    limit(
      'user.id',
      report: (n) => replaced(full, user: FeedbackUser(id: text(n))),
      max: FeedbackUser.maxIdLength,
      violation: ProtocolViolation.invalidValue,
      path: r'$.user.id',
    );
    limit(
      'user.email',
      report: (n) => replaced(full, user: FeedbackUser(email: text(n))),
      max: FeedbackUser.maxEmailLength,
      violation: ProtocolViolation.invalidValue,
      path: r'$.user.email',
    );
    limit(
      'user.name',
      report: (n) => replaced(full, user: FeedbackUser(name: text(n))),
      max: FeedbackUser.maxNameLength,
      violation: ProtocolViolation.invalidValue,
      path: r'$.user.name',
    );
    limit(
      'reporterAssertion',
      report: (n) => replaced(full, reporterAssertion: 'a.b.${text(n - 4)}'),
      max: FeedbackReport.maxReporterAssertionLength,
      violation: ProtocolViolation.invalidValue,
      path: r'$.reporterAssertion',
    );
    limit(
      'trail',
      report: (n) => replaced(full, trail: List.filled(n, _crumb())),
      max: FeedbackReport.maxTrailItems,
      violation: ProtocolViolation.oversized,
      path: r'$.trail',
    );
    limit(
      'diagnostics groups',
      report: (n) => replaced(
        full,
        diagnostics: {
          for (var i = 0; i < n; i++) 'g$i': {'v': const DiagnosticScalar(1)},
        },
      ),
      max: FeedbackReport.maxDiagnosticGroups,
      violation: ProtocolViolation.oversized,
      path: r'$.diagnostics',
    );
    limit(
      'diagnostics values per group',
      report: (n) => replaced(
        full,
        diagnostics: {
          'sync': {for (var i = 0; i < n; i++) 'v$i': DiagnosticScalar(i)},
        },
      ),
      max: FeedbackReport.maxDiagnosticValues,
      violation: ProtocolViolation.oversized,
      path: r'$.diagnostics.sync',
    );
    limit(
      'a diagnostics token',
      report: (n) => replaced(
        full,
        diagnostics: {
          'sync': {'v': DiagnosticToken(text(n))},
        },
      ),
      max: 64,
      violation: ProtocolViolation.invalidValue,
      path: r'$.diagnostics.sync.v',
    );
    limit(
      'attachments',
      report: (n) =>
          replaced(full, attachments: List.filled(n, full.attachments.single)),
      max: FeedbackReport.maxAttachments,
      violation: ProtocolViolation.oversized,
      path: r'$.attachments',
    );
    limit(
      'attachment byteLength',
      report: (n) => replaced(
        full,
        attachments: [
          FeedbackAttachmentRef(
            index: 0,
            contentType: FeedbackContentType.png,
            byteLength: n,
            sha256: exampleSha256,
          ),
        ],
      ),
      max: FeedbackAttachmentRef.maxByteLength,
      violation: ProtocolViolation.invalidValue,
      path: r'$.attachments[0].byteLength',
    );
    limit(
      'attachment index',
      report: (n) => replaced(
        full,
        attachments: [
          FeedbackAttachmentRef(
            index: n,
            contentType: FeedbackContentType.png,
            byteLength: 10,
            sha256: exampleSha256,
          ),
        ],
      ),
      max: FeedbackAttachmentRef.maxIndex,
      violation: ProtocolViolation.invalidValue,
      path: r'$.attachments[0].index',
    );

    test('diagnostics of 16 KiB are accepted, one byte more is refused', () {
      replaced(
        full,
        diagnostics: FeedbackDiagnostics.build(diagnosticsOf(16384)),
      ).toJson();
      _expectRefused(
        replaced(
          full,
          diagnostics: {
            ...FeedbackDiagnostics.build(diagnosticsOf(16384)),
            'g99': {'v': const DiagnosticScalar(1)},
          },
        ),
        ProtocolViolation.oversized,
        r'$.diagnostics',
      );
    });

    test('the worst case of every field at its maximum fits 64 KiB with an '
        'empty trail', () {
      final report = worstReport();
      expect(report.reporterAssertion!.length, 4096);
      expect(report.message.runes.length, FeedbackReport.maxMessageLength);
      expect(
        utf8.encode(report.toJsonString()).length,
        lessThanOrEqualTo(FeedbackReport.maxEncodedBytes),
      );
    });

    test('toJsonString writes 65536 bytes, and refuses one more', () {
      final base = worstReport();
      final atLimit = worstReport(trail: trailTo(base, 65536));
      expect(utf8.encode(atLimit.toJsonString()).length, 65536);
      _expectRefused(
        worstReport(trail: trailTo(base, 65537)),
        ProtocolViolation.oversized,
        r'$',
      );
    });

    test('an empty message, and an empty user, are refused', () {
      _expectRefused(
        minimalReport(message: ''),
        ProtocolViolation.invalidValue,
        r'$.message',
      );
      _expectRefused(
        fullReport(user: const FeedbackUser()),
        ProtocolViolation.invalidValue,
        r'$.user',
      );
    });

    test("the app and platform metadata by the crash protocol's rules", () {
      _expectRefused(
        replaced(
          full,
          app: AppMetadata(
            name: text(101),
            version: '1',
            build: '1',
            release: 'r',
          ),
        ),
        ProtocolViolation.invalidValue,
        r'$.app.name',
      );
      _expectRefused(
        replaced(
          full,
          platform: const PlatformMetadata(
            platform: CrashPlatform.ios,
            osVersion: '',
            deviceClass: 'phone',
          ),
        ),
        ProtocolViolation.invalidValue,
        r'$.platform.osVersion',
      );
    });
  });

  group('patterns', () {
    final full = fullReport();

    test('createdAt past the year 9999 is refused', () {
      _expectRefused(
        minimalReport(createdAt: DateTime.utc(10000)),
        ProtocolViolation.invalidValue,
        r'$.createdAt',
      );
    });

    for (final (name, value) in [
      ('in upper case', '3B0C6F2E-8D41-4A77-9C5E-1F2A3B4C5D6E'),
      ('of version 1', '3b0c6f2e-8d41-1a77-9c5e-1f2a3b4c5d6e'),
    ]) {
      test('a reportId $name is refused', () {
        _expectRefused(
          replaced(full, reportId: value),
          ProtocolViolation.invalidValue,
          r'$.reportId',
        );
      });
    }

    // A crash event's id: a UUIDv7, or the SDK's fallback id, which has no
    // version nibble.
    for (final (name, value) in [
      ('of version 4', '3b0c6f2e-8d41-4a77-9c5e-1f2a3b4c5d6e'),
      ('of version 7', '019a3f2e-8d41-7a77-9c5e-1f2a3b4c5d6e'),
      ('without a version', '3b0c6f2e-8d41-0a77-1c5e-1f2a3b4c5d6e'),
    ]) {
      test('a relatedEventId $name is accepted', () {
        expect(
          fullReport(relatedEventId: value).toJson()['relatedEventId'],
          value,
        );
      });
    }

    for (final (name, value) in [
      ('in upper case', '019A3F2E-8D41-7A77-9C5E-1F2A3B4C5D6E'),
      ('without its dashes', '019a3f2e8d417a779c5e1f2a3b4c5d6e'),
      ('one digit short', '019a3f2e-8d41-7a77-9c5e-1f2a3b4c5d6'),
    ]) {
      test('a relatedEventId $name is refused', () {
        _expectRefused(
          fullReport(relatedEventId: value),
          ProtocolViolation.invalidValue,
          r'$.relatedEventId',
        );
      });
    }

    for (final (name, value) in [
      ('15 characters', 'a' * 15),
      ('65 characters', 'a' * 65),
      ('a space', 'p_7Hq2xK9mR4 tW1zY6'),
    ]) {
      test('a sessionId of $name is refused', () {
        _expectRefused(
          replaced(full, sessionId: value),
          ProtocolViolation.invalidValue,
          r'$.sessionId',
        );
      });
    }

    test('a reporterAssertion that is no compact JWS is refused', () {
      for (final value in ['a' * 16, 'a.b.c.d${'e' * 16}', 'a.b.c']) {
        _expectRefused(
          replaced(full, reporterAssertion: value),
          ProtocolViolation.invalidValue,
          r'$.reporterAssertion',
        );
      }
    });

    test('a trail action outside the pattern is refused at its item', () {
      _expectRefused(
        replaced(
          full,
          trail: [
            _crumb(),
            _crumb(action: 'Record Toggle'),
          ],
        ),
        ProtocolViolation.invalidValue,
        r'$.trail[1].action',
      );
    });

    test('a trail timestamp past the year 9999 is refused', () {
      _expectRefused(
        replaced(full, trail: [_crumb(at: DateTime.utc(10000))]),
        ProtocolViolation.invalidValue,
        r'$.trail[0].occurredAt',
      );
    });

    test('a sha256 in upper case is refused', () {
      _expectRefused(
        fullReport(
          attachments: [
            FeedbackAttachmentRef(
              index: 0,
              contentType: FeedbackContentType.png,
              byteLength: 10,
              sha256: exampleSha256.toUpperCase(),
            ),
          ],
        ),
        ProtocolViolation.invalidValue,
        r'$.attachments[0].sha256',
      );
    });
  });

  group('U+0000 is refused in every string', () {
    const nul = '\u0000';
    final full = fullReport();
    final cases = <String, FeedbackReport>{
      r'$.message': replaced(full, message: 'before${nul}after'),
      r'$.contact.email': replaced(full, contactEmail: 'a$nul@b.example'),
      r'$.user.name': replaced(full, user: const FeedbackUser(name: 'J$nul')),
      r'$.routeTemplate': replaced(full, routeTemplate: '/list$nul'),
      r'$.app.name': replaced(
        full,
        app: const AppMetadata(
          name: 'app$nul',
          version: '1',
          build: '1',
          release: 'r',
        ),
      ),
      r'$.platform.deviceClass': replaced(
        full,
        platform: const PlatformMetadata(
          platform: CrashPlatform.ios,
          osVersion: '26.1',
          deviceClass: 'phone$nul',
        ),
      ),
      r'$.trail[0].data.component': replaced(
        full,
        trail: [
          _crumb(data: const {AllowedTag.component: 'tile$nul'}),
        ],
      ),
    };
    for (final MapEntry(key: path, value: report) in cases.entries) {
      test(path, () {
        _expectRefused(report, ProtocolViolation.invalidValue, path);
      });
    }

    test('in the user context, a value or a key', () {
      for (final (values, path) in [
        (<String, Object?>{'role': 'owner$nul'}, r'$.userContext.role'),
        (
          <String, Object?>{
            'features': ['a${nul}b'],
          },
          r'$.userContext.features[0]',
        ),
        (<String, Object?>{'ro${nul}le': 'x'}, '\$.userContext.ro${nul}le'),
      ]) {
        expect(
          () => FeedbackUserContext.check(values),
          _refusedWith(ProtocolViolation.invalidValue, path),
        );
      }
    });
  });

  group('a number that is not finite is refused', () {
    final full = fullReport();

    test('in diagnostics', () {
      _expectRefused(
        replaced(
          full,
          diagnostics: {
            'sync': {'ratio': const DiagnosticScalar(double.nan)},
          },
        ),
        ProtocolViolation.invalidValue,
        r'$.diagnostics.sync.ratio',
      );
    });

    test('in a breadcrumb', () {
      _expectRefused(
        replaced(
          full,
          trail: [
            _crumb(),
            _crumb(data: const {AllowedTag.retryCount: double.infinity}),
          ],
        ),
        ProtocolViolation.invalidValue,
        r'$.trail[1].data.retryCount',
      );
    });
  });

  group('diagnostics a host built itself are checked by their type', () {
    final full = fullReport();

    for (final (name, value, violation) in [
      (
        'a scalar that is a DateTime',
        DiagnosticScalar(DateTime.utc(2026)),
        ProtocolViolation.invalidType,
      ),
      (
        'a scalar that is a string',
        const DiagnosticScalar('premium'),
        ProtocolViolation.invalidType,
      ),
      (
        'a timestamp of a 13th month',
        const DiagnosticTimestamp('2026-13-29T14:03:12Z'),
        ProtocolViolation.invalidValue,
      ),
      (
        'a UUID of version 7',
        const DiagnosticUuid('019a3f2e-8d41-7a77-9c5e-1f2a3b4c5d6e'),
        ProtocolViolation.invalidValue,
      ),
      (
        'a token of free text',
        const DiagnosticToken('the sync failed'),
        ProtocolViolation.invalidValue,
      ),
    ]) {
      test('$name is refused', () {
        _expectRefused(
          replaced(
            full,
            diagnostics: {
              'sync': {'v': value},
            },
          ),
          violation,
          r'$.diagnostics.sync.v',
        );
      });
    }

    test('a key outside the pattern is refused', () {
      _expectRefused(
        replaced(
          full,
          diagnostics: {
            'Sync': {'v': const DiagnosticScalar(1)},
          },
        ),
        ProtocolViolation.invalidValue,
        r'$.diagnostics.Sync',
      );
    });
  });

  group('the checks of a single value', () {
    test('checkContactEmail', () {
      FeedbackReport.checkContactEmail('a@b');
      FeedbackReport.checkContactEmail('${'a' * 244}@b.example');
      for (final email in [
        'a@',
        'ab',
        'a b@c.example',
        'a@b@c',
        '${'a' * 245}@b.example',
        'a\u0000@b.example',
      ]) {
        expect(
          () => FeedbackReport.checkContactEmail(email),
          _refusedWith(ProtocolViolation.invalidValue, r'$.contact.email'),
          reason: email,
        );
      }
    });

    test('checkLocale', () {
      for (final locale in ['nl', 'nl-NL', 'zh_Hant_TW', 'sr-Latn-RS']) {
        FeedbackReport.checkLocale(locale);
      }
      for (final locale in ['n', 'nl-', 'nl NL', 'und-${'a' * 9}', '']) {
        expect(
          () => FeedbackReport.checkLocale(locale),
          _refusedWith(ProtocolViolation.invalidValue, r'$.platform.locale'),
          reason: locale,
        );
      }
    });

    test('checkRouteTemplate', () {
      FeedbackReport.checkRouteTemplate('/');
      FeedbackReport.checkRouteTemplate('/lists/:listId');
      for (final route in ['lists', '', '/${'a' * 200}', '/a\u0000']) {
        expect(
          () => FeedbackReport.checkRouteTemplate(route),
          _refusedWith(ProtocolViolation.invalidValue, r'$.routeTemplate'),
          reason: route,
        );
      }
    });

    group('checkTrailItem', () {
      final createdAt = DateTime.utc(2026, 10, 29, 14, 5);

      test('up to createdAt plus 5 minutes, not later', () {
        FeedbackReport.checkTrailItem(
          _crumb(at: createdAt.add(FeedbackReport.maxClockSkew)),
          createdAt: createdAt,
        );
        expect(
          () => FeedbackReport.checkTrailItem(
            _crumb(
              at: createdAt.add(
                FeedbackReport.maxClockSkew + const Duration(seconds: 1),
              ),
            ),
            createdAt: createdAt,
            index: 3,
          ),
          _refusedWith(
            ProtocolViolation.invalidValue,
            r'$.trail[3].occurredAt',
          ),
        );
      });

      test("an item breaking a breadcrumb's rule, at its path", () {
        for (final (item, violation, path) in [
          (
            _crumb(action: 'Tap'),
            ProtocolViolation.invalidValue,
            r'$.trail[0].action',
          ),
          (
            _crumb(at: DateTime.utc(10000)),
            ProtocolViolation.invalidValue,
            r'$.trail[0].occurredAt',
          ),
          (
            _crumb(data: const {AllowedTag.component: 'tile\u0000'}),
            ProtocolViolation.invalidValue,
            r'$.trail[0].data.component',
          ),
          (
            _crumb(data: {AllowedTag.component: 'a' * 101}),
            ProtocolViolation.oversized,
            r'$.trail[0].data.component',
          ),
        ]) {
          expect(
            () => FeedbackReport.checkTrailItem(item, createdAt: createdAt),
            _refusedWith(violation, path),
            reason: path,
          );
        }
      });
    });

    test('isUtcTimestamp', () {
      for (final value in [
        '2026-10-29T14:03:12Z',
        '2026-10-29T14:03:12.418Z',
        '2026-10-29T14:03:12.123456Z',
      ]) {
        expect(FeedbackReport.isUtcTimestamp(value), isTrue, reason: value);
      }
      for (final value in [
        '2026-10-29T14:03:12.418',
        '2026-10-29T14:03:12+01:00',
        '2026-13-29T14:03:12Z',
        '2026-10-29T25:03:12Z',
        '2026-10-29T14:03:12.1234567Z',
        '2026-10-29 14:02:40Z',
      ]) {
        expect(FeedbackReport.isUtcTimestamp(value), isFalse, reason: value);
      }
    });
  });

  group('the slot body writer', () {
    test('writes the reference without its index', () {
      const ref = FeedbackAttachmentRef(
        index: 0,
        contentType: FeedbackContentType.jpeg,
        byteLength: 10,
        sha256: exampleSha256,
      );
      expect(ref.toSlotJson(), {
        'contentType': 'image/jpeg',
        'byteLength': 10,
        'sha256': exampleSha256,
      });
    });

    for (final (name, ref, path) in [
      (
        'another index',
        const FeedbackAttachmentRef(
          index: 1,
          contentType: FeedbackContentType.png,
          byteLength: 10,
          sha256: exampleSha256,
        ),
        r'$.index',
      ),
      (
        'an empty file',
        const FeedbackAttachmentRef(
          index: 0,
          contentType: FeedbackContentType.png,
          byteLength: 0,
          sha256: exampleSha256,
        ),
        r'$.byteLength',
      ),
      (
        'a hash in upper case',
        FeedbackAttachmentRef(
          index: 0,
          contentType: FeedbackContentType.png,
          byteLength: 10,
          sha256: exampleSha256.toUpperCase(),
        ),
        r'$.sha256',
      ),
    ]) {
      test('$name is refused', () {
        expect(
          ref.toSlotJson,
          _refusedWith(ProtocolViolation.invalidValue, path),
        );
      });
    }
  });

  group('FeedbackUserContext.check', () {
    FeedbackUserContext check(Map<String, Object?> values) =>
        FeedbackUserContext.check(values);

    void expectRefused(
      Map<String, Object?> values,
      ProtocolViolation violation,
      String path,
    ) {
      expect(() => check(values), _refusedWith(violation, path));
    }

    Map<String, Object?> keys(int count) => {
      for (var i = 0; i < count; i++) 'k$i': i,
    };

    test('takes scalars, arrays of scalars and one nested object', () {
      final context = check({
        'role': 'owner',
        'seats': 5,
        'ratio': 0.5,
        'beta': false,
        'roles': ['owner', 2, true],
        'plan': {
          'tier': 'premium',
          'features': ['sharing'],
        },
      });
      expect(context.values['ratio'], 0.5);
      expect(context.toJson()['plan'], {
        'tier': 'premium',
        'features': ['sharing'],
      });
      expect(
        () => (context.values['roles']! as List).add('x'),
        throwsUnsupportedError,
      );
    });

    test('32 keys accepted, 33 refused', () {
      check(keys(32));
      expectRefused(keys(33), ProtocolViolation.oversized, r'$.userContext');
    });

    test('32 keys in the nested object accepted, 33 refused', () {
      check({'plan': keys(32)});
      expectRefused(
        {'plan': keys(33)},
        ProtocolViolation.oversized,
        r'$.userContext.plan',
      );
    });

    test('a key of 64 characters accepted, 65 refused', () {
      final key = 'a${'b' * 63}';
      check({key: 1});
      expectRefused(
        {'${key}c': 1},
        ProtocolViolation.invalidValue,
        '\$.userContext.${key}c',
      );
    });

    for (final (name, key) in [
      ('starts with a digit', '1st'),
      ('holds a dot', 'plan.tier'),
      ('holds a space', 'the plan'),
      ('is empty', ''),
    ]) {
      test('a key that $name is refused', () {
        expectRefused(
          {key: 1},
          ProtocolViolation.invalidValue,
          '\$.userContext.$key',
        );
      });
    }

    test('a nested key outside the pattern is refused at its path', () {
      expectRefused(
        {
          'plan': {'_tier': 'x'},
        },
        ProtocolViolation.invalidValue,
        r'$.userContext.plan._tier',
      );
    });

    test('a string of 256 characters accepted, 257 refused, counted in code '
        'points', () {
      check({'name': 'a' * 256});
      check({'name': '😀' * 256});
      expectRefused(
        {'name': 'a' * 257},
        ProtocolViolation.invalidValue,
        r'$.userContext.name',
      );
      expectRefused(
        {
          'plan': {'tier': '😀' * 257},
        },
        ProtocolViolation.invalidValue,
        r'$.userContext.plan.tier',
      );
    });

    test('an array of 16 accepted, 17 refused', () {
      check({'roles': List.filled(16, 'r')});
      expectRefused(
        {'roles': List.filled(17, 'r')},
        ProtocolViolation.oversized,
        r'$.userContext.roles',
      );
      expectRefused(
        {
          'plan': {'features': List.filled(17, 1)},
        },
        ProtocolViolation.oversized,
        r'$.userContext.plan.features',
      );
    });

    for (final (name, values, violation, path) in [
      (
        'an empty context',
        <String, Object?>{},
        ProtocolViolation.invalidValue,
        r'$.userContext',
      ),
      (
        'an empty string',
        <String, Object?>{'name': ''},
        ProtocolViolation.invalidValue,
        r'$.userContext.name',
      ),
      (
        'an empty array',
        <String, Object?>{'roles': <Object?>[]},
        ProtocolViolation.invalidValue,
        r'$.userContext.roles',
      ),
      (
        'an empty nested object',
        <String, Object?>{'plan': <String, Object?>{}},
        ProtocolViolation.invalidValue,
        r'$.userContext.plan',
      ),
      (
        'an object nested twice',
        <String, Object?>{
          'plan': {
            'tier': {'name': 'premium'},
          },
        },
        ProtocolViolation.invalidType,
        r'$.userContext.plan.tier',
      ),
      (
        'an object in an array',
        <String, Object?>{
          'roles': [
            {'name': 'owner'},
          ],
        },
        ProtocolViolation.invalidType,
        r'$.userContext.roles[0]',
      ),
      (
        'an array in an array',
        <String, Object?>{
          'roles': [
            'owner',
            ['nested'],
          ],
        },
        ProtocolViolation.invalidType,
        r'$.userContext.roles[1]',
      ),
      (
        'an object in a nested array',
        <String, Object?>{
          'plan': {
            'features': [
              {'a': 1},
            ],
          },
        },
        ProtocolViolation.invalidType,
        r'$.userContext.plan.features[0]',
      ),
      (
        'a null value',
        <String, Object?>{'role': null},
        ProtocolViolation.invalidType,
        r'$.userContext.role',
      ),
      (
        'a null in an array',
        <String, Object?>{
          'features': ['a', null],
        },
        ProtocolViolation.invalidType,
        r'$.userContext.features[1]',
      ),
      (
        'a number that is not finite',
        <String, Object?>{
          'plan': {'seats': double.infinity},
        },
        ProtocolViolation.invalidValue,
        r'$.userContext.plan.seats',
      ),
      (
        'a key that is no string',
        <String, Object?>{
          'plan': {1: 'x'},
        },
        ProtocolViolation.invalidType,
        r'$.userContext.plan',
      ),
      (
        'a value that is no JSON',
        <String, Object?>{'since': DateTime.utc(2026)},
        ProtocolViolation.invalidType,
        r'$.userContext.since',
      ),
      (
        'one byte over its size',
        contextOf(FeedbackUserContext.maxEncodedBytes + 1),
        ProtocolViolation.oversized,
        r'$.userContext',
      ),
    ]) {
      test('$name is refused at its path', () {
        expectRefused(values, violation, path);
      });
    }

    test('a context that nests into itself is refused, not walked', () {
      final plan = <String, Object?>{};
      plan['plan'] = plan;
      expectRefused(
        {'plan': plan},
        ProtocolViolation.invalidType,
        r'$.userContext.plan.plan',
      );
    });

    group('8192 bytes of compact UTF-8 JSON accepted, 8193 refused', () {
      /// [count] values of [length] times [char], and one ASCII value that
      /// brings the encoding to exactly [bytes].
      Map<String, Object?> sized(
        int bytes,
        String char,
        int count,
        int length,
      ) {
        String key(int index) => 'k${index.toString().padLeft(2, '0')}';
        final context = <String, Object?>{
          for (var i = 0; i < count; i++) key(i): char * length,
        };
        // `,"kNN":""` around the last value.
        final rest = bytes - utf8.encode(jsonEncode(context)).length - 9;
        expect(rest, inInclusiveRange(1, 256));
        context[key(count)] = 'a' * rest;
        expect(utf8.encode(jsonEncode(context)).length, bytes);
        return context;
      }

      test('integral numbers count as the integers they are', () {
        // 8192 bytes once `100.0` is written `100`; 8194 as Dart writes it.
        // `,"n":100` is 8 bytes.
        final context = sized(8184, 'a', 30, 256)..['n'] = 100;
        expect(utf8.encode(jsonEncode(context)).length, 8192);
        check({...context, 'n': 100.0});
      });

      test('an integer past 2^53 counts as the double it reads as', () {
        const big = 1 << 60;
        // `,"n":` and the number: longer as the double the platform reads
        // than as the integer.
        final asDouble = 5 + jsonEncode(big.toDouble()).length;
        expect(asDouble, greaterThan(5 + jsonEncode(big).length));
        Map<String, Object?> context(int platformBytes) {
          final context = sized(platformBytes - asDouble, 'a', 30, 256)
            ..['n'] = big;
          expect(
            utf8.encode(jsonEncode({...context, 'n': big.toDouble()})).length,
            platformBytes,
          );
          return context;
        }

        check(context(8192));
        // Under 8192 bytes as the integer, 8193 as the platform counts it.
        expect(utf8.encode(jsonEncode(context(8193))).length, lessThan(8192));
        expectRefused(
          context(8193),
          ProtocolViolation.oversized,
          r'$.userContext',
        );
      });

      for (final (name, char, count, length) in [
        ('ASCII', 'a', 30, 256),
        ('three-byte characters', '€', 11, 240),
        ('four-byte characters', '😀', 8, 250),
      ]) {
        test(name, () {
          check(sized(8192, char, count, length));
          expectRefused(
            sized(8193, char, count, length),
            ProtocolViolation.oversized,
            r'$.userContext',
          );
        });
      }
    });
  });

  group('FeedbackDiagnostics.build', () {
    test('types every value', () {
      final at = DateTime.utc(2026, 10, 29, 14, 1, 55);
      final sync = FeedbackDiagnostics.build({
        'sync': {
          'on': true,
          'count': 3,
          'ratio': 0.5,
          'at': at,
          'atText': '2026-10-29T14:01:55Z',
          'space': '0b6a4f1e-1c2d-4e3f-8a9b-0c1d2e3f4a5b',
          'event': '019a3f2e-8d41-7a77-9c5e-1f2a3b4c5d6e',
          'tier': 'premium',
          'token': 'a' * 64,
        },
      })['sync']!;
      expect(sync['on'], isA<DiagnosticScalar>());
      expect(sync['ratio']!.json, 0.5);
      expect(sync['at'], isA<DiagnosticTimestamp>());
      expect(sync['at']!.json, at.toIso8601String());
      expect(sync['atText'], isA<DiagnosticTimestamp>());
      expect(sync['space'], isA<DiagnosticUuid>());
      // Not a v4 UUID: a token.
      expect(sync['event'], isA<DiagnosticToken>());
      expect(sync['tier'], isA<DiagnosticToken>());
      expect(sync['token'], isA<DiagnosticToken>());
    });

    test('16 groups of 32 values and 16 KiB accepted', () {
      FeedbackDiagnostics.build({
        for (var g = 0; g < 16; g++)
          'g$g': {for (var v = 0; v < 32; v++) 'v$v': v},
      });
      final atLimit = diagnosticsOf(16384);
      expect(utf8.encode(jsonEncode(atLimit)).length, 16384);
      FeedbackDiagnostics.build(atLimit);
    });

    for (final (name, groups, violation, path)
        in <
          (String, Map<String, Map<String, Object?>>, ProtocolViolation, String)
        >[
          (
            'free text',
            {
              'sync': {'note': 'the sync failed'},
            },
            ProtocolViolation.invalidValue,
            r'$.diagnostics.sync.note',
          ),
          (
            'an empty string',
            {
              'sync': {'note': ''},
            },
            ProtocolViolation.invalidValue,
            r'$.diagnostics.sync.note',
          ),
          (
            'a token of 65 characters',
            {
              'sync': {'note': 'a' * 65},
            },
            ProtocolViolation.invalidValue,
            r'$.diagnostics.sync.note',
          ),
          (
            'null',
            {
              'sync': {'note': null},
            },
            ProtocolViolation.invalidType,
            r'$.diagnostics.sync.note',
          ),
          (
            'a number that is not finite',
            {
              'sync': {'ratio': double.nan},
            },
            ProtocolViolation.invalidValue,
            r'$.diagnostics.sync.ratio',
          ),
          (
            'infinity',
            {
              'sync': {'ratio': double.infinity},
            },
            ProtocolViolation.invalidValue,
            r'$.diagnostics.sync.ratio',
          ),
          (
            'a local DateTime',
            {
              'sync': {'at': DateTime(2026)},
            },
            ProtocolViolation.invalidValue,
            r'$.diagnostics.sync.at',
          ),
          (
            'a DateTime past year 9999',
            {
              'sync': {'at': DateTime.utc(10000)},
            },
            ProtocolViolation.invalidValue,
            r'$.diagnostics.sync.at',
          ),
          (
            'a list',
            {
              'sync': {
                'ids': <Object>[1],
              },
            },
            ProtocolViolation.invalidType,
            r'$.diagnostics.sync.ids',
          ),
          (
            'a map',
            {
              'sync': {
                'nested': {'a': 1},
              },
            },
            ProtocolViolation.invalidType,
            r'$.diagnostics.sync.nested',
          ),
          (
            'a duration',
            {
              'sync': {'took': Duration.zero},
            },
            ProtocolViolation.invalidType,
            r'$.diagnostics.sync.took',
          ),
          (
            'a key outside the pattern',
            {
              'sync': {'Count': 1},
            },
            ProtocolViolation.invalidValue,
            r'$.diagnostics.sync.Count',
          ),
          (
            'a group name outside the pattern',
            {
              'Sync': {'count': 1},
            },
            ProtocolViolation.invalidValue,
            r'$.diagnostics.Sync',
          ),
          (
            '33 values in a group',
            {
              'sync': {for (var v = 0; v < 33; v++) 'v$v': v},
            },
            ProtocolViolation.oversized,
            r'$.diagnostics.sync',
          ),
          (
            '17 groups',
            {
              for (var g = 0; g < 17; g++) 'g$g': {'v': 1},
            },
            ProtocolViolation.oversized,
            r'$.diagnostics',
          ),
          (
            'one byte over 16 KiB',
            diagnosticsOf(16385),
            ProtocolViolation.oversized,
            r'$.diagnostics',
          ),
        ]) {
      test('$name is refused at $path', () {
        expect(
          () => FeedbackDiagnostics.build(groups),
          _refusedWith(violation, path),
        );
      });
    }
  });
}
