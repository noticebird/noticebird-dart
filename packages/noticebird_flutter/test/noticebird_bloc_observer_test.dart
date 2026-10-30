import 'package:bloc/bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noticebird_flutter/noticebird_flutter.dart';
import 'package:noticebird_flutter/testing.dart';

final class _CounterCubit extends Cubit<int> {
  _CounterCubit() : super(0);

  void increment() => emit(state + 1);

  void fail() => addError(StateError('boom'), StackTrace.current);
}

void main() {
  late RecordingCrashTransport transport;
  late NoticebirdClient reporter;
  late NoticebirdBlocObserver observer;

  setUp(() {
    transport = RecordingCrashTransport();
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
    observer = NoticebirdBlocObserver(client: reporter);
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
      expect((event['tags']! as Map)['component'], '_CounterCubit');
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
        (event['exception']! as Map)['type'],
        'StateError',
        reason: 'the event is the error itself, not its wrapper',
      );
      expect(event['handled'], isTrue);
      expect(event['severity'], CrashSeverity.warning.name);
      expect((event['tags']! as Map)['operation'], 'sync.pull');
      expect(
        (event['tags']! as Map)['component'],
        '_CounterCubit',
        reason: 'the component is always the bloc',
      );
      expect((event['extra']! as Map)['pending'], 3);
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
    NoticebirdBlocObserver(client: filtered).onError(
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

  test('an UntracedBloc leaves no breadcrumb, and its errors are still '
      'captured', () async {
    final cubit = _Untraced();
    addTearDown(cubit.close);

    observer
      ..onChange(cubit, const Change(currentState: 0, nextState: 1))
      ..onError(cubit, StateError('boom'), StackTrace.current);
    await Future<void>.delayed(Duration.zero);

    expect(reporter.recentBreadcrumbs, isEmpty);
    expect(transport.events, hasLength(1));
  });

  test('a subclass leaves its own marker out of the trail by traces; its '
      'errors are still captured and it is still counted', () async {
    final observer = _OwnMarkerObserver(reporter);
    final own = _OwnUntraced();
    final untraced = _Untraced();
    final counter = _CounterCubit();
    addTearDown(own.close);
    addTearDown(untraced.close);
    addTearDown(counter.close);

    for (final bloc in <BlocBase<dynamic>>[own, untraced, counter]) {
      observer
        ..onCreate(bloc)
        ..onChange(bloc, const Change(currentState: 0, nextState: 1));
    }
    observer.onError(own, StateError('boom'), StackTrace.current);
    await Future<void>.delayed(Duration.zero);

    expect(
      [
        for (final crumb in reporter.recentBreadcrumbs)
          crumb.data[AllowedTag.component],
      ],
      ['_CounterCubit'],
      reason: 'the SDK marker stays out through super.traces',
    );
    expect(transport.events, hasLength(1));
    expect(observer.liveBlocCounts()['count'], 3);
  });

  test('a traces that throws costs the bloc nothing', () {
    final cubit = _CounterCubit();
    addTearDown(cubit.close);

    _ThrowingTracesObserver(
      reporter,
    ).onChange(cubit, const Change(currentState: 0, nextState: 1));

    expect(reporter.recentBreadcrumbs, isEmpty);
  });

  test('counts the live blocs per type, without type arguments or a '
      'leading underscore', () {
    final counter = _CounterCubit();
    final boxes = [_Box<int>(), _Box<String>()];
    final untraced = _Untraced();
    for (final bloc in <BlocBase<dynamic>>[counter, ...boxes, untraced]) {
      observer.onCreate(bloc);
    }
    observer.onClose(untraced);

    expect(observer.liveBlocCounts(), {
      'count': 3,
      'box': 2,
      'counterCubit': 1,
    });
    for (final bloc in <BlocBase<dynamic>>[counter, ...boxes, untraced]) {
      bloc.close();
    }
  });

  test('counts at most 31 types, the newest', () {
    final blocs = [for (var i = 0; i < 32; i++) _CounterCubit()];
    for (final bloc in blocs) {
      observer.onCreate(bloc);
    }
    observer.onCreate(_Untraced());

    final counts = observer.liveBlocCounts();
    expect(counts['count'], 33);
    expect(counts, hasLength(3));
    for (final bloc in blocs) {
      bloc.close();
    }
  });

  test('without a client it goes to the attached one', () {
    Noticebird.attach(reporter);
    addTearDown(Noticebird.detach);
    final cubit = _CounterCubit();
    addTearDown(cubit.close);

    NoticebirdBlocObserver().onChange(
      cubit,
      const Change(currentState: 0, nextState: 1),
    );

    expect(reporter.recentBreadcrumbs, hasLength(1));
  });

  test('a describe that throws costs the bloc nothing', () {
    final cubit = _CounterCubit();
    addTearDown(cubit.close);

    _ThrowingObserver(
      reporter,
    ).onChange(cubit, const Change(currentState: 0, nextState: 1));

    expect(reporter.recentBreadcrumbs, isEmpty);
  });
}

final class _Untraced extends Cubit<int> implements UntracedBloc {
  _Untraced() : super(0);
}

/// A bloc marked by the host's own marker, not the SDK's.
abstract interface class _HostUntraced {}

final class _OwnUntraced extends Cubit<int> implements _HostUntraced {
  _OwnUntraced() : super(0);
}

final class _OwnMarkerObserver extends NoticebirdBlocObserver {
  _OwnMarkerObserver(NoticebirdClient client) : super(client: client);

  @override
  bool traces(BlocBase<dynamic> bloc) =>
      super.traces(bloc) && bloc is! _HostUntraced;
}

final class _ThrowingTracesObserver extends NoticebirdBlocObserver {
  _ThrowingTracesObserver(NoticebirdClient client) : super(client: client);

  @override
  bool traces(BlocBase<dynamic> bloc) => throw StateError('traces');
}

final class _Box<T> extends Cubit<T?> {
  _Box() : super(null);
}

final class _ReportedElsewhere implements Exception {
  const _ReportedElsewhere();
}

final class _ThrowingObserver extends NoticebirdBlocObserver {
  _ThrowingObserver(NoticebirdClient client) : super(client: client);

  @override
  String describeState(Object? state) => throw StateError('describe');
}
