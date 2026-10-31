import 'package:noticebird_protocol/noticebird_protocol.dart';

/// Redacts from technical free text what [PrivacyPatterns] match — e-mail
/// addresses, JWTs, credentials, UUIDs, phone-number-like digit runs, IPv4
/// addresses and health values — and cuts the result to [maxLength].
/// [replacement] is as in [redactCrashText].
String sanitizeCrashText(
  String source, {
  required int maxLength,
  String replacement = _redacted,
}) {
  final value = redactCrashText(source, replacement: replacement);
  if (value.length <= maxLength) return value;
  // A cut can end the text on a credential keyword; its new end is redacted
  // too, and a redaction that outgrows the limit is cut inside [replacement].
  return truncateCrashText(
    redactCrashText(
      truncateCrashText(value, maxLength),
      replacement: replacement,
    ),
    maxLength,
  );
}

/// [source] with every match of the protocol's [PrivacyPatterns], and of
/// some wider patterns the client adds on top, redacted.
///
/// None needs a boundary after its match that a cut could create, so
/// shortening the result leaves no match behind but a credential word at its
/// new end, which [sanitizeCrashText] redacts again. A text ending in such a
/// word is redacted too: it would name whatever follows it as a credential.
/// The patterns run until nothing changes, since a redaction can set off a
/// match the patterns before it did not see.
///
/// Each match becomes [replacement], `[REDACTED]` by default; a value whose
/// protocol field allows fewer characters (an image name) passes one it
/// allows. No pattern may match it.
String redactCrashText(String source, {String replacement = _redacted}) {
  var value = source;
  for (var round = 0; round < _maxRounds; round++) {
    var redacted = value;
    for (final pattern in _patterns) {
      redacted = redacted.replaceAll(pattern, replacement);
    }
    if (redacted == value) break;
    value = redacted;
  }
  return value;
}

/// [route] as an event carries it — redacted like any other text and cut to
/// the protocol's [CrashEvent.maxRouteTemplateLength], which a redaction can
/// grow it past — or
/// null when it is not a template's shape, a path from the root.
///
/// The route a host sets and the one a native report's run recorded both
/// pass here, the latter because an earlier version may have stored it
/// unredacted.
String? sanitizeRouteTemplate(String route) => route.startsWith('/')
    ? sanitizeCrashText(route, maxLength: CrashEvent.maxRouteTemplateLength)
    : null;

/// [symbol] — a function, method or native frame symbol — spelled so that
/// no [PrivacyPatterns] pattern reads it as personal data or a credential,
/// keeping every word.
///
/// A run of ten digits reads as a phone number, a namespace such as
/// `auth::token::` as a credential assignment, a dotted version (`1.2.3.4`) as
/// an IPv4 address, a JWT-shaped name as a token, and a name ending in a
/// credential word names what follows it as a credential (`AuthHeader.bearer`
/// the frame's location, `Session.refreshToken` a native symbol from the root
/// namespace, `::alloc`). So a run of ten digits is cut to nine
/// ([shortenDigitRuns]), a symbol that reads as an assignment spells its
/// namespaces with dots, an address or a token its dots with underscores,
/// and a symbol ending in a credential word gets an underscore after it, cut
/// so that it stays within [NativeFrame.maxSymbolLength]. An empty symbol
/// becomes `_`. A symbol's
/// characters allow no e-mail address, UUID or whitespace; a caller whose
/// symbol may hold more checks what it sends.
String respellSymbol(String symbol) {
  var safe = shortenDigitRuns(symbol);
  if (_assignmentLike.hasMatch(safe)) safe = safe.replaceAll(':', '.');
  // After the namespaces: `token:1:2:3:4` only reads as an address once its
  // colons are dots.
  safe = safe.replaceAllMapped(
    _dottedValue,
    (match) => match[0]!.replaceAll('.', '_'),
  );
  if (_endsInCredentialWord.hasMatch(safe)) {
    safe = '${truncateCrashText(safe, NativeFrame.maxSymbolLength - 1)}_';
  }
  return safe.isEmpty ? '_' : safe;
}

