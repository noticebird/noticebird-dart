import 'dart:convert';

import 'protocol_exception.dart';
import 'types.dart';

/// What a report is about (`kind`).
enum FeedbackKind { bug, idea, other }

/// What opened the feedback form (`trigger`).
enum FeedbackTrigger { manual, shake, errorScreen, other }

/// The content types a screenshot may have.
enum FeedbackContentType {
  png('image/png'),
  jpeg('image/jpeg'),
  webp('image/webp');

  const FeedbackContentType(this.mimeType);

  final String mimeType;

  /// Whether [bytes] start with this type's file signature, so that what
  /// was declared is what the bytes are. A client checks it before it asks
  /// for a slot.
  bool matches(List<int> bytes) {
    bool startsWith(int offset, List<int> signature) {
      if (bytes.length < offset + signature.length) return false;
      for (var i = 0; i < signature.length; i++) {
        if (bytes[offset + i] != signature[i]) return false;
      }
      return true;
    }

    return switch (this) {
      png => startsWith(0, const [
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
      ]),
      jpeg => startsWith(0, const [0xff, 0xd8, 0xff]),
      // RIFF, a length, then WEBP.
      webp =>
        startsWith(0, ascii.encode('RIFF')) &&
            startsWith(8, ascii.encode('WEBP')),
    };
  }
}

/// The reference to an uploaded screenshot (`attachments[]`), and the body of
/// a slot request without its index.
final class FeedbackAttachmentRef {
  const FeedbackAttachmentRef({
    required this.index,
    required this.contentType,
    required this.byteLength,
    required this.sha256,
  });

  final int index;
  final FeedbackContentType contentType;
  final int byteLength;

  /// Lowercase hex, [sha256Pattern].
  final String sha256;

  /// The most bytes a screenshot may have: 5 MiB.
  static const maxByteLength = 5242880;

  /// The highest index v1 accepts: one screenshot per report.
  static const maxIndex = 0;

  /// A SHA-256 as the wire writes it: 64 lowercase hex digits.
  static final sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

  /// This reference as an item of the report's `attachments`. It is
  /// checked as part of the report, by [FeedbackReport.toJson].
  Map<String, Object> toJson() => {
    'index': index,
    'contentType': contentType.mimeType,
    'byteLength': byteLength,
    'sha256': sha256,
  };

  /// The body of the slot request for this reference: `{contentType,
  /// byteLength, sha256}`, checked first by the rules of a reference, with
  /// paths within that body (`$.index` for the slot's index), so a slot the
  /// server would refuse is never asked for.
  Map<String, Object> toSlotJson() {
    _check(r'$');
    return toJson()..remove('index');
  }

  /// The rules of a reference at [path]: an index of 0 to [maxIndex], 1 to
  /// [maxByteLength] bytes, and a [sha256Pattern] hash.
  void _check(String path) {
    if (index < 0 || index > maxIndex) {
      throw ProtocolException(
        ProtocolViolation.invalidValue,
        '$path.index',
        'Only index 0 is accepted',
      );
    }
    if (byteLength < 1 || byteLength > maxByteLength) {
      throw ProtocolException(
        ProtocolViolation.invalidValue,
        '$path.byteLength',
        'Out of range',
      );
    }
    _checkString(sha256, '$path.sha256', pattern: sha256Pattern);
  }
}

/// The unverified identity the SDK holds (`user`): never shown as verified.
/// At least one field, each a string of 1 to its maximum code points (the
/// email at least [minEmailLength]).
final class FeedbackUser {
  const FeedbackUser({this.id, this.email, this.name});

  final String? id;
  final String? email;
  final String? name;

  static const maxIdLength = 100;
  static const minEmailLength = 3;
  static const maxEmailLength = 254;
  static const maxNameLength = 200;

  Map<String, Object?> toJson() => {'id': ?id, 'email': ?email, 'name': ?name};

  void _check(String path) {
    if (id == null && email == null && name == null) {
      throw ProtocolException(
        ProtocolViolation.invalidValue,
        path,
        'At least one user field is required',
      );
    }
    if (id case final id?) {
      _checkString(id, '$path.id', maxLength: maxIdLength);
    }
    if (email case final email?) {
      _checkString(
        email,
        '$path.email',
        minLength: minEmailLength,
        maxLength: maxEmailLength,
      );
    }
    if (name case final name?) {
      _checkString(name, '$path.name', maxLength: maxNameLength);
    }
  }
}

