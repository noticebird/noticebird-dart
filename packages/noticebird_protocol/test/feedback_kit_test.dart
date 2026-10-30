// The feedback report v1 conformance kit (schema/README.md): the valid
// fixtures and the reports the tests build against the JSON Schema, the
// builder against the valid fixtures, and the HTTP pairs against the schema
// and the builder. The invalid corpus is the platform's.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:json_schema/json_schema.dart';
import 'package:noticebird_protocol/feedback.dart';
import 'package:noticebird_protocol/noticebird_protocol.dart';
import 'package:test/test.dart';

import 'support/feedback_reports.dart';

const _kit = 'test/fixtures/feedback/v1';

final _schema = JsonSchema.create(
  File('schema/feedback-report.v1.schema.json').readAsStringSync(),
);

List<File> _files(String folder) =>
    Directory('$_kit/$folder')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

String _name(File file) => file.uri.pathSegments.last;

Map<String, Object?> _object(String source) =>
    jsonDecode(source) as Map<String, Object?>;

void _expectSchemaValid(Object? json, {required bool valid, String? reason}) {
  final result = _schema.validate(json);
  expect(result.isValid, valid, reason: '$reason ${result.errors}');
}

/// [value] with every number as a double: the kit compares numbers by
/// value, `5`, `5.0` and `5e0` being one number.
Object? _numbersByValue(Object? value) => switch (value) {
  Map() => {
    for (final MapEntry(:key, value: child) in value.entries)
      key: _numbersByValue(child),
  },
  List() => [for (final item in value) _numbersByValue(item)],
  num() => value.toDouble(),
  _ => value,
};

FeedbackContentType? _contentType(Object? mimeType) => FeedbackContentType
    .values
    .where((type) => type.mimeType == mimeType)
    .firstOrNull;

/// The reference a slot body declares, built from its values; `null` for a
/// content type the model has none of.
FeedbackAttachmentRef? _slotRef(Map<String, Object?> body, int index) =>
    switch (_contentType(body['contentType'])) {
      final contentType? => FeedbackAttachmentRef(
        index: index,
        contentType: contentType,
        byteLength: body['byteLength']! as int,
        sha256: body['sha256']! as String,
      ),
      null => null,
    };

