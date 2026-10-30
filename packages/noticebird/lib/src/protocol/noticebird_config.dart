import 'dart:math';

import 'package:noticebird_protocol/noticebird_protocol.dart';

import '../feedback/feedback_config.dart';
import 'host_platform.dart';
import 'native_crash_collector.dart';

enum CrashPrivacyProfile { regulatedStrict, privacyDefault, custom }

final class CrashPiiConfig {
  const CrashPiiConfig({
    this.enabled = true,
    this.allowedFields = const {
      CrashPiiField.userId,
      CrashPiiField.email,
      CrashPiiField.name,
      CrashPiiField.ipAddress,
    },
  });

  final bool enabled;
  final Set<CrashPiiField> allowedFields;

  CrashUser? filter(CrashUser? user) {
    if (!enabled || user == null) return null;
    final filtered = CrashUser(
      id: allowedFields.contains(CrashPiiField.userId) ? user.id : null,
      email: allowedFields.contains(CrashPiiField.email) ? user.email : null,
      name: allowedFields.contains(CrashPiiField.name) ? user.name : null,
      ipAddress: allowedFields.contains(CrashPiiField.ipAddress)
          ? user.ipAddress
          : null,
    );
    return filtered.isEmpty ? null : filtered;
  }
}

/// Where the client keeps the crash events it could not send yet, so a
/// later run sends them: `FileCrashOfflineStore` on a device with a file
/// system. Under `regulatedStrict` it must be [isEncrypted].
///
/// The client calls one method at a time. After each [read] it writes the
/// queue back at once, so a store that keeps what it read until the next
/// [write] loses nothing when the process ends in between; an event read
/// twice is merged by its id.
abstract interface class CrashOfflineStore {
  bool get isEncrypted;

  /// Replaces what the store holds with [canonicalEnvelopes], each an event
  /// as the transport sends it; an empty list leaves it empty.
  Future<void> write(List<String> canonicalEnvelopes);

  /// What the last [write] left, in its order; empty when nothing was
  /// written.
  Future<List<String>> read();
}

final class NoticebirdConfig {
  NoticebirdConfig({
    required this.privacyProfile,
    required this.app,
    PlatformMetadata? platform,
    String Function()? sessionIdFactory,
    this.maxPendingEvents = 50,
    this.maxBreadcrumbs = CrashEvent.maxBreadcrumbs,
    int? breadcrumbBuffer,
    this.maxDeduplicationEntries = 100,
    this.deduplicationWindow = const Duration(minutes: 1),
    this.offlineStore,
    this.pii = const CrashPiiConfig(),
    this.shouldCapture,
    this.nativeCrashes,
    this.feedback,
  }) : platform =
           platform ?? hostPlatformMetadata(privacyProfile: privacyProfile),
       sessionIdFactory = sessionIdFactory ?? _processSessionIdFactory,
       breadcrumbBuffer = breadcrumbBuffer ?? maxBreadcrumbs {
    if (maxPendingEvents < 0 || maxPendingEvents > 200) {
      throw ArgumentError.value(maxPendingEvents, 'maxPendingEvents');
    }
    if (maxBreadcrumbs < 0 || maxBreadcrumbs > CrashEvent.maxBreadcrumbs) {
      throw ArgumentError.value(maxBreadcrumbs, 'maxBreadcrumbs');
    }
    if (this.breadcrumbBuffer < maxBreadcrumbs ||
        this.breadcrumbBuffer > maxBreadcrumbBuffer) {
      throw ArgumentError.value(this.breadcrumbBuffer, 'breadcrumbBuffer');
    }
    if (maxDeduplicationEntries < 1 || maxDeduplicationEntries > 1000) {
      throw ArgumentError.value(
        maxDeduplicationEntries,
        'maxDeduplicationEntries',
      );
    }
    if (deduplicationWindow.isNegative) {
      throw ArgumentError.value(deduplicationWindow, 'deduplicationWindow');
    }
    // Fail fast at configuration time instead of silently dropping every
    // event at capture time. The session id is produced per event and is
    // validated when the event is built.
    try {
      app.check();
      this.platform.check();
    } on ProtocolException catch (error) {
      throw ArgumentError('Invalid app or platform metadata: $error');
    }
    if (privacyProfile == CrashPrivacyProfile.regulatedStrict &&
        offlineStore != null &&
        !offlineStore!.isEncrypted) {
      throw ArgumentError(
        'regulatedStrict requires an encrypted offline store',
        'offlineStore',
      );
    }
    if (privacyProfile == CrashPrivacyProfile.regulatedStrict &&
        feedback?.offlineStore?.isEncrypted == false) {
      throw ArgumentError(
        'regulatedStrict requires an encrypted feedback offline store',
        'feedback',
      );
    }
    if (pii.enabled && pii.allowedFields.isEmpty) {
      throw ArgumentError(
        'Enabled PII requires at least one allowed field',
        'pii',
      );
    }
  }

  final CrashPrivacyProfile privacyProfile;
  final AppMetadata app;