/// The context the host gives about its user (`userContext`): identity it
/// supplies on purpose, never verified, as the unverified [FeedbackUser] is.
///
/// An object of 1–[maxKeys] keys, each matching [keyPattern]. A value is a
/// string (1–[maxStringLength] characters), a finite number, a boolean, an
/// array of 1–[maxArrayItems] of those, or an object of 1–[maxKeys] keys
/// whose values are those scalars or arrays: one nested level, never an
/// object in an array. No string holds U+0000. Its compact UTF-8 JSON
/// encoding, with every number read as a double and written as an integer
/// where that double is integral and up to 2^53, is at most
/// [maxEncodedBytes] bytes.
final class FeedbackUserContext {
  FeedbackUserContext._(this.values);

  /// [values] checked by the rules of a report's `userContext`, the only
  /// way to make one, so a host can check its context before it builds a
  /// report. A refusal is a [ProtocolException] whose path names the value
  /// within the report (`$.userContext.plan.tier`).
  factory FeedbackUserContext.check(Map<String, Object?> values) {
    // The shape first: it refuses any nesting past one level before
    // anything walks deeper.
    final checked = _contextObject(values, _userContextPath, nests: true);
    _checkValues(checked, _userContextPath);
    if (utf8.encode(jsonEncode(_integralNumbers(checked))).length >
        maxEncodedBytes) {
      throw const ProtocolException(
        ProtocolViolation.oversized,
        _userContextPath,
        'The user context exceeds $maxEncodedBytes bytes',
      );
    }
    return FeedbackUserContext._(checked);
  }

  static const maxKeys = 32;
  static const maxStringLength = 256;
  static const maxArrayItems = 16;
  static const maxEncodedBytes = 8192;

  /// A key: no `.`, so a nested value's path (`plan.tier`) stays readable.
  static final keyPattern = RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,63}$');

  /// The checked values, unmodifiable at every level: a [String], a [num],
  /// a [bool], a `List<Object>` of those, or a `Map<String, Object>` of
  /// those and such lists.
  final Map<String, Object> values;

  Map<String, Object> toJson() => values;
}

/// A diagnostics value: a [bool], a finite [num], or a [String] that is a UTC
/// timestamp, a UUID or a token without spaces. Never free text.
sealed class DiagnosticValue {
  const DiagnosticValue();

  Object get json;
}

final class DiagnosticScalar extends DiagnosticValue {
  const DiagnosticScalar(this.json);

  /// A [bool] or a finite [num].
  @override
  final Object json;
}

final class DiagnosticTimestamp extends DiagnosticValue {
  const DiagnosticTimestamp(this.json);

  /// A UTC timestamp, [FeedbackReport.isUtcTimestamp].
  @override
  final String json;
}

final class DiagnosticUuid extends DiagnosticValue {
  const DiagnosticUuid(this.json);

  /// A lowercase UUID v4, [FeedbackReport.uuidV4].
  @override
  final String json;
}

final class DiagnosticToken extends DiagnosticValue {
  const DiagnosticToken(this.json);

  /// A token, [FeedbackDiagnostics.tokenPattern].
  @override
  final String json;
}

/// Builds a report's `diagnostics` from the host's values.
abstract final class FeedbackDiagnostics {
  /// A group's name, and a value's key within its group.
  static final keyPattern = RegExp(r'^[a-z][a-zA-Z0-9_]{0,63}$');

  /// A token: 1–64 characters without spaces.
  static final tokenPattern = RegExp(r'^[A-Za-z0-9_.:+/-]{1,64}$');

  /// [groups] as typed diagnostics values, by the rules of a report's
  /// `diagnostics`: at most [FeedbackReport.maxDiagnosticGroups] groups of
  /// at most [FeedbackReport.maxDiagnosticValues] values, names and keys
  /// matching [keyPattern], and at most [FeedbackReport.maxDiagnosticsBytes]
  /// bytes encoded.
  ///
  /// A value is a [bool], a finite [num], a UTC [DateTime] (a timestamp), or
  /// a [String] that is a lowercase UUID v4, a UTC timestamp, or a token
  /// ([tokenPattern]), typed in that order. Anything else is free text or
  /// no value of the wire, and refused with a [ProtocolException] whose path
  /// names it within the report (`$.diagnostics.sync.note`): diagnostics
  /// are never shortened, so a refusal is the host's to fix.
  static Map<String, Map<String, DiagnosticValue>> build(
    Map<String, Map<String, Object?>> groups,
  ) => _diagnostics(
    groups,
    (value, path) => _checkedDiagnostic(_typed(value, path), path),
  );

