/// Noticebird for a Flutter app: [NoticebirdFlutter.start] wires the client
/// in (error handlers, breadcrumbs, offline stores, delivery), and the
/// `Noticebird` facade reports and sends feedback from anywhere. The
/// feedback types are in `package:noticebird_flutter/feedback.dart`.
library;

export 'package:noticebird/noticebird.dart';

export 'src/bloc_error_report.dart';
export 'src/noticebird_bloc_observer.dart';
export 'src/noticebird_flutter.dart';
export 'src/noticebird_navigator_observer.dart';