/// [value] with every run of ten or more digits, which reads as a phone
/// number, cut to its first nine.
String shortenDigitRuns(String value) =>
    value.replaceAllMapped(_longDigitRun, (match) => match[0]!.substring(0, 9));

/// [value] cut to at most [maxLength] characters.
String truncateCrashText(String value, int maxLength) =>
    value.length <= maxLength ? value : value.substring(0, maxLength);

/// [value] as an event carries it: a string redacted and shortened to the
/// protocol's [maxTagValueLength], any other scalar as it is.
TagScalar sanitizeTagValue(TagScalar value) =>
    value is String ? clampTagValue(redactCrashText(value)) : value;

/// [groupingKey] as an event carries it: each part redacted and shortened
/// to the protocol's [CrashEvent.maxGroupingKeyPartLength], empty parts left
/// out, and the first [CrashEvent.maxGroupingKeyParts] kept; `null` when no
/// part is left, so the event carries no key. Shortened
/// rather than rejected, as a tag value is: a key the protocol would refuse
/// must not cost the report.
List<String>? sanitizeGroupingKey(List<String> groupingKey) {
  final parts = [
    for (final part in groupingKey)
      if (part.isNotEmpty)
        sanitizeCrashText(part, maxLength: CrashEvent.maxGroupingKeyPartLength),
  ].take(CrashEvent.maxGroupingKeyParts).toList();
  return parts.isEmpty ? null : List.unmodifiable(parts);
}

/// [breadcrumb] as an event carries it: every data value through
/// [sanitizeTagValue], and an action a redaction pattern matches (it names
/// an id or a credential) replaced by `redacted`; `null` when the protocol
/// still refuses it ([TypedBreadcrumb.check]), such as an action outside its
/// pattern. A bad breadcrumb costs only itself, never the event or the
/// report that carries the trail.
TypedBreadcrumb? sanitizeBreadcrumb(TypedBreadcrumb breadcrumb) {
  final sanitized = TypedBreadcrumb(
    occurredAt: breadcrumb.occurredAt,
    category: breadcrumb.category,
    action: redactCrashText(breadcrumb.action) == breadcrumb.action
        ? breadcrumb.action
        : 'redacted',
    level: breadcrumb.level,
    data: {
      for (final entry in breadcrumb.data.entries)
        entry.key: sanitizeTagValue(entry.value),
    },
  );
  try {
    sanitized.check();
    return sanitized;
  } on ProtocolException {
    return null;
  }
}

/// Every round that changes the text turns a match into the replacement,
/// which no pattern matches, so the fixed point comes within a few rounds; the
/// bound only caps what a pathological text costs.
const _maxRounds = 8;

const _redacted = '[REDACTED]';

final _patterns = <RegExp>[
  for (final source in [
    // Wider than the protocol's patterns, on purpose: a three-part token
    // whose payload is not JSON (an encrypted JWT), a credential word before
    // whitespace, a UUID-shaped hex run of any version, and a health value up
    // to the next separator. They run first, so a health value goes as a
    // whole.
    r'eyJ[\w-]+\.[\w-]+\.[\w-]+',
    '${PrivacyPatterns.credentialWord}(?:\\s*[:=]|\\s)\\s*\\S+',
    // A credential word at the end, which would take the next value as its
    // secret.
    '${PrivacyPatterns.credentialWord}\\s*[:=]?\\s*\$',
    r'\b[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}',
    '\\b${PrivacyPatterns.healthMeasure}\\b\\s*[:=]\\s*\\S[^\\n,;]*',
    ...PrivacyPatterns.all,
  ])
    RegExp(source, caseSensitive: false),
];

final _longDigitRun = RegExp(r'\d{10,}');
final _assignmentLike = RegExp(
  '${PrivacyPatterns.credentialKey}\\s*[:=]',
  caseSensitive: false,
);
final _dottedValue = RegExp(
  '${PrivacyPatterns.ipv4}|${PrivacyPatterns.jwt}',
  caseSensitive: false,
);
final _endsInCredentialWord = RegExp(
  '${PrivacyPatterns.credentialWord}\$',
  caseSensitive: false,
);
