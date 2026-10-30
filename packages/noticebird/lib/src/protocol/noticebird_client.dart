import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui';

import 'package:noticebird_protocol/feedback.dart';
import 'package:noticebird_protocol/noticebird_protocol.dart';
import 'package:flutter/foundation.dart';

import '../feedback/feedback_capture.dart';
import '../feedback/feedback_config.dart';
import '../feedback/feedback_draft.dart';
import '../feedback/feedback_queue.dart';
import '../feedback/feedback_sender.dart';
import 'crash_exception_type.dart';
import 'crash_http_transport.dart';
import 'deduplication_key.dart';
import 'host_mistakes.dart';
import 'noticebird_config.dart';
import 'native_crash_collector.dart';
import 'native_crash_event.dart';
import 'text_sanitizer.dart';

/// What happened to an event passed to [NoticebirdClient.captureException].
enum CaptureOutcome {
  /// Delivered to the transport.
  sent,

  /// Suppressed because the same error was captured within the
  /// deduplication window: the same grouping key, or the same type and top
  /// app frames, line numbers aside.
  deduplicated,

  /// The transport failed; the event is queued for a later
  /// [NoticebirdClient.flush].
  queued,

  /// The event could not be captured, for example because config-supplied
  /// metadata violates the protocol, the retry queue is disabled, or the
  /// platform refused the event for good (see `CrashTransport.send`).
  dropped,

  /// The host's [NoticebirdConfig.shouldCapture] declined the error.
  ignored,
}

/// What [NoticebirdClient.captureException] made of an error: its [outcome],
/// and the id of the event that stands for it, to pass on as a feedback
/// report's `relatedEventId`.
final class CaptureResult {
  const CaptureResult(this.outcome, {this.eventId});

  final CaptureOutcome outcome;

  /// The event's `eventId`, by [outcome]:
  ///
  /// - [CaptureOutcome.sent] and [CaptureOutcome.queued]: the id of the
  ///   event built for this error, sent or waiting for a
  ///   [NoticebirdClient.flush].
  /// - [CaptureOutcome.deduplicated]: the id of the earlier event within
  ///   the deduplication window this one was suppressed against; null when
  ///   that event was dropped.
  /// - [CaptureOutcome.dropped] and [CaptureOutcome.ignored]: null; no event
  ///   went anywhere, even when one was built.
  final String? eventId;

  @override
  bool operator ==(Object other) =>
      other is CaptureResult &&
      other.outcome == outcome &&
      other.eventId == eventId;

  @override
  int get hashCode => Object.hash(outcome, eventId);

  @override
  String toString() => eventId == null
      ? 'CaptureResult(${outcome.name})'
      : 'CaptureResult(${outcome.name}, eventId: $eventId)';
}

final class NoticebirdClient {
  NoticebirdClient({
    required NoticebirdConfig config,
    required CrashTransport transport,
    DateTime Function()? clock,
    String Function()? eventIdFactory,
  }) : _config = config,
       _transport = transport,
       _clock = clock ?? DateTime.now,
       _eventIdFactory = eventIdFactory ?? _fallbackEventId {
    final collector = config.nativeCrashes;
    if (collector != null) _nativeStarted = _startNative(collector);
  }

  /// Native reports delivered per batch at most; the rest wait for the next
  /// launch. Bounds the burst a crash loop leaves behind.
  static const maxNativeCrashesPerBatch = 10;
  static const _nativeStartTimeout = Duration(seconds: 5);
  static const _nativeFirstBatchTimeout = Duration(seconds: 15);
  static const _nativeSettleTimeout = Duration(seconds: 5);

  final NoticebirdConfig _config;
  final CrashTransport _transport;
  final DateTime Function() _clock;
  final String Function() _eventIdFactory;
  final List<TypedBreadcrumb> _breadcrumbs = [];

  /// How many breadcrumbs were ever recorded, and how many of those a sent
  /// event carried or a clear forgot: the newest `_recorded - _sentThrough`
  /// of the buffer are the ones the next event carries.
  int _recorded = 0;
  int _sentThrough = 0;
  final List<_WrittenEvent> _pending = [];

  /// Per error captured within the deduplication window
  /// ([deduplicationKey]): when, and the id of the event that went, for a
  /// [CaptureOutcome.deduplicated] result. The id is null when that event
  /// was dropped.
  final Map<String, ({DateTime seenAt, String? eventId})> _lastByKey = {};
  bool _handlersInstalled = false;
  bool _flushingEvents = false;
  FlutterExceptionHandler? _previousFlutterHandler;
  ErrorCallback? _previousPlatformHandler;
  String? _userId;
  CrashUser? _user;
  String? _liveDebugSessionId;
  DateTime? _liveDebugSessionExpiresAt;
  bool _liveDebugSyncInFlight = false;
  bool _liveDebugSyncPending = false;
  Future<void>? _nativeStarted;
  bool _nativeDeliveryRequested = false;

  bool get handlersInstalled => _handlersInstalled;
  int get pendingCount => _pending.length;
  bool get isLiveDebugSessionActive =>
      _isLiveDebugSessionActiveAt(_clock().toUtc());

  /// Read-only snapshot of the breadcrumb buffer, oldest first: the last
  /// [NoticebirdConfig.breadcrumbBuffer] breadcrumbs as they were
  /// recorded, each string value bounded at [maxBufferedTagValueLength]. For
  /// host-app diagnostics (an error details dialog, a user's feedback report)
  /// — never sent anywhere by reading it.
  ///
  /// A sent event does not empty it: the event carries the newest of the
  /// breadcrumbs no sent event carried yet ([NoticebirdConfig.maxBreadcrumbs]
  /// at most, shortened to the protocol's limits), and the next event starts
  /// after them. Only [clearBreadcrumbs] forgets the trail.
  List<TypedBreadcrumb> get recentBreadcrumbs =>
      List.unmodifiable(_breadcrumbs);

  /// The longest string value a buffered breadcrumb keeps. An event shortens
  /// it further, to the protocol's [maxTagValueLength].
  static const maxBufferedTagValueLength = 1000;