  /// [value] as the diagnostics value of its type, checked after.
  static DiagnosticValue _typed(Object? value, String path) => switch (value) {
    bool() || num() => DiagnosticScalar(value as Object),
    DateTime(isUtc: true) => DiagnosticTimestamp(value.toIso8601String()),
    DateTime() => throw ProtocolException(
      ProtocolViolation.invalidValue,
      path,
      'Expected a UTC moment',
    ),
    String() =>
      _stringDiagnostic(value) ??
          (throw ProtocolException(
            ProtocolViolation.invalidValue,
            path,
            'A diagnostics value is never free text',
          )),
    _ => throw ProtocolException(
      ProtocolViolation.invalidType,
      path,
      'Expected a boolean, a number or a string',
    ),
  };
}

/// A feedback report, schema version 1, written by [toJson] and
/// [toJsonString].
///
/// Fail-closed: [toJson] checks every field by its rules and the limits,
/// which are literals, and a refusal is a [ProtocolException] whose path
/// names the offending value. The checks of a single value a client fills in
/// itself are public: [checkContactEmail], [checkLocale],
/// [checkRouteTemplate] and [checkTrailItem]. The rules that need the moment
/// of submission or the project are the platform's.
final class FeedbackReport {
  const FeedbackReport({
    required this.reportId,
    required this.createdAt,
    required this.kind,
    required this.message,
    required this.app,
    required this.platform,
    required this.sessionId,
    this.trigger,
    this.contactEmail,
    this.locale,
    this.routeTemplate,
    this.relatedEventId,
    this.user,
    this.userContext,
    this.reporterAssertion,
    this.trail = const [],
    this.diagnostics = const {},
    this.attachments = const [],
  });

  static const schemaVersion = 1;

  /// The most bytes an encoded report may have, as an event.
  static const maxEncodedBytes = 65536;

  /// The most bytes the encoded `diagnostics` may take of that.
  static const maxDiagnosticsBytes = 16384;
  static const maxDiagnosticGroups = 16;
  static const maxDiagnosticValues = 32;
  static const maxMessageLength = 4000;
  static const maxTrailItems = 100;
  static const maxAttachments = 1;

  static const minContactEmailLength = 3;
  static const maxContactEmailLength = 254;
  static final contactEmailPattern = RegExp(r'^[^@\s]+@[^@\s]+$');

  /// A language tag, such as `nl-NL`.
  static const maxLocaleLength = 35;
  static final localePattern = RegExp(
    r'^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8}){0,3}$',
  );

  /// A route template, such as `/lists/:listId`.
  static const maxRouteTemplateLength = 200;
  static final routeTemplatePattern = RegExp('^/');

  static final sessionIdPattern = RegExp(r'^[A-Za-z0-9_-]{16,64}$');

  /// A compact JWS: three base64url parts.
  static const minReporterAssertionLength = 16;
  static const maxReporterAssertionLength = 4096;
  static final reporterAssertionPattern = RegExp(
    r'^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$',
  );

