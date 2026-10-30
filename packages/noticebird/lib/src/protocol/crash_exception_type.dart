import 'dart:async';

import 'package:noticebird_protocol/noticebird_protocol.dart';

import 'text_sanitizer.dart';

/// The `exception.type` of [error], whose runtime type is named
/// [runtimeTypeName] (`error.runtimeType.toString()`), cut to the protocol's
/// [CrashException.maxTypeLength].
///
/// A minified dart2js build names every type `minified:<id>`, an id that
/// changes from build to build, so nobody can read it and grouping breaks
/// across releases. An error of a Dart core type is named by that type
/// instead, the most specific first: an `IndexError` is a `RangeError` and an
/// `ArgumentError`, an `UnimplementedError` an `UnsupportedError`. Any other
/// type keeps its minified name, which still tells the types of one build
/// apart where a common supertype such as `Exception` would merge unrelated
/// ones. A readable name passes as it is.
String crashExceptionType(Object error, String runtimeTypeName) {
  final type = runtimeTypeName.startsWith('minified:')
      ? _coreType(error) ?? runtimeTypeName
      : runtimeTypeName;
  return truncateCrashText(type, CrashException.maxTypeLength);
}

/// The Dart core type [error] is, or null when it is none of them.
String? _coreType(Object error) => switch (error) {
  IndexError() => 'IndexError',
  RangeError() => 'RangeError',
  ArgumentError() => 'ArgumentError',
  UnimplementedError() => 'UnimplementedError',
  UnsupportedError() => 'UnsupportedError',
  StateError() => 'StateError',
  TypeError() => 'TypeError',
  NoSuchMethodError() => 'NoSuchMethodError',
  AssertionError() => 'AssertionError',
  ConcurrentModificationError() => 'ConcurrentModificationError',
  OutOfMemoryError() => 'OutOfMemoryError',
  StackOverflowError() => 'StackOverflowError',
  FormatException() => 'FormatException',
  TimeoutException() => 'TimeoutException',
  _ => null,
};
