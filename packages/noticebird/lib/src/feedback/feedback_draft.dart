import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:noticebird_protocol/feedback.dart';
import 'package:noticebird_protocol/noticebird_protocol.dart';

import '../protocol/text_sanitizer.dart';
import 'feedback_capture.dart';

/// A value the host passed that the report refuses, at [path].
final class FeedbackInputException implements Exception {
  const FeedbackInputException(this.path, this.message);

  final String path;
  final String message;

  @override
  String toString() => 'Invalid feedback input at $path: $message';
}

/// A report built from the host's input and the client's context, waiting
/// only for its reporter assertion ([report]).
///
/// Every rule is the report's own, applied by [FeedbackReport.toJson] and
/// the report's checks of a single value: what the client fills in itself
/// and the report refuses is left out where it is optional (a locale, a
/// route template, a user field, a trail item) and fails the report where
/// it is not (the session id, the app and platform metadata), what the host
/// passed and the report refuses is a [FeedbackInputException], and the
/// trail is cut to fit.
final class FeedbackDraft {
  FeedbackDraft._(this._build, this._trail, this.attachment);

  /// Throws a [FeedbackInputException] for a value of the host's the report
  /// refuses: the message redacted and cut to
  /// [FeedbackReport.maxMessageLength] and left empty, [contactEmail],
  /// [diagnostics] ([FeedbackDiagnostics.build]), [userContext]
  /// ([FeedbackUserContext.check]), [relatedEventId], or a [screenshot]
  /// whose bytes are too many or not its type. Throws a [StateError] for a
  /// value of the client's own the report refuses and cannot do without:
  /// [sessionId], [app] or [platform].
  ///
  /// The message loses its U+0000 characters, which no report string may
  /// hold, before it is redacted and cut.
  ///
  /// [userContext] is checked for its shape only and sent as the host gave
  /// it: the platform drops what it may not keep. [trail] is the newest
  /// breadcrumbs, oldest first and each already sanitized; one the report
  /// refuses ([FeedbackReport.checkTrailItem]) is left out, and [report]
  /// keeps as many of the newest as fit.
  factory FeedbackDraft({
    required String reportId,
    required DateTime createdAt,
    required FeedbackKind kind,
    required String message,
    required FeedbackTrigger? trigger,
    required FeedbackScreenshot? screenshot,
    required String? contactEmail,
    required Map<String, Map<String, Object?>>? diagnostics,
    required Map<String, Object?>? userContext,
    required String? relatedEventId,
    required AppMetadata app,
    required PlatformMetadata platform,
    required String? locale,
    required String sessionId,
    required String? routeTemplate,
    required CrashUser? user,
    required List<TypedBreadcrumb> trail,
  }) {
    final context = switch (userContext) {
      final values? => _checked(() => FeedbackUserContext.check(values)),
      null => null,
    };
    final (attachment, reference) = switch (screenshot) {
      final screenshot? => _attachment(screenshot),
      null => (null, null),
    };
    final userFields = <String, String>{
      'id': ?user?.id,
      'email': ?user?.email,
      'name': ?user?.name,
    };
    final keptLocale =
        locale != null && _passes(() => FeedbackReport.checkLocale(locale))
        ? locale
        : null;
    final keptRoute =
        routeTemplate != null &&
            _passes(() => FeedbackReport.checkRouteTemplate(routeTemplate))
        ? routeTemplate
        : null;
    final safeMessage = sanitizeCrashText(
      message.replaceAll('\u0000', ''),
      maxLength: FeedbackReport.maxMessageLength,
    );
    final typedDiagnostics = diagnostics == null
        ? const <String, Map<String, DiagnosticValue>>{}
        : _checked(() => FeedbackDiagnostics.build(diagnostics));

    FeedbackReport build(List<TypedBreadcrumb> trail, String? assertion) =>
        FeedbackReport(
          reportId: reportId,
          createdAt: createdAt,
          kind: kind,
          trigger: trigger,
          message: safeMessage,
          contactEmail: contactEmail,
          app: app,
          platform: platform,
          locale: keptLocale,
          routeTemplate: keptRoute,
          sessionId: sessionId,
          relatedEventId: relatedEventId,
          user: userFields.isEmpty
              ? null
              : FeedbackUser(
                  id: userFields['id'],
                  email: userFields['email'],
                  name: userFields['name'],
                ),
          userContext: context,
          reporterAssertion: assertion,
          trail: trail,
          diagnostics: typedDiagnostics,
          attachments: [?reference],
        );

    // A user field the client holds goes when the report refuses it, or
    // fails the report when the report needs it; what the host passed is
    // the host's to fix.
    for (;;) {
      try {
        build(const [], null).toJson();
        break;
      } on ProtocolException catch (error) {
        final path = error.path;
        if (path.startsWith(r'$.user.') &&
            userFields.remove(path.substring(7)) != null) {
          continue;
        } else if (_isHostInput(path)) {
          throw FeedbackInputException(path, error.message);
        } else {
          throw StateError('The report refuses the client\'s own $error');
        }
      }
    }

    // A breadcrumb the report refuses goes alone (a timestamp later than
    // the report allows, an action outside the wire's pattern).
    return FeedbackDraft._(
      build,
      List.unmodifiable(
        trail.where(
          (item) => _passes(
            () => FeedbackReport.checkTrailItem(item, createdAt: createdAt),
          ),
        ),
      ),
      attachment,
    );
  }

