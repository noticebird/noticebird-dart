import 'package:noticebird_protocol/noticebird_protocol.dart';

/// What a client tells the platform about the app and the device, as its
/// reports carry it: for a host that shows the user what goes out with a
/// report, such as a feedback sheet's disclosure, rather than reading its
/// own copy that may differ.
///
/// `NoticebirdClient.reportedContext` answers it at the moment it is
/// asked: the locale is the one a report sent now would carry.
final class ReportedContext {
  const ReportedContext({
    required this.app,
    required this.platform,
    this.locale,
  });

  /// The app this run's crash events and feedback reports name: its name,
  /// version, build and release. A native crash of an earlier run names
  /// the app of that run.
  final AppMetadata app;

  /// The platform this run's crash events and feedback reports name: the
  /// operating system, its version and the device class, as the config
  /// holds them (`hostPlatformMetadata` by default, whose version is
  /// `not-collected` under `regulatedStrict`). No device model leaves the
  /// device.
  final PlatformMetadata platform;

  /// The app's locale as a language tag (`nl-NL`), which a feedback report
  /// carries and a crash event does not; `null` when a report would carry
  /// none: no locale configured, one the protocol refuses, or
  /// `regulatedStrict`.
  final String? locale;

  @override
  String toString() =>
      'ReportedContext(${app.release}, ${platform.platform.name} '
      '${platform.osVersion}, ${platform.deviceClass}, locale: $locale)';
}
