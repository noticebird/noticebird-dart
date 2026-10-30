import 'dart:io' show Platform;

import 'package:noticebird_protocol/noticebird_protocol.dart';

import 'noticebird_config.dart';

/// The [PlatformMetadata] of the platform this app runs on: its
/// [CrashPlatform], the operating system version, and a device class
/// (`mobile`, `desktop`, `web` or `unknown`).
///
/// Under [CrashPrivacyProfile.regulatedStrict] the operating system version is
/// `not-collected`: a build string narrows a device down, and a regulated app
/// sends only what a report cannot do without.
PlatformMetadata hostPlatformMetadata({
  CrashPrivacyProfile privacyProfile = CrashPrivacyProfile.privacyDefault,
}) {
  final platform = _hostCrashPlatform();
  final osVersion = privacyProfile == CrashPrivacyProfile.regulatedStrict
      ? notCollectedOsVersion
      : _isWeb
      ? 'web'
      : Platform.operatingSystemVersion.trim();
  final deviceClass = switch (platform) {
    CrashPlatform.android || CrashPlatform.ios => 'mobile',
    CrashPlatform.macos ||
    CrashPlatform.windows ||
    CrashPlatform.linux => 'desktop',
    CrashPlatform.web => 'web',
    CrashPlatform.unknown => 'unknown',
  };
  return PlatformMetadata(
    platform: platform,
    osVersion: osVersion.isEmpty ? 'unknown' : osVersion,
    deviceClass: deviceClass,
  );
}

/// The operating system version a [CrashPrivacyProfile.regulatedStrict]
/// report carries.
const notCollectedOsVersion = 'not-collected';

/// Whether this runs on the web, as Flutter's `kIsWeb` tells it.
const bool _isWeb = bool.fromEnvironment('dart.library.js_interop');

CrashPlatform _hostCrashPlatform() {
  if (_isWeb) return CrashPlatform.web;
  if (Platform.isAndroid) return CrashPlatform.android;
  if (Platform.isIOS) return CrashPlatform.ios;
  if (Platform.isMacOS) return CrashPlatform.macos;
  if (Platform.isWindows) return CrashPlatform.windows;
  if (Platform.isLinux) return CrashPlatform.linux;
  return CrashPlatform.unknown;
}
