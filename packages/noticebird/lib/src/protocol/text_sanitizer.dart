import 'package:noticebird_protocol/noticebird_protocol.dart';

/// Redacts from technical free text what [PrivacyPatterns] match — e-mail
/// addresses, JWTs, credentials, UUIDs, phone-number-like digit runs, IPv4
/// addresses and health values — and cuts the result to [maxLength], never
/// inside a surrogate pair ([cutText]). A surrogate that is not half of a
/// pair, which no JSON store takes, becomes U+FFFD first
/// ([replaceUnpairedSurrogates]). [replacement] is as in [redactCrashText].
String sanitizeCrashText(
  String source, {
  required int maxLength,
  String replacement = _redacted,
}) {
  final value = redactCrashText(
    replaceUnpairedSurrogates(source),
    replacement: replacement,
  );
  if (value.length <= maxLength) return value;
  // A cut can end the text on a credential keyword; its new end is redacted
  // too, and a redaction that outgrows the limit is cut inside [replacement].
  return cutText(
    redactCrashText(cutText(value, maxLength), replacement: replacement),
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
    safe = '${cutText(safe, NativeFrame.maxSymbolLength - 1)}_';
  }
  return safe.isEmpty ? '_' : safe;
}

/// [value] with every run of ten or more digits, which reads as a phone
/// number, cut to its first nine.
String shortenDigitRuns(String value) =>
    value.replaceAllMapped(_longDigitRun, (match) => match[0]!.substring(0, 9));

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

/// [breadcrumb] as an event or a feedback report carries it, and how many
/// of its values were left out ([SanitizedBreadcrumb]); its `step` is
/// `null` when the protocol refuses it even so ([TypedBreadcrumb.check]),
/// such as a message left empty. A bad breadcrumb costs only itself, a bad
/// value only itself, never the event or the report that carries the trail.
///
/// - The message's U+0000 characters go, and its line breaks and other
///   control characters ([TypedBreadcrumb.controlPattern]) become spaces;
///   it is redacted ([redactCrashText]) and cut to
///   [TypedBreadcrumb.maxMessageLength], never inside a surrogate pair.
/// - An action or a category outside its pattern, or one a redaction
///   pattern matches (it names an id or a credential), is left out: the
///   step is kept without it.
/// - A data entry is left out when its name is no data name
///   ([TypedBreadcrumb.isDataName]) or names a credential, a health measure
///   or an identity on its own ([PrivacyPatterns.extraKeyViolation]), when
///   its value is no data value ([TypedBreadcrumb.isDataValue]), when
///   [strict] and its value is a string, and when a redaction pattern
///   matches the entry read as one text ([TypedBreadcrumb.dataEntryText]),
///   so a number reads with its name (`contact: 31612345678`). The entries
///   past [TypedBreadcrumb.maxDataEntries] are left out too.
/// - A step over [TypedBreadcrumb.maxEncodedBytes] loses its last data
///   entries first, in the order they were given, and then the end of its
///   message, until it fits.
///
/// Every value left out of a kept step counts in `dataDropped`, and so does
/// a message that was cut, once, whether to its length or to the step's
/// bytes.
SanitizedBreadcrumb sanitizeBreadcrumb(
  TypedBreadcrumb breadcrumb, {
  required bool strict,
}) {
  var dropped = 0;
  String? kept(String? value, int maxLength, RegExp pattern) {
    if (value == null) return null;
    if (value.length <= maxLength &&
        pattern.hasMatch(value) &&
        !_holdsMatch(value)) {
      return value;
    }
    dropped++;
    return null;
  }

  final action = kept(
    breadcrumb.action,
    TypedBreadcrumb.maxActionLength,
    TypedBreadcrumb.actionPattern,
  );
  final category = kept(
    breadcrumb.category,
    TypedBreadcrumb.maxCategoryLength,
    TypedBreadcrumb.categoryPattern,
  );
  final data = <String, Object>{};
  for (final MapEntry(:key, :value) in breadcrumb.data.entries) {
    if (data.length < TypedBreadcrumb.maxDataEntries &&
        _keepsEntry(key, value, strict: strict)) {
      data[key] = value;
    } else {
      dropped++;
    }
  }
  final oneLine = breadcrumb.message
      .replaceAll('\u0000', '')
      .replaceAll(TypedBreadcrumb.lineBreakPattern, ' ')
      .replaceAll(TypedBreadcrumb.controlPattern, ' ');
  var message = sanitizeCrashText(
    oneLine,
    maxLength: TypedBreadcrumb.maxMessageLength,
  );
  var messageCut =
      redactCrashText(replaceUnpairedSurrogates(oneLine)).length >
      TypedBreadcrumb.maxMessageLength;
  TypedBreadcrumb step() => TypedBreadcrumb(
    at: breadcrumb.at.toUtc(),
    message: message,
    action: action,
    category: category,
    level: breadcrumb.level,
    data: Map.unmodifiable(data),
  );

  var sanitized = step();
  for (
    var over = sanitized.encodedBytes - TypedBreadcrumb.maxEncodedBytes;
    over > 0 && message.isNotEmpty;
    over = sanitized.encodedBytes - TypedBreadcrumb.maxEncodedBytes
  ) {
    if (data.isNotEmpty) {
      data.remove(data.keys.last);
      dropped++;
    } else {
      // A character takes at most three bytes encoded (no control is left
      // to take six), so at least this many go.
      final cut = (over + 2) ~/ 3;
      messageCut = true;
      message = sanitizeCrashText(
        message,
        maxLength: cut < message.length ? message.length - cut : 0,
      );
    }
    sanitized = step();
  }
  try {
    sanitized.check();
    return (step: sanitized, dataDropped: dropped + (messageCut ? 1 : 0));
  } on ProtocolException {
    return (step: null, dataDropped: 0);
  }
}

