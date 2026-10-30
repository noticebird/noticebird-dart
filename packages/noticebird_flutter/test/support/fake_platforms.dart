import 'dart:async';

import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:package_info_plus_platform_interface/package_info_data.dart';
import 'package:package_info_plus_platform_interface/package_info_platform_interface.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// The installed build, as the platform reports it; [never] for one that
/// does not answer.
final class FakePackageInfo extends PackageInfoPlatform
    with MockPlatformInterfaceMixin {
  FakePackageInfo({this.version = '2.4.0', this.build = '17', this.never});

  final String version;
  final String build;
  final Completer<PackageInfoData>? never;

  @override
  Future<PackageInfoData> getAll({String? baseUrl}) =>
      never?.future ??
      Future.value(
        PackageInfoData(
          appName: 'Example',
          packageName: 'com.example.app',
          version: version,
          buildNumber: build,
          buildSignature: '',
        ),
      );
}

/// The app's support directory at [path]; [never] for a platform that does
/// not answer.
final class FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  FakePathProvider(this.path, {this.never});

  final String path;
  final Completer<String?>? never;

  @override
  Future<String?> getApplicationSupportPath() =>
      never?.future ?? Future.value(path);
}

/// The connection as the test sets it, by [changes].
final class FakeConnectivity extends ConnectivityPlatform
    with MockPlatformInterfaceMixin {
  final changes = StreamController<List<ConnectivityResult>>.broadcast();

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => const [
    ConnectivityResult.wifi,
  ];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => changes.stream;
}