  void addBreadcrumb(TypedBreadcrumb breadcrumb) {
    try {
      // Bounded on the way in, so the buffer stays small whatever a host
      // records; shortened to the wire's limit only when an event is built
      // (`_eventBreadcrumbs`), so a host reading the trail keeps the whole
      // label.
      _breadcrumbs.add(
        breadcrumb.clamped(maxLength: maxBufferedTagValueLength),
      );
      _recorded++;
      while (_breadcrumbs.length > _config.breadcrumbBuffer) {
        _breadcrumbs.removeAt(0);
      }
      _updateNativeRun();
      // Streams the just-added breadcrumb out immediately instead of waiting
      // for the next real crash, so a support engineer watching a live
      // session sees it in near real time.
      if (_isLiveDebugSessionActiveAt(_clock().toUtc())) {
        _scheduleLiveBreadcrumbSync();
      }
    } catch (_) {
      // Reporting must never affect the host application.
    }
  }

  /// Clears the breadcrumb buffer without capturing an event, for cases such
  /// as logout, where the trail leading up to the next event should not
  /// include a previous user's session.
  void clearBreadcrumbs() {
    try {
      _breadcrumbs.clear();
      // Nothing recorded so far is left to send. Counted on rather than reset,
      // so an event in flight cannot mark later breadcrumbs as sent.
      _sentThrough = _recorded;
      _updateNativeRun();
    } catch (_) {
      // Reporting must never affect the host application.
    }
  }