  /// A UUID of version 4 in lower case, as `reportId` and a diagnostics
  /// UUID are.
  static final uuidV4 = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  /// A UUID of any version, or none, in lower case, as `relatedEventId` is:
  /// a crash event's id may be a UUIDv7, or the SDK's fallback id without a
  /// version nibble.
  static final uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );

  /// How old `createdAt` may be at submission, and how far in the future it,
  /// and a trail item after it, may be.
  static const maxAge = Duration(days: 7);
  static const maxClockSkew = Duration(minutes: 5);

  final String reportId;
  final DateTime createdAt;
  final FeedbackKind kind;
  final FeedbackTrigger? trigger;
  final String message;
  final String? contactEmail;
  final AppMetadata app;
  final PlatformMetadata platform;
  final String? locale;
  final String? routeTemplate;
  final String sessionId;
  final String? relatedEventId;
  final FeedbackUser? user;
  final FeedbackUserContext? userContext;
  final String? reporterAssertion;
  final List<TypedBreadcrumb> trail;
  final Map<String, Map<String, DiagnosticValue>> diagnostics;
  final List<FeedbackAttachmentRef> attachments;

  /// Whether [value] is a UTC timestamp as the schema writes one
  /// (`2026-10-29T14:03:12.418Z`, up to six fraction digits), naming a
  /// moment that exists: no 13th month, no 25th hour.
  static bool isUtcTimestamp(String value) {
    final match = _utcTimestamp.firstMatch(value);
    if (match == null) return false;
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return false;
    final fields = [for (var i = 1; i <= 6; i++) int.parse(match[i]!)];
    return parsed.year == fields[0] &&
        parsed.month == fields[1] &&
        parsed.day == fields[2] &&
        parsed.hour == fields[3] &&
        parsed.minute == fields[4] &&
        parsed.second == fields[5];
  }

  static final _utcTimestamp = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d{1,6})?Z$',
  );

  /// Refuses [email] as `contact.email` refuses it, at `$.contact.email`:
  /// [minContactEmailLength] to [maxContactEmailLength] code points, and
  /// [contactEmailPattern].
  static void checkContactEmail(String email) => _checkString(
    email,
    r'$.contact.email',
    minLength: minContactEmailLength,
    maxLength: maxContactEmailLength,
    pattern: contactEmailPattern,
  );

  /// Refuses [locale] as `platform.locale` refuses it, at
  /// `$.platform.locale`: at most [maxLocaleLength] code points, and
  /// [localePattern].
  static void checkLocale(String locale) => _checkString(
    locale,
    r'$.platform.locale',
    maxLength: maxLocaleLength,
    pattern: localePattern,
  );

  /// Refuses [routeTemplate] as `routeTemplate` refuses it, at
  /// `$.routeTemplate`: at most [maxRouteTemplateLength] code points, and
  /// [routeTemplatePattern].
  static void checkRouteTemplate(String routeTemplate) => _checkString(
    routeTemplate,
    r'$.routeTemplate',
    maxLength: maxRouteTemplateLength,
    pattern: routeTemplatePattern,
  );

  /// Refuses [item] as the trail of a report created at [createdAt] refuses
  /// it, at `$.trail[index]`: a crash event's breadcrumb, with a UTC
  /// timestamp the schema writes, and no later than [createdAt] plus
  /// [maxClockSkew].
  static void checkTrailItem(
    TypedBreadcrumb item, {
    required DateTime createdAt,
    int index = 0,
  }) {
    final path = '\$.trail[$index]';
    _checkBreadcrumb(item, path);
    if (item.occurredAt.isAfter(createdAt.add(maxClockSkew))) {
      throw ProtocolException(
        ProtocolViolation.invalidValue,
        '$path.occurredAt',
        'Later than createdAt',
      );
    }
  }

  /// This report as the wire's JSON object, checked by every rule of a
  /// report, then the [maxEncodedBytes] of its encoding. A null field, and
  /// an empty trail, diagnostics or attachments, is left out; any other
  /// value is checked. A report the server would refuse for its shape
  /// throws a [ProtocolException] here, before it is sent or queued.
  Map<String, Object?> toJson() => _checked().json;

  /// [toJson], encoded: the body of `POST /v1/feedback`.
  String toJsonString() => _checked().encoded;

  ({Map<String, Object?> json, String encoded}) _checked() {
    _checkFields();
    final json = <String, Object?>{
      'schemaVersion': schemaVersion,
      'reportId': reportId,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'kind': kind.name,
      'trigger': ?trigger?.name,
      'message': message,
      if (contactEmail != null) 'contact': {'email': contactEmail},
      'app': app.toJson(),
      'platform': {...platform.toJson(), 'locale': ?locale},
      'routeTemplate': ?routeTemplate,
      'sessionId': sessionId,
      'relatedEventId': ?relatedEventId,
      'user': ?user?.toJson(),
      'userContext': ?userContext?.toJson(),
      'reporterAssertion': ?reporterAssertion,
      if (trail.isNotEmpty) 'trail': [for (final item in trail) item.toJson()],
      if (diagnostics.isNotEmpty) 'diagnostics': _diagnosticsJson(diagnostics),
      if (attachments.isNotEmpty)
        'attachments': [for (final item in attachments) item.toJson()],
    };
    // Every value is a checked scalar by now, so the walk and the encoder
    // meet no value JSON cannot carry.
    _checkValues(json, r'$');
    final encoded = jsonEncode(json);
    if (utf8.encode(encoded).length > maxEncodedBytes) {
      throw const ProtocolException(
        ProtocolViolation.oversized,
        r'$',
        'Payload exceeds $maxEncodedBytes bytes',
      );
    }
    return (json: json, encoded: encoded);
  }

  /// Every field by its rules, in the order of the schema. [userContext]
  /// was checked when it was made.
  void _checkFields() {
    _checkString(reportId, r'$.reportId', pattern: uuidV4);
    if (!isUtcTimestamp(createdAt.toUtc().toIso8601String())) {
      throw const ProtocolException(
        ProtocolViolation.invalidValue,
        r'$.createdAt',
        'Expected UTC timestamp',
      );
    }
    _checkString(message, r'$.message', maxLength: maxMessageLength);
    if (contactEmail case final email?) checkContactEmail(email);
    app.check();
    platform.check();
    if (locale case final locale?) checkLocale(locale);
    if (routeTemplate case final route?) checkRouteTemplate(route);
    _checkString(sessionId, r'$.sessionId', pattern: sessionIdPattern);
    if (relatedEventId case final id?) {
      _checkString(id, r'$.relatedEventId', pattern: uuid);
    }
    user?._check(r'$.user');
    if (reporterAssertion case final assertion?) {
      _checkString(
        assertion,
        r'$.reporterAssertion',
        minLength: minReporterAssertionLength,
        maxLength: maxReporterAssertionLength,
        pattern: reporterAssertionPattern,
      );
    }
    if (trail.length > maxTrailItems) {
      throw const ProtocolException(
        ProtocolViolation.oversized,
        r'$.trail',
        'Maximum is $maxTrailItems',
      );
    }
    for (final (index, item) in trail.indexed) {
      _checkBreadcrumb(item, '\$.trail[$index]');
    }
    _diagnostics(diagnostics, _checkedDiagnostic);
    if (attachments.length > maxAttachments) {
      throw const ProtocolException(
        ProtocolViolation.oversized,
        r'$.attachments',
        'Maximum is $maxAttachments',
      );
    }
    for (final (index, item) in attachments.indexed) {
      item._check('\$.attachments[$index]');
    }
  }
}

