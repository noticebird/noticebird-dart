import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:noticebird/feedback.dart';

/// The ticket [FakeFeedbackTransport] files every accepted report under.
const fakeTicket = FeedbackTicket(number: 7, display: 'FB-7');

/// The fields every report holds.
const _requiredFields = {
  'schemaVersion',
  'reportId',
  'createdAt',
  'kind',
  'message',
  'app',
  'platform',
  'sessionId',
};

/// The fields a report may hold besides [_requiredFields].
const _optionalFields = {
  'trigger',
  'contact',
  'routeTemplate',
  'relatedEventId',
  'user',
  'userContext',
  'reporterAssertion',
  'trail',
  'diagnostics',
  'attachments',
};

/// [reportJson] decoded, after the test fails unless it is a report of the
/// current schema version: a JSON object with every field a report needs
/// and no field a report does not have.
Map<String, Object?> _wellFormedReport(String reportJson) {
  final json = jsonDecode(reportJson);
  expect(json, isA<Map<String, Object?>>());
  final report = json as Map<String, Object?>;
  expect(report['schemaVersion'], FeedbackReport.schemaVersion);
  expect(report.keys, containsAll(_requiredFields));
  expect(
    report.keys,
    everyElement(isIn(_requiredFields.union(_optionalFields))),
  );
  return report;
}

/// A [FeedbackTransport] that takes what it is given as the platform does:
/// the slot body through `toSlotJson`, the report as a report's JSON object
/// of the current schema version. Answers from its queues, and by default as
/// a platform that takes everything.
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
    final json = _wellFormedReport(reportJson);
    submitted.add(json);
    return submitAnswers.isEmpty
        ? FeedbackAccepted(
            ticket: fakeTicket,
            verified: json.containsKey('reporterAssertion'),
          )
        : submitAnswers.removeAt(0);
  }
}
