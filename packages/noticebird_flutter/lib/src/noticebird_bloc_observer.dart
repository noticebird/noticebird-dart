import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:flutter/foundation.dart';
import 'package:noticebird/feedback.dart';
import 'package:noticebird/noticebird.dart';

import 'bloc_error_report.dart';

/// Records bloc events and state changes as breadcrumbs, captures bloc
/// errors in the shape a [BlocErrorReport] gives them, and knows which blocs
/// are live, for a feedback report's `blocs` diagnostics group
/// ([liveBlocCounts]).
///
/// `NoticebirdFlutter.start` makes one and sets it as `Bloc.observer`,
/// together with the observer it found (bloc's `MultiBlocObserver`). A host
/// that sets an observer of its own afterwards keeps this one the same way:
/// `MultiBlocObserver(observers: [noticebird.blocObserver, mine])`.
///
/// A breadcrumb names the bloc as its component and, as its operation, what
/// [describeEvent] and [describeChange] make of the step: the runtime type
/// only, since a breadcrumb leaves the device. An observer that says more
/// overrides those two.
///
/// A bloc [traces] declines leaves no breadcrumb — by default one that is an
/// [UntracedBloc]; its errors are still captured, and it is still counted. A
/// host with a marker of its own overrides [traces].
///
/// An error is captured through the client's filter
/// ([NoticebirdConfig.shouldCapture]), like every other channel, so an error
/// the host reports elsewhere is not reported here again. It goes to
/// [client], or the client attached to `Noticebird` when there is none.
class NoticebirdBlocObserver extends BlocObserver {
  NoticebirdBlocObserver({NoticebirdClient? client, DateTime Function()? clock})
    : _client = client,
      _clock = clock ?? DateTime.now;

  final NoticebirdClient? _client;
  final DateTime Function() _clock;

  NoticebirdClient? get _reporter => _client ?? Noticebird.instance;

  /// The most bloc types [liveBlocCounts] counts beside its total: a
  /// diagnostics group holds at most [FeedbackReport.maxDiagnosticValues]
  /// values. The newest types are the ones counted.
  static const maxBlocTypes = FeedbackReport.maxDiagnosticValues - 1;

  /// The live blocs, oldest first. Held weakly: a bloc nobody closed is not
  /// kept alive by the observer that lists it.
  final List<WeakReference<BlocBase<dynamic>>> _live = [];

  /// The blocs created under this observer and not closed yet, oldest first.
  List<BlocBase<dynamic>> get liveBlocs => [
    for (final ref in _live)
      if (ref.target case final bloc?) bloc,
  ];

  /// How many blocs are live (`count`), and how many of each type, under
  /// the type's name with its first letter in lower case and without type
  /// arguments or leading underscores (`collectionRecordsBloc`), for the
  /// newest [maxBlocTypes] types: the `blocs` group a feedback report
  /// carries.
  Map<String, Object?> liveBlocCounts() {
    final live = liveBlocs;
    final perType = <String, int>{};
    for (final bloc in live.reversed) {
      final name = _typeName(bloc.runtimeType);
      if (name == null) continue;
      if (!perType.containsKey(name) && perType.length >= maxBlocTypes) {
        continue;
      }
      perType[name] = (perType[name] ?? 0) + 1;
    }
    return {'count': live.length, ...perType};
  }

  static String? _typeName(Type type) {
    var name = '$type';
    final generic = name.indexOf('<');
    if (generic >= 0) name = name.substring(0, generic);
    name = name.replaceFirst(RegExp('^_+'), '');
    if (name.isEmpty) return null;
    name = '${name[0].toLowerCase()}${name.substring(1)}';
    return name == 'count' ? null : name;
  }

  @override
  void onCreate(BlocBase<dynamic> bloc) {
    super.onCreate(bloc);
    _live
      ..removeWhere((ref) => ref.target == null)
      ..add(WeakReference(bloc));
  }

  @override
  void onEvent(Bloc<dynamic, dynamic> bloc, Object? event) {
    super.onEvent(bloc, event);
    _note(bloc, 'bloc.event', () => describeEvent(event));
  }

  @override
  void onChange(BlocBase<dynamic> bloc, Change<dynamic> change) {
    super.onChange(bloc, change);
    _note(bloc, 'bloc.change', () => describeChange(change));
  }

  @override
  void onError(BlocBase<dynamic> bloc, Object error, StackTrace stackTrace) {
    super.onError(bloc, error, stackTrace);
    final reporter = _reporter;
    if (reporter != null) {
      unawaited(reporter.captureBlocError(bloc, error, stackTrace));
    }
  }

  @override
  void onClose(BlocBase<dynamic> bloc) {
    super.onClose(bloc);
    _live.removeWhere((ref) {
      final target = ref.target;
      return target == null || identical(target, bloc);
    });
  }

  /// Whether the events and changes of [bloc] leave a breadcrumb: by default
  /// every bloc but an [UntracedBloc]. A host whose own marker says which
  /// blocs stay out of the trail overrides it:
  ///
  /// ```dart
  /// @override
  /// bool traces(BlocBase<dynamic> bloc) =>
  ///     super.traces(bloc) && bloc is! MyUntracedBloc;
  /// ```
  ///
  /// It decides the breadcrumbs only: the errors of a bloc it declines are
  /// still captured, and the bloc is still counted ([liveBlocCounts]).
  @protected
  bool traces(BlocBase<dynamic> bloc) => bloc is! UntracedBloc;

  /// The operation of an event's breadcrumb: the event's runtime type.
  @protected
  String describeEvent(Object? event) => event.runtimeType.toString();

  /// The operation of a change's breadcrumb: [describeState] of the next
  /// state.
  @protected
  String describeChange(Change<dynamic> change) =>
      describeState(change.nextState);

  /// A state as a breadcrumb names it: its runtime type.
  @protected
  String describeState(Object? state) => state.runtimeType.toString();

  /// Leaves the breadcrumb of a step of a bloc [traces] takes; [traces]
  /// and [operation] are asked inside the guard, since a subclass's may
  /// throw.
  void _note(
    BlocBase<dynamic> bloc,
    String action,
    String Function() operation,
  ) {
    try {
      if (!traces(bloc)) return;
      _reporter?.addBreadcrumb(
        TypedBreadcrumb(
          occurredAt: _clock().toUtc(),
          category: BreadcrumbCategory.bloc,
          action: action,
          data: {
            AllowedTag.component: bloc.runtimeType.toString(),
            AllowedTag.operation: operation(),
          },
        ),
      );
    } catch (_) {
      // Reporting must never affect the host application.
    }
  }
}

/// A bloc whose events and changes leave no breadcrumb
/// ([NoticebirdBlocObserver]).
///
/// For a bloc that changes with every keystroke of a text the user types —
/// a feedback sheet's, whose report carries the trail: a trail holds the
/// newest breadcrumbs only, and a message typed into it would push out the
/// steps that led to the report. Its errors are still captured.
abstract interface class UntracedBloc {}
