import 'dart:typed_data';

import 'package:noticebird_protocol/feedback.dart';
import 'package:noticebird_protocol/noticebird_protocol.dart';

/// How a feedback report reaches the platform: the three requests of its
/// delivery, each of which can be repeated safely.
///
/// A report with a screenshot asks for a slot ([requestSlot]), uploads the
/// bytes to it when they are not stored yet ([upload]), and is then
/// submitted ([submit]); a report without one is only submitted.
///
/// `FeedbackHttpTransport` is the transport to the hosted API. A host that
/// writes its own, to relay reports through its backend for instance,
/// answers each request with the [FeedbackDelivery] its answer means, and
/// never throws: a failure to reach the other side is a
/// [FeedbackTransient].
abstract interface class FeedbackTransport {
  /// Asks for the slot of [attachment] in the report [reportId]: a
  /// [FeedbackSlotPending] that says where the bytes go, or
  /// [FeedbackAttachmentStored] when the same bytes are stored already.
  Future<FeedbackDelivery> requestSlot(
    String reportId,
    FeedbackAttachmentRef attachment,
  );

  /// Uploads [bytes] to [slot]: [FeedbackAttachmentStored] once they are
  /// stored.
  Future<FeedbackDelivery> upload(FeedbackUploadSlot slot, Uint8List bytes);

  /// Submits [reportJson], the report as `FeedbackReport.toJsonString`
  /// writes it: [FeedbackAccepted] once the platform has it.
  Future<FeedbackDelivery> submit(String reportJson);
}

/// What one request of a report's delivery came to.
///
/// The answers to go on with are [FeedbackSlotPending],
/// [FeedbackAttachmentStored] and [FeedbackAccepted]. The others say what to
/// do with the report instead: drop it ([FeedbackFinalRefusal]), keep it for
/// later ([FeedbackRetryAfter], [FeedbackTransient]), ask for the slot again
/// ([FeedbackBackToSlot]), or send it again without its reporter assertion
/// ([FeedbackAssertionRefused]).
sealed class FeedbackDelivery {
  const FeedbackDelivery();
}

/// The report is submitted: `202` the first time, `200` for a replay of
/// the same report.
///
/// Read leniently: a success answer without a readable ticket is still
/// accepted, with [ticket] `null`.
final class FeedbackAccepted extends FeedbackDelivery {
  const FeedbackAccepted({this.ticket, required this.verified});

  /// The ticket the report was filed under, if the answer named one.
  final FeedbackTicket? ticket;

  /// Whether the platform verified the report's reporter assertion; `false`
  /// for a report without one, and when the answer does not say.
  final bool verified;

  @override
  bool operator ==(Object other) =>
      other is FeedbackAccepted &&
      other.ticket == ticket &&
      other.verified == verified;

  @override
  int get hashCode => Object.hash(ticket, verified);

  @override
  String toString() => 'FeedbackAccepted(ticket: $ticket, verified: $verified)';
}

/// The ticket a submitted report was filed under.
final class FeedbackTicket {
  const FeedbackTicket({required this.number, required this.display});

  /// The ticket's number within its project, from 1.
  final int number;

  /// The ticket as the platform formats it, such as `FB-12`: show it as it
  /// is, never compose it from [number].
  final String display;

  @override
  bool operator ==(Object other) =>
      other is FeedbackTicket &&
      other.number == number &&
      other.display == display;

  @override
  int get hashCode => Object.hash(number, display);

  @override
  String toString() => 'FeedbackTicket($display)';
}

/// The slot is made and waits for its bytes, to be uploaded to [slot].
final class FeedbackSlotPending extends FeedbackDelivery {
  const FeedbackSlotPending(this.slot);

  final FeedbackUploadSlot slot;

  @override
  bool operator ==(Object other) =>
      other is FeedbackSlotPending && other.slot == slot;

  @override
  int get hashCode => slot.hashCode;

  @override
  String toString() => 'FeedbackSlotPending($slot)';
}

/// Where and how the bytes of a slot are uploaded, as the platform named it.
final class FeedbackUploadSlot {
  FeedbackUploadSlot({
    required this.uploadUrl,
    required this.uploadMethod,
    Map<String, String> uploadHeaders = const {},
  }) : uploadHeaders = Map.unmodifiable(uploadHeaders);

  /// Where the bytes go: the answer's `uploadUrl`, which may be relative,
  /// resolved against the URL of the slot request.
  final Uri uploadUrl;