  /// The platform every event names. Defaults to [hostPlatformMetadata] of
  /// the running platform, under this config's [privacyProfile].
  final PlatformMetadata platform;

  /// The session id of each event. Defaults to [processSessionId]: one id for
  /// the whole app run.
  final String Function() sessionIdFactory;
  final int maxPendingEvents;

  /// How many breadcrumbs one event carries at most: the newest of those no
  /// sent event carried yet. At most [CrashEvent.maxBreadcrumbs], the protocol's
  /// limit per event.
  final int maxBreadcrumbs;

  /// How many breadcrumbs the client keeps in memory, for
  /// [NoticebirdClient.recentBreadcrumbs]: the trail a host shows or sends
  /// on its own, such as with a user's feedback report. At least
  /// [maxBreadcrumbs] (the default) and at most [maxBreadcrumbBuffer].
  ///
  /// A larger buffer changes nothing on the wire: an event still carries at
  /// most [maxBreadcrumbs] of them, each shortened to the protocol's limits.
  final int breadcrumbBuffer;
  final int maxDeduplicationEntries;
  final Duration deduplicationWindow;
  final CrashOfflineStore? offlineStore;
  final CrashPiiConfig pii;

  /// Whether an error is captured, asked once per capture on every channel:
  /// an explicit `captureException`, `ProtocolNoticebirdBlocObserver`, the
  /// handlers `installGlobalHandlers` installs and the zone of `run`. `false`
  /// drops it as [CaptureOutcome.ignored].
  ///
  /// It is how a host keeps errors it reports at a report point of its own
  /// from being reported again by whichever channel sees them next: set it
  /// once, here, and every channel — including one added later — honours it.
  /// The report point itself bypasses it with `captureException(...,
  /// filtered: false)`. A filter that throws counts as `true`, so a failing
  /// filter never costs a report.
  ///
  /// `null` (the default) captures everything.
  final bool Function(Object error)? shouldCapture;

  /// Collects the crash reports the operating system keeps about earlier
  /// runs — native crashes, watchdog and ANR kills, foreground low-memory
  /// kills — so they reach the platform as events. `NativeCrashCapture()`
  /// from the `noticebird_native` package; `null` (the default) is off.
  ///
  /// Share one config between every engine: each records its run, and only
  /// the engine that calls [NoticebirdClient.reportNativeCrashes] (which
  /// `run` does) delivers. [shouldCapture] is asked with the
  /// [NativeCrashRecord] of each report.
  final NativeCrashCollector? nativeCrashes;

  /// How user feedback is delivered, from `package:noticebird/feedback.dart`;
  /// `null` (the default) is off, and `NoticebirdClient.captureFeedback`
  /// answers `FeedbackDisabled`.
  final FeedbackConfig? feedback;

  /// The largest [breadcrumbBuffer].
  static const maxBreadcrumbBuffer = 200;

  /// A session id for this process: generated once, the same for every event
  /// of the app run, and valid under the protocol's session id pattern. The
  /// default [sessionIdFactory]; a host that correlates something of its own
  /// with the run (a feedback report) reads it here.
  static String get processSessionId => _processSessionId;

  static String _processSessionIdFactory() => _processSessionId;
}

final String _processSessionId = _buildProcessSessionId();

String _buildProcessSessionId() {
  final micros = DateTime.now().microsecondsSinceEpoch
      .toRadixString(16)
      .padLeft(16, '0');
  final random = Random();
  final suffix = List.generate(
    16,
    (_) => random.nextInt(16).toRadixString(16),
  ).join();
  return 'run_$micros$suffix';
}

/// Delivers the events a [NoticebirdClient] captures.
abstract interface class CrashTransport {
  /// Sends one event as the client wrote it: its canonical JSON
  /// (`CrashEvent.toCanonicalJson`), checked by the protocol when it was
  /// built, the body of `POST /v1/envelope`. An event a flush sends again is
  /// the same text, read back from [CrashOfflineStore]. Post it unchanged as
  /// the body; never decode and re-encode it.
  ///
  /// Throws when it was not delivered, so the client keeps the event for a
  /// later flush. A `CrashTransportException` with `refusedForGood` is a
  /// refusal for good: the client drops that event, at the capture and at a
  /// flush, which goes on with the next. The envelope route's final answers
  /// are `413` with the `error` `payload_too_large` and `422` with
  /// `privacy_rejected`; any other answer, a gateway's page without that
  /// `error` included, is not final.
  Future<void> send(String eventJson);
}

/// Accepts every event and sends it nowhere.
///
/// For a build that uploads nothing but still wants the client: it owns the
/// breadcrumb trail, the user and the route, which a feedback report or an
/// error details view reads whether or not crashes leave the device. It succeeds
/// rather than throwing, because a failing transport makes the client queue
/// each event for a flush that never comes.
final class DiscardingCrashTransport implements CrashTransport {
  const DiscardingCrashTransport();

  @override
  Future<void> send(String eventJson) async {}
}
