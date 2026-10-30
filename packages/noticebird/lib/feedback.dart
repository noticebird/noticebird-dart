/// User feedback: what `NoticebirdClient.captureFeedback` takes and answers,
/// its config, transport and offline store, and the report's model from
/// `package:noticebird_protocol/feedback.dart`.
///
/// A library of its own, apart from `noticebird.dart`, so an app with
/// feedback types of its own imports these names only where it means them.
library;

export 'package:noticebird_protocol/feedback.dart';

export 'src/feedback/feedback_capture.dart';
export 'src/feedback/feedback_config.dart';
export 'src/feedback/feedback_http_transport.dart';
export 'src/feedback/feedback_offline_store.dart'
    show FeedbackOfflineStore, PendingFeedback;
export 'src/feedback/feedback_transport.dart';
export 'src/feedback/file_feedback_offline_store.dart';
