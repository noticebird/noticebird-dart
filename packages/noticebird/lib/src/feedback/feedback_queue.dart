import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:noticebird_protocol/feedback.dart';

import 'feedback_capture.dart';
import 'feedback_offline_store.dart';
import 'feedback_sender.dart';

/// The schedule of the reports a [FeedbackOfflineStore] keeps: when a
/// postponed report is sent again, which reports the store keeps, and the
/// end of each. Every delivery goes through the one [FeedbackSender]; the
/// queue only keeps and times them.
///
/// One store call runs at a time, and one [drain]. While a drain runs, the
/// store may hold more than its bounds: the drain brings it within them
/// when it ends, the oldest report evicted first.
final class FeedbackQueue {
  FeedbackQueue(
    this._store,
    this._sender, {
    required DateTime Function() clock,
    required void Function(FeedbackSettled settled) onSettled,
  }) : _clock = clock,
       _onSettled = onSettled;

  final FeedbackOfflineStore _store;
  final FeedbackSender _sender;
  final DateTime Function() _clock;
  final void Function(FeedbackSettled settled) _onSettled;
  final Random _jitter = Random();

  bool _draining = false;
  Future<void> _tail = Future.value();

  /// Keeps the report of [postponed] for a later [drain], and answers
  /// [FeedbackQueued]; [FeedbackRejection.noStore] when the store fails.
  Future<FeedbackOutcome> keep(FeedbackSendPostponed postponed) async {
    try {
      final report = pendingFeedback(
        postponed.state,
        nextAttemptAt: _nextAttemptAt(postponed),
      );
      await _locked(() => _put(report));
      return FeedbackQueued(report.reportId);
    } catch (_) {
      return const FeedbackRejected(FeedbackRejection.noStore);
    }
  }

  /// How many reports the store keeps; 0 when it fails.
  Future<int> count() async {
    try {
      return (await _locked(_store.pending)).length;
    } catch (_) {
      return 0;
    }
  }

  /// Sends each kept report that is due, the oldest first, and settles it
  /// or keeps it for its next attempt, until the first that is postponed.
  /// Removes the reports past [FeedbackReport.maxAge] first. Never throws;
  /// a report the store fails for stays as it was. A call while a drain
  /// runs returns at once.
  Future<void> drain() async {
    if (_draining) return;
    _draining = true;
    try {
      final due = await _locked(() async {
        final now = _clock().toUtc();
        final due = <PendingFeedback>[];
        for (final report in await _store.pending()) {
          if (_expired(report, now)) {
            await _settle(report, _expiredOutcome);
          } else if (!report.nextAttemptAt.isAfter(now)) {
            due.add(report);
          }
        }
        return due..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      });
      for (final report in due) {
        try {
          if (await _deliver(report)) break;
        } catch (_) {
          // The store failed: the report stays as it was.
        }
      }
    } catch (_) {
      // Reporting must never affect the host application.
    } finally {
      _draining = false;
      try {
        await _locked(_bound);
      } catch (_) {
        // The store failed: the next keep or drain bounds it.
      }
    }
  }

  /// Delivers [report], with its screenshot read from the store, and
  /// answers whether it was postponed.
  Future<bool> _deliver(PendingFeedback report) async {
    final reference = attachmentOf(report);
    final bytes = reference == null
        ? null
        : await _locked(() => _store.attachment(report.reportId));
    if (reference != null &&
        (bytes == null ||
            bytes.length != reference.byteLength ||
            sha256.convert(bytes).toString() != reference.sha256)) {
      // Not the screenshot the report names: it cannot be delivered.
      await _locked(() => _settle(report, _failedOutcome));
      return false;
    }
    final result = await _sender.send(sendStateOf(report, attachment: bytes));
    switch (result) {
      case FeedbackSendAccepted(:final answer):
        await _locked(
          () => _settle(
            report,
            FeedbackDelivered(ticket: answer.ticket, verified: answer.verified),
          ),
        );
      case FeedbackSendRejected(:final outcome):
        await _locked(() => _settle(report, outcome));
      case FeedbackSendPostponed():
        final next = pendingFeedback(
          result.state,
          nextAttemptAt: _nextAttemptAt(result),
        );
        await _locked(() => _put(next));
        return true;
    }
    return false;
  }

  /// Puts [report] in the store and, unless a drain runs, brings the store
  /// within its bounds, [report] kept.
  Future<void> _put(PendingFeedback report) async {
    await _store.put(report);
    if (!_draining) await _bound(except: report.reportId);
  }

  /// Removes the reports past [FeedbackReport.maxAge] and, the oldest
  /// first, as many as the bounds need; never the report [except].
  Future<void> _bound({String? except}) async {
    final now = _clock().toUtc();
    final kept = <PendingFeedback>[];
    for (final report in await _store.pending()) {
      if (report.reportId != except && _expired(report, now)) {
        await _settle(report, _expiredOutcome);
      } else {
        kept.add(report);
      }
    }
    kept.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    var count = kept.length;
    var bytes = kept.fold(0, (sum, report) => sum + _bytes(report));
    for (final candidate in kept) {
      if (count <= FeedbackOfflineStore.maxReports &&
          bytes <= FeedbackOfflineStore.maxBytes) {
        break;
      }
      if (candidate.reportId == except) continue;
      count--;
      bytes -= _bytes(candidate);
      await _settle(candidate, _evictedOutcome);
    }
  }

  /// Removes [report] and tells its [outcome]; a report the store could
  /// not remove stays, and is told when it is settled again.
  Future<void> _settle(PendingFeedback report, FeedbackOutcome outcome) async {
    try {
      await _store.remove(report.reportId);
    } catch (_) {
      return;
    }
    _onSettled(FeedbackSettled(report.reportId, outcome));
  }

  /// The platform's `Retry-After` from now, at most [FeedbackReport.maxAge],
  /// else the backoff of [FeedbackOfflineStore.firstRetryDelay] doubled per
  /// attempt, capped at [FeedbackOfflineStore.maxRetryDelay], less up to a
  /// quarter at random.
  DateTime _nextAttemptAt(FeedbackSendPostponed postponed) {
    final now = _clock().toUtc();
    final retryAfter = postponed.retryAfter;
    if (retryAfter != null) {
      // Past maxAge the report expires before it is due anyway.
      if (retryAfter > FeedbackReport.maxAge) {
        return now.add(FeedbackReport.maxAge);
      }
      return now.add(retryAfter.isNegative ? Duration.zero : retryAfter);
    }
    final doublings = min(max(postponed.state.attempts - 1, 0), 30);
    final delay = min(
      FeedbackOfflineStore.firstRetryDelay.inMilliseconds * (1 << doublings),
      FeedbackOfflineStore.maxRetryDelay.inMilliseconds,
    );
    final jitter = (delay * _jitter.nextDouble() / 4).floor();
    return now.add(Duration(milliseconds: delay - jitter));
  }

  static bool _expired(PendingFeedback report, DateTime now) =>
      !now.isBefore(report.createdAt.add(FeedbackReport.maxAge));

  static int _bytes(PendingFeedback report) =>
      utf8.encode(report.reportJson).length +
      (attachmentOf(report)?.byteLength ?? 0);

  static const _expiredOutcome = FeedbackRejected(FeedbackRejection.expired);
  static const _evictedOutcome = FeedbackRejected(FeedbackRejection.evicted);
  static const _failedOutcome = FeedbackRejected(FeedbackRejection.failed);

  /// Runs [action] once every store call before it has ended.
  Future<T> _locked<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }
}
