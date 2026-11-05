// BreadcrumbFields: each kind, the run-local id aliases, a reader that does
// not fit or fails, an object whose text holds a secret, and the names and
// values the protocol takes.

import 'package:noticebird/noticebird.dart';
import 'package:test/test.dart';

enum _Status { loading, loaded }

enum _Mode { grid, list, board }

final class _State {
  _State({
    this.status,
    this.records,
    this.spaceId,
    this.query,
    this.mode,
    this.error,
    this.busy,
    this.total,
  });

  final _Status? status;
  final List<Object>? records;
  final String? spaceId;
  final String? query;
  final Object? mode;
  final Object? error;
  final bool? busy;
  final num? total;
}

/// An object whose text is a secret, as a freezed event's `toString()`
/// renders its constructor arguments.
final class _Secretive {
  @override
  String toString() => 'Reauthenticate(password: hunter2)';
}

/// A freezed union's case, as its generated code names it.
// ignore: camel_case_types
final class _$ReauthenticateImpl {
  _$ReauthenticateImpl(this.password);

  final String password;

  @override
  String toString() => 'ProfileEvent.reauthenticate(password: $password)';
}

final class _Failure {
  _Failure(this.reason);

  final _Mode reason;

  @override
  String toString() => 'Failure: could not save "Groceries for Alice"';
}