  /// Sets the account identifier attached to subsequent events, or clears it
  /// when `null`. The id is sent as given, in the shape the protocol requires:
  /// characters outside `[A-Za-z0-9_-]` are stripped and the result is cut to
  /// 100 characters, so a malformed value can never poison every subsequent
  /// capture.
  ///
  /// Whether it is sent at all is the host's choice, made once in
  /// [NoticebirdConfig.pii] (`CrashPiiField.userId`); `regulatedStrict`
  /// never sends identity. E-mail, name and IP address go through [setUser],
  /// under the same choice — this method is for the id alone.
  void setUserId(String? userId) {
    try {
      if (userId == null) {
        _userId = null;
        _user = null;
        _feedbackSender?.identity = null;
        return;
      }
      // The id is sent as given: whether identity leaves the device is the
      // host's choice ([NoticebirdConfig.pii]), not something this method
      // second-guesses by content. It only enforces the shape the protocol
      // requires for an id. A UUID or a numeric id stays intact — the free-text
      // sanitizer used to turn every UUID into `REDACTED`.
      final sanitized = truncateCrashText(
        userId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), ''),
        CrashUser.maxIdLength,
      );
      _userId = sanitized.isEmpty ? null : sanitized;
      _user = _config.pii.filter(CrashUser(id: _userId));
      _feedbackSender?.identity = _userId;
    } catch (_) {
      // Reporting must never affect the host application.
    }
  }

  /// Sets user identity explicitly supplied by the host application.
  ///
  /// All fields are enabled by default. [NoticebirdConfig.pii] can still
  /// disable identity or restrict fields, while `regulatedStrict` never sends
  /// identity regardless of this setting.
  void setUser(CrashUser? user) {
    _feedbackSender?.identity = user == null || user.isEmpty
        ? null
        : jsonEncode([user.id, user.email, user.name]);
    try {
      _userId = null;
      _user = _config.pii.filter(user);
      _user?.check();
    } catch (_) {
      _user = null;
    }
  }

  /// What a feedback report is about, now: [routeTemplate] (a template
  /// such as `/lists/:listId`; by default the one of [setRouteTemplate]),
  /// what [FeedbackConfig.contextDiagnostics] answers, and when. Take it
  /// when the feedback sheet opens and pass it to [captureFeedback], so the
  /// report describes the screen the user was on, not the sheet.
  ///
  /// A raw route throws an [ArgumentError] in a debug build, as
  /// [setRouteTemplate] does, and is left out in a release build. Otherwise
  /// it never throws.
  FeedbackMoment feedbackMoment({String? routeTemplate}) {
    final DateTime takenAt;
    try {
      takenAt = _clock().toUtc();
    } catch (_) {
      return FeedbackMoment(takenAt: DateTime.now().toUtc());
    }
    String? route = _routeTemplate;
    if (routeTemplate != null) {
      route = _isRouteTemplate(routeTemplate)
          ? sanitizeRouteTemplate(routeTemplate)
          : hostMistakesThrow
          ? throw _rawRoute(routeTemplate)
          : null;
    }
    Map<String, Map<String, Object?>> context = const {};
    try {
      context = Map.unmodifiable(
        _config.feedback?.contextDiagnostics?.call() ?? const {},
      );
    } catch (_) {
      // A group that fails adds nothing; the report still goes.
    }
    return FeedbackMoment(
      takenAt: takenAt,
      routeTemplate: route,
      diagnostics: context,
    );
  }

  /// Sends a user's feedback report — a bug, an idea, anything else — with
  /// [message] in the user's words, and says what became of it. Its types
  /// come from `package:noticebird/feedback.dart`; without
  /// [NoticebirdConfig.feedback] it answers [FeedbackDisabled].
  ///
  /// [moment] is what the report is about ([feedbackMoment], taken when the
  /// sheet opened): its route template and its context diagnostics. Without
  /// one, it is taken now. The client fills in the rest as for an event:
  /// the app, the platform and its locale, the session, the user of
  /// [setUser] and the trail, the newest [FeedbackReport.maxTrailItems]
  /// breadcrumbs of the buffer, sanitized, the oldest left out first until
  /// the report fits [FeedbackReport.maxEncodedBytes]. Under
  /// [CrashPrivacyProfile.regulatedStrict] it sends no user, no
  /// [userContext] and no locale. A report is not an event: its trail does
  /// not count as sent.
  ///
  /// - [message] loses its U+0000 characters, is redacted as an event's
  ///   is, and cut to [FeedbackReport.maxMessageLength] characters.
  /// - [screenshot] is a picture's bytes, PNG, JPEG or WebP by their
  ///   signature, uploaded before the report is submitted. Bytes of another
  ///   type, or more than [FeedbackAttachmentRef.maxByteLength] of them, are
  ///   left out, and the report says so (`noticebird.screenshot_dropped`).
  /// - [contactEmail] is the reporter's consent to be contacted
  ///   ([FeedbackContact.isValid] checks it first).
  /// - [diagnostics] are content-free values, in named groups of named
  ///   values: a bool, a finite number, an enum (its name), a [DateTime], a
  ///   UUID or a token ([FeedbackDiagnostics.tokenPattern]). What the
  ///   report does not take — a key that is no key, free text, a group or
  ///   value past the limits — is left out, never the report: the report
  ///   counts it (`noticebird.dropped_values`), and a debug build prints it.
  ///   The group name `noticebird` is the client's.
  /// - [userContext] is what the host tells about its user on purpose
  ///   ([FeedbackUserContext.check] checks its shape); it is sent as given,
  ///   and the platform drops what it may not keep.
  /// - [relatedEventId] is the id of a crash event this report is about
  ///   ([eventIdOf]).
  ///
  /// A value the host passed that the report refuses — an empty message, a
  /// contact address, a user context, a related event id — throws an
  /// [ArgumentError] in a debug build and is
  /// [FeedbackRejection.invalidInput] in a release build; nothing is sent.
  /// What the client fills in itself never is: a locale or route template
  /// the report refuses is left out, and a session id or app or platform
  /// metadata it refuses is [FeedbackRejection.failed]. Otherwise it never
  /// throws.
  Future<FeedbackOutcome> captureFeedback({
    required FeedbackKind kind,
    required String message,
    FeedbackMoment? moment,
    FeedbackTrigger? trigger,
    Uint8List? screenshot,
    String? contactEmail,
    Map<String, Map<String, Object?>>? diagnostics,
    Map<String, Object?>? userContext,
    String? relatedEventId,
  }) async {
    final sender = _feedbackSender;
    if (sender == null) return const FeedbackDisabled();
    final about = moment ?? feedbackMoment();
    try {
      final strict =
          _config.privacyProfile == CrashPrivacyProfile.regulatedStrict;
      final draft = FeedbackDraft(
        reportId: _reportId(),
        createdAt: _clock().toUtc(),
        kind: kind,
        message: message,
        trigger: trigger,
        screenshot: screenshot,
        contactEmail: contactEmail,
        contextDiagnostics: about.diagnostics,
        diagnostics: diagnostics,
        momentTakenAt: moment?.takenAt,
        userContext: strict ? null : userContext,
        relatedEventId: relatedEventId?.toLowerCase(),
        app: _config.app,
        platform: _config.platform,
        locale: strict ? null : _locale(),
        sessionId: _config.sessionIdFactory(),
        routeTemplate: about.routeTemplate,
        user: strict ? null : _user,
        trail: [
          for (final breadcrumb in _breadcrumbs.skip(
            max(0, _breadcrumbs.length - FeedbackReport.maxTrailItems),
          ))
            _sanitized[breadcrumb] ??= sanitizeBreadcrumb(breadcrumb),
        ],
        dropped: (count) {
          if (count > 0) {
            _debugNote('$count feedback diagnostics values left out');
          }
        },
      );
      final report = draft.report(
        reporterAssertion: await sender.reporterAssertion(),
      );
      final result = await sender.send(
        FeedbackSendState(
          reportJson: report.toJsonString(),
          attachment: draft.attachment,
        ),
      );
      return switch (result) {
        FeedbackSendAccepted(:final answer) => FeedbackDelivered(
          ticket: answer.ticket,
          verified: answer.verified,
        ),
        FeedbackSendRejected(:final outcome) => outcome,
        FeedbackSendPostponed() =>
          await _feedbackQueue?.keep(result) ??
              const FeedbackRejected(FeedbackRejection.noStore),
      };
    } on FeedbackInputException catch (error) {
      if (hostMistakesThrow) throw ArgumentError(error.toString());
      return FeedbackRejected(FeedbackRejection.invalidInput, path: error.path);
    } catch (failure) {
      _debugNote('feedback not sent: $failure');
      return const FeedbackRejected(FeedbackRejection.failed);
    }
  }

  late final FeedbackSender? _feedbackSender = switch (_config.feedback) {
    final feedback? => FeedbackSender(feedback, clock: _clock),
    null => null,
  };

  late final FeedbackQueue? _feedbackQueue = switch ((
    _feedbackSender,
    _config.feedback?.offlineStore,
  )) {
    (final sender?, final store?) => FeedbackQueue(
      store,
      sender,
      clock: _clock,
      onSettled: _feedbackSettled,
    ),
    _ => null,
  };

  /// Tells [FeedbackConfig.onSettled] the end of a report kept in the
  /// store; without a callback, a debug build prints a rejected one.
  void _feedbackSettled(FeedbackSettled settled) {
    final onSettled = _config.feedback?.onSettled;
    if (onSettled == null) {
      if (settled.outcome is FeedbackRejected) {
        _debugNote('a kept feedback report ended unsent: $settled');
      }
      return;
    }
    try {
      onSettled(settled);
    } catch (_) {
      // Reporting must never affect the host application.
    }
  }

  /// How many feedback reports [FeedbackConfig.offlineStore] keeps; 0
  /// without a store, or when it fails. Never throws.
  Future<int> get pendingFeedbackCount async =>
      await _feedbackQueue?.count() ?? 0;

  /// The platform's locale as a language tag; the report leaves out one it
  /// refuses.
  static String? _locale() {
    try {
      return PlatformDispatcher.instance.locale.toLanguageTag();
    } catch (_) {
      return null;
    }
  }

  static final Random _secureRandom = Random.secure();

  /// A lowercase UUID v4 from a cryptographically secure source: the
  /// report's idempotency key, unique per project.
  static String _reportId() {
    final bytes = List.generate(16, (_) => _secureRandom.nextInt(256));
    bytes[6] = bytes[6] & 0x0f | 0x40;
    bytes[8] = bytes[8] & 0x3f | 0x80;
    final hex = [
      for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0'),
    ].join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  /// Starts a time-boxed live debug session: while active, the deduplication
  /// window is bypassed (every capture sends) and every [addBreadcrumb] call
  /// also streams immediately as a synthetic event, so a support engineer can
  /// watch breadcrumbs arrive without waiting for a real crash. Eligibility,
  /// tokens, and TTL policy are entirely the host app's concern — the client
  /// only tracks whether a session id is active until [expiresAt].
  void startLiveDebugSession({
    required String sessionId,
    required DateTime expiresAt,
  }) {
    try {
      _liveDebugSessionId = sessionId;
      _liveDebugSessionExpiresAt = expiresAt.toUtc();
    } catch (_) {
      // Reporting must never affect the host application.
    }
  }

  void stopLiveDebugSession() {
    _liveDebugSessionId = null;
    _liveDebugSessionExpiresAt = null;
    _liveDebugSyncPending = false;
  }

  bool _isLiveDebugSessionActiveAt(DateTime now) {
    final expiresAt = _liveDebugSessionExpiresAt;
    if (_liveDebugSessionId == null || expiresAt == null) return false;
    if (!now.isBefore(expiresAt)) {
      _liveDebugSessionId = null;
      _liveDebugSessionExpiresAt = null;
      return false;
    }
    return true;
  }

  /// Sets the route context attached to subsequent events.
  ///
  /// Only templates such as `/lists/:listId` are accepted. A raw route throws
  /// in debug builds to surface the integration mistake; release builds drop
  /// the value instead, because the reporter must never crash the host app.
  /// What a template still holds that the platform's privacy firewall rejects
  /// (an e-mail address, an IPv4 address) is redacted, so it never reaches an
  /// event or the native run state.
  void setRouteTemplate(String? routeTemplate) {
    if (routeTemplate != null && !_isRouteTemplate(routeTemplate)) {
      if (hostMistakesThrow) throw _rawRoute(routeTemplate);
      _routeTemplate = null;
      _updateNativeRun();
      return;
    }
    _routeTemplate = routeTemplate == null
        ? null
        : sanitizeRouteTemplate(routeTemplate);
    _updateNativeRun();
  }

  String? _routeTemplate;

  /// Whether [route] is a template such as `/lists/:listId`, not a raw
  /// route with an id in it.
  static bool _isRouteTemplate(String route) =>
      route.startsWith('/') &&
      route.length <= CrashEvent.maxRouteTemplateLength &&
      !RegExp(r'/[0-9a-fA-F-]{16,}').hasMatch(route) &&
      !RegExp(r'/\d{2,}').hasMatch(route);

  static ArgumentError _rawRoute(String route) => ArgumentError.value(
    route,
    'routeTemplate',
    'Use a template such as /lists/:listId, never a raw route',
  );

  /// Captures [error] and delivers it, queues it, or says why not.
  ///
  /// [filtered] (the default) asks [NoticebirdConfig.shouldCapture] first,
  /// as every channel does. `filtered: false` is for the host's own report
  /// point of the errors that filter declines — the one place such an error is
  /// meant to be captured.
  ///
  /// [groupingKey] is the host's own grouping of this error: the platform
  /// groups every event of this app with the same key into one issue,
  /// whatever its type or stack, and deduplicates by it here. Its parts are
  /// technical text like tag values, redacted and shortened the same way
  /// ([sanitizeGroupingKey]); without one, the event is grouped by its type
  /// and stack.
  ///
  /// The [CaptureResult] carries the event's id
  /// ([CaptureResult.eventId]), for a feedback report about this error.
  /// Never throws.
  Future<CaptureResult> captureException(
    Object error,
    StackTrace stackTrace, {
    CrashSeverity severity = CrashSeverity.error,
    bool handled = false,
    Map<AllowedTag, TagScalar> tags = const {},
    Map<String, Object?> extra = const {},
    List<String>? groupingKey,
    bool filtered = true,
  }) async {
    if (filtered && !_accepts(error)) {
      return const CaptureResult(CaptureOutcome.ignored);
    }
    String? key;
    String? builtId;
    try {
      // The breadcrumbs recorded up to here are the ones this event carries.
      final carriedThrough = _recorded;
      final event = _buildEvent(
        error,
        stackTrace,
        severity: severity,
        handled: handled,
        tags: tags,
        extra: extra,
        groupingKey: groupingKey,
      );
      // Written, and so checked, at capture time: an invalid event (a
      // session id the protocol refuses) is dropped instead of poisoning the
      // queue.
      final written = _write(event);
      builtId = event.eventId;
      final now = _clock().toUtc();
      if (!_isLiveDebugSessionActiveAt(now)) {
        key = deduplicationKey(event);
        _lastByKey.removeWhere(
          (_, seen) =>
              now.difference(seen.seenAt) >= _config.deduplicationWindow,
        );
        final seen = _lastByKey[key];
        if (seen != null) {
          return CaptureResult(
            CaptureOutcome.deduplicated,
            eventId: seen.eventId,
          );
        }
        _lastByKey[key] = (seenAt: now, eventId: event.eventId);
        while (_lastByKey.length > _config.maxDeduplicationEntries) {
          _lastByKey.remove(_lastByKey.keys.first);
        }
      }
      try {
        await _transport.send(written.json);
        // A live sync repeats the trail on purpose; a real event marks what
        // it carried as sent, so the next one starts after it.
        if (event.exception.type != 'LiveBreadcrumbSync' &&
            carriedThrough > _sentThrough) {
          _sentThrough = carriedThrough;
          _updateNativeRun();
        }
        return CaptureResult(CaptureOutcome.sent, eventId: event.eventId);
      } catch (failure) {
        final result = _refusedForGood(failure)
            ? const CaptureResult(CaptureOutcome.dropped)
            : await _enqueue(written);
        if (result.eventId == null) _forgetEventId(key, event.eventId);
        return result;
      }
    } catch (failure) {
      _debugNote('event dropped: $failure');
      _forgetEventId(key, builtId);
      return const CaptureResult(CaptureOutcome.dropped);
    }
  }

  /// A dropped event still suppresses its repeats within the window, but
  /// went nowhere: a [CaptureOutcome.deduplicated] result against it carries
  /// no id.
  void _forgetEventId(String? key, String? eventId) {
    if (key == null || eventId == null) return;
    final seen = _lastByKey[key];
    if (seen == null || seen.eventId != eventId) return;
    _lastByKey[key] = (seenAt: seen.seenAt, eventId: null);
  }

  /// Whether [failure], what [CrashTransport.send] threw, refuses the
  /// event for good, so it is dropped rather than kept.
  static bool _refusedForGood(Object failure) =>
      failure is CrashTransportException && failure.refusedForGood;

  bool _accepts(Object error) {
    final filter = _config.shouldCapture;
    if (filter == null) return true;
    try {
      return filter(error);
    } catch (_) {
      // A failing filter must never cost a report.
      return true;
    }
  }

  /// Sends what waits: the queued events, those of
  /// [NoticebirdConfig.offlineStore] included, until the first that fails
  /// (one the platform refuses for good is removed, and the next sent), and
  /// then the feedback reports of [FeedbackConfig.offlineStore] that
  /// are due, the oldest first, each settled ([FeedbackConfig.onSettled]) or
  /// kept for its next attempt, until the first that does not get through.
  /// [run] calls it once at start. A call while one runs skips what that
  /// one is sending still, the events or the feedback, so a slow feedback
  /// report never holds up the events. Never throws.
  Future<void> flush() async {
    if (!_flushingEvents) {
      _flushingEvents = true;
      try {
        await _flushEvents();
      } finally {
        _flushingEvents = false;
      }
    }
    await _feedbackQueue?.drain();
  }

  Future<void> _flushEvents() async {
    try {
      final stored = await _config.offlineStore?.readAndClear() ?? const [];
      final knownEventIds = {for (final event in _pending) event.eventId};
      for (final source in stored) {
        try {
          final event = _WrittenEvent.of(source);
          // The store persists a snapshot of the in-memory queue, so entries
          // may still be pending; merging them twice would duplicate sends.
          if (knownEventIds.add(event.eventId)) _pending.add(event);
        } catch (_) {
          // An entry without an event id is discarded without exposing its
          // contents.
        }
      }
      while (_pending.length > _config.maxPendingEvents) {
        _pending.removeAt(0);
      }
      // The store was cleared: it holds them again before any is sent, so a
      // process that dies meanwhile loses none.
      try {
        await _persistPending();
      } catch (_) {
        // A store that fails to write does not hold up the send.
      }
      while (_pending.isNotEmpty) {
        // The head itself is removed after its send, not whatever is first
        // by then: a capture during the send may have evicted it.
        final head = _pending.first;
        try {
          await _transport.send(head.json);
        } catch (failure) {
          if (!_refusedForGood(failure)) break;
        }
        _pending.remove(head);
      }
      await _persistPending();
    } catch (_) {
      // Reporting must never affect the host application.
    }
  }

  void installGlobalHandlers() {
    if (_handlersInstalled) return;
    _handlersInstalled = true;
    _previousFlutterHandler = FlutterError.onError;
    _previousPlatformHandler = PlatformDispatcher.instance.onError;
    FlutterError.onError = (details) {
      unawaited(
        captureException(details.exception, details.stack ?? StackTrace.empty),
      );
      _previousFlutterHandler?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      unawaited(captureException(error, stack, severity: CrashSeverity.fatal));
      // Chain to any previous handler; when none exists, report the error as
      // handled so an uncaught platform error cannot take down the host app.
      return _previousPlatformHandler?.call(error, stack) ?? true;
    };
  }

  void uninstallGlobalHandlers() {
    if (!_handlersInstalled) return;
    FlutterError.onError = _previousFlutterHandler;
    PlatformDispatcher.instance.onError = _previousPlatformHandler;
    _handlersInstalled = false;
  }

  /// Installs the global handlers, starts delivering native crash reports
  /// ([reportNativeCrashes] — `run` wraps `runApp`, so this is the engine
  /// that shows the UI) and what earlier runs left queued ([flush]), and
  /// runs [body] in a guarded zone.
  Future<void> run(FutureOr<void> Function() body) async {
    installGlobalHandlers();
    unawaited(reportNativeCrashes());
    unawaited(flush());
    await runZonedGuarded(() async => body(), (error, stack) {
      unawaited(captureException(error, stack, severity: CrashSeverity.fatal));
    });
  }

  /// Delivers the native crash reports of earlier runs: those waiting now,
  /// and for the rest of this run every report that arrives later.
  ///
  /// Call it from the engine that shows the UI — `run` does. A host that owns
  /// its bootstrap calls it from its UI start only, never from a headless
  /// background engine, which may have seconds to live. A no-op without
  /// [NoticebirdConfig.nativeCrashes], and after the first call.
  ///
  /// Returns the result of each report of the first batch once it is
  /// settled, its [CaptureResult.eventId] as for [captureException]: `sent`,
  /// `queued` (retried by [flush]; the report stays claimed
  /// under a lease), `ignored` by [NoticebirdConfig.shouldCapture] (asked
  /// with the [NativeCrashRecord]), or `dropped` (no known build, a record
  /// the protocol rejects, or an event the platform refused for good). A
  /// native report is never deduplicated within the
  /// window — three crashes are three occurrences — and sending
  /// one leaves the live breadcrumb trail alone. Never throws, and gives up
  /// waiting for a collector that does not answer.
  Future<List<CaptureResult>> reportNativeCrashes() async {
    final collector = _config.nativeCrashes;
    if (collector == null || _nativeDeliveryRequested) return const [];
    _nativeDeliveryRequested = true;
    final firstBatch = Completer<List<CaptureResult>>();
    try {
      await _nativeStarted;
      final subscription = collector
          .claimed(max: maxNativeCrashesPerBatch)
          .listen(null, cancelOnError: false);
      subscription
        ..onData((batch) {
          subscription.pause();
          _deliverNativeBatch(collector, batch)
              .then((outcomes) {
                if (!firstBatch.isCompleted) firstBatch.complete(outcomes);
              })
              .whenComplete(subscription.resume);
        })
        ..onError((Object _) {
          if (!firstBatch.isCompleted) firstBatch.complete(const []);
        })
        ..onDone(() {
          if (!firstBatch.isCompleted) firstBatch.complete(const []);
        });
      return await firstBatch.future.timeout(
        _nativeFirstBatchTimeout,
        onTimeout: () => const [],
      );
    } catch (_) {
      // Reporting must never affect the host application.
      return const [];
    }
  }

  Future<void> _startNative(NativeCrashCollector collector) async {
    try {
      await collector
          .start(
            NativeRunInfo(
              sessionId: _config.sessionIdFactory(),
              app: _config.app,
              platform: _config.platform,
              privacyProfile: _config.privacyProfile,
            ),
          )
          .timeout(_nativeStartTimeout);
      _updateNativeRun();
    } catch (_) {
      // Reporting must never affect the host application.
    }
  }

  /// Hands the collector the context a native crash of this run would carry;
  /// it persists a debounced snapshot. No trail under `regulatedStrict`.
  void _updateNativeRun() {
    final collector = _config.nativeCrashes;
    if (collector == null) return;
    try {
      collector.update(
        NativeRunState(
          routeTemplate: _routeTemplate,
          breadcrumbs:
              _config.privacyProfile == CrashPrivacyProfile.regulatedStrict
              ? const []
              : _eventBreadcrumbs(),
        ),
      );
    } catch (_) {
      // Reporting must never affect the host application.
    }
  }

  Future<List<CaptureResult>> _deliverNativeBatch(
    NativeCrashCollector collector,
    NativeCrashBatch batch,
  ) async {
    final results = <CaptureResult>[];
    try {
      for (final record in batch.records.take(maxNativeCrashesPerBatch)) {
        final result = await _deliverNativeRecord(record, batch.runs);
        results.add(result);
        try {
          await collector
              .settle(
                record.recordId,
                delivered: result.outcome != CaptureOutcome.queued,
              )
              .timeout(_nativeSettleTimeout);
        } catch (_) {
          // An unsettled claim expires with its lease; the resend is a
          // replay on the platform.
        }
      }
    } catch (_) {
      // Reporting must never affect the host application.
    }
    return results;
  }

  Future<CaptureResult> _deliverNativeRecord(
    NativeCrashRecord record,
    List<NativeRecordedRun> runs,
  ) async {
    if (!_accepts(record)) return const CaptureResult(CaptureOutcome.ignored);
    try {
      final event = buildNativeCrashEvent(
        record,
        runs,
        privacyProfile: _config.privacyProfile,
      );
      if (event == null) return const CaptureResult(CaptureOutcome.dropped);
      // Checked here, once: a record that breaks the protocol throws, and is
      // dropped below.
      final written = _write(event);
      try {
        await _transport.send(written.json);
        return CaptureResult(CaptureOutcome.sent, eventId: event.eventId);
      } catch (failure) {
        return _refusedForGood(failure)
            ? const CaptureResult(CaptureOutcome.dropped)
            : await _enqueue(written);
      }
    } catch (failure) {
      _debugNote('native report dropped: $failure');
      return const CaptureResult(CaptureOutcome.dropped);
    }
  }

  CrashEvent _buildEvent(
    Object error,
    StackTrace stackTrace, {
    required CrashSeverity severity,
    required bool handled,
    required Map<AllowedTag, TagScalar> tags,
    required Map<String, Object?> extra,
    List<String>? groupingKey,
  }) {
    final strict =
        _config.privacyProfile == CrashPrivacyProfile.regulatedStrict;
    // _LiveBreadcrumbSync gets a fixed type string instead of
    // runtimeType.toString(), so it stays stable across obfuscated/minified
    // builds instead of drifting with the compiler's renaming; a Dart core
    // error is named by its core type in a minified build too.
    final type = switch (error) {
      _LiveBreadcrumbSync() => 'LiveBreadcrumbSync',
      _ => crashExceptionType(error, error.runtimeType.toString()),
    };
    final message = strict
        ? type
        : sanitizeCrashText(
            error.toString(),
            maxLength: CrashException.maxMessageLength,
          );
    final safeStack = truncateCrashText(
      _sanitizeStack(stackTrace.toString()),
      CrashException.maxStackTraceLength,
    );
    // Redacted and shortened rather than rejected, as breadcrumbs are: an
    // over-long tag value would fail validation when the event is written,
    // and an id or an address in one would have the platform reject the
    // whole event.
    final safeTags = Map<AllowedTag, TagScalar>.unmodifiable({
      for (final entry in tags.entries)
        entry.key: sanitizeTagValue(entry.value),
    });
    final safeExtra = strict
        ? const <String, Object?>{}
        : _sanitizeExtra(extra);
    return CrashEvent(
      eventId: _eventIdFactory(),
      occurredAt: _clock().toUtc(),
      severity: severity,
      handled: handled,
      exception: CrashException(
        type: type,
        sanitizedMessage: message.isEmpty ? '<no-message>' : message,
        stackTrace: safeStack.isEmpty ? '<no-app-frames>' : safeStack,
      ),
      app: _config.app,
      platform: _config.platform,
      routeTemplate: _routeTemplate,
      sessionId: _config.sessionIdFactory(),
      user: strict ? null : _user,
      tags: safeTags,
      extra: safeExtra,
      breadcrumbs: _eventBreadcrumbs(),
      groupingKey: groupingKey == null
          ? null
          : sanitizeGroupingKey(groupingKey),
    );
  }

  /// [event] as the transport sends it and the store keeps it; throws a
  /// [ProtocolException] for an event the protocol refuses.
  static _WrittenEvent _write(CrashEvent event) =>
      _WrittenEvent(event.eventId, event.toCanonicalJson());

  /// The breadcrumbs the next event carries: the newest of those no sent
  /// event carried yet, [NoticebirdConfig.maxBreadcrumbs] at most, each
  /// redacted and shortened to the protocol's limits ([sanitizeBreadcrumb]).
  /// The buffer keeps them as recorded, for [recentBreadcrumbs].
  List<TypedBreadcrumb> _eventBreadcrumbs() {
    final unsent = min(_recorded - _sentThrough, _breadcrumbs.length);
    final count = min(unsent, _config.maxBreadcrumbs);
    return List.unmodifiable([
      for (final breadcrumb in _breadcrumbs.skip(_breadcrumbs.length - count))
        _sanitized[breadcrumb] ??= sanitizeBreadcrumb(breadcrumb),
    ]);
  }

  /// Each buffered breadcrumb's [sanitizeBreadcrumb], made once: the native
  /// run state takes the event's breadcrumbs on every [addBreadcrumb].
  final _sanitized = Expando<TypedBreadcrumb>();

  Future<CaptureResult> _enqueue(_WrittenEvent event) async {
    if (_config.maxPendingEvents == 0) {
      return const CaptureResult(CaptureOutcome.dropped);
    }
    _pending.add(event);
    while (_pending.length > _config.maxPendingEvents) {
      _pending.removeAt(0);
    }
    await _persistPending();
    return CaptureResult(CaptureOutcome.queued, eventId: event.eventId);
  }

  void _scheduleLiveBreadcrumbSync() {
    if (_liveDebugSyncInFlight) {
      _liveDebugSyncPending = true;
      return;
    }
    _liveDebugSyncInFlight = true;
    unawaited(_drainLiveBreadcrumbSync());
  }

  Future<void> _drainLiveBreadcrumbSync() async {
    try {
      do {
        _liveDebugSyncPending = false;
        await captureException(
          const _LiveBreadcrumbSync(),
          StackTrace.empty,
          severity: CrashSeverity.debug,
          handled: true,
          filtered: false,
        );
      } while (_liveDebugSyncPending &&
          _isLiveDebugSessionActiveAt(_clock().toUtc()));
    } catch (_) {
      // Reporting must never affect the host application.
    } finally {
      _liveDebugSyncInFlight = false;
    }
  }

  Future<void> _persistPending() async {
    final store = _config.offlineStore;
    if (store == null) return;
    await store.write([for (final event in _pending) event.json]);
  }

  static final Object _dropExtraValue = Object();

  static Map<String, Object?> _sanitizeExtra(Map<String, Object?> source) {
    final result = <String, Object?>{};
    for (final entry in source.entries.take(CrashEvent.maxExtraEntries)) {
      if (_isForbiddenExtraKey(entry.key) || !_isSafeExtraKey(entry.key)) {
        continue;
      }
      final value = _sanitizeExtraValue(entry.value, depth: 0);
      if (!identical(value, _dropExtraValue)) result[entry.key] = value;
    }
    return Map.unmodifiable(result);
  }

  static Object? _sanitizeExtraValue(Object? value, {required int depth}) {
    if (value is String) {
      return sanitizeCrashText(
        value,
        maxLength: CrashEvent.maxExtraStringLength,
      );
    }
    if (value == null || value is bool) return value;
    if (value is num) return value.isFinite ? value : _dropExtraValue;
    if (value is List) {
      if (depth >= CrashEvent.maxExtraDepth) return _dropExtraValue;
      final result = <Object?>[];
      for (final item in value.take(CrashEvent.maxExtraEntries)) {
        final sanitized = _sanitizeExtraValue(item, depth: depth + 1);
        if (!identical(sanitized, _dropExtraValue)) result.add(sanitized);
      }
      return List.unmodifiable(result);
    }
    if (value is Map) {
      if (depth >= CrashEvent.maxExtraDepth) return _dropExtraValue;
      final result = <String, Object?>{};
      for (final entry in value.entries.take(CrashEvent.maxExtraEntries)) {
        final key = entry.key.toString();
        if (_isForbiddenExtraKey(key) || !_isSafeExtraKey(key)) continue;
        final sanitized = _sanitizeExtraValue(entry.value, depth: depth + 1);
        if (!identical(sanitized, _dropExtraValue)) result[key] = sanitized;
      }
      return Map.unmodifiable(result);
    }
    return _dropExtraValue;
  }

  static bool _isSafeExtraKey(String key) =>
      CrashEvent.extraKeyPattern.hasMatch(key);

  /// Whether [key] goes from `extra`: a key the firewall rejects an event
  /// over ([PrivacyPatterns.extraKeyViolation]), or one that names a patient
  /// or a health-data source, which the client drops on top of those.
  static bool _isForbiddenExtraKey(String key) =>
      PrivacyPatterns.extraKeyViolation(key) != null ||
      const [
        'fitbit',
        'google',
        'patient',
      ].any(key.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '').contains);

  /// Keeps the app's frames, at most 50, each in the VM shape
  /// `#<i> <function> (<location>)` ([_renderFrame]):
  ///
  /// - VM frames of a package (`#0 method (package:app/file.dart:1:2)`), with
  ///   their own number;
  /// - the friendly frames `package:stack_trace` writes on the web
  ///   (`package:app/file.dart 1:2  method`);
  /// - the JavaScript frames of a dart2js build: V8's
  ///   (`at cOy.$0 (https://host/main.dart.js:375562:14)`, also anonymous,
  ///   `async` and `new`) and Firefox's and Safari's
  ///   (`cOy.$0@https://host/main.dart.js:375562:14`), in a script dart2js
  ///   wrote — `<name>.dart.js` or a deferred part,
  ///   `<name>.dart.js_<n>.part.js` — with the script's file name alone, so
  ///   no host or path leaves the device: `#0 cOy.$0 (main.dart.js:375562:14)`.
  ///   Line and column stay: with the build's source map they lead back to
  ///   the Dart source.
  ///
  /// Any other frame — the SDK's, the engine's, another script's — is left
  /// out; a trace with none of these is sent as `<no-app-frames>`.
  static String _sanitizeStack(String source) {
    final frames = <String>[];
    for (final line in source.split('\n')) {
      final frame = _parseFrame(line.trim(), '${frames.length}');
      if (frame == null) continue;
      if (_renderFrame(frame) case final rendered?) frames.add(rendered);
      if (frames.length == 50) break;
    }
    return frames.join('\n');
  }

  /// [line] as an app frame, numbered [next] unless it carries its own
  /// number (a VM frame), or null when it is none of the shapes
  /// [_sanitizeStack] keeps.
  ///
  /// A JavaScript function's name is kept only when it is a JavaScript name
  /// — identifiers and `<anonymous>` joined by dots — and is null otherwise.
  static _Frame? _parseFrame(String line, String next) {
    if (_vmFrame.firstMatch(line) case final vm?) {
      return (
        index: vm.group(1)!,
        function: vm.group(2),
        location: vm.group(3)!,
      );
    }
    if (_friendlyFrame.firstMatch(line) case final friendly?) {
      final column = friendly.group(3);
      return (
        index: next,
        function: friendly.group(4),
        location:
            'package:${friendly.group(1)}:${friendly.group(2)}'
            '${column == null ? '' : ':$column'}',
      );
    }
    final js = _jsFrames
        .map((pattern) => pattern.firstMatch(line))
        .nonNulls
        .firstOrNull;
    if (js == null) return null;
    final script = js.group(2)!.replaceFirst(_urlQuery, '').split('/').last;
    if (!_dart2jsScript.hasMatch(script)) return null;
    final function = js.group(1)!;
    return (
      index: next,
      function: _jsFunction.hasMatch(function) ? function : null,
      location: '$script:${js.group(3)}:${js.group(4)}',
    );
  }

  /// [frame] in the VM shape, or null when it cannot be sent.
  ///
  /// The function's name is respelled as a native frame symbol is
  /// ([respellSymbol]), so it keeps its words: `AuthHeader.bearer`, which
  /// would take the location after it as its token, is sent as
  /// `AuthHeader.bearer_`. A frame without a name is written `<anonymous>`.
  /// A frame the redaction patterns still match (a name holding an e-mail
  /// address, a script or file named like a phone number) is left out, as the
  /// platform's privacy firewall would reject the whole event over it.
  static String? _renderFrame(_Frame frame) {
    final function = switch (frame.function) {
      final name? => respellSymbol(name),
      null => '<anonymous>',
    };
    final rendered = '#${frame.index} $function (${frame.location})';
    return redactCrashText(rendered) == rendered ? rendered : null;
  }

  static final _vmFrame = RegExp(
    r'^#([0-9]+)\s+([^\s(]+)\s+\((package:[A-Za-z0-9_./-]+:\d+(?::\d+)?)\)',
  );
  static final _friendlyFrame = RegExp(
    r'^(?:package:|packages/)([A-Za-z0-9_./-]+\.dart)\s+(\d+)(?::(\d+))?\s+([A-Za-z0-9_.<>$]+)$',
  );

  /// The JavaScript frame shapes, each with the function (empty when there
  /// is none), the script's URL, the line and the column as groups 1 to 4:
  /// V8's named frame, V8's anonymous frame, and Firefox's and Safari's.
  static final _jsFrames = [
    RegExp(r'^at (?:(?:async|new) )?(.+) \((\S+):(\d+):(\d+)\)$'),
    RegExp(r'^at (?:async )?()(\S+):(\d+):(\d+)$'),
    RegExp(r'^(?:async\*)?([^@]*)@(\S+):(\d+):(\d+)$'),
  ];
  static final _urlQuery = RegExp(r'[?#].*$');
  static final _dart2jsScript = RegExp(
    r'^[A-Za-z0-9_-]+\.dart\.js(?:_\d+\.part\.js)?$',
  );
  static final _jsFunction = RegExp(
    r'^(?:[A-Za-z_$][\w$]*|<anonymous>)(?:\.(?:[A-Za-z_$][\w$]*|<anonymous>))*$',
  );

  static final Random _random = Random();

  /// Time-prefixed identifier with 64 bits of randomness, matching the
  /// protocol's event id pattern. Prefer supplying a UUIDv7 `eventIdFactory`.
  static String _fallbackEventId() {
    final micros = DateTime.now().microsecondsSinceEpoch
        .toRadixString(16)
        .padLeft(16, '0');
    final suffix = List.generate(
      16,
      (_) => _random.nextInt(16).toRadixString(16),
    ).join();
    final hex = '${micros.substring(micros.length - 16)}$suffix';
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }
}

