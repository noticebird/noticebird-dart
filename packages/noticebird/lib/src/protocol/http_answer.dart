import 'dart:convert';

import 'package:http/http.dart' as http;

/// The JSON object an HTTP answer carries as its body; `null` for any other
/// body. Both transports read the platform's answers through it.
Map<String, Object?>? jsonBodyOf(http.Response response) {
  try {
    final body = jsonDecode(
      utf8.decode(response.bodyBytes, allowMalformed: true),
    );
    return body is Map<String, Object?> ? body : null;
  } on FormatException {
    return null;
  }
}
