// The name a bloc's actions give its type. Not exported: the rule is the
// observer's, and a test reaches it here for a name no type of a test can
// have, such as a minified web build's.

import 'package:noticebird/noticebird.dart';

/// [typeName] as a bloc's actions start with it (`profileBloc.change`) and
/// a feedback report's `blocs` group counts it: [BreadcrumbFields.typeName]
/// with its first letter in lower case, and `bloc` in front when it does
/// not start with a letter.
String blocActionName(String typeName) {
  final name = BreadcrumbFields.typeName(typeName);
  if (name.isEmpty || !_letter.hasMatch(name[0])) return 'bloc$name';
  return '${name[0].toLowerCase()}${name.substring(1)}';
}

final _letter = RegExp('[A-Za-z]');