/// Prints [note] in a debug build, where someone looks; nothing in a
/// release build.
void _debugNote(String note) {
  assert(() {
    debugPrint('noticebird: $note');
    return true;
  }());
}

/// An event as [NoticebirdClient] wrote it: its id, and its canonical JSON,
/// the text the transport sends and the offline store keeps. The client
/// reads nothing else back: the event was checked when it was written, and
/// the platform checks it again.
final class _WrittenEvent {
  const _WrittenEvent(this.eventId, this.json);

  /// The event of [json] as the offline store kept it; throws a
  /// [FormatException] for a text without an event id.
  factory _WrittenEvent.of(String json) {
    if (jsonDecode(json) case {
      'eventId': final String eventId,
    } when CrashEvent.eventIdPattern.hasMatch(eventId)) {
      return _WrittenEvent(eventId, json);
    }
    throw const FormatException('Not a crash event');
  }

  final String eventId;
  final String json;
}

/// A stack frame [NoticebirdClient] keeps: its number, its function (null
/// when it has no name it may keep) and its location, the parts of
/// `#<index> <function> (<location>)`.
typedef _Frame = ({String index, String? function, String location});

/// Marker error for the synthetic event fired by [NoticebirdClient.addBreadcrumb]
/// during an active live debug session. Never constructed by consumers.
final class _LiveBreadcrumbSync implements Exception {
  const _LiveBreadcrumbSync();

  @override
  String toString() => 'Live breadcrumb sync';
}
