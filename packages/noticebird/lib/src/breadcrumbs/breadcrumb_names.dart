/// The names a breadcrumb gives a type, for an observer an app writes
/// (a bloc's, a provider's, a notifier's): never an object's text, only
/// its type's name.
abstract final class BreadcrumbNames {
  /// [runtimeTypeName], a runtime type's name (`'${value.runtimeType}'`),
  /// as a breadcrumb writes it: without type arguments and leading
  /// underscores, a freezed `_$…Impl` reduced to its middle
  /// (`_$ReauthenticateImpl` → `Reauthenticate`), and every character
  /// outside `[A-Za-z0-9_]` (a minified web name's `:`) a `_`. Empty when
  /// nothing is left.
  ///
  /// ```dart
  /// Noticebird.addBreadcrumb(
  ///   '${BreadcrumbNames.typeName('${bloc.runtimeType}')} changed',
  ///   category: 'bloc',
  /// );
  /// ```
  static String typeName(String runtimeTypeName) {
    var name = runtimeTypeName;
    final generic = name.indexOf('<');
    if (generic >= 0) name = name.substring(0, generic);
    if (_freezed.firstMatch(name) case final match?) name = match[1]!;
    return name.replaceFirst(_leadingUnderscores, '').replaceAll(_outside, '_');
  }

  static final _freezed = RegExp(r'^_\$(.+)Impl$');
  static final _leadingUnderscores = RegExp('^_+');
  static final _outside = RegExp('[^A-Za-z0-9_]');
}
