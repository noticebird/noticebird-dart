// The test support a Flutter host imports from
// package:noticebird_flutter/testing.dart: the SDK's own bloc observer
// reporting to a recorder, and the start's reset.

import 'dart:io';

import 'package:bloc/bloc.dart';
import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noticebird_flutter/noticebird_flutter.dart';
import 'package:noticebird_flutter/testing.dart';
import 'package:package_info_plus_platform_interface/package_info_platform_interface.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/fake_platforms.dart';

final class _ListCubit extends Cubit<int> {
  _ListCubit() : super(0);

  void fail() => addError(StateError('boom'), StackTrace.current);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the bloc observer reports a bloc error to a recorder, as it would '
      'in the app', () {
    final recorder = NoticebirdRecorder();
    final previous = Bloc.observer;
    Bloc.observer = NoticebirdBlocObserver(client: recorder.client);
    addTearDown(() => Bloc.observer = previous);
    final cubit = _ListCubit();
    addTearDown(cubit.close);

    cubit
      ..emit(1)
      ..fail();

    final event = recorder.events.single;
    expect(event['handled'], isTrue);
    expect((event['tags']! as Map)['component'], '_ListCubit');
    expect(
      recorder.client.recentBreadcrumbs.single.data[AllowedTag.component],
      '_ListCubit',
    );
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
