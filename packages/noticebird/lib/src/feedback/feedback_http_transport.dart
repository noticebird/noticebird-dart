import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:noticebird_protocol/feedback.dart';
import 'package:noticebird_protocol/noticebird_protocol.dart';

import '../protocol/crash_http_transport.dart';
import '../protocol/http_answer.dart';
import 'feedback_transport.dart';

/// The [FeedbackTransport] to a Noticebird API, over `package:http`, made
/// from the app's [CrashHttpTransport] with [FeedbackHttpTransport.of], so
/// the key, the API and the HTTP client are configured once.
///
/// It sends to the feedback routes below the crash transport's API URL, so
/// a proxy's path prefix stays. Every request carries the publishable key as
/// `Authorization: Bearer <key>`, and none of its methods throws.
///
/// The upload goes where the slot's answer says: its `uploadUrl`, absolute
/// or relative, resolved against the URL of the slot request (RFC 3986), so
/// the platform's relative `0` is the slot's own URL, behind a proxy's path
/// prefix too. The resolved URL follows these rules:
/// - it is `https`; `http` only to the API's own origin when the API is
///   itself `http`, as a local development server is;
/// - its method is `PUT`;
/// - it carries the key only when its URL has the API's origin (scheme,
///   host and port);
/// - it declares its length (`content-length`).
///
/// An upload outside these rules is not made: it is a
/// [FeedbackFinalRefusal] with the code `invalid_upload_url` or
/// `invalid_upload_method`. So is a slot body the
/// protocol refuses, with the code, violation and path the API would answer
/// (`invalid_report`).
///
/// The final answers are these, by status and `error` code:
/// - `400` `invalid_report`;
/// - `401` `invalid_key` or `origin_not_allowed`, and `401`
///   `invalid_reporter_assertion` ([FeedbackAssertionRefused]);
/// - `403` `feedback_disabled` or `attachments_disabled`;
/// - `409` `report_conflict` or `attachment_conflict`, and `409`
///   `attachment_missing` ([FeedbackBackToSlot]);
/// - a `404`, `411`, `413` or `415`, whatever its body.
///
/// A `429` is a [FeedbackRetryAfter]. Any other answer that is no `2xx`,
/// such as a gateway's `403` page without an `error`, a `421` or a
/// redirect, is a [FeedbackTransient]: it did not come from the API, and a
/// later try may reach it.
final class FeedbackHttpTransport implements FeedbackTransport {
  /// The feedback transport to the API [crash] sends to, with its key and
  /// over its HTTP client, which stays [crash]'s to close.
  factory FeedbackHttpTransport.of(CrashHttpTransport crash) {
    final connection = crashHttpConnection(crash);
    return FeedbackHttpTransport._(
      connection.apiUrl,
      connection.publishableKey,
      connection.httpClient,
    );
  }

  FeedbackHttpTransport._(this._base, this._publishableKey, this._httpClient);

  /// How long a slot request or a submit waits for its answer.
  static const _requestTimeout = Duration(seconds: 10);

  /// How long an upload of [byteLength] bytes waits for its answer: 30
  /// seconds, and one more for every 64 KiB begun (110 seconds for 5 MiB).
  static Duration _uploadTimeout(int byteLength) =>
      Duration(seconds: 30 + (byteLength + _uploadStep - 1) ~/ _uploadStep);

  static const _uploadStep = 64 * 1024;

  /// The wait of a `429` without a readable `Retry-After`.
  static const _defaultRetryAfter = Duration(seconds: 60);

  final Uri _base;

  /// Checked by the crash transport, before it opened a client.
  final String _publishableKey;
  final http.Client _httpClient;

  @override
  Future<FeedbackDelivery> requestSlot(
    String reportId,
    FeedbackAttachmentRef attachment,
  ) async {
    try {
      final Map<String, Object> body;
      try {
        body = attachment.toSlotJson();
      } on ProtocolException catch (error) {
        return FeedbackFinalRefusal(
          code: 'invalid_report',
          violation: error.violation,
          path: error.path,
        );
      }
      final url = _route(ApiRoutes.attachment(reportId, attachment.index));
      final response = await _send(
        'POST',
        url,
        _jsonHeaders,
        utf8.encode(jsonEncode(body)),
        _requestTimeout,
      );
      return _deliveryOf(response, (body) => _slotOf(url, body));
    } catch (_) {
      return const FeedbackTransient();
    }
  }

  @override
  Future<FeedbackDelivery> upload(
    FeedbackUploadSlot slot,
    Uint8List bytes,
  ) async {
    try {
      final url = slot.uploadUrl;
      final apiOrigin =
          url.scheme == _base.scheme &&
          url.host.toLowerCase() == _base.host.toLowerCase() &&
          url.port == _base.port;
      if (url.host.isEmpty ||
          !(url.isScheme('https') || (apiOrigin && url.isScheme('http')))) {
        return const FeedbackFinalRefusal(code: 'invalid_upload_url');
      }
      if (slot.uploadMethod != 'PUT') {
        return const FeedbackFinalRefusal(code: 'invalid_upload_method');
      }
      final response = await _send(
        'PUT',
        url,
        {
          ...slot.uploadHeaders,
          if (apiOrigin) 'authorization': 'Bearer $_publishableKey',
        },
        bytes,
        _uploadTimeout(bytes.length),
      );
      return _deliveryOf(response, (_) => const FeedbackAttachmentStored());
    } catch (_) {
      return const FeedbackTransient();
    }
  }

