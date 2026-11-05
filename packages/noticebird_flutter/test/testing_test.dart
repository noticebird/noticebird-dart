// The test support a Flutter host imports from
// package:noticebird_flutter/testing.dart: a recorder an app's own code
// reports to, and the start's reset.

import 'dart:io';

import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noticebird_flutter/noticebird_flutter.dart';
import 'package:noticebird_flutter/testing.dart';
import 'package:package_info_plus_platform_interface/package_info_platform_interface.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/fake_platforms.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the navigator observer reports to a recorder, as it would in the '
      'app', () async {
    final recorder = NoticebirdRecorder();
    NoticebirdNavigatorObserver(client: recorder.client).didPush(
      PageRouteBuilder<void>(
        settings: const RouteSettings(name: '/lists/:listId'),
        pageBuilder: (_, _, _) => const SizedBox(),
      ),
      null,
    );

    await recorder.client.captureException(
      StateError('boom'),
      StackTrace.empty,
    );

    final step = (recorder.events.single['breadcrumbs']! as List).single;
    expect((step as Map)['details'], {'route': '/lists/:listId'});
  });

  group('resetForTesting', () {
    late Directory support;

    setUp(() async {
      support = await Directory.systemTemp.createTemp('noticebird_reset');
      PackageInfoPlatform.instance = FakePackageInfo();
      PathProviderPlatform.instance = FakePathProvider(support.path);
      ConnectivityPlatform.instance = FakeConnectivity();
    });

    tearDown(() async {
      await NoticebirdFlutter.resetForTesting();
      await support.delete(recursive: true);
    });

    Future<NoticebirdFlutter> start() =>
        NoticebirdFlutter.start(appName: 'example_app');

    test('closes the start, so the next one starts anew', () async {
      final handler = FlutterError.onError;
      final first = await start();

      await NoticebirdFlutter.resetForTesting();

      expect(Noticebird.instance, isNull);
      expect(FlutterError.onError, same(handler));
      expect(await start(), isNot(same(first)));
    });

    test('closes a start made after a start that threw, before the reset '
        'resumes', () async {
      final handler = FlutterError.onError;
      Future<NoticebirdFlutter>? second;
      // Its listener runs after the start's own, before the reset's.
      NoticebirdFlutter.start(
        appName: 'example_app',
        breadcrumbBuffer: 0,
      ).then<void>((_) {}, onError: (Object _) => second = start());

      await NoticebirdFlutter.resetForTesting();
      await second;

      expect(second, isNotNull);
      expect(Noticebird.instance, isNull);
      expect(FlutterError.onError, same(handler));
    });

    test('closes a start still under way', () async {
      final handler = FlutterError.onError;
      final starting = start();

      await NoticebirdFlutter.resetForTesting();

      expect(Noticebird.instance, isNull);
      expect(FlutterError.onError, same(handler));
      expect(await start(), isNot(same(await starting)));
    });
  });
}
