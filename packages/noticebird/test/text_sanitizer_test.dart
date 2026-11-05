// The client's sanitizing of a breadcrumb and a trail: what is left out of a
// step and counted, in which order a step over its bytes is trimmed, and how
// a trail is held to its budget.

import 'package:noticebird/feedback.dart';
import 'package:noticebird/noticebird.dart';
import 'package:noticebird/src/protocol/text_sanitizer.dart';
import 'package:test/test.dart';

void main() {
  final at = DateTime.utc(2026, 11, 5, 9);

  TypedBreadcrumb crumb(
    String message, {
    String? action,
    String? category,
    Map<String, Object> details = const {},
  }) => TypedBreadcrumb(
    at: at,
    message: message,
    action: action,
    category: category,
    details: details,
  );

  SanitizedBreadcrumb sanitized(TypedBreadcrumb step, {bool strict = false}) =>
      sanitizeBreadcrumb(step, strict: strict);

  group('sanitizeBreadcrumb', () {
    test('a step within the rules goes as it is', () {
      final given = crumb(
        'Opened page',
        action: 'route.push',
        category: 'navigation',
        details: const {
          'route': '/lists/:listId',
          'items.count': 3,
          'busy': true,
        },
      );
      final (:step, :detailsDropped) = sanitized(given);
      expect(step!.toJson(), given.toJson());
      expect(detailsDropped, 0);
    });

    test('a line break in the message becomes a space, U+0000 goes', () {
      final (:step, :detailsDropped) = sanitized(
        crumb('one\ntwo\r\nthree\rfour five\u0000'),
      );
      expect(step!.message, 'one two three four five');
      expect(detailsDropped, 0);
    });

    test('a zero-width joiner and non-joiner stay as they are', () {
      for (final message in [
        'Shared with 👨\u200D👩\u200D👧',
        'می\u200Cخواهم',
      ]) {
        final (:step, :detailsDropped) = sanitized(crumb(message));
        expect(step!.message, message);
        expect(detailsDropped, 0);
      }
    });

    test('a control, zero-width or bidirectional character in the message '
        'becomes a space', () {
      for (final control in [
        '\u0001',
        '\u001B',
        '\u007F',
        '\u0090',
        '\u200B',
        '\u200E',
        '\u200F',
        '\u202E',
        '\u2066',
        '\u061C',
        '\u2060',
        '\u2064',
        '\uFEFF',
      ]) {
        final (:step, :detailsDropped) = sanitized(crumb('a${control}b'));
        expect(step!.message, 'a b', reason: control.codeUnits.toString());
        expect(detailsDropped, 0);
      }
    });

    test('the message is redacted and cut to 200 characters, the cut '
        'counted once', () {
      final (:step, :detailsDropped) = sanitized(
        crumb('Invited person@example.com ${'x' * 300}'),
      );
      expect(step!.message, startsWith('Invited [REDACTED] '));
      expect(step.message.length, TypedBreadcrumb.maxMessageLength);
      expect(detailsDropped, 1);
      expect(sanitized(crumb('x' * 200)).detailsDropped, 0);
    });

    test('a cut never ends inside a surrogate pair', () {
      // 'a' and 100 emoji: 201 code units, whose 200th is the first half of
      // a pair.
      final (:step, :detailsDropped) = sanitized(crumb('a${'😀' * 100}'));
      expect(step, isNotNull);
      expect(step!.message, 'a${'😀' * 99}');
      expect(hasUnpairedSurrogate(step.message), isFalse);
      expect(detailsDropped, 1);
    });

    test('an unpaired surrogate in a message becomes U+FFFD', () {
      final (:step, detailsDropped: _) = sanitized(crumb('a\ud83db\ude00c'));
      expect(step!.message, 'a\uFFFDb\uFFFDc');
    });

    test('a step whose message is left empty is refused, its values not '
        'counted', () {
      final result = sanitized(
        crumb('\u0000', details: const {'password': 'x'}),
      );
      expect(result.step, isNull);
      expect(result.detailsDropped, 0);
    });

    test('an action or a category outside its pattern is left out and '
        'counted', () {
      final (:step, :detailsDropped) = sanitized(
        crumb('Tapped', action: 'Tap Button', category: 'UI'),
      );
      expect(step!.toJson(), {
        'at': '2026-11-05T09:00:00.000Z',
        'message': 'Tapped',
      });
      expect(detailsDropped, 2);
    });

    test('the canary corpus: no name or value that reads as personal data or '
        'a credential is kept', () {
      const corpus = <String, Object>{
        'password': 'x',
        'heartRate': 80,
        'userEmail': true,
        'contact': 31612345678,
        'row': '7d3f1c2a-9b4e-4f6a-8c1d-2e3f4a5b6c7d',
        'apiKey': 'abc',
        'host': '10.20.30.40',
        'mode': 'bearer',
      };
      final (:step, :detailsDropped) = sanitized(
        crumb('Signed in', details: {...corpus, 'phase': 'load'}),
      );
      expect(step!.details, {'phase': 'load'});
      expect(detailsDropped, corpus.length);
    });

    test('a name or a value the protocol does not take is left out', () {
      final (:step, :detailsDropped) = sanitized(
        crumb(
          'Loaded',
          details: const {
            'Status': 'loaded',
            'note': 'two words',
            'ratio': double.nan,
            'items': ['a'],
            'kept': 'yes',
          },
        ),
      );
      expect(step!.details, {'kept': 'yes'});
      expect(detailsDropped, 4);
    });

    test('under strict every detail string is left out', () {
      final (:step, :detailsDropped) = sanitized(
        crumb(
          'Loaded',
          details: const {'status': 'loaded', 'count': 3, 'busy': true},
        ),
        strict: true,
      );
      expect(step!.details, {'count': 3, 'busy': true});
      expect(detailsDropped, 1);
    });

    test('entries past 16 are left out, the first ones kept', () {
      final (:step, :detailsDropped) = sanitized(
        crumb('Loaded', details: {for (var i = 0; i < 20; i++) 'n$i': i}),
      );
      expect(step!.details.keys, [for (var i = 0; i < 16; i++) 'n$i']);
      expect(detailsDropped, 4);
    });

    test('a step over 512 bytes loses its last detail entries first, then the '
        'end of its message', () {
      // A whole message of 200 characters and four 64-character values
      // are over 512 bytes; the first entries are kept, as many as fit.
      final details = {for (var i = 0; i < 4; i++) 'name$i': 'v' * 64};
      final detailsFirst = sanitized(crumb('m' * 200, details: details));
      final kept = 4 - detailsFirst.detailsDropped;
      expect(detailsFirst.detailsDropped, greaterThan(0));
      expect(detailsFirst.step!.message, 'm' * 200);
      expect(detailsFirst.step!.details.keys, details.keys.take(kept));
      expect(
        detailsFirst.step!.encodedBytes,
        lessThanOrEqualTo(TypedBreadcrumb.maxEncodedBytes),
      );
      expect(
        crumb(
          'm' * 200,
          details: Map.fromEntries(details.entries.take(kept + 1)),
        ).encodedBytes,
        greaterThan(TypedBreadcrumb.maxEncodedBytes),
      );

      // A message of 200 characters of three bytes each (`€`) is over 512
      // bytes alone: every entry goes, then its end, the cut counted once.
      final messageToo = sanitized(
        crumb('€' * 200, details: const {'phase': 'load'}),
      );
      expect(messageToo.step!.details, isEmpty);
      expect(messageToo.detailsDropped, 2);
      expect(messageToo.step!.message.length, lessThan(200));
      expect(
        messageToo.step!.encodedBytes,
        lessThanOrEqualTo(TypedBreadcrumb.maxEncodedBytes),
      );
      expect(messageToo.step!.encodedBytes, greaterThan(450));
    });

    test('lengths count UTF-16 code units, budgets UTF-8 bytes', () {
      // 100 emoji: 200 code units, kept whole; 400 bytes.
      final emoji = sanitized(crumb('😀' * 100));
      expect(emoji.step!.message, '😀' * 100);
      // 101 emoji: past 200 code units, cut.
      final over = sanitized(crumb('😀' * 101));
      expect(over.step!.message.length, lessThanOrEqualTo(200));
    });

    test('the same step always gives the same result', () {
      final given = crumb(
        '€' * 200,
        action: 'a.b',
        details: {for (var i = 0; i < 16; i++) 'name$i': 'v' * 30},
      );
      expect(sanitized(given).step!.toJson(), sanitized(given).step!.toJson());
    });
  });

  group('sanitizeTrail', () {
    TypedBreadcrumb sized(int index) => crumb(
      '${'m' * 190} $index',
      action: 'a.step$index',
      details: {for (var e = 0; e < 3; e++) 'name$e': 'v' * 40},
    );

    test('refused steps go, and the oldest until the trail fits', () {
      final steps = [for (var i = 0; i < 50; i++) sized(i)];
      final (steps: kept, :drops) = sanitizeTrail([
        (step: null, detailsDropped: 0),
        for (final step in steps) (step: step, detailsDropped: 1),
      ], maxBytes: CrashEvent.maxBreadcrumbsBytes);
      expect(
        TypedBreadcrumb.trailBytes(kept),
        lessThanOrEqualTo(CrashEvent.maxBreadcrumbsBytes),
      );
      // One more of the older ones would not have fitted.
      expect(
        TypedBreadcrumb.trailBytes([steps[50 - kept.length - 1], ...kept]),
        greaterThan(CrashEvent.maxBreadcrumbsBytes),
      );
      expect(kept.last.action, 'a.step49');
      expect(drops.stepsDropped, 1 + 50 - kept.length);
      // Only the kept steps' values count.
      expect(drops.detailsDropped, kept.length);
    });

    test('a trail that fits loses nothing', () {
      final (steps: kept, :drops) = sanitizeTrail([
        for (var i = 0; i < 3; i++) (step: sized(i), detailsDropped: 0),
      ], maxBytes: FeedbackReport.maxTrailBytes);
      expect(kept, hasLength(3));
      expect(drops.isEmpty, isTrue);
    });
  });
}
