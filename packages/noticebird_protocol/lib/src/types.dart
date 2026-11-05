import 'dart:convert';

import 'canonical_json.dart';
import 'checks.dart';
import 'protocol_exception.dart';
import 'text.dart';

enum CrashSeverity { debug, info, warning, error, fatal }

enum CrashPlatform { android, ios, macos, windows, linux, web, unknown }

/// The keys of an event's `tags`, each with a fixed meaning and a scalar
/// value.
enum AllowedTag {
  feature,
  operation,
  component,
  connectivity,
  foreground,
  retryCount,
}

typedef TagScalar = Object;

enum CrashPiiField { userId, email, name, ipAddress }

/// Explicit user identity attached to a crash by the SDK consumer.
///
/// Medical data and credentials never belong here, in any privacy profile.
final class CrashUser {
  const CrashUser({this.id, this.email, this.name, this.ipAddress});

  final String? id;
  final String? email;
  final String? name;
  final String? ipAddress;

  static const maxIdLength = 100;
  static const maxEmailLength = 254;
  static const maxNameLength = 200;
  static const maxIpAddressLength = 45;

  bool get isEmpty =>
      id == null && email == null && name == null && ipAddress == null;

  Map<String, Object?> toJson() => {
    if (id != null) 'id': id,
    if (email != null) 'email': email,
    if (name != null) 'name': name,
    if (ipAddress != null) 'ipAddress': ipAddress,
  };

  /// Refuses this identity as an event's `user` refuses it, with a
  /// [ProtocolException] at `$.user`: at least one field, each 1 to its
  /// maximum characters.
  void check() {
    if (isEmpty) {
      throw const ProtocolException(
        ProtocolViolation.invalidValue,
        r'$.user',
        'At least one user field is required',
      );
    }
    if (id case final id?) {
      checkText(id, r'$.user.id', maxLength: maxIdLength);
    }
    if (email case final email?) {
      checkText(email, r'$.user.email', maxLength: maxEmailLength);
    }
    if (name case final name?) {
      checkText(name, r'$.user.name', maxLength: maxNameLength);
    }
    if (ipAddress case final ipAddress?) {
      checkText(ipAddress, r'$.user.ipAddress', maxLength: maxIpAddressLength);
    }
  }
}

final class CrashException {
  const CrashException({
    required this.type,
    required this.sanitizedMessage,
    required this.stackTrace,
  });

  final String type;
  final String sanitizedMessage;
  final String stackTrace;

  static const maxTypeLength = 160;
  static const maxMessageLength = 512;
  static const maxStackTraceLength = 32768;

  Map<String, Object?> toJson() => {
    'type': type,
    'sanitizedMessage': sanitizedMessage,
    'stackTrace': stackTrace,
  };
}

final class AppMetadata {
  const AppMetadata({
    required this.name,
    required this.version,
    required this.build,
    required this.release,
  });

  final String name;
  final String version;
  final String build;
  final String release;

  static const maxNameLength = 100;
  static const maxVersionLength = 50;
  static const maxBuildLength = 50;
  static const maxReleaseLength = 160;

  Map<String, Object?> toJson() => {
    'name': name,
    'version': version,
    'build': build,
    'release': release,
  };

  /// Refuses this metadata as an event's `app` refuses it, with a
  /// [ProtocolException] at `$.app`: each field 1 to its maximum characters.
  void check() {
    checkText(name, r'$.app.name', maxLength: maxNameLength);
    checkText(version, r'$.app.version', maxLength: maxVersionLength);
    checkText(build, r'$.app.build', maxLength: maxBuildLength);
    checkText(release, r'$.app.release', maxLength: maxReleaseLength);
  }
}

final class PlatformMetadata {
  const PlatformMetadata({
    required this.platform,
    required this.osVersion,
    required this.deviceClass,
  });

  final CrashPlatform platform;
  final String osVersion;
  final String deviceClass;

  static const maxOsVersionLength = 100;
  static const maxDeviceClassLength = 100;

  Map<String, Object?> toJson() => {
    'name': platform.name,
    'osVersion': osVersion,
    'deviceClass': deviceClass,
  };

  /// Refuses this metadata as an event's `platform` refuses it, with a
  /// [ProtocolException] at `$.platform`: each field 1 to its maximum
  /// characters.
  void check() {
    checkText(
      osVersion,
      r'$.platform.osVersion',
      maxLength: maxOsVersionLength,
    );
    checkText(
      deviceClass,
      r'$.platform.deviceClass',
      maxLength: maxDeviceClassLength,
    );
  }
}

/// Longest string a tag value may carry.
///
/// A tag is a label to filter and group by, not a place for a sentence — the
/// limit is what keeps it one. Exported because a consumer that has to guess
/// the number will eventually guess a different one: a producer capping its
/// labels at 160 produced events this validator rejected, and the whole
/// report was lost over a label.
const int maxTagValueLength = 100;

