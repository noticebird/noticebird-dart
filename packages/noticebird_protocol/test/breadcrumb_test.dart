// The breadcrumb as a client builds it (protocol v2 of a breadcrumb): its
// JSON, every limit and pattern of its fields, and the 512 bytes of a step.

import 'package:noticebird_protocol/noticebird_protocol.dart';
import 'package:test/test.dart';

import 'support/crash_events.dart';

void main() {
  group('toJson', () {
    test('writes every field it has', () {
      expect(v6Breadcrumb().toJson(), {
        'at': '2026-07-11T10:14:59.000Z',
        'message': 'Opened page',
        'action': 'route.push',
        'category': 'navigation',
        'level': 'info',
        'data': {'route': '/lists/:listId', 'from': '/'},
      });
    });

    test('leaves out what it does not have', () {
      final step = TypedBreadcrumb(
        at: DateTime.utc(2026, 7, 11),
        message: 'Started',
      );
      expect(step.toJson(), {
        'at': '2026-07-11T00:00:00.000Z',
        'message': 'Started',
      });
      step.check();
    });

    test('writes its moment in UTC', () {
      final local = DateTime(2026, 7, 11, 12);
      expect(
        TypedBreadcrumb(at: local, message: 'm').toJson()['at'],
        local.toUtc().toIso8601String(),
      );
    });
  });

  group('check', () {
    void refused(
      TypedBreadcrumb step,
      ProtocolViolation violation,
      String path,
    ) => expect(step.check, refusedWith(violation, path), reason: path);

    test('a message of 1 to 200 characters, on one line', () {
      v6Breadcrumb(message: 'm' * TypedBreadcrumb.maxMessageLength).check();
      for (final message in [
        '',
        'm' * (TypedBreadcrumb.maxMessageLength + 1),
        'one\ntwo',
        'one\r\ntwo',
        'one\rtwo',
        'one two',
        'one\u0085two',
        'nul\u0000',
      ]) {
        refused(
          v6Breadcrumb(message: message),
          ProtocolViolation.invalidValue,
          r'$.breadcrumbs[].message',
        );
      }
    });

    test('a character is a UTF-16 code unit', () {
      // 100 emoji are 200 code units: at the limit, and one more is over.
      v6Breadcrumb(message: '😀' * 100, data: const {}).check();
      refused(
        v6Breadcrumb(message: '${'😀' * 100}a', data: const {}),
        ProtocolViolation.invalidValue,
        r'$.breadcrumbs[].message',
      );
    });

    test('an action of 1 to 100 characters by its pattern', () {
      for (final action in [
        'route.push',
        'profileBloc.change',
        'sync.write_held-2',
        'a' * TypedBreadcrumb.maxActionLength,
      ]) {
        v6Breadcrumb(action: action).check();
      }
      v6Breadcrumb(action: null).check();
      for (final action in [
        '',
        'Route.push',
        '1route',
        'route push',
        'route:push',
        'a' * (TypedBreadcrumb.maxActionLength + 1),
      ]) {
        refused(
          v6Breadcrumb(action: action),
          ProtocolViolation.invalidValue,
          r'$.breadcrumbs[].action',
        );
      }
    });

    test('a category of 1 to 32 characters by its pattern', () {
      for (final category in [
        'bloc',
        'sync_2',
        'c' * TypedBreadcrumb.maxCategoryLength,
      ]) {
        v6Breadcrumb(category: category).check();
      }
      v6Breadcrumb(category: null).check();
      for (final category in [
        '',
        'Bloc',
        'bloc.change',
        'blocState',
        '_bloc',
        'c' * (TypedBreadcrumb.maxCategoryLength + 1),
      ]) {
        refused(
          v6Breadcrumb(category: category),
          ProtocolViolation.invalidValue,
          r'$.breadcrumbs[].category',
        );
      }
    });

    test('a level is optional', () {
      for (final level in [null, ...BreadcrumbLevel.values]) {
        final step = v6Breadcrumb(level: level);
        step.check();
        expect(step.toJson()['level'], level?.name);
      }
    });

    test('at most 16 data entries', () {
      Map<String, Object> entries(int count) => {
        for (var i = 0; i < count; i++) 'n$i': i,
      };
      v6Breadcrumb(data: entries(TypedBreadcrumb.maxDataEntries)).check();
      refused(
        v6Breadcrumb(data: entries(TypedBreadcrumb.maxDataEntries + 1)),
        ProtocolViolation.oversized,
        r'$.breadcrumbs[].data',
      );
    });

    test('a data name of 1 to 48 characters by its pattern', () {
      for (final name in [
        'status',
        'collections.count',
        'error.reason',
        'retryCount',
        'a_b.c_d.e',
        'n' * TypedBreadcrumb.maxDataNameLength,
      ]) {
        expect(TypedBreadcrumb.isDataName(name), isTrue, reason: name);
        v6Breadcrumb(data: {name: 1}).check();
      }
      for (final name in [
        '',
        'Status',
        '_status',
        'status.',
        '.status',
        'a..b',
        'a.B',
        'a-b',
        'a b',
        'n' * (TypedBreadcrumb.maxDataNameLength + 1),
      ]) {
        expect(TypedBreadcrumb.isDataName(name), isFalse, reason: name);
        refused(
          v6Breadcrumb(data: {name: 1}),
          ProtocolViolation.invalidValue,
          '\$.breadcrumbs[].data.$name',
        );
      }
    });

    test('a data value is a finite number, a boolean or a data string', () {
      for (final value in <Object>[
        0,
        -3.5,
        true,
        false,
        'loaded',
        '/lists/:listId',
        'sync.write_held:collection_entries',
        '1.2.0+42',
        'id1',
        'v' * TypedBreadcrumb.maxDataStringLength,
      ]) {
        expect(TypedBreadcrumb.isDataValue(value), isTrue, reason: '$value');
        v6Breadcrumb(data: {'value': value}).check();
      }
      for (final (value, violation) in <(Object, ProtocolViolation)>[
        ('', ProtocolViolation.invalidValue),
        ('two words', ProtocolViolation.invalidValue),
        ('-leading', ProtocolViolation.invalidValue),
        ('_leading', ProtocolViolation.invalidValue),
        ('a@b', ProtocolViolation.invalidValue),
        ('line\nbreak', ProtocolViolation.invalidValue),
        (
          'v' * (TypedBreadcrumb.maxDataStringLength + 1),
          ProtocolViolation.oversized,
        ),
        (double.nan, ProtocolViolation.invalidValue),
        (double.infinity, ProtocolViolation.invalidValue),
        (const ['a'], ProtocolViolation.invalidType),
        (const {'a': 1}, ProtocolViolation.invalidType),
      ]) {
        expect(TypedBreadcrumb.isDataValue(value), isFalse, reason: '$value');
        refused(
          v6Breadcrumb(data: {'value': value}),
          violation,
          r'$.breadcrumbs[].data.value',
        );
      }
    });

    test('a step takes at most 512 bytes encoded', () {
      // A 200-character message of three-byte characters and full data
      // entries: every field within its own limit, the step over 512 bytes.
      final over = v6Breadcrumb(
        message: '€' * TypedBreadcrumb.maxMessageLength,
        data: {for (var i = 0; i < 4; i++) 'name$i': 'v' * 64},
      );
      expect(over.encodedBytes, greaterThan(TypedBreadcrumb.maxEncodedBytes));
      refused(over, ProtocolViolation.oversized, r'$.breadcrumbs[]');
      final fitting = v6Breadcrumb(message: '€' * 100);
      expect(
        fitting.encodedBytes,
        lessThanOrEqualTo(TypedBreadcrumb.maxEncodedBytes),
      );
      fitting.check();
    });
  });

  test('trailBytes counts the canonical JSON array in UTF-8', () {
    final step = v6Breadcrumb(message: 'é');
    expect(TypedBreadcrumb.trailBytes(const []), 2);
    expect(TypedBreadcrumb.trailBytes([step]), step.encodedBytes + 2);
    expect(TypedBreadcrumb.trailBytes([step, step]), 2 * step.encodedBytes + 3);
  });

  test('dataEntryText reads a name and its value together', () {
    expect(TypedBreadcrumb.dataEntryText('status', 'loaded'), 'status: loaded');
    expect(
      TypedBreadcrumb.dataEntryText('contact', 31612345678),
      'contact: 31612345678',
    );
    expect(TypedBreadcrumb.dataEntryText('ratio', 0.5), 'ratio: 0.5');
    expect(TypedBreadcrumb.dataEntryText('busy', true), 'busy: true');
  });
}
