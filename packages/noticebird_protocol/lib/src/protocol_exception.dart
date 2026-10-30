/// Stable machine-readable reasons for rejecting a protocol payload.
enum ProtocolViolation {
  invalidJson,
  unsupportedSchemaVersion,
  unknownField,
  missingField,
  invalidType,
  invalidValue,
  oversized,
}

/// A deterministic protocol validation failure.
final class ProtocolException implements FormatException {
  const ProtocolException(this.violation, this.path, this.message);

  final ProtocolViolation violation;
  final String path;

  @override
  final String message;

  @override
  int? get offset => null;

  @override
  Object? get source => path;

  @override
  String toString() => 'ProtocolException(${violation.name}, $path): $message';
}