/// A trail item at [path]: exactly a crash event's breadcrumb, checked by
/// the protocol's [TypedBreadcrumb.check], with the schema's stricter
/// timestamp on top.
void _checkBreadcrumb(TypedBreadcrumb item, String path) {
  try {
    item.check();
  } on ProtocolException catch (error) {
    // The protocol names a breadcrumb's place in an event.
    throw ProtocolException(
      error.violation,
      error.path.replaceFirst(r'$.breadcrumbs[]', path),
      error.message,
    );
  }
  final json = item.toJson();
  if (!FeedbackReport.isUtcTimestamp(json['occurredAt']! as String)) {
    throw ProtocolException(
      ProtocolViolation.invalidValue,
      '$path.occurredAt',
      'Expected UTC timestamp',
    );
  }
  _checkValues(json, path);
}

const _userContextPath = r'$.userContext';

/// The context itself ([nests]), or the one object it may hold.
Map<String, Object> _contextObject(
  Object? value,
  String path, {
  required bool nests,
}) {
  if (value is! Map) {
    throw ProtocolException(
      ProtocolViolation.invalidType,
      path,
      'Expected object',
    );
  }
  if (value.isEmpty) {
    throw ProtocolException(
      ProtocolViolation.invalidValue,
      path,
      'An empty object is no value of the context',
    );
  }
  if (value.length > FeedbackUserContext.maxKeys) {
    throw ProtocolException(
      ProtocolViolation.oversized,
      path,
      'Maximum is ${FeedbackUserContext.maxKeys} keys',
    );
  }
  final values = <String, Object>{};
  for (final MapEntry(:key, value: child) in value.entries) {
    if (key is! String) {
      throw ProtocolException(
        ProtocolViolation.invalidType,
        path,
        'An object key is a string',
      );
    }
    final childPath = '$path.$key';
    if (!FeedbackUserContext.keyPattern.hasMatch(key)) {
      throw ProtocolException(
        ProtocolViolation.invalidValue,
        childPath,
        'Invalid user context key',
      );
    }
    values[key] = switch (child) {
      Map() when nests => _contextObject(child, childPath, nests: false),
      Map() => throw ProtocolException(
        ProtocolViolation.invalidType,
        childPath,
        'The user context nests one level only',
      ),
      List() => _contextArray(child, childPath),
      _ => _contextScalar(child, childPath),
    };
  }
  return Map.unmodifiable(values);
}