  /// The HTTP method of the upload; v1 names `PUT`.
  final String uploadMethod;

  /// The headers the upload sends, such as its `content-type`.
  final Map<String, String> uploadHeaders;

  @override
  bool operator ==(Object other) =>
      other is FeedbackUploadSlot &&
      other.uploadUrl == uploadUrl &&
      other.uploadMethod == uploadMethod &&
      other.uploadHeaders.length == uploadHeaders.length &&
      uploadHeaders.entries.every(
        (header) => other.uploadHeaders[header.key] == header.value,
      );

  @override
  int get hashCode => Object.hash(
    uploadUrl,
    uploadMethod,
    Object.hashAllUnordered(
      uploadHeaders.entries.map(
        (header) => Object.hash(header.key, header.value),
      ),
    ),
  );

  @override
  String toString() =>
      'FeedbackUploadSlot($uploadMethod $uploadUrl, headers: $uploadHeaders)';
}

/// The attachment's bytes are stored: the slot found them stored already,
/// or the upload stored them. The report can be submitted.
final class FeedbackAttachmentStored extends FeedbackDelivery {
  const FeedbackAttachmentStored();

  @override
  bool operator ==(Object other) => other is FeedbackAttachmentStored;

  @override
  int get hashCode => (FeedbackAttachmentStored).hashCode;

  @override
  String toString() => 'FeedbackAttachmentStored()';
}

/// The request is refused for good: the report is dropped. A transport may
/// refuse a request itself before it sends it, as `FeedbackHttpTransport`
/// does with a slot body the protocol refuses or an upload it will not
/// make.
final class FeedbackFinalRefusal extends FeedbackDelivery {
  const FeedbackFinalRefusal({this.code, this.violation, this.path});

  /// The answer's `error`, such as `invalid_report` or `feedback_disabled`;
  /// `null` for an answer without one, such as `404`.
  final String? code;

  /// For `invalid_report`: the rule the report or slot body broke.
  final ProtocolViolation? violation;

  /// For `invalid_report`: the JSON path of the value that broke it, such as
  /// `$.userContext.plan`.
  final String? path;

  @override
  bool operator ==(Object other) =>
      other is FeedbackFinalRefusal &&
      other.code == code &&
      other.violation == violation &&
      other.path == path;

  @override
  int get hashCode => Object.hash(code, violation, path);

  @override
  String toString() =>
      'FeedbackFinalRefusal(code: $code, violation: ${violation?.name}, '
      'path: $path)';
}

/// A rate limit is spent (`429`): keep the report, and try again after
/// [delay].
final class FeedbackRetryAfter extends FeedbackDelivery {
  const FeedbackRetryAfter(this.delay);

  final Duration delay;

  @override
  bool operator ==(Object other) =>
      other is FeedbackRetryAfter && other.delay == delay;

  @override
  int get hashCode => delay.hashCode;

  @override
  String toString() => 'FeedbackRetryAfter($delay)';
}

/// The attachment is not where the report needs it (`409
/// attachment_missing`): the slot expired before the upload, or the report
/// was submitted before its upload completed. Ask for the slot again.
final class FeedbackBackToSlot extends FeedbackDelivery {
  const FeedbackBackToSlot();

  @override
  bool operator ==(Object other) => other is FeedbackBackToSlot;

  @override
  int get hashCode => (FeedbackBackToSlot).hashCode;

  @override
  String toString() => 'FeedbackBackToSlot()';
}

/// The platform did not verify the report's reporter assertion (`401
/// invalid_reporter_assertion`): send the report again without it, or drop
/// it when the host requires a verified report.
final class FeedbackAssertionRefused extends FeedbackDelivery {
  const FeedbackAssertionRefused();

  @override
  bool operator ==(Object other) => other is FeedbackAssertionRefused;

  @override
  int get hashCode => (FeedbackAssertionRefused).hashCode;

  @override
  String toString() => 'FeedbackAssertionRefused()';
}

/// The request did not get through for now: no answer in time, no network,
/// a server error, or an answer the protocol does not name, such as a
/// gateway's page or a redirect. Keep the report and back off.
final class FeedbackTransient extends FeedbackDelivery {
  const FeedbackTransient();

  @override
  bool operator ==(Object other) => other is FeedbackTransient;

  @override
  int get hashCode => (FeedbackTransient).hashCode;

  @override
  String toString() => 'FeedbackTransient()';
}
