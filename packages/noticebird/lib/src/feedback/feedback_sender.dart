import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:noticebird_protocol/feedback.dart';
import 'package:noticebird_protocol/noticebird_protocol.dart';

import 'feedback_capture.dart';
import 'feedback_config.dart';
import 'feedback_transport.dart';

/// The request a report's delivery goes on with.
enum FeedbackSendStep {
  /// Ask for the screenshot's slot, and upload it unless it is stored.
  slot,

  /// Submit the report.
  submit,

  /// Submit the report, which the slot answered is stored under its id
  /// already (`report_conflict`): a `report_conflict` to the submit then
  /// delivers it. Kept across a postponed submit, so a later delivery, in
  /// this run or another, still knows.
  submitStored,
}

/// What a delivery reads of a report the client wrote, as
/// `FeedbackReport.toJsonString` writes it: its id, when it was captured,
/// the reference of its screenshot, and whether it carries a reporter
/// assertion. The client reads nothing else back: the report was checked
/// when it was written, and the platform checks it again.
final class WrittenReport {
  WrittenReport._(
    this.reportId,
    this.createdAt,
    this.attachment, {
    required this.hasAssertion,
  });

  /// Throws a [FormatException] for a [reportJson] without them.
  factory WrittenReport.of(String reportJson) {
    try {
      final json = jsonDecode(reportJson) as Map<String, Object?>;
      final reportId = json['reportId']! as String;
      if (!FeedbackReport.uuidV4.hasMatch(reportId)) {
        throw const FormatException('Not a report id');
      }
      return WrittenReport._(
        reportId,
        DateTime.parse(json['createdAt']! as String).toUtc(),
        switch (json['attachments']) {
          null => null,
          [
            {
              'index': final int index,
              'contentType': final String mimeType,
              'byteLength': final int byteLength,
              'sha256': final String sha256,
            },
          ] =>
            FeedbackAttachmentRef(
              index: index,
              contentType: FeedbackContentType.values.firstWhere(
                (type) => type.mimeType == mimeType,
              ),
              byteLength: byteLength,
              sha256: sha256,
            ),
          _ => throw const FormatException('Not an attachment'),
        },
        hasAssertion: json.containsKey('reporterAssertion'),
      );
    } on FormatException {
      rethrow;
    } catch (error) {
      throw FormatException('Not a feedback report: $error');
    }
  }

  final String reportId;
  final DateTime createdAt;

  /// The screenshot's reference, `null` for a report without one.
  final FeedbackAttachmentRef? attachment;
  final bool hasAssertion;
}

/// Where one report's delivery stands: all a store keeps of it to go on
/// later, each field a plain value.
final class FeedbackSendState {
  FeedbackSendState({
    required this.reportJson,
    this.attachment,
    FeedbackSendStep? next,
    this.attempts = 0,
  }) : next =
           next ??
           (attachment == null
               ? FeedbackSendStep.submit
               : FeedbackSendStep.slot);

  /// The report as it is submitted, `FeedbackReport.toJsonString`'s:
  /// without its reporter assertion once the platform refused it.
  final String reportJson;

  /// The bytes of the report's screenshot, `null` without one.
  final Uint8List? attachment;

  /// The request the delivery goes on with: by default the slot for a
  /// report with an [attachment], the submit for one without. A report
  /// without an attachment reference is submitted whatever this says.
  final FeedbackSendStep next;

  /// How many deliveries this report went through without an end.
  final int attempts;

  /// What the delivery reads of [reportJson]; throws a [FormatException]
  /// for one that is no report.
  late final WrittenReport report = WrittenReport.of(reportJson);
}

/// What a delivery came to.
sealed class FeedbackSendResult {
  const FeedbackSendResult();
}

/// The platform has the report.
final class FeedbackSendAccepted extends FeedbackSendResult {
  const FeedbackSendAccepted(this.answer);

  final FeedbackAccepted answer;
}

