import 'checks.dart';
import 'protocol_exception.dart';

enum CrashSeverity { debug, info, warning, error, fatal }

enum CrashPlatform { android, ios, macos, windows, linux, web, unknown }

enum BreadcrumbCategory { bloc, navigation, http, ui, auth, lifecycle, system }

/// Keys whose meaning and scalar shape are fixed by protocol v1.
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
/// Medical data and credentials never belong here. They remain prohibited by
/// the ingestion privacy firewall for every privacy profile.
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
/// the number will eventually guess a different one: a bloc observer capping
/// its summaries at 160 produced events this validator rejected, and the whole
/// report was lost over a label.
const int maxTagValueLength = 100;

/// [value] shortened to [maxLength] (by default [maxTagValueLength]),
/// ellipsis included, or returned unchanged when it already fits. Non-string
/// scalars have no length to clamp.
TagScalar clampTagValue(TagScalar value, {int maxLength = maxTagValueLength}) {
  if (value is! String || value.length <= maxLength) return value;
  return '${value.substring(0, maxLength - 1)}…';
}

final class TypedBreadcrumb {
  const TypedBreadcrumb({
    required this.occurredAt,
    required this.category,
    required this.action,
    this.level = CrashSeverity.info,
    this.data = const {},
  });

  final DateTime occurredAt;
  final BreadcrumbCategory category;

  /// A technical action identifier such as `route.push` or `bloc.transition`.
  final String action;
  final CrashSeverity level;
  final Map<AllowedTag, TagScalar> data;

  static const maxActionLength = 100;

  /// An action: lowercase, starting with a letter.
  static final actionPattern = RegExp(r'^[a-z][a-z0-9_.-]*$');

  /// The tags `data` holds at most on the wire, more than there are
  /// [AllowedTag]s.
  static const maxDataTags = 8;

  /// The same breadcrumb with every tag value longer than [maxLength] (by
  /// default the wire's [maxTagValueLength]) shortened.
  ///
  /// The validator is deliberately strict — it is the wire contract — but a
  /// crash report is worth more than the precision of one label, so a producer
  /// should clamp before an event is built rather than have the report
  /// rejected on the way out.
  TypedBreadcrumb clamped({int maxLength = maxTagValueLength}) {
    if (data.isEmpty) return this;
    return TypedBreadcrumb(
      occurredAt: occurredAt,
      category: category,
      action: action,
      level: level,
      data: {
        for (final entry in data.entries)
          entry.key: clampTagValue(entry.value, maxLength: maxLength),
      },
    );
  }

  Map<String, Object?> toJson() => {
    'occurredAt': occurredAt.toUtc().toIso8601String(),
    'category': category.name,
    'action': action,
    'level': level.name,
    if (data.isNotEmpty)
      'data': {for (final entry in data.entries) entry.key.name: entry.value},
  };

  /// Refuses this breadcrumb as an event's `breadcrumbs` refuse one, with a
  /// [ProtocolException] at `$.breadcrumbs[]`: an [action] of 1 to
  /// [maxActionLength] characters matching [actionPattern], and scalar tags,
  /// each string of at most [maxTagValueLength] characters.
  void check() {
    checkText(
      action,
      r'$.breadcrumbs[].action',
      maxLength: maxActionLength,
      pattern: actionPattern,
    );
    checkTags(data, r'$.breadcrumbs[].data');
  }
}