  /// What [attempt] answers for the most of the newest of [trail] it takes,
  /// or `null` when it takes not even an empty trail: [attempt] answers
  /// `null` for a trail too large. The encoding grows with every
  /// breadcrumb, so the count is found by halving, between one that fits
  /// and one that does not.
  static T? _fitTrail<T extends Object>(
    List<TypedBreadcrumb> trail,
    T? Function(List<TypedBreadcrumb> trail) attempt,
  ) {
    T? newest(int count) => attempt(trail.sublist(trail.length - count));
    final whole = newest(trail.length);
    if (whole != null) return whole;
    var best = newest(0);
    if (best == null) return null;
    var low = 0;
    var high = trail.length;
    while (high - low > 1) {
      final middle = (low + high) ~/ 2;
      final result = newest(middle);
      if (result != null) {
        low = middle;
        best = result;
      } else {
        high = middle;
      }
    }
    return best;
  }

  final FeedbackReport Function(List<TypedBreadcrumb>, String?) _build;
  final List<TypedBreadcrumb> _trail;

  /// The screenshot's bytes, copied at capture; `null` without one.
  final Uint8List? attachment;

  /// The report with [reporterAssertion], left out when the report refuses
  /// it, and as many of the newest breadcrumbs as fit
  /// [FeedbackReport.maxEncodedBytes]: the oldest go first.
  FeedbackReport report({String? reporterAssertion}) {
    FeedbackReport? fitting(List<TypedBreadcrumb> trail, String? assertion) {
      try {
        return _build(trail, assertion)..toJson();
      } on ProtocolException {
        return null;
      }
    }

    return (reporterAssertion == null
            ? null
            : _fitTrail(
                _trail,
                (trail) => fitting(trail, reporterAssertion),
              )) ??
        _fitTrail(_trail, (trail) => fitting(trail, null)) ??
        _build(const [], null);
  }

  /// Whether [path] names a value of the host's input rather than of the
  /// client's own context; `$` is the report too large without its trail,
  /// which only the host's content can make it.
  static bool _isHostInput(String path) =>
      path == r'$' ||
      const [
        r'$.message',
        r'$.contact',
        r'$.diagnostics',
        r'$.userContext',
        r'$.relatedEventId',
        r'$.attachments',
      ].any(path.startsWith);

  static T _checked<T>(T Function() check) {
    try {
      return check();
    } on ProtocolException catch (error) {
      throw FeedbackInputException(error.path, error.message);
    }
  }

  static bool _passes(void Function() check) {
    try {
      check();
      return true;
    } on ProtocolException {
      return false;
    }
  }

  /// The screenshot's bytes, copied, and their reference: its size and
  /// type are checked before the bytes are copied and hashed.
  static (Uint8List, FeedbackAttachmentRef) _attachment(
    FeedbackScreenshot screenshot,
  ) {
    if (screenshot.bytes.lengthInBytes > FeedbackAttachmentRef.maxByteLength) {
      throw const FeedbackInputException(
        r'$.attachments[0].byteLength',
        'More than ${FeedbackAttachmentRef.maxByteLength} bytes',
      );
    }
    if (!screenshot.contentType.matches(screenshot.bytes)) {
      throw FeedbackInputException(
        r'$.attachments[0].contentType',
        'The bytes are no ${screenshot.contentType.mimeType}',
      );
    }
    final bytes = Uint8List.fromList(screenshot.bytes);
    return (
      bytes,
      FeedbackAttachmentRef(
        index: 0,
        contentType: screenshot.contentType,
        byteLength: bytes.length,
        sha256: sha256.convert(bytes).toString(),
      ),
    );
  }
}
