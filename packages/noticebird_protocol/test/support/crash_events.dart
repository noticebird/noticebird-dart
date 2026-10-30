// Events built as a client builds them, for the crash event's tests: each
// argument defaults to the value of `test/fixtures/v5_event.json`.

import 'dart:convert';
import 'dart:io';

import 'package:noticebird_protocol/noticebird_protocol.dart';
import 'package:test/test.dart';

/// `test/fixtures/v5_event.json`, decoded.
Map<String, Object?> v5Fixture() => Map<String, Object?>.from(
  jsonDecode(File('test/fixtures/v5_event.json').readAsStringSync()) as Map,
);

const v5Exception = CrashException(
  type: 'SyncRefused',
  sanitizedMessage: 'Refused: 23505 on collections',
  stackTrace: '#0 SyncWriter.push (package:app_sync/sync_writer.dart:88:5)',
);

const v5App = AppMetadata(
  name: 'justorganize',
  version: '1.0.0',
  build: '100',
  release: 'justorganize@1.0.0+100',
);

const v5Platform = PlatformMetadata(
  platform: CrashPlatform.macos,
  osVersion: '15.5',
  deviceClass: 'desktop',
);

TypedBreadcrumb v5Breadcrumb({
  String action = 'route.push',
  Map<AllowedTag, TagScalar> data = const {AllowedTag.component: 'list-detail'},
}) => TypedBreadcrumb(
  occurredAt: DateTime.utc(2026, 7, 11, 10, 14, 59),
  category: BreadcrumbCategory.navigation,
  action: action,
  data: data,
);

/// The fixture's event, with any field replaced.
CrashEvent v5Event({
  String eventId = '0197f232-2bd8-7000-8000-000000000005',
  CrashException exception = v5Exception,
  AppMetadata app = v5App,
  PlatformMetadata platform = v5Platform,
  String? routeTemplate = '/lists/:listId',
  String sessionId = 'random_session_123456',
  String? userId,
  CrashUser? user = const CrashUser(id: 'user_abc123'),
  Map<AllowedTag, TagScalar> tags = const {
    AllowedTag.feature: 'lists',
    AllowedTag.foreground: true,
  },
  Map<String, Object?> extra = const {'retry_count': 2},
  List<TypedBreadcrumb>? breadcrumbs,
  NativeCrashInfo? nativeCrash,
  List<String>? groupingKey = const ['sync-refusal', '23505', 'collections'],
}) => CrashEvent(
  eventId: eventId,
  occurredAt: DateTime.utc(2026, 7, 11, 10, 15),
  severity: CrashSeverity.error,
  handled: false,
  exception: exception,
  app: app,
  platform: platform,
  routeTemplate: routeTemplate,
  sessionId: sessionId,
  userId: userId,
  user: user,
  tags: tags,
  extra: extra,
  breadcrumbs: breadcrumbs ?? [v5Breadcrumb()],
  nativeCrash: nativeCrash,
  groupingKey: groupingKey,
);

/// A native crash as MetricKit reports one: a frame in no image, two in the
/// app's engine and one in a system library.
const metricKitCrash = NativeCrashInfo(
  kind: NativeCrashKind.crash,
  source: NativeReportSource.metricKit,
  machException: 'EXC_BAD_ACCESS',
  signal: 'SIGBUS',
  code: '0x32',
  images: [
    NativeImage(
      name: 'Flutter',
      inApp: true,
      debugId: '4c4c44e555553144a13dcc7994841aac',
      arch: NativeArch.arm64,
    ),
    NativeImage(
      name: 'libdispatch.dylib',
      inApp: false,
      debugId: '8e5c2f1a9b3d47e6a0c4d2b1f7e9a3c5',
      arch: NativeArch.arm64,
    ),
  ],
  frames: [
    NativeFrame.unknown(),
    NativeFrame.inImage(0, 10481952),
    NativeFrame.inImage(0, 5402168),
    NativeFrame.inImage(1, 17104),
  ],
);

/// A native event, as a client builds one of [native]: the marker as its
/// stack trace, and no grouping key.
CrashEvent nativeEvent([NativeCrashInfo native = metricKitCrash]) => v5Event(
  exception: const CrashException(
    type: 'EXC_BAD_ACCESS/SIGBUS',
    sanitizedMessage: 'EXC_BAD_ACCESS (SIGBUS) code 0x32',
    stackTrace: nativeStackTraceMarker,
  ),
  nativeCrash: native,
  groupingKey: null,
);

/// Refused with [violation] at [path].
Matcher refusedWith(ProtocolViolation violation, String path) => throwsA(
  isA<ProtocolException>()
      .having((error) => error.violation, 'violation', violation)
      .having((error) => error.path, 'path', path),
);

/// [event] refused by both writers with [violation] at [path].
void expectRefused(CrashEvent event, ProtocolViolation violation, String path) {
  expect(event.toJson, refusedWith(violation, path), reason: path);
  expect(event.toCanonicalJson, refusedWith(violation, path), reason: path);
}
