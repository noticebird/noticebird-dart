// NoticebirdClient.captureFeedback against a fake transport that reads every
// report it is given as the platform does: the report the client builds from
// the host's input and its own context, the delivery of a screenshot and a
// report, the reporter assertion and its fallback, the outcome of each
// final refusal, and input the report refuses, in a debug and a release
// build.

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:noticebird/feedback.dart';
import 'package:noticebird/noticebird.dart';
import 'package:noticebird/src/protocol/host_mistakes.dart';

import 'support/fake_feedback_transport.dart';

const _assertionA = 'eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJhIn0.c2lnbmF0dXJlLWE';
const _assertionB = 'eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJiIn0.c2lnbmF0dXJlLWI';

/// A compact JWS whose claims hold [sub] and an `exp` of [expiresAt]; the
/// client reads the claims only, never the signature.
String _assertionUntil(DateTime expiresAt, {String sub = 'a'}) {
  String part(Object json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${part({'alg': 'EdDSA', 'kid': 'k1'})}.'
      '${part({'sub': sub, 'exp': expiresAt.millisecondsSinceEpoch ~/ 1000})}.'
      'c2lnbmF0dXJl';
}

const _app = AppMetadata(
  name: 'test-app',
  version: '1.0.0',
  build: '1',
  release: 'test-app@1.0.0+1',
);
const _platform = PlatformMetadata(
  platform: CrashPlatform.macos,
  osVersion: '15.5',
  deviceClass: 'desktop',
);
const _sessionId = 'random_session_123456';

final _capturedAt = DateTime.utc(2026, 10, 30, 12);
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, //
  ...List.filled(60, 7),
]);

