/// The shape of a publishable ingest key: `<prefix>_pk_<token>`.
///
/// The prefix is the platform's to choose, so a key it issues under a new
/// prefix works without an SDK release. The `_pk_` marker is what keeps a
/// secret key (`<prefix>_sk_…`) out of a client.
final RegExp publishableKeyPattern = RegExp(
  r'^[a-z][a-z0-9]*_pk_[A-Za-z0-9_-]+$',
);

/// Returns [publishableKey] if it has the shape of a publishable ingest key
/// ([publishableKeyPattern]); throws an [ArgumentError] otherwise.
///
/// Every transport that sends the key checks it here, first in its
/// initializer list, so a secret key never reaches a request and a refused
/// key opens no HTTP client.
String checkPublishableKey(String publishableKey) {
  if (!publishableKeyPattern.hasMatch(publishableKey)) {
    throw ArgumentError.value(
      publishableKey,
      'publishableKey',
      'A client takes a publishable ingest key, <prefix>_pk_<token>',
    );
  }
  return publishableKey;
}
