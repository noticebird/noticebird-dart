// The rules of a text's code units: a cut never splits a surrogate pair,
// and a surrogate that is not half of a pair is found and replaced.

import 'package:noticebird_protocol/noticebird_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('a cut that would split a pair ends before it', () {
    // 'a' and 100 emoji: the 100th code unit is the first half of a pair.
    final cut = cutText('a${'😀' * 100}', 100);
    expect(cut, 'a${'😀' * 49}');
    expect(hasUnpairedSurrogate(cut), isFalse);
    expect(cutText('😀' * 100, 100), '😀' * 50);
    expect(cutText('short', 100), 'short');
    expect(cutText('abc', 0), '');
  });

  test('an unpaired surrogate is found, a pair is not', () {
    expect(hasUnpairedSurrogate('😀'), isFalse);
    expect(hasUnpairedSurrogate('a\ud83d'), isTrue);
    expect(hasUnpairedSurrogate('\ude00a'), isTrue);
    expect(hasUnpairedSurrogate('\ud83d\ud83d\ude00'), isTrue);
  });

  test('an unpaired surrogate becomes U+FFFD, a pair stays', () {
    expect(replaceUnpairedSurrogates('a\ud83db😀\ude00'), 'a\uFFFDb😀\uFFFD');
  });

  test('a tag value is clamped without splitting a pair', () {
    final clamped = clampTagValue('😀' * 100) as String;
    expect(hasUnpairedSurrogate(clamped), isFalse);
    expect(clamped.length, lessThanOrEqualTo(maxTagValueLength));
  });

  group('canonicalJsonEncode writes a number alike on every platform', () {
    test('a whole double as an integer, -0.0 as 0', () {
      expect(
        canonicalJsonEncode({'a': 1.0, 'b': -0.0, 'c': 3}),
        '{"a":1,"b":0,"c":3}',
      );
    });

    test('a fraction, and a whole double past 2^53, as a double', () {
      expect(canonicalJsonEncode([0.5, -2.25]), '[0.5,-2.25]');
      expect(canonicalJsonEncode([1e300]), '[1e+300]');
    });
  });
}
