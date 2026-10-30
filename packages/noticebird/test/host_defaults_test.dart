import 'dart:convert';

import 'package:noticebird/noticebird.dart';
import 'package:test/test.dart';

/// What every host would otherwise write itself: the running platform's
/// metadata, a session id per app run, and a transport that sends nothing.
void main() {
  test('hostPlatformMetadata describes the running platform validly', () {
    final metadata = hostPlatformMetadata();

    expect(metadata.check, returnsNormally);
    expect(metadata.osVersion, isNotEmpty);
    expect(metadata.deviceClass, isNotEmpty);
  });

  test('a regulated report does not collect the operating system version', () {
    final metadata = hostPlatformMetadata(
      privacyProfile: CrashPrivacyProfile.regulatedStrict,
    );

    expect(metadata.osVersion, notCollectedOsVersion);
    expect(metadata.check, returnsNormally);
  });

  test('a config without a platform describes the running one', () {
    for (final profile in CrashPrivacyProfile.values) {
      final config = NoticebirdConfig(
        privacyProfile: profile,
        app: const AppMetadata(
          name: 'test',
          version: '1.0.0',
          build: '1',
          release: 'test@1.0.0+1',
        ),
      );

      expect(
        config.platform.toJson(),
        hostPlatformMetadata(privacyProfile: profile).toJson(),
      );
    }
  });

  test('the process session id is one valid id for the whole run', () {
    final id = NoticebirdConfig.processSessionId;

    expect(id, NoticebirdConfig.processSessionId);
    expect(RegExp(r'^[A-Za-z0-9_-]{16,64}$').hasMatch(id), isTrue);
  });

  test(
    'a config without a session factory uses the process session id',
    () async {
      final transport = _RecordingTransport();
      final reporter = NoticebirdClient(
        config: NoticebirdConfig(
          privacyProfile: CrashPrivacyProfile.privacyDefault,
          app: const AppMetadata(
            name: 'test',
            version: '1.0.0',
            build: '1',
            release: 'test@1.0.0+1',
          ),
          platform: hostPlatformMetadata(),
        ),
        transport: transport,
      );

      await reporter.captureException(StateError('boom'), StackTrace.current);

      expect(
        transport.events.single['sessionId'],
        NoticebirdConfig.processSessionId,
      );
    },
  );

  test(
    'a discarding transport makes no event, keeps nothing and names no id',
    () async {
      final reporter = NoticebirdClient(
        config: NoticebirdConfig(
          privacyProfile: CrashPrivacyProfile.privacyDefault,
          app: const AppMetadata(
            name: 'test',
            version: '1.0.0',
            build: '1',
            release: 'test@1.0.0+1',
          ),
          platform: hostPlatformMetadata(),
        ),
      );

      final result = await reporter.captureException(
        StateError('boom'),
        StackTrace.current,
      );

      // Discarded, not queued: a failing transport would grow a retry queue
      // that never drains; and no id, since no event went anywhere.
      expect(result, const CaptureResult(CaptureOutcome.discarded));
      expect(reporter.pendingCount, 0);
    },
  );
}

final class _RecordingTransport implements CrashTransport {
  final events = <Map<String, dynamic>>[];

  @override
  Future<void> send(String eventJson) async {
    events.add(jsonDecode(eventJson) as Map<String, dynamic>);
  }
}
