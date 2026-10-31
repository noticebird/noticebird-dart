import 'feedback_capture.dart';
import 'feedback_offline_store.dart';
import 'feedback_transport.dart';

/// How the client delivers user feedback: `NoticebirdConfig.feedback`.
/// Without one, `NoticebirdClient.captureFeedback` answers
/// `FeedbackDisabled`.
final class FeedbackConfig {
  const FeedbackConfig({
    this.transport,
    this.offlineStore,
    this.onSettled,
    this.contextDiagnostics,
  });

  /// Where reports go: `FeedbackHttpTransport.of(crashTransport)`, to the
  /// API the crash transport names. `null` for a build without an API URL
  /// the SDK can send to or without a usable key:
  /// `NoticebirdClient.captureFeedback` answers `FeedbackDisabled`, and the
  /// rest of this config is checked all the same.
  final FeedbackTransport? transport;

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
