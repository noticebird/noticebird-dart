import 'dart:convert';

/// Encodes JSON with lexicographically sorted object keys at every depth.
///
/// A number encodes the same on every platform: a double that is a whole
/// number within ±2^53 encodes as that integer (`1.0` as `1`, `-0.0` as
/// `0`), as the web, whose numbers are all doubles, writes it.
String canonicalJsonEncode(Object? value) => jsonEncode(_canonicalize(value));

Object? _canonicalize(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalize(value[key]),
    };
  }
  if (value is List) return value.map(_canonicalize).toList();
  if (value is double &&
      value.isFinite &&
      value.abs() <= _maxSafeInteger &&
      value == value.truncateToDouble()) {
    return value.toInt();
  }
  return value;
}

/// 2^53: the largest magnitude below which every whole double is exact.
const _maxSafeInteger = 9007199254740992;
