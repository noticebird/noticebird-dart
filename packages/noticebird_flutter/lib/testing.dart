/// Test support for a Flutter app that reports through Noticebird:
/// `NoticebirdRecorder`, a client that records its reports instead of
/// sending them, on a `RecordingCrashTransport`. A bloc observer reports to
/// it as it would in the app — `NoticebirdBlocObserver(client:
/// recorder.client)`, or the app's own subclass — without a network.
///
/// A test that calls `NoticebirdFlutter.start` resets it with
/// `NoticebirdFlutter.resetForTesting()`; the facade's reset is
/// `Noticebird.detach()`.
library;

export 'package:noticebird/testing.dart';
