import 'dart:convert';

import 'package:noticebird_protocol/noticebird_protocol.dart';

import '../protocol/noticebird_client.dart';
import '../protocol/noticebird_config.dart';
import '../protocol/noticebird_facade.dart';

/// A [CrashTransport] that keeps each event instead of sending it: what a
/// client would post, with no network. The event reaches it while
/// `captureException` runs, before its future completes.
final class RecordingCrashTransport implements CrashTransport {
  /// Each event as the client wrote it, its canonical JSON, oldest first.
  final List<String> sent = [];

  /// Each event of [sent], decoded.
  List<Map<String, Object?>> get events => [
    for (final event in sent) jsonDecode(event) as Map<String, Object?>,
  ];

  @override
  Future<void> send(String eventJson) async => sent.add(eventJson);
}

/// A client that records what it reports instead of sending it, for a
/// host's tests: its [client] goes wherever the host's code takes one — a
/// `NoticebirdBlocObserver(client: …)`, the host's own adapter, the
/// `Noticebird` facade ([attach]) — and [events] are the reports as the
/// platform would receive them, built, sanitized and checked by the real
/// client.
///
/// It does not deduplicate: an error reported twice is two events, so a
/// test sees a report made twice. Its app and platform are fixed
/// ([app], [platform]) rather than the machine's, and it sends no
/// feedback.
///
/// ```dart
/// final recorder = NoticebirdRecorder(shouldCapture: shouldCaptureError);
/// Bloc.observer = NoticebirdBlocObserver(client: recorder.client);
/// // Made after the observer is set, a cubit that calls addError when its
/// // load fails:
/// await ListCubit(load: () => throw StateError('boom')).load();
/// expect(recorder.events.single['handled'], isTrue);
/// ```
final class NoticebirdRecorder {
  /// A recorder whose client asks [shouldCapture] as the host's does, under
  /// [privacyProfile] and [pii], and stamps its events by [clock] when
  /// given; a breadcrumb carries the time its observer gave it.
  NoticebirdRecorder({
    bool Function(Object error)? shouldCapture,
    CrashPrivacyProfile privacyProfile = CrashPrivacyProfile.privacyDefault,
    CrashPiiConfig pii = const CrashPiiConfig(),
    DateTime Function()? clock,
  }) : this._(
         RecordingCrashTransport(),
         shouldCapture,
         privacyProfile,
         pii,
         clock,
       );

  NoticebirdRecorder._(
    this.transport,
    bool Function(Object error)? shouldCapture,
    CrashPrivacyProfile privacyProfile,
    CrashPiiConfig pii,
    DateTime Function()? clock,
  ) : client = NoticebirdClient(
        config: NoticebirdConfig(
          privacyProfile: privacyProfile,
          app: app,
          platform: platform,
          pii: pii,
          shouldCapture: shouldCapture,
          deduplicationWindow: Duration.zero,
        ),
        transport: transport,
        clock: clock,
      );

  /// The app a recorder's events name.
  static const app = AppMetadata(
    name: 'test_app',
    version: '1.0.0',
    build: '1',
    release: 'test_app@1.0.0+1',
  );

  /// The platform a recorder's events name.
  static const platform = PlatformMetadata(
    platform: CrashPlatform.unknown,
    osVersion: 'test',
    deviceClass: 'test',
  );

  /// The client that records.
  final NoticebirdClient client;

  /// Where its events go.
  final RecordingCrashTransport transport;

  /// Every event the client reported, decoded, oldest first.
  List<Map<String, Object?>> get events => transport.events;

  /// The event the last capture of [error] made, once that capture has
  /// settled (`NoticebirdClient.eventIdOf`); `null` when [error] made none.
  Future<Map<String, Object?>?> eventOf(Object error) async {
    final eventId = await client.eventIdOf(error);
    if (eventId == null) return null;
    for (final event in events.reversed) {
      if (event['eventId'] == eventId) return event;
    }
    return null;
  }

  /// Attaches [client] to the `Noticebird` facade, so code that reports
  /// through the facade reports to this recorder.
  void attach() => Noticebird.attach(client);

  /// Closes [client], and detaches it from the facade when it is attached.
  void close() {
    client.close();
    if (identical(Noticebird.instance, client)) Noticebird.detach();
  }
}