/// Whether [value] is a tag value an event takes: a string of at most
/// [maxTagValueLength] characters, a finite number or a boolean.
bool isTagValue(TagScalar value) => switch (value) {
  String() => value.length <= maxTagValueLength,
  num() => value.isFinite,
  bool() => true,
  _ => false,
};

/// [value] shortened to [maxLength] (by default [maxTagValueLength]),
/// ellipsis included, or returned unchanged when it already fits. Non-string
/// scalars have no length to clamp.
TagScalar clampTagValue(TagScalar value, {int maxLength = maxTagValueLength}) {
  if (value is! String || value.length <= maxLength) return value;
  return '${cutText(value, maxLength - 1)}…';
}

/// How much a breadcrumb matters. Absent, a breadcrumb has none and reads as
/// [info].
enum BreadcrumbLevel { debug, info, warning, error }

/// One step of the trail that led to an event or a feedback report: when
/// ([at]) and what happened as one line a human reads ([message]) — all a
/// step needs — and, optionally, a technical id of the kind of step
/// ([action]), a short group ([category]), a [level] and [details]: extra
/// lines under the step, each `name: value`.
///
/// A character is a UTF-16 code unit (Dart's [String.length]) for every
/// length limit here, and a byte a byte of the UTF-8 encoding of the
/// canonical JSON ([canonicalJsonEncode]) for every budget: a step's
/// [maxEncodedBytes], an event's `CrashEvent.maxBreadcrumbsBytes` and a
/// feedback report's `FeedbackReport.maxTrailBytes`.
///
/// [detailStringPattern] is a shape, not a privacy guarantee: a surname or a
/// postcode fits it. What keeps such values out is what the app puts in
/// [details], and the per-entry checks of the client and the platform.
final class TypedBreadcrumb {
  const TypedBreadcrumb({
    required this.at,
    required this.message,
    this.action,
    this.category,
    this.level,
    this.details = const {},
  });

  /// When the step happened, on the device's clock.
  final DateTime at;

  /// One line a human reads: 1 to [maxMessageLength] characters, without a
  /// line break ([lineBreakPattern]), a control character
  /// ([controlPattern]) or an unpaired surrogate ([hasUnpairedSurrogate]).
  final String message;

  /// A technical id of the kind of step, such as `route.push` or
  /// `checkout.submit`: 1 to [maxActionLength] characters matching
  /// [actionPattern]. The key for grouping steps, and for comparing a step
  /// with the previous step of the same action.
  final String? action;

  /// A short group, such as `navigation`: 1 to [maxCategoryLength]
  /// characters matching [categoryPattern].
  final String? category;

  final BreadcrumbLevel? level;

  /// Extra lines under the step, each `name: value` (`items: 3`), flat:
  /// at most [maxDetails] entries, each name 1
  /// to [maxDetailNameLength] characters matching [detailNamePattern], each
  /// value an [isDetailValue].
  final Map<String, Object> details;

  static const maxMessageLength = 200;

  /// A line break, which a message never holds: the client turns each into
  /// a space.
  static final lineBreakPattern = RegExp('\r\n|[\n\r\u000B\u000C\u0085  ]');

  /// A character a message never holds, the one list of them: a C0 or C1
  /// control (every line break among them), a line or paragraph separator
  /// (U+2028, U+2029), an invisible character (the zero-width space
  /// U+200B, U+2060–U+2064, the byte order mark U+FEFF) or a bidirectional
  /// mark, override or isolate (U+061C, U+200E, U+200F, U+202A–U+202E,
  /// U+2066–U+2069), which hide or reorder what a reader sees. The
  /// zero-width non-joiner and joiner (U+200C, U+200D) are not in it: an
  /// emoji sequence (👨‍👩‍👧) and Persian and Indic words need them. The client turns each into a space,
  /// U+0000 excepted, which it leaves out; a reader of text that is shown
  /// (a mail) uses the same list.
  static final controlPattern = RegExp(
    r'[\u0000-\u001F\u007F-\u009F\u061C\u200B\u200E\u200F\u2028\u2029'
    r'\u202A-\u202E\u2060-\u2064\u2066-\u2069\uFEFF]',
  );

  static const maxActionLength = 100;

  /// An action: a lowercase letter first, then letters, digits, `_`, `.` and
  /// `-`, so that a type's name in camel case can lead it.
  static final actionPattern = RegExp(r'^[a-z][A-Za-z0-9_.-]*$');

  static const maxCategoryLength = 32;

  /// A category: a lowercase letter first, then lowercase letters, digits
  /// and `_`.
  static final categoryPattern = RegExp(r'^[a-z][a-z0-9_]*$');

  static const maxDetails = 16;

  static const maxDetailNameLength = 48;

  /// A detail name: identifier-like parts joined by dots
  /// (`collections.count`).
  static final detailNamePattern = RegExp(
    r'^[a-z][A-Za-z0-9_]*(\.[a-z][A-Za-z0-9_]*)*$',
  );

  static const maxDetailStringLength = 64;

