/// Test support for an app that reports through Noticebird:
/// [NoticebirdRecorder], a client that records its reports instead of
/// sending them, on a [RecordingCrashTransport]. The facade's reset is
/// `Noticebird.detach()`.
library;

export 'src/testing/noticebird_recorder.dart';
