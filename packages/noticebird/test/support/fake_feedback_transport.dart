import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:json_schema/json_schema.dart';
import 'package:noticebird/feedback.dart';

/// The ticket [FakeFeedbackTransport] files every accepted report under.
const fakeTicket = FeedbackTicket(number: 7, display: 'FB-7');

/// The report's JSON Schema, read in place from this workspace.
final _schema = JsonSchema.create(
  File(
    '../noticebird_protocol/schema/feedback-report.v1.schema.json',
  ).readAsStringSync(),
);

/// [reportJson] decoded, after the test fails unless it is a report the
/// schema takes.
Map<String, Object?> schemaValidReport(String reportJson) {
  final json = jsonDecode(reportJson) as Map<String, Object?>;
  final result = _schema.validate(json);
  expect(result.isValid, isTrue, reason: '${result.errors}');
  return json;
}

/// A [FeedbackTransport] that takes what it is given as the platform does:
/// the slot body through `toSlotJson`, the report through the report's JSON
/// Schema. Answers from its queues, and by default as a platform that takes
/// everything.
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
    final json = schemaValidReport(reportJson);
    submitted.add(json);
    return submitAnswers.isEmpty
        ? FeedbackAccepted(
            ticket: fakeTicket,
            verified: json.containsKey('reporterAssertion'),
          )
        : submitAnswers.removeAt(0);
  }
}
