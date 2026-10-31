// FeedbackHttpTransport against a fake HTTP client: the API's answers row by
// row, the upload rules, the lenient reading of an answer, and the routes
// below the crash transport's API URL.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noticebird/feedback.dart';
import 'package:noticebird/noticebird.dart';

const _key = 'noticebird_pk_feedback_transport_example_key';
const _reportId = '3b0c6f2e-8d41-4a77-9c5e-1f2a3b4c5d6e';
const _api = 'https://api.noticebird.com';
const _screenshot = FeedbackAttachmentRef(
  index: 0,
  contentType: FeedbackContentType.png,
  byteLength: 68,
  sha256: '7ac2abfce2be8b46dd9826d597d94edeefc1570b4a992622721b90a1850e3ee9',
);
final _bytes = Uint8List.fromList(List.filled(68, 7));

enum _Request { slot, upload, submit }

void main() {
  http.Request? sent;

  FeedbackHttpTransport transport(
    FutureOr<http.Response> Function(http.Request request) answer, {
    Uri? apiUrl,
    String key = _key,
  }) => FeedbackHttpTransport.of(
    CrashHttpTransport(
      apiUrl: apiUrl ?? CrashHttpTransport.hostedApiUrl,
      publishableKey: key,
      httpClient: MockClient((request) async {
        sent = request;
        return answer(request);
      }),
    ),
  );

  http.Response json(int status, Object body, {Map<String, String>? headers}) =>
      http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json', ...?headers},
      );

  FeedbackUploadSlot slot(String url, {String method = 'PUT'}) =>
      FeedbackUploadSlot(
        uploadUrl: Uri.parse(url),
        uploadMethod: method,
        uploadHeaders: const {'content-type': 'image/png'},
      );

  final apiSlot = slot('$_api/v1/feedback/$_reportId/attachments/0');

  Future<FeedbackDelivery> send(
    _Request request,
    FeedbackHttpTransport transport,
  ) => switch (request) {
    _Request.slot => transport.requestSlot(_reportId, _screenshot),
    _Request.upload => transport.upload(apiSlot, _bytes),
    _Request.submit => transport.submit('{"reportId":"$_reportId"}'),
  };

  setUp(() => sent = null);

  group('the answers', () {
    final rows = <(String, _Request, http.Response, FeedbackDelivery)>[
      (
        '200 with an upload URL is a pending slot, its URL resolved against '
            "the slot request's",
        _Request.slot,
        json(200, {
          'uploaded': false,
          'uploadUrl': '0',
          'uploadMethod': 'PUT',
          'uploadHeaders': {'content-type': 'image/png'},
          'expiresAt': '2026-10-30T12:05:00.000Z',
        }),
        FeedbackSlotPending(apiSlot),
      ),
      (
        '200 with an upload URL keeps the headers the API names',
        _Request.slot,
        json(200, {
          'uploaded': false,
          'uploadUrl': '0',
          'uploadMethod': 'PUT',
          'uploadHeaders': {'content-type': 'image/webp'},
          'expiresAt': '2026-10-30T12:05:00.000Z',
        }),
        FeedbackSlotPending(
          FeedbackUploadSlot(
            uploadUrl: apiSlot.uploadUrl,
            uploadMethod: 'PUT',
            uploadHeaders: const {'content-type': 'image/webp'},
          ),
        ),
      ),
      (
        '200 uploaded at the slot is the bytes stored',
        _Request.slot,
        json(200, {'uploaded': true}),
        const FeedbackAttachmentStored(),
      ),
      (
        '204 to the upload is the bytes stored',
        _Request.upload,
        http.Response('', 204),
        const FeedbackAttachmentStored(),
      ),
      (
        '202 accepted is the report accepted, with its ticket',
        _Request.submit,
        json(202, {
          'status': 'accepted',
          'reportId': _reportId,
          'ticket': {'number': 1, 'display': 'FB-1'},
          'verified': false,
          'redactions': {
            'message': <String, Object?>{},
            'trail': {'dropped': 0},
            'diagnostics': {'dropped': 0},
            'userContext': {'dropped': 0},
          },
        }),
        const FeedbackAccepted(
          ticket: FeedbackTicket(number: 1, display: 'FB-1'),
          verified: false,
        ),
      ),
      (
        '200 replay is the acceptance it repeats',
        _Request.submit,
        json(200, {
          'status': 'replay',
          'reportId': _reportId,
          'ticket': {'number': 1, 'display': 'FB-1'},
          'verified': false,
        }),
        const FeedbackAccepted(
          ticket: FeedbackTicket(number: 1, display: 'FB-1'),
          verified: false,
        ),
      ),
      (
        '400 invalid_report at the slot is final, with its violation and '
            'path',
        _Request.slot,
        json(400, {
          'error': 'invalid_report',
          'violation': 'invalidValue',
          'path': r'$.contentType',
        }),
        const FeedbackFinalRefusal(
          code: 'invalid_report',
          violation: ProtocolViolation.invalidValue,
          path: r'$.contentType',
        ),
      ),
      (
        '400 invalid_report with its violation and path is final',
        _Request.submit,
        json(400, {
          'error': 'invalid_report',
          'violation': 'invalidValue',
          'path': r'$.userContext.name',
        }),
        const FeedbackFinalRefusal(
          code: 'invalid_report',
          violation: ProtocolViolation.invalidValue,
          path: r'$.userContext.name',
        ),
      ),
      (
        '401 invalid_key is final',
        _Request.submit,
        json(401, {'error': 'invalid_key'}),
        const FeedbackFinalRefusal(code: 'invalid_key'),
      ),
      (
        '401 origin_not_allowed is final',
        _Request.submit,
        json(401, {'error': 'origin_not_allowed'}),
        const FeedbackFinalRefusal(code: 'origin_not_allowed'),
      ),
      (
        '401 invalid_reporter_assertion is the assertion refused, with its '
            'reason',
        _Request.submit,
        json(401, {'error': 'invalid_reporter_assertion', 'reason': 'time'}),
        const FeedbackAssertionRefused(),
      ),
      (
        '403 feedback_disabled is final',
        _Request.submit,
        json(403, {'error': 'feedback_disabled'}),
        const FeedbackFinalRefusal(code: 'feedback_disabled'),
      ),
      (
        '403 attachments_disabled is final',
        _Request.slot,
        json(403, {'error': 'attachments_disabled'}),
        const FeedbackFinalRefusal(code: 'attachments_disabled'),
      ),
      (
        '404 without a body is final',
        _Request.slot,
        http.Response('', 404),
        const FeedbackFinalRefusal(),
      ),
      (
        '409 report_conflict is final',
        _Request.submit,
        json(409, {'error': 'report_conflict'}),
        const FeedbackFinalRefusal(code: 'report_conflict'),
      ),
      (
        '409 report_conflict at the slot is final',
        _Request.slot,
        json(409, {'error': 'report_conflict'}),
        const FeedbackFinalRefusal(code: 'report_conflict'),
      ),
      (
        '409 attachment_conflict at the slot is final',
        _Request.slot,
        json(409, {'error': 'attachment_conflict'}),
        const FeedbackFinalRefusal(code: 'attachment_conflict'),
      ),
      (
        '409 attachment_conflict at the upload is final',
        _Request.upload,
        json(409, {'error': 'attachment_conflict'}),
        const FeedbackFinalRefusal(code: 'attachment_conflict'),
      ),
      (
        '409 attachment_missing at the upload goes back to the slot',
        _Request.upload,
        json(409, {'error': 'attachment_missing'}),
        const FeedbackBackToSlot(),
      ),
      (
        '409 attachment_missing at the submit goes back to the slot',
        _Request.submit,
        json(409, {'error': 'attachment_missing'}),
        const FeedbackBackToSlot(),
      ),
      (
        '411 length_required is final',
        _Request.upload,
        json(411, {'error': 'length_required'}),
        const FeedbackFinalRefusal(code: 'length_required'),
      ),
      (
        '413 payload_too_large is final',
        _Request.submit,
        json(413, {'error': 'payload_too_large'}),
        const FeedbackFinalRefusal(code: 'payload_too_large'),
      ),
      (
        '415 unsupported_attachment is final',
        _Request.upload,
        json(415, {'error': 'unsupported_attachment'}),
        const FeedbackFinalRefusal(code: 'unsupported_attachment'),
      ),
      (
        '429 rate_limited waits its Retry-After',
        _Request.submit,
        json(429, {'error': 'rate_limited'}, headers: {'retry-after': '120'}),
        const FeedbackRetryAfter(Duration(seconds: 120)),
      ),
      (
        '429 without a Retry-After waits the default',
        _Request.slot,
        json(429, {'error': 'rate_limited'}),
        const FeedbackRetryAfter(Duration(seconds: 60)),
      ),
      (
        '429 with an unreadable Retry-After waits the default',
        _Request.upload,
        json(
          429,
          {'error': 'rate_limited'},
          headers: {'retry-after': 'Thu, 29 Oct 2026 14:06:00 GMT'},
        ),
        const FeedbackRetryAfter(Duration(seconds: 60)),
      ),
      (
        '429 with Retry-After 0 retries at once',
        _Request.submit,
        json(429, {'error': 'rate_limited'}, headers: {'retry-after': '0'}),
        const FeedbackRetryAfter(Duration.zero),
      ),
      (
        '429 with a negative Retry-After waits the default',
        _Request.slot,
        json(429, {'error': 'rate_limited'}, headers: {'retry-after': '-1'}),
        const FeedbackRetryAfter(Duration(seconds: 60)),
      ),
      (
        '429 waits at most the age at which the report is refused',
        _Request.submit,
        json(
          429,
          {'error': 'rate_limited'},
          headers: {'retry-after': '99999999999999'},
        ),
        const FeedbackRetryAfter(FeedbackReport.maxAge),
      ),
      (
        '503 attachments_unavailable is transient',
        _Request.slot,
        json(503, {'error': 'attachments_unavailable'}),
        const FeedbackTransient(),
      ),
      (
        'another 5xx is transient',
        _Request.submit,
        http.Response('Bad gateway', 502),
        const FeedbackTransient(),
      ),
      (
        "a proxy's 408 is transient",
        _Request.upload,
        http.Response('', 408),
        const FeedbackTransient(),
      ),
      (
        '421 is transient',
        _Request.submit,
        http.Response('Misdirected Request', 421),
        const FeedbackTransient(),
      ),
      (
        '425 is transient',
        _Request.upload,
        http.Response('', 425),
        const FeedbackTransient(),
      ),
      (
        "a gateway's 403 page without an error is transient",
        _Request.submit,
        http.Response(
          '<html><body>Request blocked</body></html>',
          403,
          headers: {'content-type': 'text/html'},
        ),
        const FeedbackTransient(),
      ),
      (
        'a 4xx with an error the table does not name at its status is '
            'transient',
        _Request.slot,
        json(401, {'error': 'proxy_authentication_required'}),
        const FeedbackTransient(),
      ),
      (
        'a known error at another status is transient',
        _Request.submit,
        json(400, {'error': 'feedback_disabled'}),
        const FeedbackTransient(),
      ),
      (
        'a redirect is transient',
        _Request.slot,
        http.Response(
          '',
          302,
          headers: {'location': 'https://portal.example.com/login'},
        ),
        const FeedbackTransient(),
      ),
      (
        '404 with a body is final',
        _Request.upload,
        http.Response('Not Found', 404),
        const FeedbackFinalRefusal(),
      ),
      (
        '413 without an error is final',
        _Request.upload,
        http.Response('<html>Request Entity Too Large</html>', 413),
        const FeedbackFinalRefusal(),
      ),
    ];

    for (final (name, request, response, expected) in rows) {
      test(name, () async {
        expect(await send(request, transport((_) => response)), expected);
      });
    }

    for (final request in _Request.values) {
      test('no answer to the ${request.name} is transient', () async {
        expect(
          await send(
            request,
            transport((_) => throw http.ClientException('offline')),
          ),
          const FeedbackTransient(),
        );
      });

      test('anything a client throws at the ${request.name} is transient '
          'and never escapes', () async {
        expect(
          await send(request, transport((_) => throw StateError('broken'))),
          const FeedbackTransient(),
        );
      });
    }
  });

  group('timeouts', () {
    FeedbackDelivery? waited(
      Future<FeedbackDelivery> Function(FeedbackHttpTransport) request,
      Duration after,
    ) {
      FeedbackDelivery? delivery;
      fakeAsync((async) {
        final silent = transport((_) => Completer<http.Response>().future);
        request(silent).then((value) => delivery = value);
        async.elapse(after);
      });
      return delivery;
    }

    test('a slot request and a submit wait ten seconds, then are '
        'transient', () {
      const limit = Duration(seconds: 10);
      for (final request in [
        (FeedbackHttpTransport t) => t.requestSlot(_reportId, _screenshot),
        (FeedbackHttpTransport t) => t.submit('{}'),
      ]) {
        expect(
          waited(request, limit - const Duration(milliseconds: 1)),
          isNull,
        );
        expect(waited(request, limit), const FeedbackTransient());
      }
    });

    test('an upload waits 30 seconds and one more per 64 KiB begun', () {
      for (final (length, seconds) in [
        (68, 31),
        (65536, 31),
        (65537, 32),
        (FeedbackAttachmentRef.maxByteLength, 110),
      ]) {
        final bytes = Uint8List(length);
        final limit = Duration(seconds: seconds);
        Future<FeedbackDelivery> upload(FeedbackHttpTransport t) =>
            t.upload(apiSlot, bytes);
        expect(
          waited(upload, limit - const Duration(milliseconds: 1)),
          isNull,
          reason: '$length',
        );
        expect(
          waited(upload, limit),
          const FeedbackTransient(),
          reason: '$length',
        );
      }
    });
  });

  group('the slot', () {
    test(
      'sends the slot body with the key, and reads a pending slot',
      () async {
        final delivery = await transport(
          (_) => json(200, {
            'uploaded': false,
            'uploadUrl': '$_api/v1/feedback/$_reportId/attachments/0',
            'uploadMethod': 'PUT',
            'uploadHeaders': {'content-type': 'image/png'},
            'expiresAt': '2026-10-30T12:05:00.000Z',
            'futureKey': true,
          }),
        ).requestSlot(_reportId, _screenshot);

        expect(sent!.method, 'POST');
        expect(
          sent!.url,
          Uri.parse('$_api/v1/feedback/$_reportId/attachments/0'),
        );
        expect(sent!.headers['authorization'], 'Bearer $_key');
        expect(sent!.headers['content-type'], 'application/json');
        expect(jsonDecode(sent!.body), _screenshot.toSlotJson());
        expect(
          delivery,
          FeedbackSlotPending(
            FeedbackUploadSlot(
              uploadUrl: apiSlot.uploadUrl,
              uploadMethod: 'PUT',
              uploadHeaders: const {'content-type': 'image/png'},
            ),
          ),
        );
      },
    );

    test('resolves a relative or absolute uploadUrl against the slot '
        "request's URL", () async {
      final slotUrl = '$_api/v1/feedback/$_reportId/attachments/0';
      for (final (uploadUrl, resolved) in [
        ('0', slotUrl),
        ('./0', slotUrl),
        ('/v1/upload/abc', '$_api/v1/upload/abc'),
        ('//storage.example.com/upload', 'https://storage.example.com/upload'),
        (
          'https://storage.example.com/upload?sig=abc',
          'https://storage.example.com/upload?sig=abc',
        ),
        (slotUrl, slotUrl),
      ]) {
        final delivery = await transport(
          (_) => json(200, {
            'uploaded': false,
            'uploadUrl': uploadUrl,
            'uploadMethod': 'PUT',
          }),
        ).requestSlot(_reportId, _screenshot);
        expect(
          delivery,
          FeedbackSlotPending(
            FeedbackUploadSlot(
              uploadUrl: Uri.parse(resolved),
              uploadMethod: 'PUT',
            ),
          ),
          reason: uploadUrl,
        );
      }
    });

    test(
      'a 200 that is neither stored nor a usable slot is transient',
      () async {
        for (final body in [
          http.Response('<html>Sign in to the Wi-Fi</html>', 200),
          json(200, {'uploaded': false}),
          json(200, {'uploadUrl': 0, 'uploadMethod': 'PUT'}),
          json(200, {'uploadUrl': 'http://[::1', 'uploadMethod': 'PUT'}),
          json(200, {'uploadUrl': '0'}),
          json(200, {
            'uploadUrl': '$_api/upload',
            'uploadMethod': 'PUT',
            'uploadHeaders': {'content-length': 68},
          }),
        ]) {
          expect(
            await transport((_) => body).requestSlot(_reportId, _screenshot),
            const FeedbackTransient(),
            reason: body.body,
          );
        }
      },
    );

    test('a slot body the protocol refuses is final and never sent', () async {
      const second = FeedbackAttachmentRef(
        index: 1,
        contentType: FeedbackContentType.png,
        byteLength: 68,
        sha256:
            '7ac2abfce2be8b46dd9826d597d94edeefc1570b4a992622721b90a1850e3ee9',
      );
      expect(
        await transport(
          (_) => http.Response('', 204),
        ).requestSlot(_reportId, second),
        const FeedbackFinalRefusal(
          code: 'invalid_report',
          violation: ProtocolViolation.invalidValue,
          path: r'$.index',
        ),
      );
      expect(sent, isNull);
    });
  });

  group('the upload', () {
    test('sends the bytes with the slot headers and the key to the API '
        'itself', () async {
      final delivery = await transport(
        (_) => http.Response('', 204),
      ).upload(apiSlot, _bytes);

      expect(delivery, const FeedbackAttachmentStored());
      expect(sent!.method, 'PUT');
      expect(sent!.url, apiSlot.uploadUrl);
      expect(sent!.headers['content-type'], 'image/png');
      expect(sent!.headers['authorization'], 'Bearer $_key');
      expect(sent!.bodyBytes, _bytes);
    });

    test('sends no key to another origin', () async {
      for (final url in [
        'https://storage.example.com/upload/abc',
        'https://api.noticebird.com:8443/v1/upload',
        'https://uploads.noticebird.com/v1/upload',
      ]) {
        sent = null;
        final delivery = await transport(
          (_) => http.Response('', 200),
        ).upload(slot(url), _bytes);
        expect(delivery, const FeedbackAttachmentStored(), reason: url);
        expect(sent!.url, Uri.parse(url));
        expect(sent!.headers.containsKey('authorization'), false, reason: url);
        expect(sent!.headers['content-type'], 'image/png');
      }
    });

    test('declares its length', () async {
      final client = _RecordingClient();
      final delivery = await FeedbackHttpTransport.of(
        CrashHttpTransport(
          apiUrl: CrashHttpTransport.hostedApiUrl,
          publishableKey: _key,
          httpClient: client,
        ),
      ).upload(apiSlot, _bytes);
      expect(delivery, const FeedbackAttachmentStored());
      expect(client.request!.contentLength, _bytes.length);
    });

    test('refuses a URL that is not https, unless to a local http API '
        'itself', () async {
      final local = Uri.parse('http://localhost:8080');
      for (final (apiUrl, url) in [
        (null, 'http://api.noticebird.com/v1/feedback/x/attachments/0'),
        (null, 'ftp://api.noticebird.com/upload'),
        (null, 'https:upload'),
        (local, 'http://localhost:9000/upload'),
        (local, 'http://storage.example.com/upload'),
      ]) {
        expect(
          await transport(
            (_) => http.Response('', 204),
            apiUrl: apiUrl,
          ).upload(slot(url), _bytes),
          const FeedbackFinalRefusal(code: 'invalid_upload_url'),
          reason: url,
        );
      }
      expect(sent, isNull);

      final delivery =
          await transport((_) => http.Response('', 204), apiUrl: local).upload(
            slot('http://localhost:8080/v1/feedback/x/attachments/0'),
            _bytes,
          );
      expect(delivery, const FeedbackAttachmentStored());
      expect(sent!.headers['authorization'], 'Bearer $_key');
    });

    test('through a proxy, the relative uploadUrl keeps its path prefix and '
        'the key', () async {
      for (final api in [
        'https://proxy.example.com/noticebird',
        'http://10.0.2.2:8080',
        'http://localhost:8080/api',
      ]) {
        final uploadUrl = Uri.parse(
          '$api/v1/feedback/$_reportId/attachments/0',
        );
        final requests = <http.Request>[];
        final proxied = FeedbackHttpTransport.of(
          CrashHttpTransport(
            apiUrl: Uri.parse(api),
            publishableKey: _key,
            httpClient: MockClient((request) async {
              requests.add(request);
              return request.method == 'POST'
                  ? json(200, {
                      // As the platform answers: the upload route is the
                      // slot's own URL.
                      'uploaded': false,
                      'uploadUrl': '0',
                      'uploadMethod': 'PUT',
                      'uploadHeaders': {'content-type': 'image/png'},
                    })
                  : http.Response('', 204);
            }),
          ),
        );

        final delivery = await proxied.requestSlot(_reportId, _screenshot);
        expect(
          delivery,
          FeedbackSlotPending(
            FeedbackUploadSlot(
              uploadUrl: uploadUrl,
              uploadMethod: 'PUT',
              uploadHeaders: const {'content-type': 'image/png'},
            ),
          ),
          reason: api,
        );
        expect(
          await proxied.upload((delivery as FeedbackSlotPending).slot, _bytes),
          const FeedbackAttachmentStored(),
          reason: api,
        );
        final [slotRequest, put] = requests;
        expect(slotRequest.url, uploadUrl, reason: api);
        expect(put.method, 'PUT');
        expect(put.url, uploadUrl, reason: api);
        expect(put.headers['authorization'], 'Bearer $_key', reason: api);
        expect(put.headers['content-type'], 'image/png');
        expect(put.bodyBytes, _bytes);
      }
    });

    test('refuses a method other than PUT', () async {
      for (final method in ['POST', 'put', 'PATCH']) {
        expect(
          await transport(
            (_) => http.Response('', 204),
          ).upload(slot(apiSlot.uploadUrl.toString(), method: method), _bytes),
          const FeedbackFinalRefusal(code: 'invalid_upload_method'),
          reason: method,
        );
      }
      expect(sent, isNull);
    });
  });

  group('the submit', () {
    test('sends the report as it is, with the key', () async {
      const report = '{"reportId":"$_reportId","message":"Zoë"}';
      await transport((_) => http.Response('', 202)).submit(report);
      expect(sent!.method, 'POST');
      expect(sent!.url, Uri.parse('$_api/v1/feedback'));
      expect(sent!.headers['authorization'], 'Bearer $_key');
      expect(sent!.headers['content-type'], 'application/json');
      expect(sent!.bodyBytes, utf8.encode(report));
    });

    test('reads the ticket and ignores keys it does not know', () async {
      expect(
        await transport(
          (_) => json(202, {
            'status': 'accepted',
            'reportId': _reportId,
            'ticket': {'number': 12, 'display': 'FB-12', 'url': 'later'},
            'verified': true,
            'redactions': {'message': {}},
            'futureKey': [1, 2],
          }),
        ).submit('{}'),
        const FeedbackAccepted(
          ticket: FeedbackTicket(number: 12, display: 'FB-12'),
          verified: true,
        ),
      );
    });

    test('a malformed 2xx is accepted without a ticket', () async {
      for (final response in [
        http.Response('OK', 202),
        http.Response('', 200),
        json(202, ['accepted']),
        json(202, {
          'status': 7,
          'reportId': 12,
          'ticket': {'number': '12', 'display': 'FB-12'},
          'verified': 'yes',
        }),
        json(202, {
          'ticket': {'number': 0, 'display': 'FB-0'},
        }),
        json(202, {
          'ticket': {'number': 12, 'display': ''},
        }),
      ]) {
        expect(
          await transport((_) => response).submit('{}'),
          const FeedbackAccepted(verified: false),
          reason: response.body,
        );
      }
    });
  });

  group('the API', () {
    test('is the routes below the crash transport\'s API URL', () async {
      for (final (apiUrl, api) in [
        (null, _api),
        (CrashHttpTransport.hostedApiUrl, _api),
        (Uri.parse('https://api.noticebird.com/'), _api),
        (
          Uri.parse('https://proxy.example.com/noticebird'),
          'https://proxy.example.com/noticebird',
        ),
        (Uri.parse('http://localhost:8080'), 'http://localhost:8080'),
      ]) {
        final answered = transport(
          (_) => json(200, {'uploaded': true}),
          apiUrl: apiUrl,
        );
        await answered.submit('{}');
        expect(sent!.url, Uri.parse('$api/v1/feedback'));
        await answered.requestSlot(_reportId, _screenshot);
        expect(
          sent!.url,
          Uri.parse('$api/v1/feedback/$_reportId/attachments/0'),
        );
      }
    });
  });
}

/// A client that keeps the request as the transport made it, before any
/// copy, and answers `204`.
final class _RecordingClient extends http.BaseClient {
  http.BaseRequest? request;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    this.request = request;
    await request.finalize().drain<void>();
    return http.StreamedResponse(const Stream.empty(), 204);
  }
}
