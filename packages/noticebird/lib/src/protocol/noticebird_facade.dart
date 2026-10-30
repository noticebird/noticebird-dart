import 'dart:async';
import 'dart:typed_data';

import 'package:noticebird_protocol/feedback.dart';
import 'package:noticebird_protocol/noticebird_protocol.dart';

import '../feedback/feedback_capture.dart';
import 'noticebird_client.dart';

/// Static, ergonomic facade over whichever [NoticebirdClient] is currently
/// [attach]ed.
///
/// [NoticebirdClient] itself stays a plain, constructor-injected instance
/// (config, transport, clock, event id factory all supplied explicitly) so it
/// stays trivially testable — tests construct their own instance with fake
/// collaborators and never touch this facade. [Noticebird] only exists so
/// call sites in a host app can write `Noticebird.captureException(...)`
/// instead of resolving the instance from DI at every call site.
///
/// Every member no-ops (or returns `null`/empty) when no client is attached
/// yet — e.g. before bootstrap reaches [attach], or in builds/tests that
/// never attach one at all — matching [NoticebirdClient]'s own rule that
/// reporting must never affect the host application.
final class Noticebird {
  Noticebird._();

  static NoticebirdClient? _instance;

  /// The currently attached client, or `null` if none has been [attach]ed.
  static NoticebirdClient? get instance => _instance;

  /// Attaches the client that every static [Noticebird] call delegates to.
  /// Call once during app bootstrap, right after constructing the
  /// [NoticebirdClient] (and typically alongside registering it in DI for
  /// code that needs the instance directly).
  static void attach(NoticebirdClient client) => _instance = client;

  /// Detaches the current client, reverting every call to a no-op. Intended
  /// for test teardown between cases that call [attach] themselves.
  static void detach() => _instance = null;

  static Future<CaptureResult>? captureException(
    Object error,
    StackTrace stackTrace, {
    CrashSeverity severity = CrashSeverity.error,
    bool handled = false,
    Map<AllowedTag, TagScalar> tags = const {},
    Map<String, Object?> extra = const {},
    List<String>? groupingKey,
    bool filtered = true,
  }) => _instance?.captureException(
    error,
    stackTrace,
    severity: severity,
    handled: handled,
    tags: tags,
    extra: extra,
    groupingKey: groupingKey,
    filtered: filtered,
  );

  /// See [NoticebirdClient.eventIdOf]; `null` without a client.
  static Future<String?>? eventIdOf(Object error) =>
      _instance?.eventIdOf(error);

  /// See [NoticebirdClient.feedbackMoment]; `null` without a client.
  static FeedbackMoment? feedbackMoment({
    String? routeTemplate,
    Map<String, Map<String, Object?>> diagnostics = const {},
  }) => _instance?.feedbackMoment(
    routeTemplate: routeTemplate,
    diagnostics: diagnostics,
  );

  /// See [NoticebirdClient.captureFeedback]; its types come from
  /// `package:noticebird/feedback.dart`. [FeedbackDisabled] without a
  /// client.
  static Future<FeedbackOutcome> captureFeedback({
    required FeedbackKind kind,
    required String message,
    FeedbackMoment? moment,
    FeedbackTrigger? trigger,
    Uint8List? screenshot,
    String? contactEmail,
    Map<String, Object?>? userContext,
    String? relatedEventId,
  }) =>
      _instance?.captureFeedback(
        kind: kind,
        message: message,
        moment: moment,
        trigger: trigger,
        screenshot: screenshot,
        contactEmail: contactEmail,
        userContext: userContext,
        relatedEventId: relatedEventId,
      ) ??
      Future.value(const FeedbackDisabled());

  /// See [NoticebirdClient.pendingFeedbackCount].
  static Future<int>? get pendingFeedbackCount =>
      _instance?.pendingFeedbackCount;

  /// See [NoticebirdClient.reportNativeCrashes]: call it from the UI
  /// start of a host that owns its bootstrap.
  static Future<List<CaptureResult>>? reportNativeCrashes() =>
      _instance?.reportNativeCrashes();

  static void addBreadcrumb(TypedBreadcrumb breadcrumb) =>
      _instance?.addBreadcrumb(breadcrumb);

  static void clearBreadcrumbs() => _instance?.clearBreadcrumbs();

  static void setUserId(String? userId) => _instance?.setUserId(userId);

  static void setUser(CrashUser? user) => _instance?.setUser(user);

  static void setRouteTemplate(String? routeTemplate) =>
      _instance?.setRouteTemplate(routeTemplate);

  static void startLiveDebugSession({
    required String sessionId,
    required DateTime expiresAt,
  }) => _instance?.startLiveDebugSession(
    sessionId: sessionId,
    expiresAt: expiresAt,
  );

  static void stopLiveDebugSession() => _instance?.stopLiveDebugSession();

  static List<TypedBreadcrumb> get recentBreadcrumbs =>
      _instance?.recentBreadcrumbs ?? const [];

  static bool get isLiveDebugSessionActive =>
      _instance?.isLiveDebugSessionActive ?? false;
}