void main() {
  group('every valid fixture', () {
    for (final file in _files('valid')) {
      final name = _name(file);

      test('$name validates against the schema', () {
        _expectSchemaValid(
          jsonDecode(file.readAsStringSync()),
          valid: true,
          reason: name,
        );
      });
    }
  });

  group('the builder writes a valid fixture from its values', () {
    const app = AppMetadata(
      name: 'justorganize',
      version: '1.8.0',
      build: '412',
      release: 'justorganize@1.8.0+412',
    );
    final createdAt = DateTime.utc(2026, 10, 29, 14, 3, 12, 418);

    Object? fixture(String name) =>
        jsonDecode(File('$_kit/valid/$name').readAsStringSync());

    test('minimal.json', () {
      final report = FeedbackReport(
        reportId: '7c9e6679-7425-40de-944b-e07fc1f90ae7',
        createdAt: createdAt,
        kind: FeedbackKind.idea,
        message: 'A dark theme for the widgets would be nice.',
        app: app,
        platform: const PlatformMetadata(
          platform: CrashPlatform.android,
          osVersion: '16',
          deviceClass: 'phone',
        ),
        sessionId: 'p_7Hq2xK9mR4tW1zY6',
      );
      expect(jsonDecode(report.toJsonString()), fixture('minimal.json'));
    });

    test('screenshot.json', () {
      final report = FeedbackReport(
        reportId: '3b0c6f2e-8d41-4a77-9c5e-1f2a3b4c5d6e',
        createdAt: createdAt,
        kind: FeedbackKind.bug,
        trigger: FeedbackTrigger.shake,
        message: 'The list jumps back to the top when I tick off an item.',
        app: app,
        platform: const PlatformMetadata(
          platform: CrashPlatform.ios,
          osVersion: '26.1',
          deviceClass: 'phone',
        ),
        locale: 'nl-NL',
        routeTemplate: '/collections/:collectionId',
        sessionId: 'p_7Hq2xK9mR4tW1zY6',
        userContext: FeedbackUserContext.check({
          'beta': true,
          'features': ['sharing', 'widgets'],
          'plan': {'seats': 5, 'tier': 'premium'},
          'role': 'owner',
        }),
        trail: [
          TypedBreadcrumb(
            occurredAt: DateTime.utc(2026, 10, 29, 14, 2, 40, 112),
            category: BreadcrumbCategory.navigation,
            action: 'route.push',
          ),
          TypedBreadcrumb(
            occurredAt: DateTime.utc(2026, 10, 29, 14, 3, 1, 903),
            category: BreadcrumbCategory.ui,
            action: 'record.toggle',
            data: const {
              AllowedTag.component: 'record_tile',
              AllowedTag.feature: 'collections',
            },
          ),
        ],
        diagnostics: FeedbackDiagnostics.build({
          'sync': {
            'lastPullAt': DateTime.utc(2026, 10, 29, 14, 1, 55),
            'outboxPending': 3,
            'realtimeConnected': true,
          },
          'subscription': {'tier': 'premium'},
        }),
        attachments: const [
          FeedbackAttachmentRef(
            index: 0,
            contentType: FeedbackContentType.png,
            byteLength: 68,
            sha256:
                '7ac2abfce2be8b46dd9826d597d94edeefc1570b4a992622721b90a1850e3ee9',
          ),
        ],
      );
      expect(jsonDecode(report.toJsonString()), fixture('screenshot.json'));
    });
  });

  group('the reports the tests build validate against the schema', () {
    for (final (name, report) in [
      ('the minimal report', minimalReport()),
      ('the full report', fullReport()),
      ('the worst case of every field', worstReport()),
      (
        'a report of exactly 65536 bytes',
        worstReport(trail: trailTo(worstReport(), 65536)),
      ),
      (
        'a report with every diagnostics value kind',
        fullReport(
          diagnostics: FeedbackDiagnostics.build({
            'kinds': {
              'flag': false,
              'count': 7,
              'ratio': 0.125,
              'at': DateTime.utc(2026, 10, 29, 14),
              'atText': '2026-10-29T14:00:00Z',
              'space': '0b6a4f1e-1c2d-4e3f-8a9b-0c1d2e3f4a5b',
              'event': '019a3f2e-8d41-7a77-9c5e-1f2a3b4c5d6e',
              'tier': 'premium',
            },
          }),
        ),
      ),
    ]) {
      test(name, () {
        _expectSchemaValid(report.toJson(), valid: true, reason: name);
        _expectSchemaValid(
          jsonDecode(report.toJsonString()),
          valid: true,
          reason: name,
        );
      });
    }
  });

  group('every HTTP pair', () {
    Map<String, Object?> pair(String name) =>
        _object(File('$_kit/http/$name').readAsStringSync());

    /// The request's body as the client sends it.
    List<int> body(Map<String, Object?> request) => switch (request) {
      {'body': final Object body} => utf8.encode(jsonEncode(body)),
      {'bodyFile': final String file} => File('$_kit/$file').readAsBytesSync(),
      _ => const [],
    };

    /// The report id and index of a slot or upload path, when both are in
    /// their canonical form: else the server answers 404, unread.
    ({String reportId, int index})? canonicalSlot(String path) {
      final match = RegExp(
        r'^/v1/feedback/([^/]+)/attachments/([^/]+)$',
      ).firstMatch(path);
      expect(match, isNotNull, reason: path);
      final reportId = match![1]!;
      final index = match[2]!;
      if (!FeedbackReport.uuidV4.hasMatch(reportId) ||
          !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(index)) {
        return null;
      }
      return (reportId: reportId, index: int.parse(index));
    }

    Matcher refusedAs(Map<String, Object?>? answer) => throwsA(
      isA<ProtocolException>()
          .having((e) => e.violation.name, 'violation', answer!['violation'])
          .having((e) => e.path, 'path', answer['path']),
    );

    for (final file in _files('http')) {
      final name = _name(file);

      test('$name is a request and its answer, of the kit\'s fixtures', () {
        final json = pair(name);
        expect(
          json.keys.toSet().difference({
            'description',
            'given',
            'request',
            'response',
          }),
          isEmpty,
        );
        expect(json['description'], isA<String>());
        for (final given
            in (json['given'] as List?)?.cast<String>() ?? const <String>[]) {
          expect(File('$_kit/http/$given').existsSync(), true, reason: given);
        }
        final request = Map<String, Object?>.from(json['request']! as Map);
        final response = Map<String, Object?>.from(json['response']! as Map);
        expect(
          request.keys.toSet().difference({
            'method',
            'path',
            'headers',
            'body',
            'bodyFile',
          }),
          isEmpty,
        );
        expect(
          response.keys.toSet().difference({'status', 'headers', 'body'}),
          isEmpty,
        );
        expect(
          request.containsKey('body') && request.containsKey('bodyFile'),
          false,
        );
        if (request['bodyFile'] case final String bodyFile) {
          expect(File('$_kit/$bodyFile').existsSync(), true, reason: bodyFile);
        }
        expect(response['status'], isA<int>());
      });

      test(
        '$name sends a body the schema and the builder take as its answer says',
        () {
          final json = pair(name);
          final request = Map<String, Object?>.from(json['request']! as Map);
          final response = Map<String, Object?>.from(json['response']! as Map);
          final status = response['status']! as int;
          final answer = response['body'] as Map<String, Object?>?;
          final bytes = body(request);
          final path = request['path']! as String;

          switch (request['method']) {
            case 'POST' when path == '/v1/feedback':
              final report = jsonDecode(utf8.decode(bytes));
              if (status == 413) {
                expect(
                  bytes.length,
                  greaterThan(FeedbackReport.maxEncodedBytes),
                );
              } else {
                // A 400 is a report the schema refuses; any other a report a
                // client may send.
                _expectSchemaValid(report, valid: status != 400, reason: name);
                if (status == 200 || status == 202) {
                  expect(answer!['reportId'], (report as Map)['reportId']);
                }
              }
            case 'POST':
              final slotAt = canonicalSlot(path);
              expect(slotAt == null, status == 404, reason: path);
              if (slotAt == null) {
                expect(
                  answer,
                  isNull,
                  reason: "a 404's body is not part of the contract",
                );
              } else if (status == 400) {
                // No client can build it: the model has no such content type,
                // or its writer refuses the reference as the server does.
                final slot = _slotRef(
                  jsonDecode(utf8.decode(bytes)) as Map<String, Object?>,
                  slotAt.index,
                );
                if (slot == null) {
                  expect(answer!['path'], r'$.contentType');
                } else {
                  expect(slot.toSlotJson, refusedAs(answer));
                }
              } else {
                final body =
                    jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
                final slot = _slotRef(body, slotAt.index)!;
                // What the client writes for the reference it declares.
                expect(slot.toSlotJson(), body);
                if (answer case {
                  'uploaded': false,
                  'uploadUrl': final String url,
                }) {
                  // Relative, so it keeps the host and a proxy's path prefix
                  // of the URL the client sent the slot request to.
                  expect(Uri.parse(url).isAbsolute, isFalse, reason: url);
                  for (final api in [
                    'https://api.noticebird.com',
                    'https://proxy.example.com/noticebird',
                    'http://10.0.2.2:8080',
                  ]) {
                    final slotUrl = Uri.parse('$api$path');
                    expect(slotUrl.resolve(url), slotUrl, reason: api);
                  }
                  expect(answer['uploadHeaders'], {
                    'content-type': slot.contentType.mimeType,
                  });
                }
              }
            case 'PUT':
              expect(canonicalSlot(path), isNotNull, reason: path);
              final headers = Map<String, Object?>.from(
                request['headers']! as Map,
              );
              expect(
                headers['content-length'],
                status == 411 ? isNull : '${bytes.length}',
              );
              // The slot it uploads to declared exactly these bytes.
              final slots = [
                for (final given in (json['given']! as List).cast<String>())
                  if (Map<String, Object?>.from(pair(given)['request']! as Map)
                      case {
                        'method': 'POST',
                        'path': final String slotAt,
                        'body': final Map<String, Object?> slotBody,
                      } when slotAt == path)
                    _slotRef(slotBody, 0)!,
              ];
              expect(slots, hasLength(1));
              final declared =
                  slots.single.byteLength == bytes.length &&
                  slots.single.sha256 == sha256.convert(bytes).toString();
              expect(
                declared,
                answer?['error'] != 'attachment_conflict',
                reason:
                    'a 409 attachment_conflict is other bytes than declared',
              );
              if (status == 204 || status == 415) {
                expect(
                  slots.single.contentType.matches(bytes),
                  status == 204,
                  reason: 'a 415 is a signature that is not the declared type',
                );
              }
            default:
              fail('Unknown method ${request['method']}');
          }
        },
      );
    }

    test('submit_replay_context_numbers.json is valid/screenshot.json, its '
        'numbers by value', () {
      final screenshot = jsonDecode(
        File('$_kit/valid/screenshot.json').readAsStringSync(),
      );
      final replay = Map<String, Object?>.from(
        pair('submit_replay_context_numbers.json')['request']! as Map,
      )['body'];
      expect(
        ((replay! as Map)['userContext'] as Map)['plan'],
        containsPair('seats', isA<double>()),
        reason: 'it writes 5.0 for the 5 of the accepted report',
      );
      expect(_numbersByValue(replay), _numbersByValue(screenshot));
    });

    test('submit_report_conflict.json is valid/screenshot.json with another '
        'userContext.role', () {
      final screenshot =
          jsonDecode(File('$_kit/valid/screenshot.json').readAsStringSync())
              as Map<String, Object?>;
      final conflict = Map<String, Object?>.from(
        Map<String, Object?>.from(
              pair('submit_report_conflict.json')['request']! as Map,
            )['body']!
            as Map,
      );
      final context = Map<String, Object?>.from(
        conflict['userContext']! as Map,
      );
      final screenshotContext = Map<String, Object?>.from(
        screenshot['userContext']! as Map,
      );
      expect(context['role'], isNot(screenshotContext['role']));
      expect({
        ...conflict,
        'userContext': {...context, 'role': screenshotContext['role']},
      }, screenshot);
    });

    test('valid/screenshot.json declares the bytes of the HTTP flow', () {
      final report =
          jsonDecode(File('$_kit/valid/screenshot.json').readAsStringSync())
              as Map<String, Object?>;
      final bytes = File('$_kit/http/screenshot.png').readAsBytesSync();
      final attachment = Map<String, Object?>.from(
        (report['attachments']! as List).single as Map,
      );
      expect(attachment['byteLength'], bytes.length);
      expect(attachment['sha256'], sha256.convert(bytes).toString());
      expect(_contentType(attachment['contentType'])!.matches(bytes), true);
    });
  });
}
