// The names a bloc's breadcrumbs give a type. Not exported: the rule is
// the observer's, and a test reaches it here for a name no type of a test
// can have, such as a minified web build's.

/// [typeName], a runtime type's name, as a breadcrumb's message writes it:
/// without type arguments and leading underscores, a freezed `_$…Impl`
/// reduced to its middle, and every character outside `[A-Za-z0-9_]` (a
/// minified web name's `:`) a `_`.
String blocTypeName(String typeName) {
  var name = typeName;
  final generic = name.indexOf('<');
  if (generic >= 0) name = name.substring(0, generic);
  if (_freezed.firstMatch(name) case final match?) name = match[1]!;
  return name.replaceFirst(_leadingUnderscores, '').replaceAll(_outside, '_');
}

/// [typeName] as a bloc's actions start with it (`profileBloc.change`) and
/// a feedback report's `blocs` group counts it: [blocTypeName] with its
/// first letter in lower case, and `bloc` in front when it does not start
/// with a letter.
String blocActionName(String typeName) {
  final name = blocTypeName(typeName);
  if (name.isEmpty || !_letter.hasMatch(name[0])) return 'bloc$name';
  return '${name[0].toLowerCase()}${name.substring(1)}';
}

final _freezed = RegExp(r'^_\$(.+)Impl$');
final _leadingUnderscores = RegExp('^_+');
final _outside = RegExp('[^A-Za-z0-9_]');
final _letter = RegExp('[A-Za-z]');