/// The report is refused for good.
final class FeedbackSendRejected extends FeedbackSendResult {
  const FeedbackSendRejected(this.outcome);

  final FeedbackRejected outcome;
}

/// The report did not get through for now: [state] goes on, no earlier
/// than [retryAfter] when the platform named a delay.
final class FeedbackSendPostponed extends FeedbackSendResult {
  const FeedbackSendPostponed(this.state, {this.retryAfter});

  final FeedbackSendState state;
  final Duration? retryAfter;
}

/// The delivery of one report, from a [FeedbackSendState] to its end or to
/// the state it goes on from: the slot and upload of its screenshot, the
/// submit, and what each answer of [FeedbackConfig.transport] leads to.
///
/// - The slot answers where to upload ([FeedbackSlotPending]) or that the
///   bytes are stored ([FeedbackAttachmentStored]), and the upload that they
///   are; then the report is submitted.
/// - [FeedbackBackToSlot] returns to the slot, [maxSlotReturns] times at
///   most; after that the report is postponed.
/// - [FeedbackAssertionRefused]: the report is resubmitted at once without
///   its assertion, unless [FeedbackConfig.requireVerified] makes that a
///   rejection. The provider is not asked again for this report, and a held
///   assertion that was refused is let go of ([forgetAssertion]).
/// - [FeedbackFinalRefusal] rejects the report, with a reason the host can
///   act on where there is one; but after `report_conflict` at the slot the
///   report is submitted, and a `report_conflict` to that submit delivers
///   it without a ticket: a report id is this client's own UUID v4 from a
///   secure random source, so the conflict can only be this report's own
///   earlier delivery. A submit postponed after such a slot goes on as
///   [FeedbackSendStep.submitStored], so it still knows. A
///   `report_conflict` to a first submit stays a refusal.
/// - [FeedbackRetryAfter] and [FeedbackTransient] postpone it.
/// - An answer the request cannot have, such as an acceptance of a slot
///   request or a slot for a submit, is a broken transport: the report is
///   rejected as [FeedbackRejection.failed] at once, since asking again
///   would only meet the same answer, and a queue would retry it forever.
final class FeedbackSender {
  FeedbackSender(
    this._config,
    this._transport, {
    required DateTime Function() clock,
  }) : _clock = clock;

  final FeedbackConfig _config;
  final FeedbackTransport _transport;
  final DateTime Function() _clock;

  /// How long [reporterAssertion] waits for the provider.
  static const assertionTimeout = Duration(seconds: 5);

  /// How long before its `exp` a held assertion is asked for anew. The
  /// platform verifies an assertion against the moment its report was
  /// captured (`createdAt`, by the device's clock), so a report captured
  /// with a held assertion keeps its proof, queued offline too; the margin
  /// covers a device clock that runs ahead of the backend that signed it.
  static const assertionReuseMargin = Duration(minutes: 5);

  /// How many times one delivery returns to the slot.
  static const maxSlotReturns = 2;

  /// The host's user as the client knows it ([identity]), and the
  /// assertion held for that user until [_heldUntil].
  String? _identity;
  String? _held;
  DateTime? _heldUntil;

  /// The provider call in flight for [_identity].
  Future<String?>? _asking;

  /// The host's user as the client knows it: its id, e-mail address and
  /// name as the host set them, or `null` when it set none. A change lets
  /// go of the held assertion, so another user's never goes with a report.
  set identity(String? identity) {
    if (identity == _identity) return;
    forgetAssertion();
    _identity = identity;
  }

