// A platform whose reads never answer (a headless engine, a plugin that is
// not registered) does not hold up the start: it goes on without them after
// NoticebirdFlutter.platformReadTimeout. In a file of its own, since the
// package-info plugin keeps its first answer for the whole process.

import 'dart:async';

import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noticebird_flutter/noticebird_flutter.dart';
import 'package:package_info_plus_platform_interface/package_info_platform_interface.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/fake_platforms.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a start goes on without reads that never answer', () {
    PackageInfoPlatform.instance = FakePackageInfo(never: Completer());
    PathProviderPlatform.instance = FakePathProvider('', never: Completer());
    ConnectivityPlatform.instance = FakeConnectivity();

    fakeAsync((async) {
      NoticebirdFlutter? started;
      NoticebirdFlutter.start(
        apiUrl: CrashHttpTransport.hostedApiUrl,
        publishableKey: 'noticebird_pk_example00000000000000000',
        appName: 'example_app',
        uploadCrashes: false,
      ).then((value) => started = value);

      async.elapse(
        NoticebirdFlutter.platformReadTimeout - const Duration(milliseconds: 1),
      );
      expect(started, isNull);
      async.elapse(const Duration(milliseconds: 1));

      expect(started, isNotNull);
      expect(Noticebird.instance, same(started!.client));
      expect(started!.platformReadFailures.map((failure) => failure.read), [
        'packageInfo',
        'supportDirectory',
      ]);
      started!.close();
    });
  });
}
