import 'package:flutter/foundation.dart';

/// Whether an integration mistake of the host throws, to be seen while
/// someone looks: a raw route in `NoticebirdClient.setRouteTemplate`, input
/// `NoticebirdClient.captureFeedback` refuses. [kDebugMode]; a release build
/// drops the value or rejects the report instead.
bool get hostMistakesThrow => _hostMistakesThrow;

bool _hostMistakesThrow = kDebugMode;

/// Sets [hostMistakesThrow], so that a test runs the release path. A test
/// that sets it sets it back to [kDebugMode] when it ends.
@visibleForTesting
set debugHostMistakesThrow(bool value) => _hostMistakesThrow = value;
