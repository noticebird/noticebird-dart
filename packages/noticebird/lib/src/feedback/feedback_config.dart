import 'feedback_capture.dart';
import 'feedback_offline_store.dart';
import 'feedback_transport.dart';

/// How the client delivers user feedback: `NoticebirdConfig.feedback`.
/// Without one, `NoticebirdClient.captureFeedback` answers
/// `FeedbackDisabled`.
final class FeedbackConfig {
  /// Throws an [ArgumentError] for [requireVerified] without a
  /// [reporterAssertion], under which no report could ever be sent.
  FeedbackConfig({
    this.transport,
    this.reporterAssertion,
    this.requireVerified = false,
    this.offlineStore,
    this.onSettled,
    this.contextDiagnostics,
  }) {
    if (requireVerified && reporterAssertion == null) {
      throw ArgumentError(
        'requireVerified needs a reporterAssertion',
        'requireVerified',
      );
    }
  }

  /// Where reports go: `FeedbackHttpTransport.of(crashTransport)`, to the
  /// API the crash transport names. `null` for a build without an API URL
  /// or a publishable key: `NoticebirdClient.captureFeedback`
  /// answers `FeedbackDisabled`, and the rest of this config is checked all
  /// the same.
  final FeedbackTransport? transport;

  /// Asks the host's backend for a reporter assertion, the signed token that
  /// lets the platform show the reporter as verified. Asked when a report
  /// is captured, and given 5 seconds: a provider that throws, answers
  /// `null` or takes longer leaves the report without one. A refusal by the
  /// platform is not retried: the report goes on without its assertion, or
  /// under [requireVerified] is rejected.
  ///
  /// The client holds an assertion for the user the host set
  /// (`NoticebirdClient.setUser` or `setUserId`) until 5 minutes before
  /// its `exp`, and sends it with each report of that user meanwhile; it
  /// asks again for another user, after `setUser(null)`, and once the
  /// platform refused the one it held. Without a user set, it asks for
  /// every report.
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

  /// Told the end of each report kept in [offlineStore]: delivered by a
  /// later `NoticebirdClient.flush`, or rejected for good — refused by the
  /// platform, expired ([FeedbackRejection.expired]) or evicted to keep the
  /// store within its bounds ([FeedbackRejection.evicted]). A report
  /// `captureFeedback` delivered or rejected at once is not told here: its
  /// outcome says so. A callback that throws costs nothing; without one, a
  /// debug build prints each report rejected from the store.
  final void Function(FeedbackSettled settled)? onSettled;

  /// Diagnostics groups of the app's state the client takes itself with
  /// each report's [FeedbackMoment], before the host's own: what a
  /// framework integration knows, such as the live blocs per type
  /// (`noticebird_flutter` fills it). Asked when the moment is taken; one
  /// that throws adds nothing. Its values are sanitised as the host's are.
  final Map<String, Map<String, Object?>> Function()? contextDiagnostics;
}