  /// A detail string: identifier-like, no space, so never prose; `/` and `:`
  /// for route templates (`/lists/:listId`) and sites
  /// (`sync.write_held:entries`).
  static final detailStringPattern = RegExp(
    r'^[A-Za-z0-9/:][A-Za-z0-9_.:/+-]*$',
  );

  /// The most bytes one step takes, encoded.
  static const maxEncodedBytes = 512;

  /// The largest magnitude of a detail number: 2^53, below which every whole
  /// number is exact as a double, on every platform.
  static const maxDetailNumber = 9007199254740992;

  /// Whether [value] is a value [details] takes: a finite number of at most
  /// [maxDetailNumber] in magnitude, a boolean,
  /// or a string of 1 to [maxDetailStringLength] characters matching
  /// [detailStringPattern].
  static bool isDetailValue(Object? value) => switch (value) {
    num() => value.isFinite && value.abs() <= maxDetailNumber,
    bool() => true,
    String() =>
      value.length <= maxDetailStringLength &&
          detailStringPattern.hasMatch(value),
    _ => false,
  };

  /// Whether [name] is a name [details] takes: 1 to [maxDetailNameLength]
  /// characters matching [detailNamePattern].
  static bool isDetailName(String name) =>
      name.length <= maxDetailNameLength && detailNamePattern.hasMatch(name);

  /// The entry [name] → [value] as one text, `name: value`, a number and a
  /// boolean as Dart writes them: what a privacy check scans of an entry,
  /// on the client and on the platform alike, so a name and its value are
  /// read together (`contact: 31612345678`).
  static String detailEntryText(String name, Object value) => '$name: $value';

  Map<String, Object?> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'message': message,
    'action': ?action,
    'category': ?category,
    'level': ?level?.name,
    if (details.isNotEmpty) 'details': details,
  };

  /// The bytes [trail] takes encoded, as an event's
  /// `CrashEvent.maxBreadcrumbsBytes` and a feedback report's
  /// `FeedbackReport.maxTrailBytes` count them: the array's canonical JSON
  /// in UTF-8.
  static int trailBytes(List<TypedBreadcrumb> trail) => utf8
      .encode(canonicalJsonEncode([for (final item in trail) item.toJson()]))
      .length;

  /// The bytes of this step's encoding: what [maxEncodedBytes] bounds.
  int get encodedBytes => utf8.encode(canonicalJsonEncode(toJson())).length;

  /// Refuses this breadcrumb as an event's `breadcrumbs` refuse one, with a
  /// [ProtocolException] at `$.breadcrumbs[]`: every field by the rules
  /// above, then the [maxEncodedBytes] of its encoding.
  void check() {
    checkText(message, r'$.breadcrumbs[].message', maxLength: maxMessageLength);
    if (lineBreakPattern.hasMatch(message) ||
        controlPattern.hasMatch(message)) {
      throw const ProtocolException(
        ProtocolViolation.invalidValue,
        r'$.breadcrumbs[].message',
        'A message is one line, without control characters',
      );
    }
    if (hasUnpairedSurrogate(message)) {
      throw const ProtocolException(
        ProtocolViolation.invalidValue,
        r'$.breadcrumbs[].message',
        'A message holds no unpaired surrogate',
      );
    }
    if (action case final action?) {
      checkText(
        action,
        r'$.breadcrumbs[].action',
        maxLength: maxActionLength,
        pattern: actionPattern,
      );
    }
    if (category case final category?) {
      checkText(
        category,
        r'$.breadcrumbs[].category',
        maxLength: maxCategoryLength,
        pattern: categoryPattern,
      );
    }
    _checkData();
    if (encodedBytes > maxEncodedBytes) {
      throw const ProtocolException(
        ProtocolViolation.oversized,
        r'$.breadcrumbs[]',
        'A breadcrumb exceeds $maxEncodedBytes bytes',
      );
    }
  }

  void _checkData() {
    const path = r'$.breadcrumbs[].details';
    if (details.length > maxDetails) {
      throw const ProtocolException(
        ProtocolViolation.oversized,
        path,
        'Maximum is $maxDetails entries',
      );
    }
    for (final MapEntry(:key, :value) in details.entries) {
      if (!isDetailName(key)) {
        throw ProtocolException(
          ProtocolViolation.invalidValue,
          '$path.$key',
          'Invalid detail name',
        );
      }
      if (isDetailValue(value)) continue;
      final (violation, message) = switch (value) {
        String() when value.length > maxDetailStringLength => (
          ProtocolViolation.oversized,
          'Data string exceeds $maxDetailStringLength characters',
        ),
        String() => (
          ProtocolViolation.invalidValue,
          'A detail string is identifier-like',
        ),
        num() => (
          ProtocolViolation.invalidValue,
          'Data numbers are finite, at most $maxDetailNumber in magnitude',
        ),
        _ => (ProtocolViolation.invalidType, 'A detail value is a scalar'),
      };
      throw ProtocolException(violation, '$path.$key', message);
    }
  }
}