  /// The reporter assertion of the [identity] at this moment: the one held
  /// for it while its `exp` is more than [assertionReuseMargin] away, else
  /// the provider's, which is then held for it. Reports captured at once
  /// share one provider call.
  ///
  /// `null` without a provider, or when it throws, answers `null` or takes
  /// longer than [assertionTimeout]. Without an [identity] nothing is held,
  /// since the client cannot tell whose an assertion is, and neither is a
  /// token without a readable `exp`.
  Future<String?> reporterAssertion() async {
    final provider = _config.reporterAssertion;
    if (provider == null) return null;
    final identity = _identity;
    final held = _held;
    final heldUntil = _heldUntil;
    if (identity != null &&
        held != null &&
        heldUntil != null &&
        _clock().toUtc().isBefore(heldUntil)) {
      return held;
    }
    final asking = _asking;
    if (asking != null) return asking;
    final call = _ask(provider);
    _asking = call;
    final token = await call;
    if (!identical(_asking, call)) return token;
    _asking = null;
    final expiry = token == null ? null : _expiryOf(token);
    if (identity != null && expiry != null) {
      _held = token;
      _heldUntil = expiry.subtract(assertionReuseMargin);
    }
    return token;
  }

  /// Lets go of the held assertion and of a provider call in flight: the
  /// next report asks the provider.
  void forgetAssertion() {
    _held = null;
    _heldUntil = null;
    _asking = null;
  }

  static Future<String?> _ask(Future<String?> Function() provider) async {
    try {
      return await provider().timeout(assertionTimeout);
    } catch (_) {
      return null;
    }
  }

