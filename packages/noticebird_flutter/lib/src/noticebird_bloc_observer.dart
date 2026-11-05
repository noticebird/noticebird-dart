import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:flutter/foundation.dart';
import 'package:noticebird/feedback.dart';
import 'package:noticebird/noticebird.dart';

import 'bloc_error_report.dart';
import 'bloc_names.dart';

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
/// A step leaves a breadcrumb in category `bloc`: a change as
/// `ProfileBloc changed` with the action `profileBloc.change`, an event as
/// `ProfileBloc got Reauthenticate` with the action `profileBloc.event`.
/// The message is the sentence, never the facts; it names the types only,
/// since a breadcrumb leaves the device. Several live blocs of one type
/// share its action. A name is the runtime type's, without type arguments
/// and leading underscores, a freezed `_$…Impl` reduced to its middle, and
/// every character outside `[A-Za-z0-9_]` (a minified web name's `:`) a
/// `_` ([BreadcrumbFields.typeName]); in the action it starts in lower
/// case, with `bloc` in front of a name that does not start with a letter.
///
/// The facts of a step are its data, from the app's tables: a change's
/// [stateFields] describe the next state (`status: loaded`,
/// `collections.count: 6`), an event's [eventFields] the event. Without a
/// table a step has no data. A change whose next state describes as the
/// state before it — an emit that changed nothing the trail can show —
/// leaves no step; one whose states describe as nothing at all (a state the
/// table has no field for) still does, by its name.
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
  NoticebirdBlocObserver({
    NoticebirdClient? client,
    DateTime Function()? clock,
    this.stateFields,
    this.eventFields,
  }) : _client = client,
       _clock = clock ?? DateTime.now;

  /// What a change step says of the next state, as its data; null for no
  /// data.
  final BreadcrumbFields? stateFields;

  /// What an event step says of the event, as its data; null for no data.
  final BreadcrumbFields? eventFields;

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
  /// the name the type's actions start with (`collectionRecordsBloc`), for
  /// the newest [maxBlocTypes] types: the `blocs` group a feedback report
  /// carries.
  Map<String, Object?> liveBlocCounts() {
    final live = liveBlocs;
    final perType = <String, int>{};
    for (final bloc in live.reversed) {
      final name = blocActionName('${bloc.runtimeType}');
      if (name == 'count') continue;
      if (!perType.containsKey(name) && perType.length >= maxBlocTypes) {
        continue;
      }
      perType[name] = (perType[name] ?? 0) + 1;
    }
    return {'count': live.length, ...perType};
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
    _note(
      bloc,
      'event',
      (name) =>
          '$name got ${BreadcrumbFields.typeName('${event.runtimeType}')}',
      (ids) => eventFields?.describe(event, ids: ids) ?? const {},
    );
  }

  @override
  void onChange(BlocBase<dynamic> bloc, Change<dynamic> change) {
    super.onChange(bloc, change);
    _note(bloc, 'change', (name) => '$name changed', (ids) {
      final fields = stateFields;
      if (fields == null) return const {};
      final before = fields.describe(change.currentState, ids: ids);
      final after = fields.describe(change.nextState, ids: ids);
      return after.isNotEmpty && mapEquals(after, before) ? null : after;
    });
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

  /// Leaves the breadcrumb of a step of a bloc [traces] takes, its action
  /// the bloc's name and [step], its message what [message] makes of the
  /// bloc's name, its data what [data] describes with the client's id
  /// aliases — no breadcrumb when [data] answers null; [traces] is asked
  /// inside the guard, since a subclass's may throw.
  void _note(
    BlocBase<dynamic> bloc,
    String step,
    String Function(String name) message,
    Map<String, Object>? Function(BreadcrumbIds ids) data,
  ) {
    try {
      final reporter = _reporter;
      if (reporter == null || !traces(bloc)) return;
      final facts = data(reporter.breadcrumbIds);
      if (facts == null) return;
      final type = '${bloc.runtimeType}';
      reporter.addBreadcrumb(
        message(BreadcrumbFields.typeName(type)),
        action: '${blocActionName(type)}.$step',
        category: 'bloc',
        level: BreadcrumbLevel.info,
        data: facts,
        at: _clock(),
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
