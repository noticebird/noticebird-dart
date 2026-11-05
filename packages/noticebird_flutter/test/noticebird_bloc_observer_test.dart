import 'package:bloc/bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noticebird_flutter/noticebird_flutter.dart';
import 'package:noticebird_flutter/src/bloc_names.dart';
import 'package:noticebird_flutter/testing.dart';

final class _CounterCubit extends Cubit<int> {
  _CounterCubit() : super(0);

  void increment() => emit(state + 1);

  void fail() => addError(StateError('boom'), StackTrace.current);
}

sealed class _CounterEvent {}

final class _Increment extends _CounterEvent {}

/// A freezed union's case, as its generated code names it.
// ignore: camel_case_types
final class _$ReauthenticateImpl extends _CounterEvent {}

final class _CounterBloc extends Bloc<_CounterEvent, int> {
  _CounterBloc() : super(0);
}

final class _Box<T> extends Cubit<T?> {
  _Box() : super(null);
}

enum _Status { loading, loaded }

final class _Profile {
  _Profile(this.status, this.records, this.spaceId, this.query);

  final _Status status;
  final List<int> records;
  final String spaceId;
  final String query;
}

final class _ProfileCubit extends Cubit<_Profile?> {
  _ProfileCubit() : super(null);
}

final class _Open extends _CounterEvent {
  _Open(this.spaceId);

  final String spaceId;
}

/// A freezed case holding what a user typed, whose text shows it.
// ignore: camel_case_types
final class _$ReauthenticateWithPasswordImpl extends _CounterEvent {
  _$ReauthenticateWithPasswordImpl(this.password);

  final String password;

  @override
  String toString() => 'Reauthenticate(password: $password)';
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

  test('a change is a step of the bloc: its name changed, and no facts', () {
    final cubit = _CounterCubit();
    addTearDown(cubit.close);
    observer.onChange(cubit, const Change(currentState: 0, nextState: 1));

    final breadcrumb = reporter.recentBreadcrumbs.single;
    expect(breadcrumb.message, 'CounterCubit changed');
    expect(breadcrumb.action, 'counterCubit.change');
    expect(breadcrumb.category, 'bloc');
    expect(breadcrumb.level, BreadcrumbLevel.info);
    expect(breadcrumb.data, isEmpty);
  });

  test('an event is a step of the bloc: its name got the event', () {
    final bloc = _CounterBloc();
    addTearDown(bloc.close);
    observer
      ..onEvent(bloc, _Increment())
      ..onEvent(bloc, _$ReauthenticateImpl());

    expect(
      [for (final crumb in reporter.recentBreadcrumbs) crumb.message],
      ['CounterBloc got Increment', 'CounterBloc got Reauthenticate'],
    );
    expect(
      [for (final crumb in reporter.recentBreadcrumbs) crumb.action],
      ['counterBloc.event', 'counterBloc.event'],
    );
  });

  test('a generic bloc is named without its type arguments', () {
    final box = _Box<Map<String, int>>();
    addTearDown(box.close);
    observer.onChange(box, const Change(currentState: null, nextState: null));

    expect(reporter.recentBreadcrumbs.single.message, 'Box changed');
    expect(reporter.recentBreadcrumbs.single.action, 'box.change');
  });

  group('the name rule', () {
    for (final (type, message, action) in [
      ('ProfileBloc', 'ProfileBloc', 'profileBloc'),
      ('_ProfileBloc', 'ProfileBloc', 'profileBloc'),
      ('Foo<Bar>', 'Foo', 'foo'),
      ('_Box<Map<String, int>>', 'Box', 'box'),
      (r'_$ReauthenticateImpl', 'Reauthenticate', 'reauthenticate'),
      ('minified:aB', 'minified_aB', 'minified_aB'),
      ('1Bloc', '1Bloc', 'bloc1Bloc'),
      ('_', '', 'bloc'),
    ]) {
      test('$type is $message, its action $action', () {
        expect(BreadcrumbFields.typeName(type), message);
        expect(blocActionName(type), action);
        for (final step in ['change', 'event']) {
          expect(
            TypedBreadcrumb.actionPattern.hasMatch('$action.$step'),
            isTrue,
          );
        }
      });
    }
  });

