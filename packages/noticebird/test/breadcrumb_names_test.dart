// BreadcrumbNames.typeName: the name a breadcrumb gives a type, for an
// observer an app writes.

import 'package:noticebird/noticebird.dart';
import 'package:test/test.dart';

void main() {
  for (final (type, name) in [
    ('ProfileState', 'ProfileState'),
    ('_ProfileBloc', 'ProfileBloc'),
    ('Foo<Bar>', 'Foo'),
    ('_Box<Map<String, int>>', 'Box'),
    (r'_$ReauthenticateImpl', 'Reauthenticate'),
    ('minified:aB', 'minified_aB'),
    ('_', ''),
  ]) {
    test('the type $type is named $name', () {
      expect(BreadcrumbNames.typeName(type), name);
    });
  }

  test('a name it gives fits a breadcrumb detail string', () {
    for (final type in ['minified:aB', r'_$ReauthenticateImpl', 'Foo<Bar>']) {
      expect(
        TypedBreadcrumb.isDetailValue(BreadcrumbNames.typeName(type)),
        isTrue,
      );
    }
  });
}
