import 'dart:convert';

import 'package:bloc/bloc.dart';
import 'package:noticebird/noticebird.dart';
import 'package:flutter_test/flutter_test.dart';

final class _RecordingTransport implements CrashTransport {
  final events = <Map<String, dynamic>>[];

  @override
  Future<void> send(String eventJson) async {
    events.add(jsonDecode(eventJson) as Map<String, dynamic>);
  }
}

final class _CounterCubit extends Cubit<int> {
  _CounterCubit() : super(0);

  void increment() => emit(state + 1);

  void fail() => addError(StateError('boom'), StackTrace.current);
}

void main() {
  late _RecordingTransport transport;
  late NoticebirdClient reporter;
  late ProtocolNoticebirdBlocObserver observer;

  setUp(() {
    transport = _RecordingTransport();
    reporter = NoticebirdClient(
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
        sessionIdFactory: () => 'test_session_1234567890',
      ),
      transport: transport,
    );
    observer = ProtocolNoticebirdBlocObserver(reporter);
  });

  test('onChange adds a bloc breadcrumb tagged with component/operation', () {
    final cubit = _CounterCubit();
    observer.onChange(cubit, const Change(currentState: 0, nextState: 1));

    expect(reporter.recentBreadcrumbs, hasLength(1));
    final breadcrumb = reporter.recentBreadcrumbs.single;
    expect(breadcrumb.category, BreadcrumbCategory.bloc);
    expect(breadcrumb.action, 'bloc.change');
    expect(breadcrumb.data[AllowedTag.component], '_CounterCubit');
    expect(breadcrumb.data[AllowedTag.operation], 'int');
    cubit.close();
  });

  test(
    'onError captures the exception as handled, tagged with the bloc type',
    () async {
      final cubit = _CounterCubit();
      observer.onError(cubit, StateError('boom'), StackTrace.current);
      // The capture is fire-and-forget; flush pending microtasks.
      await Future<void>.delayed(Duration.zero);

      expect(transport.events, hasLength(1));
      final event = transport.events.single;
      expect(
        event['handled'],
        isTrue,
        reason: 'a bloc already caught this error',
      );
      expect(event['tags']['component'], '_CounterCubit');
      cubit.close();
    },
  );

  test(
    'a BlocErrorReport is captured as its cause, in the shape it gives',
    () async {
      final cubit = _CounterCubit();
      observer.onError(
        cubit,
        BlocErrorReport(
          StateError('offline'),
          severity: CrashSeverity.warning,
          tags: const {
            AllowedTag.operation: 'sync.pull',
            AllowedTag.component: 'not the bloc',
          },
          extra: const {'pending': 3},
        ),
        StackTrace.current,
      );
      await Future<void>.delayed(Duration.zero);

      final event = transport.events.single;
      expect(
        event['exception']['type'],
        'StateError',
        reason: 'the event is the error itself, not its wrapper',
      );
      expect(event['handled'], isTrue);
      expect(event['severity'], CrashSeverity.warning.name);
      expect(event['tags']['operation'], 'sync.pull');
      expect(
        event['tags']['component'],
        '_CounterCubit',
        reason: 'the component is always the bloc',
      );
      expect(event['extra']['pending'], 3);
      cubit.close();
    },
  );

  test('the capture filter sees the cause of a BlocErrorReport', () async {
    final filtered = NoticebirdClient(
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
        sessionIdFactory: () => 'test_session_1234567890',
        shouldCapture: (error) => error is! _ReportedElsewhere,
      ),
      transport: transport,
    );
    final cubit = _CounterCubit();
    ProtocolNoticebirdBlocObserver(filtered).onError(
      cubit,
      const BlocErrorReport(
        _ReportedElsewhere(),
        severity: CrashSeverity.warning,
      ),
      StackTrace.current,
    );
    await Future<void>.delayed(Duration.zero);

    expect(transport.events, isEmpty);
    cubit.close();
  });
}

final class _ReportedElsewhere implements Exception {
  const _ReportedElsewhere();
}