List<Object> _contextArray(List<Object?> value, String path) {
  if (value.isEmpty) {
    throw ProtocolException(
      ProtocolViolation.invalidValue,
      path,
      'An empty array is no value of the context',
    );
  }
  if (value.length > FeedbackUserContext.maxArrayItems) {
    throw ProtocolException(
      ProtocolViolation.oversized,
      path,
      'Maximum is ${FeedbackUserContext.maxArrayItems} items',
    );
  }
  return List.unmodifiable([
    for (final (index, item) in value.indexed)
      switch (item) {
        Map() || List() => throw ProtocolException(
          ProtocolViolation.invalidType,
          '$path[$index]',
          'An array of the context holds scalars only',
        ),
        _ => _contextScalar(item, '$path[$index]'),
      },
  ]);
}

/// A string, a number or a boolean; U+0000 and a number that is not finite
/// are refused after, with the rest of the context ([_checkValues]).
Object _contextScalar(Object? value, String path) => switch (value) {
  bool() || num() => value as Object,
  String()
      when value.runes.length <= FeedbackUserContext.maxStringLength &&
          value.isNotEmpty =>
    value,
  String() => throw ProtocolException(
    ProtocolViolation.invalidValue,
    path,
    'Invalid string value',
  ),
  _ => throw ProtocolException(
    ProtocolViolation.invalidType,
    path,
    'Expected a string, a number or a boolean',
  ),
};

/// [value] with every number as the platform counts it when it measures
/// the user context's size: first as its double, then written as an int
/// where that double is integral and at most 2^53. So `100.0` counts as
/// `100`, and an int past 2^53, such as `1 << 60`, as the double it reads
/// as.
Object? _integralNumbers(Object? value) => switch (value) {
  Map() => {
    for (final MapEntry(:key, value: child) in value.entries)
      key: _integralNumbers(child),
  },
  List() => [for (final item in value) _integralNumbers(item)],
  num() => switch (value.toDouble()) {
    final number
        when number == number.truncateToDouble() &&
            number.abs() <= _maxExactInteger =>
      number.toInt(),
    final number => number,
  },
  _ => value,
};

/// 2^53: every integer up to it is a double exactly.
const _maxExactInteger = 9007199254740992;

/// The diagnostics of [groups], each value made by [value] from the one
/// given at its path, by the rules of a report's `diagnostics`: the number
/// of groups and of values, the names and keys, then the encoded size.
Map<String, Map<String, DiagnosticValue>> _diagnostics<T>(
  Map<String, Map<String, T>> groups,
  DiagnosticValue Function(T value, String path) value,
) {
  if (groups.length > FeedbackReport.maxDiagnosticGroups) {
    throw const ProtocolException(
      ProtocolViolation.oversized,
      r'$.diagnostics',
      'Maximum is ${FeedbackReport.maxDiagnosticGroups} groups',
    );
  }
  final result = <String, Map<String, DiagnosticValue>>{};
  for (final MapEntry(key: name, value: group) in groups.entries) {
    final groupPath = '\$.diagnostics.$name';
    _checkDiagnosticKey(name, groupPath);
    if (group.length > FeedbackReport.maxDiagnosticValues) {
      throw ProtocolException(
        ProtocolViolation.oversized,
        groupPath,
        'Maximum is ${FeedbackReport.maxDiagnosticValues} values',
      );
    }
    final values = <String, DiagnosticValue>{};
    for (final MapEntry(:key, value: item) in group.entries) {
      final path = '$groupPath.$key';
      _checkDiagnosticKey(key, path);
      values[key] = value(item, path);
    }
    result[name] = Map.unmodifiable(values);
  }
  if (utf8.encode(jsonEncode(_diagnosticsJson(result))).length >
      FeedbackReport.maxDiagnosticsBytes) {
    throw const ProtocolException(
      ProtocolViolation.oversized,
      r'$.diagnostics',
      'Diagnostics exceed ${FeedbackReport.maxDiagnosticsBytes} bytes',
    );
  }
  return Map.unmodifiable(result);
}

