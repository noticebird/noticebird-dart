import 'dart:convert';

import 'canonical_json.dart';
import 'checks.dart';
import 'native_crash.dart';
import 'protocol_exception.dart';
import 'types.dart';

/// A crash event, schema version [schemaVersion], as a client builds it.
///
/// Fail-closed: [toJson] checks every field by its rules and the limits,
/// which are named here and on the value types, and a refusal is a
/// [ProtocolException] whose path names the offending value. The checks of
/// a value a client sets before an event is built are public on its type:
/// [AppMetadata.check], [PlatformMetadata.check], [CrashUser.check],
/// [TypedBreadcrumb.check], [BreadcrumbDrops.check] and
/// [NativeCrashInfo.check].
final class CrashEvent {
  const CrashEvent({
    required this.eventId,
    required this.occurredAt,
    required this.severity,
    required this.handled,
    required this.exception,
    required this.app,
    required this.platform,
    required this.routeTemplate,
    required this.sessionId,
    this.user,
    this.tags = const {},
    this.extra = const {},
    this.breadcrumbs = const [],
    this.nativeCrash,
    this.groupingKey,
    this.breadcrumbDrops,
  });

  /// The schema version [toJson] writes, the only one it writes.
  static const schemaVersion = 6;
  static const maxEncodedBytes = 65536;

  /// An event id: 36 hex digits and dashes, a UUID's shape.
  static final eventIdPattern = RegExp(r'^[0-9a-fA-F-]{36}$');

  static final sessionIdPattern = RegExp(r'^[A-Za-z0-9_-]{16,64}$');

  /// A route template starts with `/`.
  static const maxRouteTemplateLength = 200;

  /// The fields an [extra] object, or the items a list in it, holds at most,
  /// at every level.
  static const maxExtraEntries = 20;

  /// The levels of objects and lists [extra] nests below its own.
  static const maxExtraDepth = 2;
  static const maxExtraStringLength = 1000;

  /// A key of [extra], at every level.
  static final extraKeyPattern = RegExp(r'^[A-Za-z][A-Za-z0-9_.-]{0,63}$');

  /// The breadcrumbs one event may carry at most.
  static const maxBreadcrumbs = 50;

  /// The most bytes the encoded [breadcrumbs] take together, the array's
  /// canonical JSON in UTF-8.
  static const maxBreadcrumbsBytes = 16384;

  /// The parts a [groupingKey] holds at most.
  static const maxGroupingKeyParts = 8;

  /// The characters one part of a [groupingKey] holds at most.
  static const maxGroupingKeyPartLength = 100;

  final String eventId;
  final DateTime occurredAt;
  final CrashSeverity severity;
  final bool handled;
  final CrashException exception;
  final AppMetadata app;
  final PlatformMetadata platform;
  final String? routeTemplate;
  final String sessionId;

  final CrashUser? user;
  final Map<AllowedTag, TagScalar> tags;

  /// Free context: JSON values, [maxExtraEntries] at most per object or
  /// list, nested [maxExtraDepth] levels at most, strings of at most
  /// [maxExtraStringLength] characters, keys by [extraKeyPattern], numbers
  /// finite.
  final Map<String, Object?> extra;
  final List<TypedBreadcrumb> breadcrumbs;

  /// The operating system's report of a native crash from an earlier run,
  /// written as `native` (schema 4). Its presence and the
  /// [nativeStackTraceMarker] as `exception.stackTrace` require each other.
  final NativeCrashInfo? nativeCrash;

  /// The app's own grouping of this event (schema 5): every event of the
  /// app with the same parts is one issue, whatever its type or stack. One
  /// to [maxGroupingKeyParts] non-empty parts of at most
  /// [maxGroupingKeyPartLength] characters each, technical text like a tag
  /// value: never personal data or a credential.
  final List<String>? groupingKey;

  /// What the client left out of [breadcrumbs] on the device (schema 6):
  /// absent when it left out nothing.
  final BreadcrumbDrops? breadcrumbDrops;

