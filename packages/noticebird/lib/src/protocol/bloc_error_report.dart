import 'package:bloc/bloc.dart';
import 'package:noticebird_protocol/noticebird_protocol.dart';

import 'noticebird_client.dart';

/// An error a bloc hands to `addError`, with how it is to be reported.
///
/// A bloc observer reports `addError(error, stack)` as handled, at
/// [CrashSeverity.error], tagged with the bloc. A bloc that knows more about a
/// failure — it is expected offline and recovered from, which operation
/// failed, the counts that explain it — wraps the error instead of capturing
/// it beside the observer:
///
/// ```dart
/// } catch (error, stack) {
///   addError(
///     BlocErrorReport(
///       error,
///       severity: CrashSeverity.warning,
///       tags: const {AllowedTag.operation: 'sync.pull'},
///     ),
///     stack,
///   );
/// }
/// ```
///
/// The observer captures [cause], not the wrapper, so the event groups and
/// reads as the error itself, and the client's capture filter
/// ([NoticebirdConfig.shouldCapture]) sees [cause]: a wrapped error the host
/// reports elsewhere is still reported once. The component tag is always the
/// bloc's type; [tags] add to it.
final class BlocErrorReport {
  const BlocErrorReport(
    this.cause, {
    this.severity = CrashSeverity.error,
    this.tags = const {},
    this.extra = const {},
  });

  final Object cause;
  final CrashSeverity severity;
  final Map<AllowedTag, TagScalar> tags;
  final Map<String, Object?> extra;

  /// The cause's, so a log of the bloc's errors reads as the error itself.
  @override
  String toString() => cause.toString();
}

/// The capture every bloc observer makes of a bloc's `addError`.
extension BlocErrorCapture on NoticebirdClient {
  /// Captures [error] from [bloc] as handled — the bloc caught it into a state
  /// instead of crashing the app — tagged with the bloc's type, in the shape a
  /// [BlocErrorReport] gives it.
  Future<CaptureResult> captureBlocError(
    BlocBase<dynamic> bloc,
    Object error,
    StackTrace stackTrace,
  ) {
    final report = error is BlocErrorReport ? error : BlocErrorReport(error);
    return captureException(
      report.cause,
      stackTrace,
      severity: report.severity,
      handled: true,
      tags: {...report.tags, AllowedTag.component: bloc.runtimeType.toString()},
      extra: report.extra,
    );
  }
}
