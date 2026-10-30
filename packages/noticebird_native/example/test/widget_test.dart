import 'dart:convert';

import 'package:noticebird/noticebird.dart';
import 'package:noticebird_native_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the lab lists delivered native reports', (tester) async {
    await tester.pumpWidget(const CrashLabApp());
    expect(find.text('Nothing yet.'), findsOneWidget);

    final event = CrashEvent(
      eventId: '6c3b9f0e-8d2a-8c41-9f5e-2b7d4a1c0e95',
      occurredAt: DateTime.utc(2026, 9, 25, 8, 41, 17),
      severity: CrashSeverity.fatal,
      handled: false,
      exception: const CrashException(
        type: 'EXC_BAD_ACCESS/SIGSEGV',
        sanitizedMessage: 'EXC_BAD_ACCESS (SIGSEGV) code 0x1',
        stackTrace: nativeStackTraceMarker,
      ),
      app: const AppMetadata(
        name: 'noticebird_native_example',
        version: '1.0.0',
        build: '1',
        release: 'noticebird_native_example@1.0.0+1',
      ),
      platform: const PlatformMetadata(
        platform: CrashPlatform.ios,
        osVersion: '26.5.2',
        deviceClass: 'mobile',
      ),
      routeTemplate: '/lab',
      sessionId: 'run_0000000000000001',
      nativeCrash: const NativeCrashInfo(
        kind: NativeCrashKind.crash,
        source: NativeReportSource.metricKit,
      ),
    );
    delivered.value = [
      jsonDecode(event.toCanonicalJson()) as Map<String, dynamic>,
    ];
    await tester.pump();

    expect(find.text('EXC_BAD_ACCESS/SIGSEGV'), findsOneWidget);
    expect(find.textContaining('crash · metricKit · 0 frames'), findsOneWidget);
    // Two crashes through dart:ffi, two through the example's MainActivity.
    expect(find.byType(FilledButton), findsNWidgets(4));
  });
}
