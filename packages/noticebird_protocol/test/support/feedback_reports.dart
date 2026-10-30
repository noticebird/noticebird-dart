// Reports built as a client builds them, for the model's tests and the
// conformance kit's: every one of them must validate against the schema.

import 'dart:convert';
import 'dart:math';

import 'package:noticebird_protocol/feedback.dart';
import 'package:noticebird_protocol/noticebird_protocol.dart';

const exampleSha256 =
    '9f2c4b1e7a0d3c5f8e6b2a4d1c0f9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f';

TypedBreadcrumb breadcrumb(String action) => TypedBreadcrumb(
  occurredAt: DateTime.utc(2026, 10, 29, 14, 2, 40, 112),
  category: BreadcrumbCategory.ui,
  action: action,
);

/// A report of its required fields only, as a client builds one.
FeedbackReport minimalReport({String? message, DateTime? createdAt}) =>
    FeedbackReport(
      reportId: '3b0c6f2e-8d41-4a77-9c5e-1f2a3b4c5d6e',
      createdAt: createdAt ?? DateTime.utc(2026, 10, 29, 14, 3, 12, 418),
      kind: FeedbackKind.bug,
      message: message ?? 'The list jumps back to the top.',
      app: const AppMetadata(
        name: 'example_app',
        version: '1.8.0',
        build: '412',
        release: 'example_app@1.8.0+412',
      ),
      platform: const PlatformMetadata(
        platform: CrashPlatform.android,
        osVersion: '16',
        deviceClass: 'phone',
      ),
      sessionId: 'p_7Hq2xK9mR4tW1zY6',
    );

/// A report with every field, as a client builds one.
FeedbackReport fullReport({
  FeedbackUser? user,
  String? relatedEventId,
  List<TypedBreadcrumb>? trail,
  Map<String, Map<String, DiagnosticValue>>? diagnostics,
  List<FeedbackAttachmentRef>? attachments,
}) {
  final minimal = minimalReport();
  return FeedbackReport(
    reportId: minimal.reportId,
    createdAt: minimal.createdAt,
    kind: minimal.kind,
    trigger: FeedbackTrigger.errorScreen,
    message: minimal.message,
    contactEmail: 'reporter@example.com',
    app: minimal.app,
    platform: minimal.platform,
    locale: 'en-GB',
    routeTemplate: '/lists/:listId',
    sessionId: minimal.sessionId,
    relatedEventId: relatedEventId ?? '019a3f2e-8d41-7a77-9c5e-1f2a3b4c5d6e',
    user:
        user ??
        const FeedbackUser(id: 'u1', email: 'jane@example.com', name: 'Jane'),
    userContext: FeedbackUserContext.check({
      'role': 'owner',
      'beta': true,
      'features': ['sharing', 'widgets'],
      'plan': {'seats': 5, 'tier': 'premium'},
    }),
    reporterAssertion: 'eyJhbGciOiJFZERTQSJ9.eyJzdWIiOiJ1MSJ9.c2lnbmF0dXJl',
    trail:
        trail ??
        [
          breadcrumb('route.push'),
          TypedBreadcrumb(
            occurredAt: DateTime.utc(2026, 10, 29, 14, 3, 1, 903),
            category: BreadcrumbCategory.ui,
            action: 'record.toggle',
            level: CrashSeverity.warning,
            data: const {
              AllowedTag.component: 'record_tile',
              AllowedTag.retryCount: 2,
            },
          ),
        ],
    diagnostics:
        diagnostics ??
        FeedbackDiagnostics.build({
          'sync': {
            'lastPullAt': DateTime.utc(2026, 10, 29, 14, 1, 55),
            'outboxPending': 3,
            'ratio': 0.25,
            'realtimeConnected': true,
            'spaceId': '0b6a4f1e-1c2d-4e3f-8a9b-0c1d2e3f4a5b',
          },
          'subscription': {'tier': 'premium'},
        }),
    attachments:
        attachments ??
        const [
          FeedbackAttachmentRef(
            index: 0,
            contentType: FeedbackContentType.png,
            byteLength: 183422,
            sha256: exampleSha256,
          ),
        ],
  );
}

/// [base] with each field given here in place of its own.
FeedbackReport replaced(
  FeedbackReport base, {
  String? reportId,
  DateTime? createdAt,
  String? message,
  String? contactEmail,
  AppMetadata? app,
  PlatformMetadata? platform,
  String? locale,
  String? routeTemplate,
  String? sessionId,
  String? relatedEventId,
  FeedbackUser? user,
  String? reporterAssertion,
  List<TypedBreadcrumb>? trail,
  Map<String, Map<String, DiagnosticValue>>? diagnostics,
  List<FeedbackAttachmentRef>? attachments,
}) => FeedbackReport(
  reportId: reportId ?? base.reportId,
  createdAt: createdAt ?? base.createdAt,
  kind: base.kind,
  trigger: base.trigger,
  message: message ?? base.message,
  contactEmail: contactEmail ?? base.contactEmail,
  app: app ?? base.app,
  platform: platform ?? base.platform,
  locale: locale ?? base.locale,
  routeTemplate: routeTemplate ?? base.routeTemplate,
  sessionId: sessionId ?? base.sessionId,
  relatedEventId: relatedEventId ?? base.relatedEventId,
  user: user ?? base.user,
  userContext: base.userContext,
  reporterAssertion: reporterAssertion ?? base.reporterAssertion,
  trail: trail ?? base.trail,
  diagnostics: diagnostics ?? base.diagnostics,
  attachments: attachments ?? base.attachments,
);

