// The CrashEvent model as a client builds it: its validating writer against
// the rules of the current schema, and the checks of a single value.

import 'dart:convert';

import 'package:noticebird_protocol/noticebird_protocol.dart';
import 'package:test/test.dart';

import 'support/crash_events.dart';

void main() {
  group('toJson', () {
    test('the fixture built from its values is the fixture', () {
      expect(v5Event().toJson(), v5Fixture());
    });

    test('writes the current schema version', () {
      expect(CrashEvent.schemaVersion, 5);
      expect(v5Event().toJson()['schemaVersion'], CrashEvent.schemaVersion);
    });

    test('toCanonicalJson encodes toJson', () {
      final event = v5Event(
        extra: const {
          'zone': 'eu',
          'attempt': {'retry': true, 'count': 2},
        },
      );
      expect(jsonDecode(event.toCanonicalJson()), event.toJson());
      expect(event.toCanonicalJson(), canonicalJsonEncode(event.toJson()));
    });

    test('an event without its optional fields leaves them out', () {
      final json = v5Event(
        routeTemplate: null,
        user: null,
        tags: const {},
        extra: const {},
        breadcrumbs: const [],
        groupingKey: null,
      ).toJson();
      expect(json.keys, isNot(contains('routeTemplate')));
      expect(json.keys, isNot(contains('user')));
      expect(json.keys, isNot(contains('tags')));
      expect(json.keys, isNot(contains('extra')));
      expect(json.keys, isNot(contains('breadcrumbs')));
      expect(json.keys, isNot(contains('groupingKey')));
    });
  });

  test('canonical JSON recursively sorts object keys', () {
    expect(
      canonicalJsonEncode({
        'z': 1,
        'a': {'y': 2, 'b': 3},
      }),
      '{"a":{"b":3,"y":2},"z":1}',
    );
  });

  group('every rule of an event', () {
    test('the event id has a UUID\'s shape', () {
      expectRefused(
        v5Event(eventId: 'not-an-event-id'),
        ProtocolViolation.invalidValue,
        r'$.eventId',
      );
    });

    test('the exception\'s fields are bounded and never empty', () {
      for (final (exception, field) in [
        (
          CrashException(
            type: 't' * (CrashException.maxTypeLength + 1),
            sanitizedMessage: 'm',
            stackTrace: 's',
          ),
          'type',
        ),
        (
          const CrashException(
            type: '',
            sanitizedMessage: 'm',
            stackTrace: 's',
          ),
          'type',
        ),
        (
          CrashException(
            type: 't',
            sanitizedMessage: 'm' * (CrashException.maxMessageLength + 1),
            stackTrace: 's',
          ),
          'sanitizedMessage',
        ),
        (
          CrashException(
            type: 't',
            sanitizedMessage: 'm',
            stackTrace: 's' * (CrashException.maxStackTraceLength + 1),
          ),
          'stackTrace',
        ),
      ]) {
        expectRefused(
          v5Event(exception: exception),
          ProtocolViolation.invalidValue,
          '\$.exception.$field',
        );
      }
    });

    test('the app and the platform are checked as their check does', () {
      final longName = AppMetadata(
        name: 'a' * (AppMetadata.maxNameLength + 1),
        version: '1',
        build: '1',
        release: 'r',
      );
      expect(
        longName.check,
        refusedWith(ProtocolViolation.invalidValue, r'$.app.name'),
      );
      expectRefused(
        v5Event(app: longName),
        ProtocolViolation.invalidValue,
        r'$.app.name',
      );

      const noOs = PlatformMetadata(
        platform: CrashPlatform.ios,
        osVersion: '',
        deviceClass: 'mobile',
      );
      expect(
        noOs.check,
        refusedWith(ProtocolViolation.invalidValue, r'$.platform.osVersion'),
      );
      expectRefused(
        v5Event(platform: noOs),
        ProtocolViolation.invalidValue,
        r'$.platform.osVersion',
      );
      v5App.check();
      v5Platform.check();
    });

    test('the session id matches its pattern', () {
      expectRefused(
        v5Event(sessionId: 'short'),
        ProtocolViolation.invalidValue,
        r'$.sessionId',
      );
    });

    test('a route template is a bounded path from the root', () {
      for (final route in [
        'lists/:listId',
        '/${'a' * CrashEvent.maxRouteTemplateLength}',
      ]) {
        expectRefused(
          v5Event(routeTemplate: route),
          ProtocolViolation.invalidValue,
          r'$.routeTemplate',
        );
      }
    });

    test('a user has a field, each bounded', () {
      expect(
        const CrashUser().check,
        refusedWith(ProtocolViolation.invalidValue, r'$.user'),
      );
      expectRefused(
        v5Event(user: const CrashUser()),
        ProtocolViolation.invalidValue,
        r'$.user',
      );
      for (final (user, field) in [
        (CrashUser(id: 'i' * (CrashUser.maxIdLength + 1)), 'id'),
        (CrashUser(email: 'e' * (CrashUser.maxEmailLength + 1)), 'email'),
        (CrashUser(name: 'n' * (CrashUser.maxNameLength + 1)), 'name'),
        (
          CrashUser(ipAddress: '1' * (CrashUser.maxIpAddressLength + 1)),
          'ipAddress',
        ),
        (const CrashUser(name: ''), 'name'),
      ]) {
        expectRefused(
          v5Event(user: user),
          ProtocolViolation.invalidValue,
          '\$.user.$field',
        );
      }
      const CrashUser(
        id: 'user-123',
        email: 'person@example.com',
        name: 'Example Person',
        ipAddress: '203.0.113.10',
      ).check();
    });

    test('a tag is a bounded scalar', () {
      expectRefused(
        v5Event(tags: {AllowedTag.feature: 'x' * (maxTagValueLength + 1)}),
        ProtocolViolation.oversized,
        r'$.tags.feature',
      );
      expectRefused(
        v5Event(
          tags: const {
            AllowedTag.feature: {'patient': 'forbidden'},
          },
        ),
        ProtocolViolation.invalidType,
        r'$.tags.feature',
      );
      for (final number in [double.nan, double.infinity, -double.infinity]) {
        expectRefused(
          v5Event(tags: {AllowedTag.retryCount: number}),
          ProtocolViolation.invalidValue,
          r'$.tags.retryCount',
        );
        expectRefused(
          v5Event(
            breadcrumbs: [
              v5Breadcrumb(data: {AllowedTag.retryCount: number}),
            ],
          ),
          ProtocolViolation.invalidValue,
          r'$.breadcrumbs[].data.retryCount',
        );
      }
    });

    test('isTagValue answers what a tag takes', () {
      for (final value in <TagScalar>[
        '',
        'x' * maxTagValueLength,
        3,
        0.5,
        true,
      ]) {
        expect(isTagValue(value), isTrue, reason: '$value');
        v5Event(tags: {AllowedTag.feature: value}).toJson();
      }
      for (final value in <TagScalar>[
        'x' * (maxTagValueLength + 1),
        double.nan,
        double.infinity,
        -double.infinity,
        const {'k': 'v'},
        const ['v'],
      ]) {
        expect(isTagValue(value), isFalse, reason: '$value');
        expect(
          () => v5Event(tags: {AllowedTag.feature: value}).toJson(),
          throwsA(isA<ProtocolException>()),
        );
      }
    });

    test('extra is bounded JSON with keys of its pattern', () {
      final cases = <String, (Map<String, Object?>, ProtocolViolation, String)>{
        'too many fields': (
          {for (var i = 0; i <= CrashEvent.maxExtraEntries; i++) 'k$i': i},
          ProtocolViolation.oversized,
          r'$.extra',
        ),
        'a key outside the pattern': (
          {'invalid key': true},
          ProtocolViolation.invalidValue,
          r'$.extra.invalid key',
        ),
        'a nested key outside the pattern': (
          {
            'nested': {'_hidden': true},
          },
          ProtocolViolation.invalidValue,
          r'$.extra.nested._hidden',
        ),
        'nesting past two levels': (
          {
            'nested': {
              'second': {
                'third': {'fourth': 'too deep'},
              },
            },
          },
          ProtocolViolation.oversized,
          r'$.extra.nested.second.third',
        ),
        'a long list': (
          {'items': List.filled(CrashEvent.maxExtraEntries + 1, 1)},
          ProtocolViolation.oversized,
          r'$.extra.items',
        ),
        'a long string': (
          {'note': 'x' * (CrashEvent.maxExtraStringLength + 1)},
          ProtocolViolation.oversized,
          r'$.extra.note',
        ),
        'a number that is not finite': (
          {
            'ratios': [1.5, double.nan],
          },
          ProtocolViolation.invalidValue,
          r'$.extra.ratios[1]',
        ),
        'a value JSON cannot carry': (
          {'when': DateTime.utc(2026)},
          ProtocolViolation.invalidType,
          r'$.extra.when',
        ),
      };
      for (final MapEntry(key: name, value: (extra, violation, path))
          in cases.entries) {
        expect(
          v5Event(extra: extra).toJson,
          refusedWith(violation, path),
          reason: name,
        );
      }
      v5Event(
        extra: const {
          'http_status': 503,
          'request': {
            'attempt': 2,
            'cached': false,
            'steps': ['load', null],
          },
        },
      ).toJson();
    });

    test('at most 50 breadcrumbs, each checked as its check does', () {
      expectRefused(
        v5Event(
          breadcrumbs: List.filled(
            CrashEvent.maxBreadcrumbs + 1,
            v5Breadcrumb(),
          ),
        ),
        ProtocolViolation.oversized,
        r'$.breadcrumbs',
      );
      for (final (breadcrumb, violation, path) in [
        (
          v5Breadcrumb(action: 'Route.Push'),
          ProtocolViolation.invalidValue,
          r'$.breadcrumbs[].action',
        ),
        (
          v5Breadcrumb(action: 'r' * (TypedBreadcrumb.maxActionLength + 1)),
          ProtocolViolation.invalidValue,
          r'$.breadcrumbs[].action',
        ),
        (
          v5Breadcrumb(
            data: {AllowedTag.component: 'c' * (maxTagValueLength + 1)},
          ),
          ProtocolViolation.oversized,
          r'$.breadcrumbs[].data.component',
        ),
      ]) {
        expect(breadcrumb.check, refusedWith(violation, path));
        expectRefused(v5Event(breadcrumbs: [breadcrumb]), violation, path);
      }
      v5Breadcrumb().check();
    });

    test('the encoded event is at most 64 KiB', () {
      expectRefused(
        v5Event(
          extra: {
            for (var i = 0; i < 4; i++)
              'k$i': List.filled(20, 'x' * CrashEvent.maxExtraStringLength),
          },
        ),
        ProtocolViolation.oversized,
        r'$',
      );
    });
  });
}
