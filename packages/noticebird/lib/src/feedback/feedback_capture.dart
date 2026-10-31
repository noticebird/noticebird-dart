import 'package:noticebird_protocol/feedback.dart';
import 'package:noticebird_protocol/noticebird_protocol.dart';

import 'feedback_transport.dart';

/// What a feedback report is about, taken when the host's feedback sheet
/// opens, before the sheet's own route and state exist:
/// `NoticebirdClient.feedbackMoment`, passed to `captureFeedback` as its
/// `moment`. Without one, `captureFeedback` takes it when it is called.
///
/// The trail is not part of it: a report carries the breadcrumbs up to its
/// capture, and a sheet keeps its own typing out of them (the bloc observer
/// of `noticebird_flutter` leaves an `UntracedBloc` out).
final class FeedbackMoment {
  const FeedbackMoment({
    required this.takenAt,
    this.routeTemplate,
    this.contextDiagnostics = const {},
    this.diagnostics = const {},
  });

  /// When it was taken; a report sends it as its diagnostics' note
  /// (`noticebird.moment_taken_at`).
  final DateTime takenAt;

  /// The screen the report is about, as a template (`/lists/:listId`).
  final String? routeTemplate;

  /// The groups `FeedbackConfig.contextDiagnostics` answered then, as they
  /// were: sent before [diagnostics], whose groups of the same name are
  /// left out.
  final Map<String, Map<String, Object?>> contextDiagnostics;

  /// The host's own diagnostics groups, as it took them then.
  final Map<String, Map<String, Object?>> diagnostics;
}

/// The reporter's contact address, `captureFeedback`'s `contactEmail`.
abstract final class FeedbackContact {
  /// Whether [email] is an address a report accepts, by the report's own
  /// rule for `contact.email` ([FeedbackReport.checkContactEmail]): a form
  /// can check it before it captures.
  static bool isValid(String email) {
    try {
      FeedbackReport.checkContactEmail(email);
      return true;
    } on ProtocolException {
      return false;
    }
  }
}

/// What became of a report passed to `captureFeedback`.
sealed class FeedbackOutcome {
  const FeedbackOutcome();
}

/// The platform has the report.
final class FeedbackDelivered extends FeedbackOutcome {
  const FeedbackDelivered({this.ticket, required this.verified});

  /// The ticket the report was filed under, to show the reporter; `null`
  /// when the answer named none, as when a `report_conflict` after a slot
  /// conflict delivers the report without a ticket.
  final FeedbackTicket? ticket;

  /// Whether the platform verified the report's reporter assertion; `false`
  /// where the answer does not say.
  final bool verified;

  @override
  bool operator ==(Object other) =>
      other is FeedbackDelivered &&
      other.ticket == ticket &&
      other.verified == verified;

  @override
  int get hashCode => Object.hash(ticket, verified);

  @override
  String toString() =>
      'FeedbackDelivered(ticket: $ticket, verified: $verified)';
}

/// The report did not get through yet and is kept in the offline store, to
/// be sent on a later `NoticebirdClient.flush`; its end comes on
/// `FeedbackConfig.onSettled`.
final class FeedbackQueued extends FeedbackOutcome {
  const FeedbackQueued(this.reportId);

  final String reportId;

  @override
  bool operator ==(Object other) =>
      other is FeedbackQueued && other.reportId == reportId;

  @override
  int get hashCode => reportId.hashCode;

  @override
  String toString() => 'FeedbackQueued($reportId)';
}

/// The client has no `NoticebirdConfig.feedback`: nothing was sent.
final class FeedbackDisabled extends FeedbackOutcome {
  const FeedbackDisabled();

  @override
  bool operator ==(Object other) => other is FeedbackDisabled;

  @override
  int get hashCode => (FeedbackDisabled).hashCode;

  @override
  String toString() => 'FeedbackDisabled()';
}

/// The report is not delivered, and will not be: [reason] says why.
final class FeedbackRejected extends FeedbackOutcome {
  const FeedbackRejected(this.reason, {this.path, this.code});

  final FeedbackRejection reason;

  /// The JSON path of the value at fault, such as `$.contact.email`, where
  /// one is.
  final String? path;

  /// The platform's error, such as `invalid_report`, for a refusal it sent.
  final String? code;

  @override
  bool operator ==(Object other) =>
      other is FeedbackRejected &&
      other.reason == reason &&
      other.path == path &&
      other.code == code;

  @override
  int get hashCode => Object.hash(reason, path, code);

  @override
  String toString() =>
      'FeedbackRejected(${reason.name}, path: $path, code: $code)';
}

/// The end of a report the client kept in its offline store: delivered
/// from the store, or rejected for good, as
/// `FeedbackConfig.onSettled` is told it.
final class FeedbackSettled {
  const FeedbackSettled(this.reportId, this.outcome);

  /// The report's id, as [FeedbackQueued.reportId] named it.
  final String reportId;

  /// [FeedbackDelivered] or [FeedbackRejected].
  final FeedbackOutcome outcome;

  @override
  bool operator ==(Object other) =>
      other is FeedbackSettled &&
      other.reportId == reportId &&
      other.outcome == outcome;

  @override
  int get hashCode => Object.hash(reportId, outcome);

  @override
  String toString() => 'FeedbackSettled($reportId, $outcome)';
}

/// Why a report was rejected.
enum FeedbackRejection {
  /// A value the host passed breaks the report's rules, at the
  /// [FeedbackRejected.path]: a contact address, a user context or a related
  /// event id the report refuses, or a message left empty. Nothing was sent. A debug build
  /// throws an [ArgumentError] instead, to show the mistake. A value the
  /// client fills in itself is never this: it is left out, or the report
  /// [failed].
  invalidInput,

  /// `FeedbackConfig.requireVerified` is set, and the report has no reporter
  /// assertion or the platform refused it.
  unverified,

  /// The project is `regulatedStrict` and refused the report's `user` or
  /// `userContext`: the client's config is not `regulatedStrict`, and
  /// should be.
  strictProject,

  /// The platform refused the report's `createdAt`: the device's clock is
  /// more than 5 minutes ahead, or the report is older than 7 days.
  clock,

  /// The project does not accept feedback, or no screenshots: the
  /// platform answered `feedback_disabled` or `attachments_disabled`.
  notAccepted,

  /// The report did not get through for now, and the client could not keep
  /// it for later: it has no `FeedbackConfig.offlineStore`, or the store
  /// failed.
  noStore,

  /// The report waited in the offline store, and was removed unsent to keep
  /// the store within its bounds: newer reports took its place.
  evicted,

  /// The report waited in the offline store for
  /// [FeedbackReport.maxAge] without getting through, and is removed
  /// unsent: the platform would refuse it.
  expired,

  /// Any other refusal of the platform: [FeedbackRejected.code] and
  /// [FeedbackRejected.path] say which.
  refused,

  /// The client failed to build or deliver the report: a fault of the
  /// client or its config, such as a session id factory that throws or
  /// answers an id the report refuses, app or platform metadata the report
  /// refuses, or a transport that answers what its request cannot have.
  /// Never thrown in a debug build.
  failed,
}
