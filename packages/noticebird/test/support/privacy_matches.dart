import 'dart:convert';

import 'package:noticebird/noticebird.dart';

/// What [event], an event as the transport sent it, holds that the
/// protocol's [PrivacyPatterns] match in a field the client redacts: each
/// match, and each `extra` key that is a [PrivacyViolation] on its own.
/// Empty for an event the client redacted as it should.
///
/// The fields are read as the platform's privacy firewall reads them, one
/// text, a value a line, with `extra` encoded as JSON after it, so a value
/// ending in a credential word takes the next one as its secret. The
/// identity (`user`) is sent as the host set it, and not read.
///
/// The client's approximation of the firewall, for these tests only: the
/// platform holds the authoritative check, and the SDK ships none.
List<String> privacyMatches(Map<String, dynamic> event) {
  final exception = event['exception'] as Map<String, dynamic>;
  final native = event['native'] as Map<String, dynamic>?;
  final text = <Object?>[
    exception['sanitizedMessage'],
    exception['stackTrace'],
    event['routeTemplate'],
    ...?(event['tags'] as Map?)?.values,
    ...?event['groupingKey'] as List?,
    for (final crumb in event['breadcrumbs'] as List? ?? const []) ...[
      crumb['action'],
      ...?(crumb['data'] as Map?)?.values,
    ],
    if (native != null) ...[
      for (final image in native['images'] as List? ?? const []) image['name'],
      for (final frame in native['frames'] as List? ?? const [])
        frame['symbol'],
    ],
  ].whereType<String>().join('\n');
  final scanned = '$text\n${jsonEncode(event['extra'] ?? const {})}';
  return [
    for (final source in PrivacyPatterns.all)
      for (final match in RegExp(
        source,
        caseSensitive: false,
      ).allMatches(scanned))
        match[0]!,
    ..._forbiddenKeys(event['extra']),
  ];
}

Iterable<String> _forbiddenKeys(Object? value) sync* {
  switch (value) {
    case List():
      for (final item in value) {
        yield* _forbiddenKeys(item);
      }
    case Map():
      for (final MapEntry(:key, value: child) in value.entries) {
        if (PrivacyPatterns.extraKeyViolation('$key') != null) yield '$key';
        yield* _forbiddenKeys(child);
      }
  }
}