  /// This event as the wire's JSON object at [schemaVersion], checked by
  /// every rule of an event, then the [maxEncodedBytes] of its encoding. An
  /// event the platform would refuse for its shape throws a
  /// [ProtocolException] here, before it is sent or queued.
  Map<String, Object?> toJson() {
    _check();
    final json = <String, Object?>{
      'schemaVersion': schemaVersion,
      'eventId': eventId,
      'occurredAt': occurredAt.toUtc().toIso8601String(),
      'severity': severity.name,
      'handled': handled,
      'exception': exception.toJson(),
      'app': app.toJson(),
      'platform': platform.toJson(),
      if (routeTemplate != null) 'routeTemplate': routeTemplate,
      'sessionId': sessionId,
      if (user != null) 'user': user!.toJson(),
      if (tags.isNotEmpty)
        'tags': {for (final entry in tags.entries) entry.key.name: entry.value},
      if (extra.isNotEmpty) 'extra': extra,
      if (breadcrumbs.isNotEmpty)
        'breadcrumbs': breadcrumbs.map((value) => value.toJson()).toList(),
      if (nativeCrash != null) 'native': nativeCrash!.toJson(),
      if (groupingKey != null) 'groupingKey': groupingKey,
      if (breadcrumbDrops != null) 'breadcrumbDrops': breadcrumbDrops!.toJson(),
    };
    if (utf8.encode(canonicalJsonEncode(json)).length > maxEncodedBytes) {
      throw const ProtocolException(
        ProtocolViolation.oversized,
        r'$',
        'Payload exceeds $maxEncodedBytes bytes',
      );
    }
    return json;
  }

  /// [toJson], encoded with sorted keys ([canonicalJsonEncode]): the body of
  /// `POST /v1/envelope`.
  String toCanonicalJson() => canonicalJsonEncode(toJson());

  /// Every field by its rules, in the order of the wire.
  void _check() {
    if (!eventIdPattern.hasMatch(eventId)) {
      throw const ProtocolException(
        ProtocolViolation.invalidValue,
        r'$.eventId',
        'Invalid value',
      );
    }
    checkText(
      exception.type,
      r'$.exception.type',
      maxLength: CrashException.maxTypeLength,
    );
    checkText(
      exception.sanitizedMessage,
      r'$.exception.sanitizedMessage',
      maxLength: CrashException.maxMessageLength,
    );
    checkText(
      exception.stackTrace,
      r'$.exception.stackTrace',
      maxLength: CrashException.maxStackTraceLength,
    );
    _checkNative();
    _checkGroupingKey();
    app.check();
    platform.check();
    if (!sessionIdPattern.hasMatch(sessionId)) {
      throw const ProtocolException(
        ProtocolViolation.invalidValue,
        r'$.sessionId',
        'Invalid value',
      );
    }
    if (routeTemplate case final route?
        when route.length > maxRouteTemplateLength || !route.startsWith('/')) {
      throw const ProtocolException(
        ProtocolViolation.invalidValue,
        r'$.routeTemplate',
        'Invalid route template',
      );
    }
    user?.check();
    checkTags(tags, r'$.tags');
    _checkExtra(extra, r'$.extra', depth: 0);
    if (breadcrumbs.length > maxBreadcrumbs) {
      throw const ProtocolException(
        ProtocolViolation.oversized,
        r'$.breadcrumbs',
        'Maximum is $maxBreadcrumbs',
      );
    }
    for (final breadcrumb in breadcrumbs) {
      breadcrumb.check();
    }
    if (TypedBreadcrumb.trailBytes(breadcrumbs) > maxBreadcrumbsBytes) {
      throw const ProtocolException(
        ProtocolViolation.oversized,
        r'$.breadcrumbs',
        'Breadcrumbs exceed $maxBreadcrumbsBytes bytes',
      );
    }
    breadcrumbDrops?.check();
  }

  /// The [nativeCrash] and the [nativeStackTraceMarker] require each other.
  void _checkNative() {
    final native = nativeCrash;
    if (native == null) {
      if (exception.stackTrace == nativeStackTraceMarker) {
        throw const ProtocolException(
          ProtocolViolation.invalidValue,
          r'$.exception.stackTrace',
          'The native marker requires a native block',
        );
      }
      return;
    }
    native.check();
    if (exception.stackTrace != nativeStackTraceMarker) {
      throw const ProtocolException(
        ProtocolViolation.invalidValue,
        r'$.exception.stackTrace',
        'A native event carries the native marker as its stack trace',
      );
    }
  }

