// The global error handlers NoticebirdFlutter.start installs: each reports
// to the client through its capture filter and chains to the one it
// replaces, an uncaught platform error without a previous handler is
// printed and handled, and what they replaced comes back.

import 'dart:convert';

import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noticebird_flutter/noticebird_flutter.dart';
import 'package:noticebird_flutter/src/error_handlers.dart';

final class _Transport implements CrashTransport {
  final events = <Map<String, dynamic>>[];

  @override
  Future<void> send(String eventJson) async =>
      events.add(jsonDecode(eventJson) as Map<String, dynamic>);
}

final class _ReportedElsewhere implements Exception {
  const _ReportedElsewhere();
}

void main() {
  late _Transport transport;
  late NoticebirdClient client;
  late FlutterExceptionHandler? flutterHandler;
  late ErrorCallback? platformHandler;
  late List<FlutterErrorDetails> presented;
  late void Function(FlutterErrorDetails) present;

  setUp(() {
    transport = _Transport();
    client = NoticebirdClient(
      config: NoticebirdConfig(
        privacyProfile: CrashPrivacyProfile.privacyDefault,
        app: const AppMetadata(
          name: 'test',
          version: '1.0.0',
          build: '1',
          release: 'test@1.0.0+1',
        ),
        platform: const PlatformMetadata(
          platform: CrashPlatform.unknown,
          osVersion: 'test',
          deviceClass: 'test',
        ),
        deduplicationWindow: Duration.zero,
        shouldCapture: (error) => error is! _ReportedElsewhere,
      ),
      transport: transport,
    );
    flutterHandler = FlutterError.onError;
    platformHandler = PlatformDispatcher.instance.onError;
    presented = [];
    present = FlutterError.presentError;
    FlutterError.presentError = presented.add;
  });

  tearDown(() {
    FlutterError.onError = flutterHandler;
    PlatformDispatcher.instance.onError = platformHandler;
    FlutterError.presentError = present;
  });

  test('FlutterError.onError reports through the filter, tagged with the '
      'library, and chains', () async {
    final chained = <Object>[];
    FlutterError.onError = (details) => chained.add(details.exception);
    installErrorHandlers(client);

    FlutterError.onError!(
      FlutterErrorDetails(exception: const _ReportedElsewhere()),
    );
    FlutterError.onError!(
      FlutterErrorDetails(
        exception: StateError('boom'),
        library: 'widgets library',
      ),
    );
    await pumpEventQueue();

    expect(transport.events, hasLength(1));
    expect(transport.events.single['exception']['type'], 'StateError');
    expect(transport.events.single['tags'], {'component': 'widgets library'});
    expect(chained, hasLength(2));
  });

  test('an uncaught platform error without a previous handler is fatal, '
      'printed and handled', () async {
    PlatformDispatcher.instance.onError = null;
    installErrorHandlers(client);

    final handled = PlatformDispatcher.instance.onError!(
      StateError('boom'),
      StackTrace.current,
    );
    await pumpEventQueue();

    expect(handled, isTrue);
    expect(transport.events.single['severity'], 'fatal');
    expect(presented.single.exception, isA<StateError>());
  });

  test('with a previous platform handler its answer is the answer', () async {
    PlatformDispatcher.instance.onError = (_, _) => false;
    installErrorHandlers(client);

    expect(
      PlatformDispatcher.instance.onError!(
        StateError('boom'),
        StackTrace.current,
      ),
      isFalse,
    );
    await pumpEventQueue();
    expect(transport.events, hasLength(1));
    expect(presented, isEmpty);
  });

  test('the platform handler honours the filter', () async {
    PlatformDispatcher.instance.onError = null;
    installErrorHandlers(client);

    PlatformDispatcher.instance.onError!(
      const _ReportedElsewhere(),
      StackTrace.current,
    );
    await pumpEventQueue();

    expect(transport.events, isEmpty);
  });

  test('restoring puts back what they replaced', () {
    void previous(FlutterErrorDetails _) {}
    FlutterError.onError = previous;
    final restore = installErrorHandlers(client);
    expect(FlutterError.onError, isNot(same(previous)));

    restore();

    expect(FlutterError.onError, same(previous));
  });

  test('a zone error is fatal and printed', () async {
    reportZoneError(client, StateError('zone'), StackTrace.current);
    reportZoneError(client, const _ReportedElsewhere(), StackTrace.current);
    await pumpEventQueue();

    expect(transport.events.single['severity'], 'fatal');
    expect(presented, hasLength(2));
  });
}
