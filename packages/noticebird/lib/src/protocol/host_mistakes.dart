import 'package:meta/meta.dart';

/// Whether this is a debug build: one that runs its asserts, as a Flutter
/// debug build and `dart test` do, and a release or profile build, a
/// compiled executable and a production web build do not.
final bool isDebugBuild = () {
  var asserts = false;
  assert(asserts = true);
  return asserts;
}();

/// Whether an integration mistake of the host throws, to be seen while
/// someone looks: a raw route in `NoticebirdClient.setRouteTemplate`, input
/// `NoticebirdClient.captureFeedback` refuses. [isDebugBuild]; a release
/// build drops the value or rejects the report instead.
bool get hostMistakesThrow => _hostMistakesThrow;

bool _hostMistakesThrow = isDebugBuild;

/// Sets [hostMistakesThrow], so that a test runs the release path. A test
/// that sets it sets it back to [isDebugBuild] when it ends.
@visibleForTesting
set debugHostMistakesThrow(bool value) => _hostMistakesThrow = value;
