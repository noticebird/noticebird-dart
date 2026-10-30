import 'protocol_exception.dart';
import 'types.dart';

// The checks the crash event's value types share. Not exported: each type
// offers its own `check`, and `CrashEvent.toJson` runs them all.

/// Refuses [value] at [path] unless it holds 1 to [maxLength] characters and
/// matches [pattern].
void checkText(
  String value,
  String path, {
  required int maxLength,
  RegExp? pattern,
}) {
  if (value.isEmpty ||
      value.length > maxLength ||
      (pattern != null && !pattern.hasMatch(value))) {
    throw ProtocolException(
      ProtocolViolation.invalidValue,
      path,
      'Invalid string value',
    );
  }
}

/// Refuses [tags] at [path] unless each is a scalar: a string of at most
/// [maxTagValueLength] characters, a finite number or a boolean. Their
/// number needs no check: there are fewer [AllowedTag]s than a map of tags
/// may hold.
void checkTags(Map<AllowedTag, TagScalar> tags, String path) {
  for (final MapEntry(:key, :value) in tags.entries) {
    if (value is! String && value is! num && value is! bool) {
      throw ProtocolException(
        ProtocolViolation.invalidType,
        '$path.${key.name}',
        'Tag value must be a scalar',
      );
    }
    if (value is num && !value.isFinite) {
      throw ProtocolException(
        ProtocolViolation.invalidValue,
        '$path.${key.name}',
        'Tag numbers must be finite',
      );
    }
    if (value is String && value.length > maxTagValueLength) {
      throw ProtocolException(
        ProtocolViolation.oversized,
        '$path.${key.name}',
        'Tag string exceeds $maxTagValueLength characters',
      );
    }
  }
}
