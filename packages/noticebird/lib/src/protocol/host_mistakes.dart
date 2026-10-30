import 'package:meta/meta.dart';

/// Whether this is a debug build, by the constants Flutter's `kDebugMode` is
/// made of: neither a release (`dart.vm.product`) nor a profile
/// (`dart.vm.profile`) build. A Dart program run with `dart run` or
/// `dart test` counts as one.
const bool isDebugBuild =
    !bool.fromEnvironment('dart.vm.product') &&
    !bool.fromEnvironment('dart.vm.profile');

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