  void _checkGroupingKey() {
    final parts = groupingKey;
    if (parts == null) return;
    if (parts.isEmpty) {
      throw const ProtocolException(
        ProtocolViolation.invalidValue,
        r'$.groupingKey',
        'A grouping key has at least one part',
      );
    }
    if (parts.length > maxGroupingKeyParts) {
      throw const ProtocolException(
        ProtocolViolation.oversized,
        r'$.groupingKey',
        'Maximum is $maxGroupingKeyParts parts',
      );
    }
    for (final part in parts) {
      if (part.isEmpty) {
        throw const ProtocolException(
          ProtocolViolation.invalidValue,
          r'$.groupingKey[]',
          'A grouping key part is not empty',
        );
      }
      if (part.length > maxGroupingKeyPartLength) {
        throw const ProtocolException(
          ProtocolViolation.oversized,
          r'$.groupingKey[]',
          'Grouping key part exceeds $maxGroupingKeyPartLength characters',
        );
      }
    }
  }
}

/// [value], the [CrashEvent.extra] object or a value in it at [path],
/// nested [depth] levels below it, by the rules of `extra`.
void _checkExtra(Object? value, String path, {required int depth}) {
  switch (value) {
    case null || bool():
      return;
    case num() when !value.isFinite:
      throw ProtocolException(
        ProtocolViolation.invalidValue,
        path,
        'Context numbers must be finite',
      );
    case num():
      return;
    case String() when value.length > CrashEvent.maxExtraStringLength:
      throw ProtocolException(
        ProtocolViolation.oversized,
        path,
        'Context string exceeds ${CrashEvent.maxExtraStringLength} characters',
      );
    case String():
      return;
    case List() || Map() when depth > CrashEvent.maxExtraDepth:
      throw ProtocolException(
        ProtocolViolation.oversized,
        path,
        'Context nesting exceeds ${CrashEvent.maxExtraDepth} levels',
      );
    case List(:final length) || Map(:final length)
        when length > CrashEvent.maxExtraEntries:
      throw ProtocolException(
        ProtocolViolation.oversized,
        path,
        'Maximum is ${CrashEvent.maxExtraEntries} entries',
      );
    case List():
      for (final (index, item) in value.indexed) {
        _checkExtra(item, '$path[$index]', depth: depth + 1);
      }
    case Map():
      for (final MapEntry(:key, value: child) in value.entries) {
        if (key is! String || !CrashEvent.extraKeyPattern.hasMatch(key)) {
          throw ProtocolException(
            ProtocolViolation.invalidValue,
            '$path.$key',
            'Invalid context key',
          );
        }
        _checkExtra(child, '$path.$key', depth: depth + 1);
      }
    default:
      throw ProtocolException(
        ProtocolViolation.invalidType,
        path,
        'Context values must be JSON-compatible',
      );
  }
}

/// What a client left out of an event's breadcrumbs before it sent them
/// (`breadcrumbDrops`, schema 6), so a loss of evidence is visible.
final class BreadcrumbDrops {
  const BreadcrumbDrops({this.detailsDropped = 0, this.stepsDropped = 0});

  /// Values left out of steps that were kept: a detail entry, an action or a
  /// category the client's checks refused, and a message the client cut
  /// (to its length or to the step's bytes), one per message.
  final int detailsDropped;

  /// Steps left out whole: refused even after their values went, or past
  /// the event's [CrashEvent.maxBreadcrumbsBytes], the oldest first.
  final int stepsDropped;

  /// Whether nothing was left out.
  bool get isEmpty => detailsDropped == 0 && stepsDropped == 0;

  /// These counts and [other]'s together.
  BreadcrumbDrops operator +(BreadcrumbDrops other) => BreadcrumbDrops(
    detailsDropped: detailsDropped + other.detailsDropped,
    stepsDropped: stepsDropped + other.stepsDropped,
  );

  Map<String, Object> toJson() => {
    'detailsDropped': detailsDropped,
    'stepsDropped': stepsDropped,
  };

  /// Refuses these counts as an event refuses them, at
  /// `$.breadcrumbDrops`: each 0 or more, and not both 0 — an event that
  /// lost nothing carries none.
  void check() {
    if (detailsDropped < 0 || stepsDropped < 0 || isEmpty) {
      throw const ProtocolException(
        ProtocolViolation.invalidValue,
        r'$.breadcrumbDrops',
        'Counts are not negative, and not both 0',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is BreadcrumbDrops &&
      other.detailsDropped == detailsDropped &&
      other.stepsDropped == stepsDropped;

  @override
  int get hashCode => Object.hash(detailsDropped, stepsDropped);

  @override
  String toString() =>
      'BreadcrumbDrops(detailsDropped: $detailsDropped, stepsDropped: $stepsDropped)';
}
