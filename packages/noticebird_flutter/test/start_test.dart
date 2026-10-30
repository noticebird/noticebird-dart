// NoticebirdFlutter.start against fake platforms and a fake HTTP client: what
// it wires (the client on the facade, the app's version, the default stores,
// the handlers and the bloc observer, delivery when the connection returns),
// a key that cannot work, a background start, and close.

import 'dart:convert';
import 'dart:io';

import 'package:bloc/bloc.dart';
import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noticebird_flutter/feedback.dart';
import 'package:noticebird_flutter/noticebird_flutter.dart';
import 'package:package_info_plus_platform_interface/package_info_platform_interface.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/fake_platforms.dart';

const _key = 'noticebird_pk_example00000000000000000';
final _stack = StackTrace.fromString('#0 A.b (package:app/a.dart:1:1)');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  late FakeConnectivity connectivity;
  late List<http.Request> requests;
  late bool offline;
  late http.Client httpClient;
  NoticebirdFlutter? started;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('noticebird_flutter_');
    PackageInfoPlatform.instance = FakePackageInfo();
    PathProviderPlatform.instance = FakePathProvider(support.path);
    connectivity = FakeConnectivity();
    ConnectivityPlatform.instance = connectivity;
    requests = [];
    offline = false;
    httpClient = MockClient((request) async {
      if (offline) throw const SocketException('offline');
      requests.add(request);
      return request.url.path.endsWith('/v1/feedback')
          ? http.Response(
              jsonEncode({
                'ticket': {'number': 1, 'display': 'FB-1'},
                'verified': false,
              }),
              201,
            )
          : http.Response('', 202);
    });
  });

  tearDown(() async {
    started?.close();
    started = null;
    await support.delete(recursive: true);
  });

  Future<NoticebirdFlutter> start({
    String publishableKey = _key,
    bool uploadCrashes = true,
    bool background = false,
    bool observeBlocs = true,
  }) async => started = await NoticebirdFlutter.start(
    publishableKey: publishableKey,
    appName: 'example_app',
    httpClient: httpClient,
    uploadCrashes: uploadCrashes,
    background: background,
    observeBlocs: observeBlocs,
  );

  List<Map<String, Object?>> envelopes() => [
    for (final request in requests)
      if (request.url.path.endsWith('/v1/envelope'))
        jsonDecode(request.body) as Map<String, Object?>,
  ];

  test('attaches a client named after the app and its installed '
      'build', () async {
    final noticebird = await start();

    expect(Noticebird.instance, same(noticebird.client));
    await Noticebird.captureException(StateError('boom'), _stack);

    expect(envelopes().single['app'], {
      'name': 'example_app',
      'version': '2.4.0',
      'build': '17',
      'release': 'example_app@2.4.0+17',
    });
  });

  test('a second start answers the running one', () async {
    final first = await start();
    expect(await start(), same(first));
  });

  test('two starts at once start one client', () async {
    final flutterHandler = FlutterError.onError;
    final [first, second] = await Future.wait([start(), start()]);

    expect(second, same(first));
    first.close();
    expect(FlutterError.onError, same(flutterHandler));
  });

  test('an argument no start can work with throws, with a key or '
      'without', () async {
    for (final key in [_key, '']) {
      await expectLater(
        NoticebirdFlutter.start(
          publishableKey: key,
          appName: 'example_app',
          httpClient: httpClient,
          requireVerified: true,
        ),
        throwsArgumentError,
      );
    }
    // A failed start is no start: the next one starts.
    expect(await start(), isA<NoticebirdFlutter>());
  });

  test('a connection stream that fails costs the start nothing', () async {
    await start();
    connectivity.changes.addError(StateError('plugin'));
    await pumpEventQueue();
    expect(Noticebird.instance, isNotNull);
  });

  test('keeps an event that did not get through in the support directory, '
      'and sends it when the connection returns', () async {
    await start();
    offline = true;
    await Noticebird.captureException(StateError('boom'), _stack);
    expect(
      File('${support.path}/noticebird/crashes/events.json').existsSync(),
      isTrue,
    );

    offline = false;
    connectivity.changes.add(const [ConnectivityResult.wifi]);
    await pumpEventQueue();

    expect(envelopes(), hasLength(1));
    expect(Noticebird.instance!.pendingCount, 0);
  });

  test('a connection that goes away flushes nothing', () async {
    await start();
    requests.clear();
    connectivity.changes.add(const [ConnectivityResult.none]);
    await pumpEventQueue();
    expect(requests, isEmpty);
  });

  test('sends feedback with the live blocs and the platform\'s locale, also '
      'with crash uploads off', () async {
    await start(uploadCrashes: false);
    final cubit = _Counter();
    addTearDown(cubit.close);

    expect(
      (await Noticebird.captureException(StateError('boom'), _stack))?.outcome,
      CaptureOutcome.discarded,
    );
    final outcome = await Noticebird.captureFeedback(
      kind: FeedbackKind.bug,
      message: 'It broke',
    );

    expect(outcome, isA<FeedbackDelivered>());
    final report =
        jsonDecode(
              requests
                  .singleWhere((r) => r.url.path.endsWith('/v1/feedback'))
                  .body,
            )
            as Map<String, Object?>;
    expect((report['diagnostics']! as Map)['blocs'], {
      'count': 1,
      'counter': 1,
    });
    expect(
      (report['platform']! as Map)['locale'],
      WidgetsBindingLocale.languageTag,
    );
  });

  test('a key that cannot work starts a client that uploads nothing and '
      'sends no feedback', () async {
    await start(publishableKey: '');

    expect(
      (await Noticebird.captureException(StateError('boom'), _stack))?.outcome,
      CaptureOutcome.discarded,
    );
    expect(
      await Noticebird.captureFeedback(kind: FeedbackKind.bug, message: 'x'),
      const FeedbackDisabled(),
    );
    expect(requests, isEmpty);
  });

  test('a background start keeps no store and flushes nothing by '
      'itself', () async {
    await start(background: true);
    offline = true;
    await Noticebird.captureException(StateError('boom'), _stack);

    expect(Directory('${support.path}/noticebird').existsSync(), isFalse);
    offline = false;
    connectivity.changes.add(const [ConnectivityResult.wifi]);
    await pumpEventQueue();
    expect(envelopes(), isEmpty);
    expect(Noticebird.instance!.pendingCount, 1);
  });

  test('close puts back the handlers and the bloc observer it found, and '
      'detaches the client', () async {
    final flutterHandler = FlutterError.onError;
    final platformHandler = PlatformDispatcher.instance.onError;
    final blocObserver = Bloc.observer;
    final noticebird = await start();
    expect(FlutterError.onError, isNot(same(flutterHandler)));
    expect(PlatformDispatcher.instance.onError, isNot(same(platformHandler)));
    expect(Bloc.observer, isA<MultiBlocObserver>());

    noticebird.close();
    noticebird.close();

    expect(FlutterError.onError, same(flutterHandler));
    expect(PlatformDispatcher.instance.onError, same(platformHandler));
    expect(Bloc.observer, same(blocObserver));
    expect(Noticebird.instance, isNull);
    expect(await start(), isNot(same(noticebird)));
  });

  test(
    'a blocObserver of the host\'s own is the one set and counted',
    () async {
      final mine = _DetailedObserver();
      final noticebird = await NoticebirdFlutter.start(
        publishableKey: _key,
        appName: 'example_app',
        httpClient: httpClient,
        blocObserver: mine,
      );
      started = noticebird;
      final cubit = _Counter();
      addTearDown(cubit.close);
      cubit.emit(1);

      expect(noticebird.blocObserver, same(mine));
      expect(mine.liveBlocCounts(), {'count': 1, 'counter': 1});
      expect(
        noticebird.client.recentBreadcrumbs.last.data[AllowedTag.operation],
        'detailed',
      );
    },
  );

  test('a handler the host set after the start stays at close', () async {
    final noticebird = await start();
    void mine(FlutterErrorDetails _) {}
    final previous = FlutterError.onError;
    FlutterError.onError = mine;
    addTearDown(() => FlutterError.onError = previous);

    noticebird.close();

    expect(FlutterError.onError, same(mine));
  });

  test('observeBlocs: false leaves Bloc.observer to the host, and sends no '
      'blocs group', () async {
    final blocObserver = Bloc.observer;
    await start(observeBlocs: false);
    expect(Bloc.observer, same(blocObserver));

    await Noticebird.captureFeedback(kind: FeedbackKind.bug, message: 'x');

    final report =
        jsonDecode(
              requests
                  .singleWhere((r) => r.url.path.endsWith('/v1/feedback'))
                  .body,
            )
            as Map<String, Object?>;
    expect(report, isNot(contains('diagnostics')));
  });

  test('reportZoneError reports a fatal event to the started client', () async {
    await start();
    final presented = <FlutterErrorDetails>[];
    final present = FlutterError.presentError;
    FlutterError.presentError = presented.add;
    addTearDown(() => FlutterError.presentError = present);

    NoticebirdFlutter.reportZoneError(StateError('zone'), _stack);
    await pumpEventQueue();

    expect(envelopes().single['severity'], 'fatal');
    expect(presented.single.exception, isA<StateError>());
  });
}

/// The locale a test binding reports, as a language tag.
abstract final class WidgetsBindingLocale {
  static String get languageTag => TestWidgetsFlutterBinding
      .instance
      .platformDispatcher
      .locale
      .toLanguageTag();
}

final class _Counter extends Cubit<int> {
  _Counter() : super(0);
}

final class _DetailedObserver extends NoticebirdBlocObserver {
  @override
  String describeState(Object? state) => 'detailed';
}