void main() {
  late BreadcrumbIds ids;

  setUp(() => ids = BreadcrumbIds());

  Map<String, Object> describe(
    List<BreadcrumbField<dynamic>> fields,
    Object? subject,
  ) => BreadcrumbFields(fields).describe(subject, ids: ids);

  group('literal', () {
    test('an enum is its name, a bool and a finite number themselves', () {
      final data = describe([
        BreadcrumbField.literal('status', (s) => s.status),
        BreadcrumbField.literal('busy', (s) => s.busy),
        BreadcrumbField.literal('total', (s) => s.total),
      ], _State(status: _Status.loaded, busy: false, total: 6));
      expect(data, {'status': 'loaded', 'busy': false, 'total': 6});
    });

    test('a string, a non-finite number or an object is its presence', () {
      expect(
        describe([
          BreadcrumbField.literal('query', (s) => s.query),
        ], _State(query: 'Groceries')),
        {'query': true},
      );
      expect(
        describe([
          BreadcrumbField.literal('query', (s) => s.query),
        ], _State(query: '')),
        {'query': false},
      );
      expect(
        describe([
          BreadcrumbField.literal('total', (s) => s.total),
        ], _State(total: double.nan)),
        {'total': true},
      );
      expect(
        describe([
          BreadcrumbField.literal('error', (s) => s.error),
        ], _State(error: _Secretive())),
        {'error': true},
      );
    });
  });

  group('vocabulary', () {
    final mode = BreadcrumbField<_State>.vocabulary('mode', (s) => s.mode, {
      'grid',
      'list',
    });

    test('a word of the set is itself, an enum by its name', () {
      expect(describe([mode], _State(mode: 'grid')), {'mode': 'grid'});
      expect(describe([mode], _State(mode: _Mode.list)), {'mode': 'list'});
    });

    test('a value outside the set is true', () {
      expect(describe([mode], _State(mode: 'Alice')), {'mode': true});
      expect(describe([mode], _State(mode: _Mode.board)), {'mode': true});
      expect(describe([mode], _State(mode: 3)), {'mode': true});
    });

    test('a word that is no data string is refused when the table is '
        'made', () {
      expect(
        () => BreadcrumbField<_State>.vocabulary('mode', (s) => s.mode, {
          'two words',
        }),
        throwsArgumentError,
      );
    });
  });

  test('count is the length of a list, a set or a map, as <name>.count', () {
    final count = BreadcrumbField<_State>.count('records', (s) => s.records);
    expect(count.dataName, 'records.count');
    expect(describe([count], _State(records: ['a', 'b', 'c'])), {
      'records.count': 3,
    });
    expect(
      describe([BreadcrumbField.count('items', (s) => s)], {'a': 1, 'b': 2}),
      {'items.count': 2},
    );
    expect(describe([BreadcrumbField.count('items', (s) => s)], {1, 2, 3}), {
      'items.count': 3,
    });
    expect(
      describe([BreadcrumbField.count('items', (s) => s)], 'no collection'),
      isEmpty,
    );
  });

  test('type is the runtime type by the name rule, never the text', () {
    final type = BreadcrumbField<_State>.type('error', (s) => s.error);
    expect(describe([type], _State(error: _Secretive())), {
      'error': 'Secretive',
    });
    expect(describe([type], _State(error: _$ReauthenticateImpl('hunter2'))), {
      'error': 'Reauthenticate',
    });
    expect(describe([type], _State(error: <String, int>{})), {
      'error': isA<String>().having(
        (name) => name,
        'name',
        isNot(contains('<')),
      ),
    });
  });

  test('an error is a type and the literal of its enum reason', () {
    final data = describe([
      BreadcrumbField.type('error', (s) => s.error),
      BreadcrumbField.literal('error.reason', (s) => s.error?.reason),
    ], _State(error: _Failure(_Mode.board)));
    expect(data, {'error': 'Failure', 'error.reason': 'board'});
  });

  test('presence is true for set, false for an empty string or '
      'collection', () {
    final presence = BreadcrumbField.presence('query', (s) => s);
    expect(describe([presence], 'Alice'), {'query': true});
    expect(describe([presence], ''), {'query': false});
    expect(describe([presence], const <int>[]), {'query': false});
    expect(describe([presence], const <String, int>{}), {'query': false});
    expect(describe([presence], 0), {'query': true});
  });

  group('id', () {
    final space = BreadcrumbField<_State>.id('spaceId', (s) => s.spaceId);
    const a = '0b9c3c55-5e51-4a8e-9a43-0c4b0f6a1e11';
    const b = '7d1f2a10-1b2c-4d3e-8f40-5a6b7c8d9e0f';

    test('the same value is the same alias through the run, another value '
        'the next', () {
      expect(describe([space], _State(spaceId: a)), {'spaceId': 'id1'});
      expect(describe([space], _State(spaceId: b)), {'spaceId': 'id2'});
      expect(describe([space], _State(spaceId: a)), {'spaceId': 'id1'});
    });

    test('one table of aliases serves every field and every table', () {
      final events = BreadcrumbFields([
        BreadcrumbField.id('recordId', (s) => s),
      ]);
      expect(describe([space], _State(spaceId: a)), {'spaceId': 'id1'});
      expect(events.describe(b, ids: ids), {'recordId': 'id2'});
      expect(events.describe(a, ids: ids), {'recordId': 'id1'});
    });

    test('the value itself never reaches the data', () {
      final data = describe([space], _State(spaceId: a));
      expect(data.values, isNot(contains(a)));
    });

    test('a table remembers at most maxRemembered values, and never reuses '
        'a number', () {
      for (var i = 0; i < BreadcrumbIds.maxRemembered; i++) {
        ids.aliasOf(i);
      }
      expect(ids.aliasOf(0), 'id1');
      expect(ids.aliasOf('new'), 'id${BreadcrumbIds.maxRemembered + 1}');
      // 1, the oldest after 0 was seen again, is forgotten.
      expect(ids.aliasOf(1), 'id${BreadcrumbIds.maxRemembered + 2}');
      expect(ids.aliasOf(0), 'id1');
    });
  });

  test('a freezed-like event holding a password yields its type only', () {
    final events = BreadcrumbFields([
      BreadcrumbField.type('event', (s) => s),
      BreadcrumbField.literal('password', (s) => s.password),
      BreadcrumbField.literal('query', (s) => s.query),
    ]);
    final data = events.describe(_$ReauthenticateImpl('hunter2'), ids: ids);
    expect(data, {'event': 'Reauthenticate', 'password': true});
    expect('$data', isNot(contains('hunter2')));
  });

  test('a reader that does not fit the subject, or throws, is skipped', () {
    final data = describe([
      BreadcrumbField.literal('missing', (s) => s.noSuchField),
      BreadcrumbField.literal('fails', (s) => throw StateError('boom')),
      BreadcrumbField.literal('status', (s) => s.status),
    ], _State(status: _Status.loading));
    expect(data, {'status': 'loading'});
  });

  test('an absent value leaves its name out', () {
    final data = describe([
      BreadcrumbField.literal('status', (s) => s.status),
      BreadcrumbField.count('records', (s) => s.records),
      BreadcrumbField.id('spaceId', (s) => s.spaceId),
      BreadcrumbField.presence('query', (s) => s.query),
      BreadcrumbField.type('error', (s) => s.error),
      BreadcrumbField.vocabulary('mode', (s) => s.mode, {'grid'}),
    ], _State());
    expect(data, isEmpty);
  });

  test('a typed field reads a subject of its type only', () {
    final fields = [
      BreadcrumbField<_State>.literal('status', (s) => s.status),
      BreadcrumbField<_Failure>.literal('reason', (s) => s.reason),
    ];
    expect(describe(fields, _State(status: _Status.loaded)), {
      'status': 'loaded',
    });
    expect(describe(fields, _Failure(_Mode.grid)), {'reason': 'grid'});
    expect(describe(fields, null), isEmpty);
  });

  test('a description holds at most maxDataEntries entries, the first', () {
    final fields = [
      for (var i = 0; i < TypedBreadcrumb.maxDataEntries + 4; i++)
        BreadcrumbField.literal('f$i', (s) => i),
    ];
    final data = describe(fields, Object());
    expect(data, hasLength(TypedBreadcrumb.maxDataEntries));
    expect(data.keys.first, 'f0');
    expect(data.keys.last, 'f${TypedBreadcrumb.maxDataEntries - 1}');
  });

  test('every description is a step the protocol takes', () {
    final data = describe(
      [
        BreadcrumbField.literal('status', (s) => s.status),
        BreadcrumbField.count('records', (s) => s.records),
        BreadcrumbField.id('spaceId', (s) => s.spaceId),
        BreadcrumbField.presence('query', (s) => s.query),
        BreadcrumbField.type('error', (s) => s.error),
      ],
      _State(
        status: _Status.loaded,
        records: [1],
        spaceId: 'Groceries',
        query: 'x',
        error: _Secretive(),
      ),
    );
    for (final MapEntry(:key, :value) in data.entries) {
      expect(TypedBreadcrumb.isDataName(key), isTrue, reason: key);
      expect(TypedBreadcrumb.isDataValue(value), isTrue, reason: key);
    }
    final step = TypedBreadcrumb(
      at: DateTime.utc(2026, 11, 5),
      message: 'ProfileBloc changed',
      data: data,
    );
    expect(step.check, returnsNormally);
  });

  group('names', () {
    test('a name the protocol does not take is refused when the field is '
        'made', () {
      for (final name in ['', 'Status', 'two words', '1st', 'a' * 49]) {
        expect(
          () => BreadcrumbField.literal(name, (s) => s),
          throwsArgumentError,
          reason: name,
        );
      }
      // `<name>.count` must fit too.
      expect(
        () => BreadcrumbField.count('a' * 43, (s) => s),
        throwsArgumentError,
      );
    });

    test('two fields of one data name are refused', () {
      expect(
        () => BreadcrumbFields([
          BreadcrumbField.literal('status', (s) => s),
          BreadcrumbField.type('status', (s) => s),
        ]),
        throwsArgumentError,
      );
    });

    for (final (type, name) in [
      ('ProfileState', 'ProfileState'),
      ('_ProfileState', 'ProfileState'),
      ('Foo<Bar>', 'Foo'),
      ('_Box<Map<String, int>>', 'Box'),
      (r'_$ReauthenticateImpl', 'Reauthenticate'),
      ('minified:aB', 'minified_aB'),
      ('_', ''),
    ]) {
      test('the type $type is named $name', () {
        expect(BreadcrumbFields.typeName(type), name);
      });
    }
  });
}
