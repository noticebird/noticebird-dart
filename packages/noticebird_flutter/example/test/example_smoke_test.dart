import 'dart:convert';
import 'dart:typed_data';

import 'package:bloc/bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noticebird_example/main.dart';
import 'package:noticebird_flutter/feedback.dart';
import 'package:noticebird_flutter/noticebird_flutter.dart';
import 'package:noticebird_flutter/testing.dart';

/// A [FeedbackTransport] that keeps each report's JSON and files it under
/// one ticket, without a network.
final class _RecordingFeedbackTransport implements FeedbackTransport {
  final List<Map<String, Object?>> reports = [];

  @override
  Future<FeedbackDelivery> requestSlot(
    String reportId,
    FeedbackAttachmentRef attachment,
  ) async => const FeedbackTransient();

  @override
  Future<FeedbackDelivery> upload(
    FeedbackUploadSlot slot,
    Uint8List bytes,
  ) async => const FeedbackTransient();

  @override
  Future<FeedbackDelivery> submit(String reportJson) async {
    reports.add(jsonDecode(reportJson) as Map<String, Object?>);
    return FeedbackAccepted(
      ticket: const FeedbackTicket(number: 1, display: 'FB-1'),
      verified: false,
    );
  }
}

NoticebirdClient _buildReporter(
  CrashTransport transport, {
  FeedbackTransport? feedback,
}) => NoticebirdClient(
  config: NoticebirdConfig(
    privacyProfile: CrashPrivacyProfile.privacyDefault,
    app: const AppMetadata(
      name: 'test',
      version: '1.0.0',
      build: '1',
      release: 'test@1.0.0+1',
    ),
    platform: const PlatformMetadata(
      platform: CrashPlatform.unknown,
      osVersion: 'test',
      deviceClass: 'test',
    ),
    feedback: feedback == null ? null : FeedbackConfig(transport: feedback),
  ),
  transport: transport,
);

void main() {
  // main() wires Bloc.observer to the live reporter; tests build ExampleApp
  // directly (bypassing main()), so tests exercising the observer path must
  // wire it themselves and restore the original afterwards.
  final originalObserver = Bloc.observer;
  tearDown(() => Bloc.observer = originalObserver);

  testWidgets('renders the demo actions', (tester) async {
    await tester.pumpWidget(
      ExampleApp(reporter: _buildReporter(RecordingCrashTransport())),
    );

    expect(find.text('Add breadcrumb'), findsOneWidget);
    expect(find.text('Report handled error'), findsOneWidget);
    expect(find.text('Trigger unhandled error'), findsOneWidget);
    expect(find.text('Simulate login'), findsOneWidget);
    expect(find.text('Send feedback'), findsOneWidget);
    expect(find.text('Start live debug session'), findsOneWidget);
  });

  testWidgets('reporting a handled error sends one event', (tester) async {
    final transport = RecordingCrashTransport();
    await tester.pumpWidget(ExampleApp(reporter: _buildReporter(transport)));

    await tester.tap(find.text('Report handled error'));
    await tester.pumpAndSettle();

    expect(transport.events, hasLength(1));
    expect(transport.events.single['handled'], isTrue);
    expect(transport.events.single['severity'], CrashSeverity.warning.name);
    expect(find.text('Handled error reported'), findsOneWidget);
  });

  testWidgets('sending feedback delivers one bug report', (tester) async {
    final transport = RecordingCrashTransport();
    final feedback = _RecordingFeedbackTransport();
    await tester.pumpWidget(
      ExampleApp(reporter: _buildReporter(transport, feedback: feedback)),
    );

    await tester.tap(find.text('Send feedback'));
    await tester.pumpAndSettle();

    final report = feedback.reports.single;
    expect(report['kind'], 'bug');
    expect(report['message'], 'Example feedback: sync keeps failing');
    expect(report, isNot(contains('attachments')));
    expect(transport.events, isEmpty);
    expect(find.text('Feedback sent as FB-1'), findsOneWidget);
  });

  testWidgets('sending feedback without a feedback config says so', (
    tester,
  ) async {
    await tester.pumpWidget(
      ExampleApp(reporter: _buildReporter(RecordingCrashTransport())),
    );

    await tester.tap(find.text('Send feedback'));
    await tester.pumpAndSettle();

    expect(find.text('Feedback is not configured'), findsOneWidget);
  });

  testWidgets('starting a live debug session syncs the next breadcrumb', (
    tester,
  ) async {
    final transport = RecordingCrashTransport();
    final reporter = _buildReporter(transport);
    Bloc.observer = NoticebirdBlocObserver(client: reporter);
    await tester.pumpWidget(ExampleApp(reporter: reporter));

    await tester.tap(find.text('Start live debug session'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add breadcrumb'));
    await tester.pumpAndSettle();

    expect(
      transport.events.where(
        (e) => (e['exception']! as Map)['type'] == 'LiveBreadcrumbSync',
      ),
      hasLength(1),
    );
    expect(find.text('Stop live debug session'), findsOneWidget);
  });
}
