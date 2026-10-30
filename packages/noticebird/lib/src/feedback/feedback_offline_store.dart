import 'dart:typed_data';

import 'package:noticebird_protocol/feedback.dart';

import 'feedback_sender.dart';

/// Where the client keeps a feedback report that did not get through yet,
/// to send it on a later `NoticebirdClient.flush`, in this run or a later
/// one: `FeedbackConfig.offlineStore`.
///
/// The client keeps the store within its bounds: at most [maxReports]
/// reports and [maxBytes] of report and screenshot bytes, the oldest
/// report evicted first, and a report older than [FeedbackReport.maxAge]
/// removed, since the platform would refuse it. It calls one method at a
/// time, so a store needs no locking of its own; give each client a store
/// of its own.
///
/// `FileFeedbackOfflineStore` keeps reports in a directory, unencrypted. A
/// store of the host's own keeps each [PendingFeedback] as
/// [PendingFeedback.toJson] writes it, and its [PendingFeedback.attachment]
/// apart: [pending] reads the reports back with [PendingFeedback.fromJson]
/// without their screenshots, and the client asks for a report's
/// screenshot with [attachment] only when it sends the report, and checks
/// the bytes against the report: one whose screenshot is missing, or of
/// another length or SHA-256, is removed as `FeedbackRejection.failed`.
/// Under `CrashPrivacyProfile.regulatedStrict` the store must be
/// [isEncrypted].
///
/// A store may throw: the client keeps the report where it was, and a
/// report it could not keep is `FeedbackRejection.noStore`.
abstract interface class FeedbackOfflineStore {
  /// Whether the store encrypts what it keeps at rest.
  bool get isEncrypted;

  /// Keeps [report] and its [PendingFeedback.attachment], in place of a
  /// report with the same [PendingFeedback.reportId].
  Future<void> put(PendingFeedback report);

  /// The reports kept, in any order, each read with
  /// [PendingFeedback.fromJson], without its screenshot.
  Future<List<PendingFeedback>> pending();

  /// The screenshot [put] kept with the report [reportId], or `null` when
  /// it kept none.
  Future<Uint8List?> attachment(String reportId);

  /// Forgets the report [reportId] and its screenshot; one the store does
  /// not hold is no error.
  Future<void> remove(String reportId);

  /// The most reports the client keeps.
  static const maxReports = 10;

  /// The most bytes the client keeps, of the reports' JSON and their
  /// screenshots together: 20 MiB.
  static const maxBytes = 20 * 1024 * 1024;

  /// The wait before the first retry of a report the platform gave no
  /// `Retry-After` for. Each later retry waits twice as long, up to
  /// [maxRetryDelay], less up to a quarter at random, so that clients
  /// that went offline together do not come back together.
  static const firstRetryDelay = Duration(seconds: 30);

  /// The longest wait between two retries without a `Retry-After`.
  static const maxRetryDelay = Duration(hours: 6);
}

/// A feedback report kept in a [FeedbackOfflineStore]: the report as it is
/// submitted, and where its delivery stands, so a later run goes on exactly
/// where this one stopped.
final class PendingFeedback {
  PendingFeedback._(FeedbackSendState state, {required this.nextAttemptAt})
    : _state = state,
      reportId = state.report.reportId,
      createdAt = state.report.createdAt;

  /// The report [toJson] wrote, without its screenshot.
  ///
  /// Throws a [FormatException] for a [json] this class did not write.
  factory PendingFeedback.fromJson(Map<String, Object?> json) {
    try {
      if (json['format'] != _format) {
        throw const FormatException('Unknown pending feedback format');
      }
      final reportJson = json['report'] as String;
      return PendingFeedback._(
        FeedbackSendState(
          reportJson: reportJson,
          next: FeedbackSendStep.values.byName(json['next'] as String),
          attempts: json['attempts'] as int,
        ),
        nextAttemptAt: DateTime.parse(json['nextAttemptAt'] as String).toUtc(),
      );
    } on FormatException {
      rethrow;
    } catch (error) {
      throw FormatException('Not a pending feedback report: $error');
    }
  }

  static const _format = 1;

  final FeedbackSendState _state;

  /// The report's id, from [reportJson].
  final String reportId;

  /// When the report was captured, from [reportJson]: the client evicts the
  /// oldest first, and drops a report past [FeedbackReport.maxAge].
  final DateTime createdAt;

  /// The report as it is submitted, `FeedbackReport.toJsonString`'s: with
  /// the reporter assertion it was captured with, or without it once the
  /// platform refused it.
  String get reportJson => _state.reportJson;

  /// The bytes of the report's screenshot, for [FeedbackOfflineStore.put]
  /// to keep apart from [toJson]; `null` for a report without one, and for
  /// a report read back with [PendingFeedback.fromJson].
  Uint8List? get attachment => _state.attachment;

  /// How many deliveries the report went through without an end.
  int get attempts => _state.attempts;

  /// The earliest time the client sends the report again.
  final DateTime nextAttemptAt;

  /// The report and its delivery's state, without [attachment]: a stable
  /// form of plain JSON values for a store to keep.
  Map<String, Object?> toJson() => {
    'format': _format,
    'report': _state.reportJson,
    'next': _state.next.name,
    'attempts': _state.attempts,
    'nextAttemptAt': nextAttemptAt.toUtc().toIso8601String(),
  };
}

/// [state], postponed, as the store keeps it until [nextAttemptAt].
PendingFeedback pendingFeedback(
  FeedbackSendState state, {
  required DateTime nextAttemptAt,
}) => PendingFeedback._(state, nextAttemptAt: nextAttemptAt.toUtc());

/// The screenshot [pending] names, `null` for a report without one.
FeedbackAttachmentRef? attachmentOf(PendingFeedback pending) =>
    pending._state.report.attachment;

/// The state the delivery of [pending] goes on from, with [attachment], the
/// bytes of its screenshot.
FeedbackSendState sendStateOf(
  PendingFeedback pending, {
  Uint8List? attachment,
}) => FeedbackSendState(
  reportJson: pending._state.reportJson,
  attachment: attachment,
  next: pending._state.next,
  attempts: pending._state.attempts,
);
