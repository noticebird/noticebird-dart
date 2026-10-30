// The app's own grouping key (schema 5) as a client builds it.

import 'package:noticebird_protocol/noticebird_protocol.dart';
import 'package:test/test.dart';

import 'support/crash_events.dart';

void main() {
  test('the key is written as given, its parts in order', () {
    expect(v5Event().toJson()['groupingKey'], [
      'sync-refusal',
      '23505',
      'collections',
    ]);
  });

  test('an event without a key writes none', () {
    expect(v5Event(groupingKey: null).toJson(), isNot(contains('groupingKey')));
  });

  test('a key has one to eight parts', () {
    expectRefused(
      v5Event(groupingKey: const []),
      ProtocolViolation.invalidValue,
      r'$.groupingKey',
    );
    expect(
      v5Event(
        groupingKey: [
          for (var i = 0; i < CrashEvent.maxGroupingKeyParts; i++) 'part$i',
        ],
      ).toJson()['groupingKey'],
      hasLength(CrashEvent.maxGroupingKeyParts),
    );
    expectRefused(
      v5Event(
        groupingKey: [
          for (var i = 0; i <= CrashEvent.maxGroupingKeyParts; i++) 'part$i',
        ],
      ),
      ProtocolViolation.oversized,
      r'$.groupingKey',
    );
  });

  test('each part is a non-empty string of at most 100 characters', () {
    expectRefused(
      v5Event(groupingKey: const ['sync-refusal', '']),
      ProtocolViolation.invalidValue,
      r'$.groupingKey[]',
    );
    expect(
      v5Event(
        groupingKey: ['a' * CrashEvent.maxGroupingKeyPartLength],
      ).toJson()['groupingKey'],
      ['a' * CrashEvent.maxGroupingKeyPartLength],
    );
    expectRefused(
      v5Event(groupingKey: ['a' * (CrashEvent.maxGroupingKeyPartLength + 1)]),
      ProtocolViolation.oversized,
      r'$.groupingKey[]',
    );
  });
}
