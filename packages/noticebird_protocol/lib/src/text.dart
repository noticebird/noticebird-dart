// The rules of a text's code units every writer of the wire format shares:
// a cut never splits a surrogate pair, and a text holds no surrogate that is
// not half of one, since JSON stores (Postgres `jsonb`) refuse it.

/// [value] cut to at most [maxLength] characters (UTF-16 code units),
/// never inside a surrogate pair: a cut that would end on the first half of
/// a pair ends before it, one character shorter.
String cutText(String value, int maxLength) {
  if (value.length <= maxLength) return value;
  if (maxLength <= 0) return '';
  final end = _isHigh(value.codeUnitAt(maxLength - 1))
      ? maxLength - 1
      : maxLength;
  return value.substring(0, end);
}

/// Whether [value] holds a surrogate that is not half of a pair: a high
/// surrogate not followed by a low one, or a low one not after a high one.
bool hasUnpairedSurrogate(String value) {
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (_isHigh(unit)) {
      if (i + 1 < value.length && _isLow(value.codeUnitAt(i + 1))) {
        i++;
        continue;
      }
      return true;
    }
    if (_isLow(unit)) return true;
  }
  return false;
}

/// [value] with every surrogate that is not half of a pair replaced by
/// [replacement], U+FFFD by default.
String replaceUnpairedSurrogates(String value, {String replacement = '�'}) {
  if (!hasUnpairedSurrogate(value)) return value;
  final out = StringBuffer();
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (_isHigh(unit) &&
        i + 1 < value.length &&
        _isLow(value.codeUnitAt(i + 1))) {
      out.writeCharCode(unit);
      out.writeCharCode(value.codeUnitAt(++i));
    } else if (_isHigh(unit) || _isLow(unit)) {
      out.write(replacement);
    } else {
      out.writeCharCode(unit);
    }
  }
  return out.toString();
}

bool _isHigh(int unit) => unit >= 0xD800 && unit <= 0xDBFF;
bool _isLow(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;
