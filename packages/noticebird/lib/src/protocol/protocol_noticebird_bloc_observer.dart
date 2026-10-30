import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:noticebird_protocol/noticebird_protocol.dart';

import 'bloc_error_report.dart';
import 'noticebird_client.dart';
import 'noticebird_config.dart';

/// Records bloc events and state changes as breadcrumbs and captures bloc
/// errors, in the shape a [BlocErrorReport] gives them.
///
/// An error is captured through the client's filter
/// ([NoticebirdConfig.shouldCapture]), like every other channel, so an
/// error the host reports elsewhere is not reported here again.
final class ProtocolNoticebirdBlocObserver extends BlocObserver {
  ProtocolNoticebirdBlocObserver(this.reporter, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final NoticebirdClient reporter;
  final DateTime Function() _clock;

  @override
  void onEvent(Bloc<dynamic, dynamic> bloc, Object? event) {
    super.onEvent(bloc, event);
    reporter.addBreadcrumb(
      TypedBreadcrumb(
        occurredAt: _clock().toUtc(),
        category: BreadcrumbCategory.bloc,
        action: 'bloc.event',
        data: {
          AllowedTag.component: bloc.runtimeType.toString(),
          AllowedTag.operation: event.runtimeType.toString(),
        },
      ),
    );
  }

  @override
  void onChange(BlocBase<dynamic> bloc, Change<dynamic> change) {
    super.onChange(bloc, change);
    reporter.addBreadcrumb(
      TypedBreadcrumb(
        occurredAt: _clock().toUtc(),
        category: BreadcrumbCategory.bloc,
        action: 'bloc.change',
        data: {
          AllowedTag.component: bloc.runtimeType.toString(),
          AllowedTag.operation: change.nextState.runtimeType.toString(),
        },
      ),
    );
  }

  @override
  void onError(BlocBase<dynamic> bloc, Object error, StackTrace stackTrace) {
    super.onError(bloc, error, stackTrace);
    unawaited(reporter.captureBlocError(bloc, error, stackTrace));
  }
}