void _checkDiagnosticKey(String key, String path) {
  if (!FeedbackDiagnostics.keyPattern.hasMatch(key)) {
    throw ProtocolException(
      ProtocolViolation.invalidValue,
      path,
      'Invalid diagnostics key',
    );
  }
}

Map<String, Map<String, Object>> _diagnosticsJson(
  Map<String, Map<String, DiagnosticValue>> diagnostics,
) => {
  for (final MapEntry(key: name, value: group) in diagnostics.entries)
    name: {for (final MapEntry(:key, :value) in group.entries) key: value.json},
};

/// [value] at [path], refused unless its [DiagnosticValue.json] is what its
/// type says: a host may build one itself.
DiagnosticValue _checkedDiagnostic(DiagnosticValue value, String path) {
  final (holds, expected) = switch (value) {
    DiagnosticScalar(:final json) => switch (json) {
      // A number that is not finite is refused below, as anywhere.
      bool() || num() => (true, ''),
      _ => throw ProtocolException(
        ProtocolViolation.invalidType,
        path,
        'Expected a boolean, a number or a string',
      ),
    },
    DiagnosticTimestamp(:final json) => (
      FeedbackReport.isUtcTimestamp(json),
      'Expected UTC timestamp',
    ),
    DiagnosticUuid(:final json) => (
      FeedbackReport.uuidV4.hasMatch(json),
      'Expected a UUID v4',
    ),
    DiagnosticToken(:final json) => (
      FeedbackDiagnostics.tokenPattern.hasMatch(json),
      'A diagnostics value is never free text',
    ),
  };
  if (!holds) {
    throw ProtocolException(ProtocolViolation.invalidValue, path, expected);
  }
  _checkValues(value.json, path);
  return value;
}

/// [value] typed as a UUID v4, a UTC timestamp or a token, in that order,
/// or null where it is free text.
DiagnosticValue? _stringDiagnostic(String value) {
  if (FeedbackReport.uuidV4.hasMatch(value)) return DiagnosticUuid(value);
  if (FeedbackReport.isUtcTimestamp(value)) return DiagnosticTimestamp(value);
  if (FeedbackDiagnostics.tokenPattern.hasMatch(value)) {
    return DiagnosticToken(value);
  }
  return null;
}

const _nul = '\u0000';

/// What no string of a report, value or key, holds: U+0000.
void _checkText(String value, String path) {
  if (value.contains(_nul)) {
    throw ProtocolException(
      ProtocolViolation.invalidValue,
      path,
      'U+0000 is no character of the schema',
    );
  }
}

/// [value] at [path] as the schema counts a string, in code points: from
/// [minLength] to [maxLength], matching [pattern], without U+0000.
void _checkString(
  String value,
  String path, {
  int minLength = 1,
  int? maxLength,
  RegExp? pattern,
}) {
  _checkText(value, path);
  final length = value.runes.length;
  if (length < minLength ||
      (maxLength != null && length > maxLength) ||
      (pattern != null && !pattern.hasMatch(value))) {
    throw ProtocolException(
      ProtocolViolation.invalidValue,
      path,
      'Invalid string value',
    );
  }
}

/// What no value at or under [path] may be: a string, value or key, that
/// holds U+0000 ([_checkText]), or a number that is not finite, which JSON
/// cannot carry. [value] is built of checked parts, never nested deep.
void _checkValues(Object? value, String path) {
  switch (value) {
    case String():
      _checkText(value, path);
    case double() when !value.isFinite:
      throw ProtocolException(
        ProtocolViolation.invalidValue,
        path,
        'Expected a finite number',
      );
    case Map():
      for (final MapEntry(:key, value: child) in value.entries) {
        final childPath = '$path.$key';
        _checkText('$key', childPath);
        _checkValues(child, childPath);
      }
    case List():
      for (final (index, child) in value.indexed) {
        _checkValues(child, '$path[$index]');
      }
  }
}
