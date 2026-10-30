import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:noticebird_protocol/noticebird_protocol.dart';

/// What [event] is deduplicated by within the client's window: the
/// exception type plus its top app frames, line numbers aside, or the
/// grouping key.
String deduplicationKey(CrashEvent event) {
  final source = switch (event.groupingKey) {
    final groupingKey? => {'groupingKey': groupingKey},
    null => {
      'exceptionType': event.exception.type,
      'frames': event.exception.stackTrace
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty && line.contains('package:'))
          .take(8)
          .map(_normalizedFrame)
          .toList(growable: false),
    },
  };
  return sha256.convert(utf8.encode(canonicalJsonEncode(source))).toString();
}

/// [frame] without its line and column and without its frame number.
String _normalizedFrame(String frame) => frame
    .replaceAll(RegExp(r':\d+(?::\d+)?\)?$'), ')')
    .replaceAll(RegExp(r'#[0-9]+\s+'), '');
