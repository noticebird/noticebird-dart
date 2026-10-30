import 'package:http/http.dart' as http;

import 'http_answer.dart';
import 'noticebird_config.dart';
import 'publishable_key.dart';

final class CrashHttpTransport implements CrashTransport {
  /// Hosted endpoint used when consumers do not provide an [endpoint].
  ///
  /// Platform maintainers can update this single value in a new SDK release.
  static final Uri hostedEndpoint = Uri.parse(
    'https://api.noticebird.com/v1/envelope',
  );

  CrashHttpTransport({
    Uri? endpoint,
    required String publishableKey,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 5),
  }) : _endpoint = endpoint ?? hostedEndpoint,
       _publishableKey = checkPublishableKey(publishableKey),
       _httpClient = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null;

  final Uri _endpoint;
  final String _publishableKey;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final Duration timeout;

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
          _endpoint,
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

/// The API [transport] sends to, the key it sends and the HTTP client it
/// sends with, for the feedback transport that shares them. Not exported.
({Uri endpoint, String publishableKey, http.Client httpClient})
crashHttpConnection(CrashHttpTransport transport) => (
  endpoint: transport._endpoint,
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