  /// The `exp` of a compact JWS's claims, or `null` when it has none that
  /// can be read.
  static DateTime? _expiryOf(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final claims = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      if (claims case {'exp': final num exp} when exp.isFinite) {
        return DateTime.fromMillisecondsSinceEpoch(
          (exp * 1000).round(),
          isUtc: true,
        );
      }
    } catch (_) {
      // Not a token whose claims can be read: it is not held.
    }
    return null;
  }

  /// Delivers the report of [state], whose [FeedbackSendState.attachment]
  /// holds the bytes of the report's screenshot, if it has one. Never
  /// throws.
  ///
  /// Before any request, [FeedbackConfig.requireVerified] rejects a report
  /// without a reporter assertion as [FeedbackRejection.unverified]. A fault
  /// inside the delivery is [FeedbackRejection.failed].
  Future<FeedbackSendResult> send(FeedbackSendState state) async {
    try {
      return await _send(state);
    } catch (_) {
      return _failed;
    }
  }

  static const _failed = FeedbackSendRejected(
    FeedbackRejected(FeedbackRejection.failed),
  );

  Future<FeedbackSendResult> _send(FeedbackSendState state) async {
    final report = state.report;
    final attachment = report.attachment;
    final bytes = state.attachment;
    if (_config.requireVerified && !report.hasAssertion) {
      return const FeedbackSendRejected(
        FeedbackRejected(FeedbackRejection.unverified),
      );
    }
    var reportJson = state.reportJson;
    var hasAssertion = report.hasAssertion;
    var step = attachment == null ? _Step.submit : _Step.of(state.next);
    FeedbackUploadSlot? slot;
    var returns = 0;
    var storedAlready =
        attachment != null && state.next == FeedbackSendStep.submitStored;

    FeedbackSendPostponed postponed(_Step from, {Duration? retryAfter}) =>
        FeedbackSendPostponed(
          FeedbackSendState(
            reportJson: reportJson,
            attachment: bytes,
            next: switch (from) {
              _Step.submit when storedAlready => FeedbackSendStep.submitStored,
              _Step.submit => FeedbackSendStep.submit,
              _Step.slot || _Step.upload => FeedbackSendStep.slot,
            },
            attempts: state.attempts + 1,
          ),
          retryAfter: retryAfter,
        );

    for (;;) {
      final answer = await _answer(
        () => switch (step) {
          _Step.slot => _transport.requestSlot(report.reportId, attachment!),
          _Step.upload => _transport.upload(slot!, bytes!),
          _Step.submit => _transport.submit(reportJson),
        },
      );
      switch (answer) {
        case FeedbackSlotPending(slot: final pending) when step == _Step.slot:
          slot = pending;
          step = _Step.upload;
        case FeedbackAttachmentStored() when step != _Step.submit:
          step = _Step.submit;
        case FeedbackAccepted() when step == _Step.submit:
          return FeedbackSendAccepted(answer);
        case FeedbackBackToSlot() when attachment != null:
          if (returns == maxSlotReturns) return postponed(_Step.slot);
          returns++;
          step = _Step.slot;
        case FeedbackAssertionRefused() when step == _Step.submit:
          if (!hasAssertion) {
            // Refused without one: nothing to leave out.
            return FeedbackSendRejected(
              FeedbackRejected(
                FeedbackRejection.refused,
                code: 'invalid_reporter_assertion',
              ),
            );
          }
          if (_config.requireVerified) {
            return const FeedbackSendRejected(
              FeedbackRejected(
                FeedbackRejection.unverified,
                code: 'invalid_reporter_assertion',
              ),
            );
          }
          final refused = _assertionOf(reportJson);
          if (refused != null && refused == _held) forgetAssertion();
          reportJson = _withoutAssertion(reportJson);
          hasAssertion = false;
        case FeedbackFinalRefusal(code: 'report_conflict')
            when step == _Step.slot:
          // This report's own earlier delivery, whose end was not kept:
          // submit it.
          storedAlready = true;
          step = _Step.submit;
        case FeedbackFinalRefusal(code: 'report_conflict')
            when step == _Step.submit && storedAlready:
          // That earlier delivery again: delivered, without a ticket.
          return const FeedbackSendAccepted(FeedbackAccepted(verified: false));
        case FeedbackFinalRefusal():
          return FeedbackSendRejected(_rejected(answer));
        case FeedbackRetryAfter(:final delay):
          return postponed(step, retryAfter: delay);
        case FeedbackTransient():
          return postponed(step);
        default:
          // An answer that does not fit the request.
          return _failed;
      }
    }
  }

  /// The reporter assertion [reportJson] carries, if any.
  static String? _assertionOf(String reportJson) =>
      switch (jsonDecode(reportJson)) {
        {'reporterAssertion': final String assertion} => assertion,
        _ => null,
      };

  /// [reportJson] without its reporter assertion: an optional field, so the
  /// report keeps to its rules, and only gets smaller.
  static String _withoutAssertion(String reportJson) => jsonEncode(
    (jsonDecode(reportJson) as Map<String, Object?>)
      ..remove('reporterAssertion'),
  );

  static FeedbackRejected _rejected(FeedbackFinalRefusal refusal) {
    final reason = switch (refusal) {
      // The platform's strict refusal; any other violation there, such as
      // an unknownField from a platform without the field, is not.
      FeedbackFinalRefusal(
        code: 'invalid_report',
        violation: ProtocolViolation.invalidValue,
        path: r'$.user' || r'$.userContext',
      ) =>
        FeedbackRejection.strictProject,
      // The platform's submission window.
      FeedbackFinalRefusal(
        code: 'invalid_report',
        violation: ProtocolViolation.invalidValue,
        path: r'$.createdAt',
      ) =>
        FeedbackRejection.clock,
      FeedbackFinalRefusal(
        code: 'feedback_disabled' || 'attachments_disabled',
      ) =>
        FeedbackRejection.notAccepted,
      _ => FeedbackRejection.refused,
    };
    return FeedbackRejected(reason, path: refusal.path, code: refusal.code);
  }

  /// [request]'s answer; one that throws, as a transport must not, is
  /// transient.
  static Future<FeedbackDelivery> _answer(
    Future<FeedbackDelivery> Function() request,
  ) async {
    try {
      return await request();
    } catch (_) {
      return const FeedbackTransient();
    }
  }
}

enum _Step {
  slot,
  upload,
  submit;

  static _Step of(FeedbackSendStep step) => switch (step) {
    FeedbackSendStep.slot => slot,
    FeedbackSendStep.submit || FeedbackSendStep.submitStored => submit,
  };
}
