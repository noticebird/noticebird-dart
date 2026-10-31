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

/// Refuses [tags] at [path] unless each is a tag value ([isTagValue]). Their
/// number needs no check: a map holds each [AllowedTag] once at most.
void checkTags(Map<AllowedTag, TagScalar> tags, String path) {
  for (final MapEntry(:key, :value) in tags.entries) {
    if (isTagValue(value)) continue;
    final (violation, message) = switch (value) {
      String() => (
        ProtocolViolation.oversized,
        'Tag string exceeds $maxTagValueLength characters',
      ),
      num() => (ProtocolViolation.invalidValue, 'Tag numbers must be finite'),
      _ => (ProtocolViolation.invalidType, 'Tag value must be a scalar'),
    };
    throw ProtocolException(violation, '$path.${key.name}', message);
  }
}