  @override
  Future<FeedbackDelivery> submit(String reportJson) async {
    try {
      final response = await _send(
        'POST',
        _route(ApiRoutes.feedback),
        _jsonHeaders,
        utf8.encode(reportJson),
        _requestTimeout,
      );
      return _deliveryOf(response, _acceptedOf);
    } catch (_) {
      return const FeedbackTransient();
    }
  }

  Uri _route(String route) => apiRoute(_base, route);

  Map<String, String> get _jsonHeaders => {
    'authorization': 'Bearer $_publishableKey',
    'content-type': 'application/json',
  };

  /// Sends one request, its body with a `content-length`, and aborts it when
  /// its answer has not come in [timeout].
  Future<http.Response> _send(
    String method,
    Uri url,
    Map<String, String> headers,
    List<int> body,
    Duration timeout,
  ) async {
    final abort = Completer<void>();
    final request =
        http.AbortableRequest(method, url, abortTrigger: abort.future)
          ..headers.addAll(headers)
          ..bodyBytes = body;
    try {
      return await _httpClient
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout);
    } on TimeoutException {
      abort.complete();
      rethrow;
    }
  }

  /// The answer's delivery: [success] reads a `2xx`, the final answers of
  /// the class doc the rest. Any other answer is transient: a `3xx`; a
  /// `408`, `421`, `425` or other `4xx` not named there, such as a
  /// gateway's `403` without an `error`; a `5xx`.
  static FeedbackDelivery _deliveryOf(
    http.Response response,
    FeedbackDelivery Function(Map<String, Object?>? body) success,
  ) {
    final status = response.statusCode;
    final body = jsonBodyOf(response);
    if (status >= 200 && status < 300) return success(body);
    final code = _string(body, 'error');
    return switch ((status, code)) {
      (401, 'invalid_reporter_assertion') => const FeedbackAssertionRefused(),
      (409, 'attachment_missing') => const FeedbackBackToSlot(),
      (429, _) => FeedbackRetryAfter(
        _retryAfterOf(response.headers['retry-after']),
      ),
      (400, 'invalid_report') ||
      (401, 'invalid_key' || 'origin_not_allowed') ||
      (403, 'feedback_disabled' || 'attachments_disabled') ||
      (409, 'report_conflict' || 'attachment_conflict') ||
      (404 || 411 || 413 || 415, _) => FeedbackFinalRefusal(
        code: code,
        violation: ProtocolViolation.values
            .asNameMap()[_string(body, 'violation')],
        path: _string(body, 'path'),
      ),
      _ => const FeedbackTransient(),
    };
  }

  /// A slot's answer to the request sent to [requestUrl]. Its `uploadUrl`
  /// is resolved against [requestUrl]; the upload's rules are checked on the
  /// result when it is used. An answer that is neither stored nor a usable
  /// slot, as a captive portal's page is, is transient: the next try may
  /// reach the API.
  static FeedbackDelivery _slotOf(Uri requestUrl, Map<String, Object?>? body) {
    if (body == null) return const FeedbackTransient();
    if (body['uploaded'] == true) return const FeedbackAttachmentStored();
    final url = switch (body['uploadUrl']) {
      final String value => Uri.tryParse(value),
      _ => null,
    };
    final method = body['uploadMethod'];
    final headers = body['uploadHeaders'] ?? const <String, Object?>{};
    if (url == null ||
        method is! String ||
        headers is! Map<String, Object?> ||
        headers.values.any((value) => value is! String)) {
      return const FeedbackTransient();
    }
    return FeedbackSlotPending(
      FeedbackUploadSlot(
        uploadUrl: requestUrl.resolveUri(url),
        uploadMethod: method,
        uploadHeaders: headers.cast<String, String>(),
      ),
    );
  }

  /// A submit's answer, read leniently: only the ticket and `verified`,
  /// each where it is readable.
  static FeedbackDelivery _acceptedOf(Map<String, Object?>? body) =>
      FeedbackAccepted(
        ticket: switch (body?['ticket']) {
          {'number': final int number, 'display': final String display}
              when number >= 1 && display.isNotEmpty =>
            FeedbackTicket(number: number, display: display),
          _ => null,
        },
        verified: body?['verified'] == true,
      );

  /// `Retry-After` in seconds, at most the age at which the report would be
  /// refused anyway.
  static Duration _retryAfterOf(String? value) {
    final seconds = int.tryParse(value?.trim() ?? '');
    if (seconds == null || seconds < 0) return _defaultRetryAfter;
    return Duration(seconds: min(seconds, FeedbackReport.maxAge.inSeconds));
  }

  static String? _string(Map<String, Object?>? body, String key) =>
      switch (body?[key]) {
        final String value => value,
        _ => null,
      };
}
