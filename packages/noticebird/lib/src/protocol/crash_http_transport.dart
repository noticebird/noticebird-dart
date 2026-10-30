import 'package:http/http.dart' as http;

import 'http_answer.dart';
import 'noticebird_config.dart';
import 'publishable_key.dart';

/// The [CrashTransport] to a Noticebird API, over `package:http`: it posts
/// each event to the API's envelope route, `<apiUrl>/v1/envelope`, with the
/// publishable key as `Authorization: Bearer <key>`.
final class CrashHttpTransport implements CrashTransport {
  /// The hosted Noticebird API, for a host that sends there: the SDK never
  /// sends anywhere by itself, so a host passes it as [apiUrl].
  ///
  /// Platform maintainers can update this single value in a new SDK release.
  static final Uri hostedApiUrl = Uri.parse('https://api.noticebird.com');

  /// A transport to the API at [apiUrl]: its base, such as [hostedApiUrl]
  /// or a proxy's `https://example.com/noticebird`, below which the SDK
  /// owns its routes (`/v1/envelope`, the feedback routes).
  ///
  /// Throws an [ArgumentError] for an [apiUrl] that is no `http` or `https`
  /// URL with a host, that has a query, a fragment or credentials, or that
  /// ends in a route of the API (`/v1`, `/v1/envelope`, `/v1/feedback`)
  /// rather than at its base, and for a [publishableKey] that is no
  /// publishable key (`<prefix>_pk_…`).
  CrashHttpTransport({
    required Uri apiUrl,
    required String publishableKey,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 5),
  }) : _apiUrl = _checkApiUrl(apiUrl),
       _publishableKey = checkPublishableKey(publishableKey),
       _httpClient = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null;

  /// The API's base, its path without a trailing `/`.
  final Uri _apiUrl;
  final String _publishableKey;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final Duration timeout;

  late final Uri _envelope = apiRoute(_apiUrl, ApiRoutes.envelope);

  static Uri _checkApiUrl(Uri apiUrl) {
    String? problem;
    final path = apiUrl.path.replaceFirst(RegExp(r'/+$'), '');
    if (!(apiUrl.isScheme('https') || apiUrl.isScheme('http')) ||
        apiUrl.host.isEmpty) {
      problem = 'The API URL is an http or https URL with a host';
    } else if (apiUrl.hasQuery || apiUrl.hasFragment) {
      problem = 'The API URL has no query or fragment';
    } else if (apiUrl.userInfo.isNotEmpty) {
      problem = 'The API URL carries no credentials; the key is sent apart';
    } else if (ApiRoutes.named(path)) {
      problem =
          'Pass the API base, such as https://api.noticebird.com; the SDK '
          'adds its routes (${ApiRoutes.version}/…) itself';
    }
    if (problem != null) {
      throw ArgumentError.value(apiUrl, 'apiUrl', problem);
    }
    return apiUrl.replace(path: path);
  }

  /// Releases the underlying HTTP client if this transport created it.
  /// A client injected by the caller stays open and remains the caller's
  /// responsibility.
  void close() {
    if (_ownsHttpClient) _httpClient.close();
  }

  @override
  Future<void> send(String eventJson) async {
    final response = await _httpClient
        .post(
          _envelope,
          headers: {
            'authorization': 'Bearer $_publishableKey',
            'content-type': 'application/json',
          },
          body: eventJson,
        )
        .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw CrashTransportException(
        response.statusCode,
        refusedForGood: _refusedForGood(response),
      );
    }
  }

  /// Whether [response] is one of the envelope route's final answers
  /// ([CrashTransport.send]), judged by its status and its `error` code.
  static bool _refusedForGood(http.Response response) =>
      switch ((response.statusCode, _errorOf(response))) {
        (413, 'payload_too_large') || (422, 'privacy_rejected') => true,
        _ => false,
      };

  /// The `error` of a JSON body; `null` for any other body.
  static String? _errorOf(http.Response response) =>
      switch (jsonBodyOf(response)) {
        {'error': final String error} => error,
        _ => null,
      };
}

/// The routes of a Noticebird API the SDK sends to, below its base URL: the
/// one place they are named. Not exported.
abstract final class ApiRoutes {
  /// The version prefix every route starts with.
  static const version = '/v1';

  /// A crash event: `POST`.
  static const envelope = '$version/envelope';

  /// A feedback report: `POST`; its attachments below it.
  static const feedback = '$version/feedback';

  /// The slot of a report's attachment: `POST`, and the upload route the
  /// platform answers.
  static String attachment(String reportId, int index) =>
      '$feedback/${Uri.encodeComponent(reportId)}/attachments/$index';

  /// Whether [path], a base URL's path without a trailing `/`, names a
  /// route or the version prefix rather than the API's base: a host that
  /// passed a route as the base.
  static bool named(String path) =>
      path.endsWith(version) ||
      path.endsWith(envelope) ||
      path.endsWith(feedback);
}

/// The route [route] (`/v1/…`) of the API at [apiUrl], a base whose path
/// has no trailing `/`. Not exported.
Uri apiRoute(Uri apiUrl, String route) =>
    apiUrl.replace(path: '${apiUrl.path}$route');

/// The API [transport] sends to, the key it sends and the HTTP client it
/// sends with, for the feedback transport that shares them. Not exported.
({Uri apiUrl, String publishableKey, http.Client httpClient})
crashHttpConnection(CrashHttpTransport transport) => (
  apiUrl: transport._apiUrl,
  publishableKey: transport._publishableKey,
  httpClient: transport._httpClient,
);

/// The platform's answer to an event it did not take: its HTTP
/// [statusCode], and whether it refused the event for good.
final class CrashTransportException implements Exception {
  const CrashTransportException(this.statusCode, {this.refusedForGood = false});

  final int statusCode;

  /// Whether sending the same event again would meet the same answer: the
  /// client then drops the event instead of keeping it for a later flush.
  final bool refusedForGood;

  @override
  String toString() => 'Crash transport failed with HTTP $statusCode';
}
