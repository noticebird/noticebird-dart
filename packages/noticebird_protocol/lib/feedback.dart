/// The feedback report, schema version 1: what a client needs to build one.
/// Its model, the limits and patterns of its fields, the validating writer
/// of its wire JSON, and the checks a client can run on a single value of
/// its own first.
///
/// A library of its own, apart from `noticebird_protocol.dart`, so an app
/// with feedback types of its own imports these names only where it means
/// them. It uses the crash protocol's [AppMetadata], [PlatformMetadata],
/// [TypedBreadcrumb] and [ProtocolException], which that library exports.
library;

import 'noticebird_protocol.dart';

export 'src/feedback_report.dart';