/// The worst case of every field at its maximum: each string at its
/// longest, in the costliest characters its rules allow, with [trail].
FeedbackReport worstReport({List<TypedBreadcrumb> trail = const []}) {
  // U+0001 is the costliest character JSON carries: six bytes (`\u0001`)
  // for one code point, and for one UTF-16 unit. The patterned fields are
  // ASCII at their longest.
  String worst(int length) => '\u0001' * length;
  return FeedbackReport(
    reportId: '3b0c6f2e-8d41-4a77-9c5e-1f2a3b4c5d6e',
    createdAt: DateTime.utc(2026, 10, 29, 14, 3, 12, 418, 123),
    kind: FeedbackKind.other,
    trigger: FeedbackTrigger.errorScreen,
    message: worst(FeedbackReport.maxMessageLength),
    contactEmail: '${worst(126)}@${worst(127)}',
    app: AppMetadata(
      name: worst(100),
      version: worst(50),
      build: worst(50),
      release: worst(160),
    ),
    platform: PlatformMetadata(
      platform: CrashPlatform.unknown,
      osVersion: worst(100),
      deviceClass: worst(100),
    ),
    // The longest locale the pattern allows.
    locale: 'abc-abcdefgh-abcdefgh-abcdefgh',
    routeTemplate: '/${worst(199)}',
    sessionId: 'a' * 64,
    relatedEventId: '019a3f2e-8d41-7a77-9c5e-1f2a3b4c5d6e',
    user: FeedbackUser(id: worst(100), email: worst(254), name: worst(200)),
    userContext: FeedbackUserContext.check(
      contextOf(FeedbackUserContext.maxEncodedBytes),
    ),
    reporterAssertion: 'a.b.${'c' * 4092}',
    diagnostics: FeedbackDiagnostics.build(
      diagnosticsOf(FeedbackReport.maxDiagnosticsBytes),
    ),
    attachments: const [
      FeedbackAttachmentRef(
        index: 0,
        contentType: FeedbackContentType.webp,
        byteLength: FeedbackAttachmentRef.maxByteLength,
        sha256: exampleSha256,
      ),
    ],
    trail: trail,
  );
}

/// A user context of string values whose compact encoding is [bytes] bytes,
/// its values at their longest and in the costliest character JSON carries
/// (U+0001, six bytes), and its last one of ASCII to reach [bytes] exactly.
/// Built outside a test too, so it checks itself without `expect`.
Map<String, Object?> contextOf(int bytes) {
  String key(int index) => 'k${index.toString().padLeft(2, '0')}';
  final context = <String, Object?>{};
  for (var index = 0; ; index++) {
    // `,"kNN":""` around the next value, or `"k00":""` for the first.
    final available =
        bytes -
        utf8.encode(jsonEncode(context)).length -
        (context.isEmpty ? 8 : 9);
    if (available <= FeedbackUserContext.maxStringLength) {
      context[key(index)] = 'a' * available;
      break;
    }
    // At least a byte left for the next value.
    final length = min(
      FeedbackUserContext.maxStringLength,
      (available - 10) ~/ 6,
    );
    context[key(index)] = '\u0001' * length;
  }
  _check(utf8.encode(jsonEncode(context)).length == bytes, 'context size');
  return context;
}

/// Diagnostics of tokens whose encoding is exactly [bytes] bytes. Built
/// outside a test too, so it checks itself without `expect`.
Map<String, Map<String, Object?>> diagnosticsOf(int bytes) {
  final groups = <String, Map<String, Object?>>{};
  var remaining = bytes - 2; // the outer braces
  var group = 0;
  while (remaining > 0) {
    final values = <String, Object?>{};
    groups['g$group'] = values;
    remaining -= '"g$group":{}'.length + (group > 0 ? 1 : 0);
    var index = 0;
    while (remaining > 0 && index < 32) {
      final overhead = '"v$index":""'.length + (index > 0 ? 1 : 0);
      final length = (remaining - overhead).clamp(1, 64);
      values['v$index'] = 'a' * length;
      remaining -= overhead + length;
      index++;
    }
    group++;
  }
  _check(utf8.encode(jsonEncode(groups)).length == bytes, 'diagnostics size');
  return groups;
}

void _check(bool holds, String what) {
  if (!holds) throw StateError('The helper missed its $what');
}

/// A trail that brings the encoding of [base] with it to exactly [bytes].
/// Built outside a test too, so it checks itself without `expect`.
List<TypedBreadcrumb> trailTo(FeedbackReport base, int bytes) {
  final json = base.toJson();
  int size(List<TypedBreadcrumb> trail) => utf8
      .encode(
        jsonEncode({
          ...json,
          if (trail.isNotEmpty)
            'trail': [for (final item in trail) item.toJson()],
        }),
      )
      .length;

  final trail = <TypedBreadcrumb>[];
  for (
    var remaining = bytes - size(trail);
    remaining > 0;
    remaining = bytes - size(trail)
  ) {
    // What one more item costs with a one-character action.
    final cost = size([...trail, breadcrumb('a')]) - size(trail);
    _check(remaining >= cost, 'trail size');
    final filling = remaining - cost + 1;
    // An item that fills the rest, or one that leaves room for another.
    final length = filling <= 100 ? filling : min(100, remaining - 2 * cost);
    trail.add(breadcrumb('a' * length));
  }
  _check(size(trail) == bytes, 'trail size');
  return trail;
}
