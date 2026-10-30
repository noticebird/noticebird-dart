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

  /// The app every crash event and feedback report names: its name,
  /// version, build and release.
  final AppMetadata app;

  /// The platform every crash event and feedback report names: the
  /// operating system, its version (`not-collected` under
  /// `regulatedStrict`) and the device class. No device model leaves the
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