/// A breadcrumb as [sanitizeBreadcrumb] made it: the `step` a trail
/// carries, or `null` for one the protocol refuses even so, and how many of
/// its values were left out of the step.
typedef SanitizedBreadcrumb = ({TypedBreadcrumb? step, int dataDropped});

/// The trail [sanitized] (oldest first, each made by [sanitizeBreadcrumb])
/// as an event or a report carries it: the refused steps left out, and
/// then the oldest steps until the trail takes at most [maxBytes]
/// ([TypedBreadcrumb.trailBytes]); with what went, as [BreadcrumbDrops].
({List<TypedBreadcrumb> steps, BreadcrumbDrops drops}) sanitizeTrail(
  Iterable<SanitizedBreadcrumb> sanitized, {
  required int maxBytes,
}) {
  var stepsDropped = 0;
  final kept = <({TypedBreadcrumb step, int dataDropped, int bytes})>[];
  for (final (:step, :dataDropped) in sanitized) {
    if (step == null) {
      stepsDropped++;
    } else {
      kept.add((
        step: step,
        dataDropped: dataDropped,
        bytes: step.encodedBytes,
      ));
    }
  }
  // `[`, `]` and a comma between two steps, around the steps' own bytes.
  var bytes = kept.fold(kept.isEmpty ? 2 : kept.length + 1, (sum, item) {
    return sum + item.bytes;
  });
  var first = 0;
  while (bytes > maxBytes && first < kept.length) {
    bytes -= kept[first].bytes + (first < kept.length - 1 ? 1 : 0);
    first++;
    stepsDropped++;
  }
  final steps = kept.skip(first);
  return (
    steps: List.unmodifiable([for (final item in steps) item.step]),
    // A step left out whole counts as a step, not as its values.
    drops: BreadcrumbDrops(
      dataDropped: steps.fold(0, (sum, item) => sum + item.dataDropped),
      stepsDropped: stepsDropped,
    ),
  );
}

/// Whether the data entry [name] → [value] goes out under [strict]: by the
/// rules of [sanitizeBreadcrumb].
bool _keepsEntry(String name, Object value, {required bool strict}) =>
    TypedBreadcrumb.isDataName(name) &&
    PrivacyPatterns.extraKeyViolation(name) == null &&
    TypedBreadcrumb.isDataValue(value) &&
    !(strict && value is String) &&
    !_holdsMatch(TypedBreadcrumb.dataEntryText(name, value));

/// Whether a redaction pattern matches [text].
bool _holdsMatch(String text) =>
    _patterns.any((pattern) => pattern.hasMatch(text));

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