  test('the step reaches an event as the protocol takes it', () async {
    final bloc = _CounterBloc();
    addTearDown(bloc.close);
    observer.onEvent(bloc, _$ReauthenticateImpl());

    await reporter.captureException(StateError('boom'), StackTrace.empty);

    final step = (transport.events.single['breadcrumbs']! as List).single;
    expect(step, {
      'at': (step as Map)['at'],
      'message': 'CounterBloc got Reauthenticate',
      'action': 'counterBloc.event',
      'category': 'bloc',
      'level': 'info',
    });
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

  group('the tables', () {
    late NoticebirdBlocObserver described;

    setUp(() {
      described = NoticebirdBlocObserver(
        client: reporter,
        stateFields: BreadcrumbFields([
          BreadcrumbField<_Profile>.literal('status', (s) => s.status),
          BreadcrumbField<_Profile>.count('records', (s) => s.records),
          BreadcrumbField<_Profile>.id('spaceId', (s) => s.spaceId),
          BreadcrumbField<_Profile>.presence('query', (s) => s.query),
        ]),
        eventFields: BreadcrumbFields([
          BreadcrumbField.id('spaceId', (s) => s.spaceId),
          BreadcrumbField.presence('password', (s) => s.password),
        ]),
      );
    });

    test('a change step\'s data is the next state, by the state table', () {
      final cubit = _ProfileCubit();
      addTearDown(cubit.close);
      described.onChange(
        cubit,
        Change(
          currentState: _Profile(_Status.loading, const [], 'space-a', ''),
          nextState: _Profile(_Status.loaded, const [1, 2], 'space-a', 'Al'),
        ),
      );

      final step = reporter.recentBreadcrumbs.single;
      expect(step.message, 'ProfileCubit changed');
      expect(step.data, {
        'status': 'loaded',
        'records.count': 2,
        'spaceId': 'id1',
        'query': true,
      });
    });

    test('an event step\'s data is the event, by the event table; a '
        'password is its presence only', () {
      final bloc = _CounterBloc();
      addTearDown(bloc.close);
      described.onEvent(bloc, _$ReauthenticateWithPasswordImpl('hunter2'));

      final step = reporter.recentBreadcrumbs.single;
      expect(step.message, 'CounterBloc got ReauthenticateWithPassword');
      expect(step.data, {'password': true});
      expect('${step.data}', isNot(contains('hunter2')));
    });

    test('an id reads as one alias in a state and an event of the run', () {
      final cubit = _ProfileCubit();
      final bloc = _CounterBloc();
      addTearDown(cubit.close);
      addTearDown(bloc.close);
      described
        ..onChange(
          cubit,
          Change(
            currentState: _Profile(_Status.loading, const [], 'space-a', ''),
            nextState: _Profile(_Status.loaded, const [], 'space-b', ''),
          ),
        )
        ..onEvent(bloc, _Open('space-b'));

      expect(
        [for (final step in reporter.recentBreadcrumbs) step.data['spaceId']],
        ['id2', 'id2'],
        reason: 'space-a, the state before, was seen first',
      );
    });

    test('a change that describes as the state before it leaves no step', () {
      final cubit = _ProfileCubit();
      addTearDown(cubit.close);
      described.onChange(
        cubit,
        Change(
          currentState: _Profile(_Status.loaded, const [1], 'space-a', 'x'),
          nextState: _Profile(_Status.loaded, const [2], 'space-a', 'y'),
        ),
      );

      expect(reporter.recentBreadcrumbs, isEmpty);
    });

    test('a state no field describes still leaves its step, by name', () {
      final cubit = _CounterCubit();
      addTearDown(cubit.close);
      described.onChange(cubit, const Change(currentState: 0, nextState: 1));

      expect(reporter.recentBreadcrumbs.single.message, 'CounterCubit changed');
      expect(reporter.recentBreadcrumbs.single.data, isEmpty);
    });

    test('a reader that throws costs the step nothing but its field', () {
      final throwing = NoticebirdBlocObserver(
        client: reporter,
        eventFields: BreadcrumbFields([
          BreadcrumbField.literal('fails', (s) => throw StateError('boom')),
          BreadcrumbField.type('event', (s) => s),
        ]),
      );
      final bloc = _CounterBloc();
      addTearDown(bloc.close);
      throwing.onEvent(bloc, _Increment());

      expect(reporter.recentBreadcrumbs.single.data, {'event': 'Increment'});
    });

    test('the step reaches an event with its data', () async {
      final cubit = _ProfileCubit();
      addTearDown(cubit.close);
      described.onChange(
        cubit,
        Change(
          currentState: _Profile(_Status.loading, const [], 'space-a', ''),
          nextState: _Profile(_Status.loaded, const [1], 'space-a', ''),
        ),
      );

      await reporter.captureException(StateError('boom'), StackTrace.empty);

      final step = (transport.events.single['breadcrumbs']! as List).single;
      expect((step as Map)['data'], {
        'status': 'loaded',
        'records.count': 1,
        'spaceId': 'id1',
        'query': false,
      });
    });
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
      [for (final crumb in reporter.recentBreadcrumbs) crumb.action],
      ['counterCubit.change'],
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

final class _ReportedElsewhere implements Exception {
  const _ReportedElsewhere();
}
