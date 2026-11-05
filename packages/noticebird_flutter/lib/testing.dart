/// Test support for a Flutter app that reports through Noticebird:
/// `NoticebirdRecorder`, a client that records its reports instead of
/// sending them, on a `RecordingCrashTransport`. An observer the app writes
/// reports to it as it would in the app, through `recorder.client`, without
/// a network.
///
/// A test that calls `NoticebirdFlutter.start` resets it with
/// `NoticebirdFlutter.resetForTesting()`; the facade's reset is
/// `Noticebird.detach()`.
library;

export 'package:noticebird/testing.dart';