void main() {
  late FakeFeedbackTransport transport;
  late DateTime now;
  late List<String?> assertions;
  late int assertionCalls;

  setUp(() {
    transport = FakeFeedbackTransport();
    now = _capturedAt;
    assertions = [];
    assertionCalls = 0;
  });
  tearDown(() => debugHostMistakesThrow = kDebugMode);

  Future<String?> provideAssertion() async {
    assertionCalls++;
    return assertions.isEmpty ? null : assertions.removeAt(0);
  }

  /// A client, of a release build unless [debugBuild]: whether a mistake
  /// of the host throws.
  NoticebirdClient client({
    CrashPrivacyProfile profile = CrashPrivacyProfile.privacyDefault,
    bool feedback = true,
    Future<String?> Function()? reporterAssertion,
    bool requireVerified = false,
    bool debugBuild = false,
    String Function()? sessionIdFactory,
    AppMetadata app = _app,
    CrashTransport crashTransport = const DiscardingCrashTransport(),
    String Function()? eventIdFactory,
    Map<String, Map<String, Object?>> Function()? contextDiagnostics,
  }) {
    debugHostMistakesThrow = debugBuild;
    return NoticebirdClient(
      config: NoticebirdConfig(
        privacyProfile: profile,
        app: app,
        platform: _platform,
        sessionIdFactory: sessionIdFactory ?? () => _sessionId,
        breadcrumbBuffer: NoticebirdConfig.maxBreadcrumbBuffer,
        feedback: feedback
            ? FeedbackConfig(
                transport: transport,
                reporterAssertion: reporterAssertion ?? provideAssertion,
                requireVerified: requireVerified,
                contextDiagnostics: contextDiagnostics,
              )
            : null,
      ),
      transport: crashTransport,
      clock: () => now,
      eventIdFactory: eventIdFactory,
    );
  }

  Future<FeedbackOutcome> capture(
    NoticebirdClient reporter, {
    String message = 'The list does not load',
    Uint8List? screenshot,
    String? contactEmail,
    Map<String, Map<String, Object?>>? diagnostics,
    Map<String, Object?>? userContext,
    String? relatedEventId,
  }) => reporter.captureFeedback(
    kind: FeedbackKind.bug,
    message: message,
    screenshot: screenshot,
    contactEmail: contactEmail,
    diagnostics: diagnostics,
    userContext: userContext,
    relatedEventId: relatedEventId,
  );

  Map<String, Object?> sent() => transport.submitted.single;

  test(
    'a report with every field is delivered as the client built it',
    () async {
      assertions = [_assertionA];
      final reporter = client()
        ..setUser(
          const CrashUser(
            id: 'user_1',
            email: 'ada@example.com',
            name: 'Ada',
            ipAddress: '10.0.0.1',
          ),
        )
        ..setRouteTemplate('/lists/:listId')
        ..addBreadcrumb(
          TypedBreadcrumb(
            occurredAt: _capturedAt.subtract(const Duration(minutes: 1)),
            category: BreadcrumbCategory.ui,
            action: 'button.tap',
            data: const {AllowedTag.feature: 'lists'},
          ),
        );

      final outcome = await reporter.captureFeedback(
        kind: FeedbackKind.bug,
        message: 'The list does not load',
        trigger: FeedbackTrigger.errorScreen,
        screenshot: _png,
        contactEmail: 'ada@example.com',
        diagnostics: {
          'sync': {
            'pending': 3,
            'online': false,
            'lastSyncAt': DateTime.utc(2026, 10, 30, 11),
            'build': 'abc-1',
          },
        },
        userContext: {
          'plan': 'pro',
          'roles': ['admin', 'editor'],
          'org': {'tier': 2},
        },
        relatedEventId: '0197F232-2BD8-7000-8000-000000000001',
      );

      expect(
        outcome,
        const FeedbackDelivered(ticket: fakeTicket, verified: true),
      );
      expect(transport.requests, ['slot', 'upload', 'submit']);
      expect(transport.uploaded.single, _png);
      final report = sent();
      expect(report, {
        'schemaVersion': 1,
        'reportId': report['reportId'],
        'createdAt': '2026-10-30T12:00:00.000Z',
        'kind': 'bug',
        'trigger': 'errorScreen',
        'message': 'The list does not load',
        'contact': {'email': 'ada@example.com'},
        'app': _app.toJson(),
        'platform': {
          ..._platform.toJson(),
          'locale': PlatformDispatcher.instance.locale.toLanguageTag(),
        },
        'routeTemplate': '/lists/:listId',
        'sessionId': _sessionId,
        'relatedEventId': '0197f232-2bd8-7000-8000-000000000001',
        'user': {'id': 'user_1', 'email': 'ada@example.com', 'name': 'Ada'},
        'userContext': {
          'plan': 'pro',
          'roles': ['admin', 'editor'],
          'org': {'tier': 2},
        },
        'reporterAssertion': _assertionA,
        'trail': [
          {
            'occurredAt': '2026-10-30T11:59:00.000Z',
            'category': 'ui',
            'action': 'button.tap',
            'level': 'info',
            'data': {'feature': 'lists'},
          },
        ],
        'diagnostics': {
          'sync': {
            'pending': 3,
            'online': false,
            'lastSyncAt': '2026-10-30T11:00:00.000Z',
            'build': 'abc-1',
          },
        },
        'attachments': [
          {
            'index': 0,
            'contentType': 'image/png',
            'byteLength': _png.length,
            'sha256': sha256.convert(_png).toString(),
          },
        ],
      });
      expect(transport.slotReportIds.single, report['reportId']);
    },
  );

  group('the context the client fills in', () {
    test('a user is sent without the fields a report refuses', () async {
      final reporter = client()
        ..setUser(
          const CrashUser(id: 'user_1', email: 'a@', ipAddress: '10.0.0.1'),
        );
      await capture(reporter);
      expect(sent()['user'], {'id': 'user_1'});
    });

    test('a user left empty is left out', () async {
      final reporter = client()
        ..setUser(const CrashUser(ipAddress: '10.0.0.1'));
      await capture(reporter);
      expect(sent(), isNot(contains('user')));
    });

    test('the id of setUserId is the user', () async {
      final reporter = client()..setUserId('user_42');
      await capture(reporter);
      expect(sent()['user'], {'id': 'user_42'});
    });

    test('regulatedStrict sends no user, user context or locale', () async {
      final reporter = client(profile: CrashPrivacyProfile.regulatedStrict)
        ..setUser(const CrashUser(id: 'user_1'));
      final outcome = await capture(reporter, userContext: {'plan': 'pro'});

      expect(outcome, isA<FeedbackDelivered>());
      expect(sent(), isNot(contains('user')));
      expect(sent(), isNot(contains('userContext')));
      expect(sent()['platform'], _platform.toJson());
    });

    test('the trail is sanitized and the oldest go until it fits', () async {
      final reporter = client();
      final long = 'x' * 1000;
      for (var index = 0; index < 150; index++) {
        reporter.addBreadcrumb(
          TypedBreadcrumb(
            occurredAt: _capturedAt.subtract(Duration(seconds: 150 - index)),
            category: BreadcrumbCategory.bloc,
            action: 'step.${index.toString().padLeft(3, '0')}',
            data: {
              AllowedTag.feature: long,
              AllowedTag.operation: long,
              AllowedTag.component: long,
              AllowedTag.connectivity: long,
            },
          ),
        );
      }
      reporter.addBreadcrumb(
        TypedBreadcrumb(
          occurredAt: _capturedAt,
          category: BreadcrumbCategory.auth,
          action: 'login.ada@example.com',
          data: const {AllowedTag.feature: 'signed in as ada@example.com'},
        ),
      );

      final outcome = await capture(reporter, message: '€' * 4000);

      expect(outcome, isA<FeedbackDelivered>());
      final report = sent();
      final trail = (report['trail']! as List).cast<Map<String, Object?>>();
      expect(trail.length, lessThan(100));
      expect(trail.last, {
        'occurredAt': '2026-10-30T12:00:00.000Z',
        'category': 'auth',
        'action': 'redacted',
        'level': 'info',
        'data': {'feature': 'signed in as [REDACTED]'},
      });
      expect(trail[trail.length - 2]['action'], 'step.149');
      for (final item in trail) {
        for (final value in (item['data']! as Map).values) {
          expect((value as String).length, lessThanOrEqualTo(100));
        }
      }
      expect(utf8.encode(jsonEncode(report)).length, lessThanOrEqualTo(65536));
      // The next older breadcrumb, the size of the oldest sent, would not
      // have fit.
      final withOneMore = {
        ...report,
        'trail': [trail.first, ...trail],
      };
      expect(utf8.encode(jsonEncode(withOneMore)).length, greaterThan(65536));
      expect(reporter.recentBreadcrumbs, hasLength(151));
    });

    test('a breadcrumb the report refuses is left out alone', () async {
      final reporter = client()
        ..addBreadcrumb(
          TypedBreadcrumb(
            occurredAt: _capturedAt,
            category: BreadcrumbCategory.ui,
            action: 'Not An Action',
          ),
        )
        ..addBreadcrumb(
          TypedBreadcrumb(
            occurredAt: _capturedAt.add(const Duration(minutes: 6)),
            category: BreadcrumbCategory.ui,
            action: 'from.the.future',
          ),
        )
        ..addBreadcrumb(
          TypedBreadcrumb(
            occurredAt: _capturedAt,
            category: BreadcrumbCategory.ui,
            action: 'kept',
          ),
        );
      await capture(reporter);
      expect(
        [for (final item in sent()['trail']! as List) (item as Map)['action']],
        ['kept'],
      );
    });

    test('the message is redacted and cut to 4000 characters', () async {
      await capture(
        client(),
        message: 'Mail ada@example.com, token: abc123 ${'y' * 5000}',
      );
      final message = sent()['message']! as String;
      expect(message, startsWith('Mail [REDACTED], [REDACTED] yyy'));
      expect(message.length, 4000);
    });

    test('a user context holding a JWT or a password key is sent as the '
        'host gave it', () async {
      const context = {
        'plan': 'pro',
        'session': 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl',
        'labels': ['beta', 'password=hunter2'],
        'account': {'password': 'x', 'tier': 'gold'},
      };
      final outcome = await capture(client(), userContext: context);

      expect(
        outcome,
        const FeedbackDelivered(ticket: fakeTicket, verified: false),
      );
      expect(sent()['userContext'], context);
    });

    test('a route template the report refuses is left out, even in a debug '
        'build', () async {
      final reporter = client(debugBuild: true)
        ..setRouteTemplate('/lists/\u0000');
      final outcome = await capture(reporter);
      expect(outcome, isA<FeedbackDelivered>());
      expect(sent(), isNot(contains('routeTemplate')));
    });

    for (final debugBuild in [false, true]) {
      final build = debugBuild ? 'debug' : 'release';
      test('a session id the report refuses fails the report in a $build '
          'build', () async {
        final outcome = await capture(
          client(debugBuild: debugBuild, sessionIdFactory: () => 'short'),
        );
        expect(outcome, const FeedbackRejected(FeedbackRejection.failed));
        expect(transport.requests, isEmpty);
      });

      // The config checks its metadata by the event's rules; the report's
      // refuse a NUL besides.
      test('app metadata the report refuses fails the report in a $build '
          'build', () async {
        final outcome = await capture(
          client(
            debugBuild: debugBuild,
            app: AppMetadata(
              name: 'test\u0000app',
              version: '1.0.0',
              build: '1',
              release: 'test-app@1.0.0+1',
            ),
          ),
        );
        expect(outcome, const FeedbackRejected(FeedbackRejection.failed));
        expect(transport.requests, isEmpty);
      });
    }

    test('a NUL in the message is stripped before the cut, and the report '
        'sent', () async {
      final outcome = await capture(
        client(debugBuild: true),
        message: 'Pasted\u0000 text ${'z' * 4000}',
      );
      expect(outcome, isA<FeedbackDelivered>());
      final message = sent()['message']! as String;
      expect(message, startsWith('Pasted text zzz'));
      expect(message.length, 4000);
    });

    test('the report id is a lowercase UUID v4, new each time', () async {
      final reporter = client();
      for (var index = 0; index < 50; index++) {
        await capture(reporter);
      }
      final ids = {
        for (final report in transport.submitted) report['reportId']! as String,
      };
      expect(ids, hasLength(50));
      for (final id in ids) {
        expect(FeedbackReport.uuidV4.hasMatch(id), isTrue, reason: id);
      }
    });
  });

  group('the delivery', () {
    test('a screenshot of no type a report takes is left out, and the report '
        'sent says so', () async {
      final outcome = await capture(
        client(),
        screenshot: Uint8List.fromList(ascii.encode('GIF89a and more')),
      );
      expect(outcome, isA<FeedbackDelivered>());
      expect(transport.requests, ['submit']);
      expect(sent(), isNot(contains('attachments')));
      expect(sent()['diagnostics'], {
        'noticebird': {'screenshot_dropped': 'unsupported_type'},
      });
    });

    test('a screenshot over 5 MiB is left out by its size before its bytes '
        'are read', () async {
      final outcome = await capture(
        client(),
        screenshot: Uint8List(FeedbackAttachmentRef.maxByteLength + 1)
          ..setAll(0, _png.take(8)),
      );
      expect(outcome, isA<FeedbackDelivered>());
      expect(transport.requests, ['submit']);
      expect(sent()['diagnostics'], {
        'noticebird': {'screenshot_dropped': 'too_large'},
      });
    });

    for (final type in FeedbackContentType.values) {
      test('a ${type.name} screenshot is sent as its bytes say', () async {
        final bytes = switch (type) {
          FeedbackContentType.png => _png,
          FeedbackContentType.jpeg => Uint8List.fromList([
            0xff, 0xd8, 0xff, 0xe0, ...List.filled(20, 1), //
          ]),
          FeedbackContentType.webp => Uint8List.fromList([
            ...ascii.encode('RIFF'), 0, 0, 0, 0, ...ascii.encode('WEBP'), //
            ...List.filled(20, 1),
          ]),
        };
        await capture(client(), screenshot: bytes);
        expect(
          (sent()['attachments']! as List).single,
          containsPair('contentType', type.mimeType),
        );
      });
    }

    for (final (name, queue, answer) in [
      (
        'an acceptance of the slot request',
        'slot',
        const FeedbackAccepted(verified: false),
      ),
      (
        'a slot for the submit',
        'submit',
        FeedbackSlotPending(
          FeedbackUploadSlot(
            uploadUrl: Uri.parse('https://api.noticebird.com/upload'),
            uploadMethod: 'PUT',
          ),
        ),
      ),
      ('a return to the slot without a screenshot', 'submit', null),
    ]) {
      test('$name fails the report at once', () async {
        final withScreenshot = answer != null;
        (queue == 'slot' ? transport.slotAnswers : transport.submitAnswers).add(
          answer ?? const FeedbackBackToSlot(),
        );
        final outcome = await capture(
          client(),
          screenshot: withScreenshot ? _png : null,
        );
        expect(outcome, const FeedbackRejected(FeedbackRejection.failed));
        expect(transport.requests, [
          if (withScreenshot) 'slot',
          if (queue == 'submit') ...[if (withScreenshot) 'upload', 'submit'],
        ]);
      });
    }

    test('stored bytes are not uploaded again', () async {
      transport.slotAnswers.add(const FeedbackAttachmentStored());
      final outcome = await capture(client(), screenshot: _png);
      expect(outcome, isA<FeedbackDelivered>());
      expect(transport.requests, ['slot', 'submit']);
    });

    test('a missing attachment returns to the slot', () async {
      transport.submitAnswers.add(const FeedbackBackToSlot());
      final outcome = await capture(client(), screenshot: _png);
      expect(outcome, isA<FeedbackDelivered>());
      expect(transport.requests, [
        ...['slot', 'upload', 'submit'],
        ...['slot', 'upload', 'submit'],
      ]);
    });

    test('after two returns to the slot the report is not delivered '
        'now', () async {
      transport.submitAnswers.addAll(
        List.filled(3, const FeedbackBackToSlot()),
      );
      final outcome = await capture(client(), screenshot: _png);
      expect(outcome, const FeedbackRejected(FeedbackRejection.noStore));
      expect(transport.requests, [
        for (var round = 0; round < 3; round++) ...['slot', 'upload', 'submit'],
      ]);
    });

    for (final (name, answer) in [
      ('a rate limit', const FeedbackRetryAfter(Duration(seconds: 30))),
      ('a transient answer', const FeedbackTransient()),
    ]) {
      test('$name without a store is noStore', () async {
        transport.submitAnswers.add(answer);
        expect(
          await capture(client()),
          const FeedbackRejected(FeedbackRejection.noStore),
        );
      });
    }

    test('a transport that throws is a transient answer', () async {
      transport.submitThrows = true;
      expect(
        await capture(client()),
        const FeedbackRejected(FeedbackRejection.noStore),
      );
    });

    final refusals = <(FeedbackFinalRefusal, FeedbackRejection)>[
      (
        const FeedbackFinalRefusal(
          code: 'invalid_report',
          violation: ProtocolViolation.invalidValue,
          path: r'$.user',
        ),
        FeedbackRejection.strictProject,
      ),
      (
        const FeedbackFinalRefusal(
          code: 'invalid_report',
          violation: ProtocolViolation.invalidValue,
          path: r'$.userContext',
        ),
        FeedbackRejection.strictProject,
      ),
      (
        const FeedbackFinalRefusal(
          code: 'invalid_report',
          violation: ProtocolViolation.invalidValue,
          path: r'$.createdAt',
        ),
        FeedbackRejection.clock,
      ),
      (
        const FeedbackFinalRefusal(
          code: 'invalid_report',
          violation: ProtocolViolation.unknownField,
          path: r'$.userContext',
        ),
        FeedbackRejection.refused,
      ),
      (
        const FeedbackFinalRefusal(
          code: 'invalid_report',
          violation: ProtocolViolation.oversized,
          path: r'$.user',
        ),
        FeedbackRejection.refused,
      ),
      (
        const FeedbackFinalRefusal(
          code: 'invalid_report',
          violation: ProtocolViolation.invalidType,
          path: r'$.createdAt',
        ),
        FeedbackRejection.refused,
      ),
      (
        const FeedbackFinalRefusal(code: 'feedback_disabled'),
        FeedbackRejection.notAccepted,
      ),
      (
        const FeedbackFinalRefusal(
          code: 'invalid_report',
          violation: ProtocolViolation.invalidValue,
          path: r'$.message',
        ),
        FeedbackRejection.refused,
      ),
      (const FeedbackFinalRefusal(), FeedbackRejection.refused),
      // To a first submit: another report under this id.
      (
        const FeedbackFinalRefusal(code: 'report_conflict'),
        FeedbackRejection.refused,
      ),
    ];
    for (final (refusal, reason) in refusals) {
      test('${refusal.code} ${refusal.violation?.name} at ${refusal.path} is '
          '${reason.name}', () async {
        transport.submitAnswers.add(refusal);
        expect(
          await capture(client()),
          FeedbackRejected(reason, path: refusal.path, code: refusal.code),
        );
      });
    }

    test('attachments_disabled at the slot is notAccepted', () async {
      transport.slotAnswers.add(
        const FeedbackFinalRefusal(code: 'attachments_disabled'),
      );
      expect(
        await capture(client(), screenshot: _png),
        const FeedbackRejected(
          FeedbackRejection.notAccepted,
          code: 'attachments_disabled',
        ),
      );
      expect(transport.requests, ['slot']);
    });
  });

  group('the reporter assertion', () {
    test('a refused assertion resends the report at once without it, the '
        'provider not asked again', () async {
      assertions = [_assertionA, _assertionB];
      transport.submitAnswers.add(const FeedbackAssertionRefused());

      final outcome = await capture(client());

      expect(
        outcome,
        const FeedbackDelivered(ticket: fakeTicket, verified: false),
      );
      expect(assertionCalls, 1);
      final [first, second] = transport.submitted;
      expect(first['reporterAssertion'], _assertionA);
      expect(second, {...first}..remove('reporterAssertion'));
    });

    test('a report refused again without its assertion is '
        'refused', () async {
      assertions = [_assertionA];
      transport.submitAnswers.addAll([
        const FeedbackAssertionRefused(),
        const FeedbackAssertionRefused(),
      ]);

      final outcome = await capture(client());

      expect(
        outcome,
        const FeedbackRejected(
          FeedbackRejection.refused,
          code: 'invalid_reporter_assertion',
        ),
      );
      expect(assertionCalls, 1);
      expect(transport.submitted, hasLength(2));
    });

    test('requireVerified rejects a report whose assertion is refused, the '
        'provider not asked again', () async {
      assertions = [_assertionA];
      transport.submitAnswers.add(const FeedbackAssertionRefused());

      final outcome = await capture(client(requireVerified: true));

      expect(
        outcome,
        const FeedbackRejected(
          FeedbackRejection.unverified,
          code: 'invalid_reporter_assertion',
        ),
      );
      expect(assertionCalls, 1);
      expect(transport.submitted, hasLength(1));
    });

    test('requireVerified sends nothing without an assertion', () async {
      final outcome = await capture(client(requireVerified: true));
      expect(outcome, const FeedbackRejected(FeedbackRejection.unverified));
      expect(transport.requests, isEmpty);
    });

    test('requireVerified needs a provider', () {
      expect(
        () => FeedbackConfig(transport: transport, requireVerified: true),
        throwsArgumentError,
      );
    });

    test('a provider that throws leaves the report without one', () async {
      final outcome = await capture(
        client(reporterAssertion: () async => throw StateError('offline')),
      );
      expect(outcome, isA<FeedbackDelivered>());
      expect(sent(), isNot(contains('reporterAssertion')));
    });

    test('an assertion the report refuses is left out', () async {
      assertions = ['not a token'];
      await capture(client());
      expect(sent(), isNot(contains('reporterAssertion')));
    });

    test('a provider that hangs is given 5 seconds', () {
      fakeAsync((async) {
        FeedbackOutcome? outcome;
        capture(
          client(reporterAssertion: () => Completer<String?>().future),
        ).then((value) => outcome = value);

        async.elapse(const Duration(seconds: 4));
        expect(outcome, isNull);
        expect(transport.requests, isEmpty);

        async.elapse(const Duration(seconds: 1));
        expect(outcome, isA<FeedbackDelivered>());
        expect(sent(), isNot(contains('reporterAssertion')));
      });
    });
  });

  group('the held reporter assertion', () {
    const ada = CrashUser(id: 'user_1', email: 'ada@example.com');
    late String fresh;
    setUp(
      () => fresh = _assertionUntil(_capturedAt.add(const Duration(hours: 1))),
    );

    test('a report of the same user within the token\'s life asks no '
        'provider, and carries the same token', () async {
      assertions = [fresh, _assertionB];
      final reporter = client()..setUser(ada);

      await capture(reporter);
      now = _capturedAt.add(const Duration(minutes: 54));
      await capture(reporter);

      expect(assertionCalls, 1);
      expect(transport.submitted.map((report) => report['reporterAssertion']), [
        fresh,
        fresh,
      ]);
    });

    test('a token within 5 minutes of its exp is asked for anew', () async {
      assertions = [fresh, _assertionB];
      final reporter = client()..setUser(ada);

      await capture(reporter);
      now = _capturedAt.add(const Duration(minutes: 55));
      await capture(reporter);

      expect(assertionCalls, 2);
      expect(transport.submitted.last['reporterAssertion'], _assertionB);
    });

    test('another user, and none, ask again', () async {
      assertions = [fresh, _assertionB, _assertionA];
      final reporter = client()..setUser(ada);

      await capture(reporter);
      reporter.setUser(const CrashUser(id: 'user_2'));
      await capture(reporter);
      reporter.setUser(null);
      await capture(reporter);

      expect(assertionCalls, 3);
      expect(transport.submitted.map((report) => report['reporterAssertion']), [
        fresh,
        _assertionB,
        _assertionA,
      ]);
    });

    test('the same user with a new address asks again', () async {
      assertions = [fresh, _assertionB];
      final reporter = client()..setUser(ada);

      await capture(reporter);
      reporter.setUser(const CrashUser(id: 'user_1', email: 'ada@new.test'));
      await capture(reporter);

      expect(assertionCalls, 2);
    });

    test('setUserId holds a token for that id', () async {
      assertions = [fresh, _assertionB];
      final reporter = client()..setUserId('user_1');

      await capture(reporter);
      await capture(reporter);
      reporter.setUserId(null);
      await capture(reporter);

      expect(assertionCalls, 2);
    });

    test('without a user every report asks', () async {
      assertions = [fresh, fresh];
      final reporter = client();

      await capture(reporter);
      await capture(reporter);

      expect(assertionCalls, 2);
    });

    test('a token the platform refused is asked for anew', () async {
      assertions = [fresh, _assertionB];
      transport.submitAnswers.add(const FeedbackAssertionRefused());
      final reporter = client()..setUser(ada);

      await capture(reporter);
      await capture(reporter);

      expect(assertionCalls, 2);
      expect(transport.submitted.last['reporterAssertion'], _assertionB);
    });

    test('a token without a readable exp is not held', () async {
      assertions = [_assertionA, _assertionA];
      final reporter = client()..setUser(ada);

      await capture(reporter);
      await capture(reporter);

      expect(assertionCalls, 2);
    });

    test('reports captured at once share one provider call', () async {
      final answer = Completer<String?>();
      final reporter = client(
        reporterAssertion: () {
          assertionCalls++;
          return answer.future;
        },
      )..setUser(ada);

      final both = Future.wait([capture(reporter), capture(reporter)]);
      answer.complete(fresh);
      await both;

      expect(assertionCalls, 1);
      expect(transport.submitted.map((report) => report['reporterAssertion']), [
        fresh,
        fresh,
      ]);
    });
  });

  group('the diagnostics a host passes', () {
    Future<Object?> diagnosticsOf(
      Map<String, Map<String, Object?>> diagnostics,
    ) async {
      final outcome = await capture(client(), diagnostics: diagnostics);
      expect(outcome, isA<FeedbackDelivered>());
      return sent()['diagnostics'];
    }

    test('lose what the report refuses, counted, and the report is '
        'sent', () async {
      expect(
        await diagnosticsOf({
          'sync': {
            'pending': 3,
            'note': 'free text here',
            'Bad key': 1,
            'nested': {'a': 1},
            'ratio': double.nan,
          },
          'Sync': {'pending': 1, 'held': 2},
        }),
        {
          'sync': {'pending': 3},
          'noticebird': {'dropped_values': 6},
        },
      );
    });

    test('take an enum by its name and a moment in UTC', () async {
      expect(
        await diagnosticsOf({
          'sync': {
            'kind': FeedbackKind.idea,
            'at': DateTime.utc(2026, 10, 30, 11).toLocal(),
          },
        }),
        {
          'sync': {'kind': 'idea', 'at': '2026-10-30T11:00:00.000Z'},
        },
      );
    });

    test('a group named noticebird is the client\'s', () async {
      expect(
        await diagnosticsOf({
          'noticebird': {'dropped_values': 0},
        }),
        {
          'noticebird': {'dropped_values': 1},
        },
      );
    });

    test('keep 15 groups and 32 values a group, room left for the '
        'note', () async {
      final diagnostics = await diagnosticsOf({
        for (var group = 0; group < 17; group++)
          'g$group': {for (var value = 0; value < 33; value++) 'v$value': 1},
      });
      final groups = diagnostics! as Map<String, Object?>;
      expect(groups.keys, [
        for (var group = 0; group < 15; group++) 'g$group',
        'noticebird',
      ]);
      expect((groups['g0']! as Map).length, 32);
      expect(groups['noticebird'], {'dropped_values': 15 + 2 * 33});
    });

    test('leave out the last groups until they fit 16 KiB', () async {
      final token = 'x' * 64;
      final diagnostics = await diagnosticsOf({
        for (var group = 0; group < 10; group++)
          'g$group': {
            for (var value = 0; value < 32; value++) 'v$value': token,
          },
      });
      final groups = diagnostics! as Map<String, Object?>;
      expect(
        utf8.encode(jsonEncode(groups)).length,
        lessThanOrEqualTo(FeedbackReport.maxDiagnosticsBytes),
      );
      expect(groups.keys.first, 'g0');
      expect(groups.keys.last, 'noticebird');
      final kept = groups.length - 1;
      expect(groups['noticebird'], {'dropped_values': (10 - kept) * 32});
    });
  });

  group('the moment', () {
    test('a report sends the route and context groups of its moment, and '
        'when it was taken', () async {
      var live = 1;
      final reporter = client(
        contextDiagnostics: () => {
          'blocs': {'count': live},
        },
      )..setRouteTemplate('/lists/:listId');
      final moment = reporter.feedbackMoment();
      live = 2;
      reporter.setRouteTemplate('/feedback');
      now = _capturedAt.add(const Duration(minutes: 2));

      await reporter.captureFeedback(
        kind: FeedbackKind.bug,
        message: 'The list does not load',
        moment: moment,
        diagnostics: {
          'blocs': {'count': 9},
          'sync': {'pending': 1},
        },
      );

      expect(sent()['routeTemplate'], '/lists/:listId');
      expect(sent()['diagnostics'], {
        'blocs': {'count': 1},
        'sync': {'pending': 1},
        'noticebird': {
          'moment_taken_at': '2026-10-30T12:00:00.000Z',
          'dropped_values': 1,
        },
      });
    });

    test('without a moment it is taken at the capture, with no note of '
        'it', () async {
      final reporter = client(
        contextDiagnostics: () => {
          'blocs': {'count': 3},
        },
      )..setRouteTemplate('/lists/:listId');

      await capture(reporter);

      expect(sent()['routeTemplate'], '/lists/:listId');
      expect(sent()['diagnostics'], {
        'blocs': {'count': 3},
      });
    });

    test('a route template named for the moment is the report\'s', () async {
      final reporter = client()..setRouteTemplate('/home');

      await reporter.captureFeedback(
        kind: FeedbackKind.idea,
        message: 'More colours',
        moment: reporter.feedbackMoment(routeTemplate: '/lists/:listId'),
      );

      expect(sent()['routeTemplate'], '/lists/:listId');
    });

    test('a raw route for the moment throws in a debug build and is left '
        'out in a release build', () async {
      expect(
        () =>
            client(debugBuild: true).feedbackMoment(routeTemplate: '/lists/42'),
        throwsArgumentError,
      );
      final reporter = client()..setRouteTemplate('/home');
      expect(
        reporter.feedbackMoment(routeTemplate: '/lists/42').routeTemplate,
        isNull,
      );
    });

    test(
      'context groups that throw add nothing, and the report goes',
      () async {
        final outcome = await capture(
          client(contextDiagnostics: () => throw StateError('observer gone')),
        );
        expect(outcome, isA<FeedbackDelivered>());
        expect(sent(), isNot(contains('diagnostics')));
      },
    );
  });

  group('input the report refuses', () {
    final cases =
        <(String, Future<FeedbackOutcome> Function(NoticebirdClient), String)>[
          ('an empty message', (c) => capture(c, message: ''), r'$.message'),
          (
            'a contact address',
            (c) => capture(c, contactEmail: 'not an address'),
            r'$.contact.email',
          ),
          (
            'a user context nested too deep',
            (c) => capture(
              c,
              userContext: {
                'plan': {
                  'tier': {'level': 1},
                },
              },
            ),
            r'$.userContext.plan.tier',
          ),
          (
            'an empty user context',
            (c) => capture(c, userContext: {}),
            r'$.userContext',
          ),
          (
            'a related event id that is no UUID',
            (c) => capture(c, relatedEventId: 'event-1'),
            r'$.relatedEventId',
          ),
        ];

    for (final (name, call, path) in cases) {
      test('$name is rejected in a release build, with nothing sent', () async {
        assertions = [_assertionA];
        final outcome = await call(client());
        expect(
          outcome,
          FeedbackRejected(FeedbackRejection.invalidInput, path: path),
        );
        expect(transport.requests, isEmpty);
        expect(assertionCalls, 0);
      });

      test('$name throws in a debug build', () async {
        await expectLater(call(client(debugBuild: true)), throwsArgumentError);
        expect(transport.requests, isEmpty);
      });
    }

    test('valid input is not refused in a debug build', () async {
      final outcome = await capture(
        client(debugBuild: true),
        screenshot: _png,
        contactEmail: 'ada@example.com',
      );
      expect(outcome, isA<FeedbackDelivered>());
    });

    test('a contact address is checked by the report rule', () {
      expect(FeedbackContact.isValid('ada@example.com'), isTrue);
      expect(FeedbackContact.isValid('a@b'), isTrue);
      expect(FeedbackContact.isValid('ada'), isFalse);
      expect(FeedbackContact.isValid('ada lovelace@example.com'), isFalse);
      expect(FeedbackContact.isValid('${'a' * 250}@b.cd'), isFalse);
    });
  });

  test('without a feedback config nothing is sent', () async {
    expect(await capture(client(feedback: false)), const FeedbackDisabled());
  });

  test('a session id factory that throws fails the report, not the '
      'host', () async {
    final outcome = await capture(
      client(sessionIdFactory: () => throw StateError('no session')),
    );
    expect(outcome, const FeedbackRejected(FeedbackRejection.failed));
    expect(transport.requests, isEmpty);
  });

  group('a report about a captured error', () {
    final uuid = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    );

    Future<(CaptureResult, Map<String, dynamic>)> captureError(
      NoticebirdClient reporter,
      _RecordingCrashTransport crashes,
    ) async {
      final result = await reporter.captureException(
        StateError('sync failed'),
        StackTrace.fromString('#0 Sync.run (package:app/sync.dart:1:1)'),
      );
      expect(result.outcome, CaptureOutcome.sent);
      return (result, crashes.events.single);
    }

    test('names the event of the default id factory, whose fallback id has '
        'no version nibble', () async {
      final crashes = _RecordingCrashTransport();
      final reporter = client(crashTransport: crashes);
      final (result, event) = await captureError(reporter, crashes);
      expect(result.eventId, event['eventId']);
      expect(result.eventId, matches(uuid));

      final outcome = await capture(reporter, relatedEventId: result.eventId);

      expect(outcome, isA<FeedbackDelivered>());
      expect(sent()['relatedEventId'], result.eventId!.toLowerCase());
    });

    test('names the event of a UUIDv7 id factory, lowercased', () async {
      final crashes = _RecordingCrashTransport();
      final reporter = client(
        crashTransport: crashes,
        eventIdFactory: () => '0197F232-2BD8-7ABC-8DEF-0123456789AB',
      );
      final (result, event) = await captureError(reporter, crashes);
      expect(result.eventId, '0197F232-2BD8-7ABC-8DEF-0123456789AB');
      expect(event['eventId'], result.eventId);

      final outcome = await capture(reporter, relatedEventId: result.eventId);

      expect(outcome, isA<FeedbackDelivered>());
      expect(sent()['relatedEventId'], '0197f232-2bd8-7abc-8def-0123456789ab');
    });
  });

  test('the facade answers null without a client', () async {
    Noticebird.detach();
    expect(
      Noticebird.captureFeedback(kind: FeedbackKind.idea, message: 'Dark mode'),
      isNull,
    );
    Noticebird.attach(client());
    addTearDown(Noticebird.detach);
    expect(
      await Noticebird.captureFeedback(
        kind: FeedbackKind.idea,
        message: 'Dark mode',
      ),
      isA<FeedbackDelivered>(),
    );
  });

  test('every report the client builds from generated input is one the '
      'platform reads', () async {
    final random = Random(20261030);
    String pick(List<String> values) => values[random.nextInt(values.length)];
    String text(int maxPieces) => [
      for (var piece = random.nextInt(maxPieces); piece >= 0; piece--)
        pick([
          'word ',
          'ada@example.com ',
          '+31 6 12345678 ',
          'Bearer abc.def ',
          'glucose: 5.4 ',
          'password=hunter2 ',
          '0197f232-2bd8-7000-8000-000000000001 ',
          '€😀 ',
          '10.0.0.1 ',
          'x' * random.nextInt(300),
        ]),
    ].join();

    for (var round = 0; round < 60; round++) {
      transport = FakeFeedbackTransport();
      final reporter = client()
        ..setUser(
          CrashUser(
            id: random.nextBool() ? 'user_${random.nextInt(99)}' : null,
            email: pick(['a@', 'ada@example.com', 'x' * 254]),
            name: pick(['Ada', 'n' * 200]),
          ),
        );
      for (var index = random.nextInt(130); index > 0; index--) {
        reporter.addBreadcrumb(
          TypedBreadcrumb(
            occurredAt: _capturedAt.add(
              Duration(seconds: random.nextInt(600) - 500),
            ),
            category: BreadcrumbCategory
                .values[random.nextInt(BreadcrumbCategory.values.length)],
            action:
                pick(['tap', 'route.push', 'Route Push', 'a' * 150]) +
                (random.nextBool() ? '' : '.ada@example.com'),
            data: {
              AllowedTag.feature: text(4),
              AllowedTag.operation: text(2),
              AllowedTag.retryCount: random.nextInt(5),
            },
          ),
        );
      }
      final outcome = await capture(
        reporter,
        message: 'm${text(40)}',
        userContext: {
          for (var key = random.nextInt(32); key >= 0; key--)
            '${pick(['plan', 'role', 'apiToken', 'note', 'glucose', 'email'])}'
                '$key': pick([
              'ada@example.com',
              'Bearer abc',
              'pro',
              '€' * 40,
            ]),
        },
      );

      expect(outcome, isA<FeedbackDelivered>(), reason: 'round $round');
    }
  });
}

/// A [CrashTransport] that keeps each event as the wire carries it.
final class _RecordingCrashTransport implements CrashTransport {
  final events = <Map<String, dynamic>>[];

  @override
  Future<void> send(String eventJson) async {
    events.add(jsonDecode(eventJson) as Map<String, dynamic>);
  }
}
