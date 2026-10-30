import 'feedback_offline_store.dart';
import 'feedback_transport.dart';

/// How the client delivers user feedback: `NoticebirdConfig.feedback`.
/// Without one, `NoticebirdClient.captureFeedback` answers
/// `FeedbackDisabled`.
final class FeedbackConfig {
  /// Throws an [ArgumentError] for [requireVerified] without a
  /// [reporterAssertion], under which no report could ever be sent.
  FeedbackConfig({
    required this.transport,
    this.reporterAssertion,
    this.requireVerified = false,
    this.offlineStore,
  }) {
    if (requireVerified && reporterAssertion == null) {
      throw ArgumentError(
        'requireVerified needs a reporterAssertion',
        'requireVerified',
      );
    }
  }

  /// Where reports go: `FeedbackHttpTransport` for the hosted API.
  final FeedbackTransport transport;

  /// Asks the host's backend for a reporter assertion, the signed token that
  /// lets the platform show the reporter as verified. Called once per
  /// report, when it is captured, and given 5 seconds: a provider that
  /// throws, answers `null` or takes longer leaves the report without one.
  /// A refusal by the platform is not retried: the report goes on without
  /// its assertion, or under [requireVerified] is rejected.
  final Future<String?> Function()? reporterAssertion;

  /// Whether a report must be verified. `false` (the default) sends a
  /// report without an assertion, or whose assertion the platform refused,
  /// unverified: an unverified report is better than a lost one. `true`
  /// rejects it instead, as `FeedbackRejection.unverified`.
  final bool requireVerified;

  /// Where a report that did not get through is kept, to be sent on a later
  /// `NoticebirdClient.flush`: `FileFeedbackOfflineStore` on a device with
  /// a file system. `null` (the default) keeps nothing, and such a report
  /// is `FeedbackRejection.noStore`. Under `regulatedStrict` it must be
  /// [FeedbackOfflineStore.isEncrypted].
  final FeedbackOfflineStore? offlineStore;
}
