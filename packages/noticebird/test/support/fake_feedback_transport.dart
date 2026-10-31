import 'dart:convert';
import 'dart:typed_data';

import 'package:noticebird/feedback.dart';

/// The ticket [FakeFeedbackTransport] files every accepted report under.
const fakeTicket = FeedbackTicket(number: 7, display: 'FB-7');

/// A [FeedbackTransport] that decodes what it is given: the slot body
/// through `toSlotJson`, the report as a JSON object. The report's field set
/// is pinned by `noticebird_protocol`'s own feedback test. Answers from its
/// queues, and by default as an API that takes everything.
final class FakeFeedbackTransport implements FeedbackTransport {
  final requests = <String>[];
  final slotReportIds = <String>[];
  final uploaded = <Uint8List>[];
  final submitted = <Map<String, Object?>>[];
  final slotAnswers = <FeedbackDelivery>[];
  final submitAnswers = <FeedbackDelivery>[];
  bool submitThrows = false;

  /// Awaited before each submit is answered, when set.
  Future<void> Function()? beforeSubmit;

  @override
  Future<FeedbackDelivery> requestSlot(
    String reportId,
    FeedbackAttachmentRef attachment,
  ) async {
    requests.add('slot');
    slotReportIds.add(reportId);
    jsonEncode(attachment.toSlotJson());
    return slotAnswers.isEmpty
        ? FeedbackSlotPending(
            FeedbackUploadSlot(
              uploadUrl: Uri.parse('https://api.noticebird.com/upload'),
              uploadMethod: 'PUT',
            ),
          )
        : slotAnswers.removeAt(0);
  }

  @override
  Future<FeedbackDelivery> upload(
    FeedbackUploadSlot slot,
    Uint8List bytes,
  ) async {
    requests.add('upload');
    uploaded.add(bytes);
    return const FeedbackAttachmentStored();
  }

  @override
  Future<FeedbackDelivery> submit(String reportJson) async {
    requests.add('submit');
    await beforeSubmit?.call();
    if (submitThrows) throw StateError('broken transport');
    final json = jsonDecode(reportJson) as Map<String, Object?>;
    submitted.add(json);
    return submitAnswers.isEmpty
        ? FeedbackAccepted(
            ticket: fakeTicket,
            verified: json.containsKey('reporterAssertion'),
          )
        : submitAnswers.removeAt(0);
  }
}
