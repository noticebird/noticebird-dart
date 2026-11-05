import 'package:noticebird_protocol/noticebird_protocol.dart';

/// What a [BreadcrumbField] makes of the value its reader returns.
enum _FieldKind { literal, vocabulary, count, type, presence, id }

/// One fact a [BreadcrumbFields] table reads from a subject (a bloc's state,
/// an event): a data [name], a reader that takes the value from the
/// subject, and a kind that says what of the value may leave the device.
///
/// No kind ever writes an arbitrary object's `toString()`: a value is
/// written as itself only when it cannot carry what a user typed (an enum's
/// name, a bool, a finite number, a word of a closed vocabulary); anything
/// else becomes its presence, its length, its type's name or a run-local
/// alias. A reader that returns `null` leaves its name out.
///
/// A field of type `BreadcrumbField<ProfileState>` reads a subject that is
/// a `ProfileState` only, so one table serves every state type; a field
/// without a type argument reads every subject, and a reader that does not
/// fit it (`(s) => s.spaceId` on a state without a `spaceId`) is skipped.
/// Inside a table's list a field without a type argument reads `dynamic`;
/// one kept in a variable of its own names it (`BreadcrumbField<dynamic>`):
///
/// ```dart
/// final states = BreadcrumbFields([
///   BreadcrumbField<ProfileState>.literal('status', (s) => s.status),
///   BreadcrumbField.count('collections', (s) => s.collections),
///   BreadcrumbField.id('spaceId', (s) => s.spaceId),
///   BreadcrumbField.presence('searchQuery', (s) => s.searchQuery),
///   BreadcrumbField.vocabulary('mode', (s) => s.mode, {'grid', 'list'}),
///   BreadcrumbField.type('error', (s) => s.error),
///   BreadcrumbField.literal('error.reason', (s) => s.error?.reason),
/// ]);
/// ```
///
/// An error has no kind of its own: its [BreadcrumbField.type] and a
/// [BreadcrumbField.literal] of its enum reason say what failed, never its
/// message, which can quote the input that caused it.
final class BreadcrumbField<S> {
  /// [name] as the value itself when it cannot carry typed text: an enum as
  /// its `name`, a bool, a number, each when it is a data value
  /// ([TypedBreadcrumb.isDataValue]: an enum's name of its pattern, a finite
  /// number of at most [TypedBreadcrumb.maxDataNumber]). Any other value, a
  /// string included, as its presence ([BreadcrumbField.presence]).
  BreadcrumbField.literal(String name, Object? Function(S subject) read)
    : this._(name, read, _FieldKind.literal);

  /// [name] as the value itself when it is one of [values], a closed
  /// vocabulary (a backend's status words); an enum is compared by its
  /// `name`. Any other value is `true`: present, but not a word the app
  /// named. Each of [values] must be a data string
  /// ([TypedBreadcrumb.isDataValue]).
  BreadcrumbField.vocabulary(
    String name,
    Object? Function(S subject) read,
    Set<String> values,
  ) : this._(name, read, _FieldKind.vocabulary, values);

  /// `<name>.count`: how many elements an `Iterable` or entries a `Map`
  /// holds, never the elements. A value that is no collection is skipped.
  BreadcrumbField.count(String name, Object? Function(S subject) read)
    : this._(name, read, _FieldKind.count);

  /// [name] as the value's runtime type, named by
  /// [BreadcrumbFields.typeName]: `Submitting`, `NetworkError`.
  BreadcrumbField.type(String name, Object? Function(S subject) read)
    : this._(name, read, _FieldKind.type);

  /// [name] as `true` when the value is set, `false` when it is an empty
  /// string or an empty collection.
  BreadcrumbField.presence(String name, Object? Function(S subject) read)
    : this._(name, read, _FieldKind.presence);

  /// [name] as a run-local alias of the value (`id1`, `id2`, …,
  /// [BreadcrumbIds]): the same value reads as the same alias through the
  /// run, so a reader of the trail sees the same row again and when it
  /// changed, and the value itself never leaves the device. A `String` or
  /// an `int` only: any other value is skipped, so the table holds no
  /// mutable key and keeps no entity alive.
  BreadcrumbField.id(String name, Object? Function(S subject) read)
    : this._(name, read, _FieldKind.id);

  BreadcrumbField._(
    this.name,
    this._read,
    this._kind, [
    Set<String> vocabulary = const {},
  ]) : _vocabulary = Set.unmodifiable(vocabulary) {
    if (!TypedBreadcrumb.isDataName(dataName)) {
      throw ArgumentError.value(
        name,
        'name',
        'Not a breadcrumb data name (TypedBreadcrumb.isDataName)',
      );
    }
    // The client's checks would drop every value of such a field: the app
    // learns it here, on the first run, rather than never.
    if (PrivacyPatterns.extraKeyViolation(dataName) case final violation?) {
      throw ArgumentError.value(
        name,
        'name',
        'Names ${violation.name} (PrivacyPatterns.extraKeyViolation): '
            'every value of it would be dropped',
      );
    }
    for (final word in _vocabulary) {
      if (!TypedBreadcrumb.isDataValue(word)) {
        throw ArgumentError.value(
          word,
          'values',
          'Not a breadcrumb data string (TypedBreadcrumb.isDataValue)',
        );
      }
    }
  }

  /// The name the app gave the field.
  final String name;

  final Object? Function(S subject) _read;
  final _FieldKind _kind;
  final Set<String> _vocabulary;

  /// The name the field writes in a step's data: [name], and for a
  /// [BreadcrumbField.count] `<name>.count`.
  String get dataName => _kind == _FieldKind.count ? '$name.count' : name;

  /// The data value of this field for [subject], or null when it writes
  /// nothing: a subject of another type, a reader that returns null or
  /// throws, a value its kind skips.
  Object? _describe(Object? subject, BreadcrumbIds ids) {
    if (subject is! S) return null;
    try {
      final value = _read(subject);
      if (value == null) return null;
      return switch (_kind) {
        _FieldKind.literal => _literal(value),
        _FieldKind.vocabulary => _word(value),
        _FieldKind.count => switch (value) {
          Iterable() => value.length,
          Map() => value.length,
          _ => null,
        },
        _FieldKind.type => _typeName(value),
        _FieldKind.presence => _presence(value),
        _FieldKind.id => switch (value) {
          String() || int() => ids.aliasOf(value),
          _ => null,
        },
      };
    } catch (_) {
      // A reader that does not fit the subject, or one that fails, writes
      // nothing: describing a step never affects the host application.
      return null;
    }
  }

  Object _literal(Object value) => switch (value) {
    Enum() when TypedBreadcrumb.isDataValue(value.name) => value.name,
    bool() => value,
    num() when TypedBreadcrumb.isDataValue(value) => value,
    _ => _presence(value),
  };

  Object _word(Object value) {
    final word = switch (value) {
      Enum() => value.name,
      String() => value,
      _ => null,
    };
    return word != null && _vocabulary.contains(word) ? word : true;
  }

  static bool _presence(Object value) => switch (value) {
    String() => value.isNotEmpty,
    Iterable() => value.isNotEmpty,
    Map() => value.isNotEmpty,
    _ => true,
  };

  static String? _typeName(Object value) {
    var name = BreadcrumbFields.typeName('${value.runtimeType}');
    if (name.length > TypedBreadcrumb.maxDataStringLength) {
      name = name.substring(0, TypedBreadcrumb.maxDataStringLength);
    }
    return TypedBreadcrumb.isDataValue(name) ? name : null;
  }
}

/// A table of [BreadcrumbField]s that describes a subject — a bloc's state,
/// an event — as a step's data ([TypedBreadcrumb.data]): the facts, never
/// the subject's text.
///
/// The app names the fields and how each may be shown; the SDK reads no
/// field by itself. `NoticebirdFlutter.start(blocStateFields:,
/// blocEventFields:)` hands two tables to the bloc observer; an app's own
/// breadcrumb describes its subject the same way:
///
/// ```dart
/// client.addBreadcrumb(
///   'Saved the record',
///   action: 'record.save',
///   data: records.describe(record, ids: client.breadcrumbIds),
/// );
/// ```
final class BreadcrumbFields {
  /// A table of [fields]; their data names ([BreadcrumbField.dataName])
  /// must differ.
  BreadcrumbFields(Iterable<BreadcrumbField<dynamic>> fields)
    : fields = List.unmodifiable(fields) {
    final names = <String>{};
    for (final field in this.fields) {
      if (!names.add(field.dataName)) {
        throw ArgumentError.value(
          field.dataName,
          'fields',
          'Two fields write the same data name',
        );
      }
    }
  }

  /// The fields, in the order a description lists them.
  final List<BreadcrumbField<dynamic>> fields;

  /// [subject] as a step's data: per field that writes a value, its data
  /// name and that value, in table order, at most
  /// [TypedBreadcrumb.maxDataEntries] entries (the first). Every name is a
  /// [TypedBreadcrumb.isDataName] and every value a
  /// [TypedBreadcrumb.isDataValue]. An id is aliased in [ids], the run's
  /// table (`NoticebirdClient.breadcrumbIds`). Never throws.
  Map<String, Object> describe(Object? subject, {required BreadcrumbIds ids}) {
    final data = <String, Object>{};
    for (final field in fields) {
      if (data.length >= TypedBreadcrumb.maxDataEntries) break;
      final value = field._describe(subject, ids);
      if (value != null) data[field.dataName] = value;
    }
    return data;
  }

  /// [runtimeTypeName], a runtime type's name, as a breadcrumb writes it:
  /// without type arguments and leading underscores, a freezed `_$…Impl`
  /// reduced to its middle (`_$ReauthenticateImpl` → `Reauthenticate`),
  /// and every character outside `[A-Za-z0-9_]` (a minified web name's
  /// `:`) a `_`. Empty when nothing is left.
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

/// The run's table of id aliases: each distinct value a
/// [BreadcrumbField.id] reads becomes `id1`, `id2`, … in the order first
/// seen, and keeps its alias for the run, so the trail shows the same row
/// as the same alias and an identifier never leaves the device. The table
/// lives in memory only (`NoticebirdClient.breadcrumbIds`); an alias means
/// nothing outside the run's trail.
///
/// It remembers at most [maxRemembered] values, forgetting the one seen
/// least recently when a new one comes: a value forgotten and seen again
/// gets a new alias. Numbers are never reused.
final class BreadcrumbIds {
  /// The most values the table remembers.
  static const maxRemembered = 4096;

  final _aliases = <Object, String>{};
  int _issued = 0;

  /// The alias of [value], a `String` or an `int`, by `==`: the one it was
  /// given, or the next one. Any other value is an [ArgumentError]: a key
  /// of another type may change under the table or keep an entity alive.
  String aliasOf(Object value) {
    if (value is! String && value is! int) {
      // Never the value itself in the message: its text may be anything.
      throw ArgumentError(
        'An id is a String or an int, not a ${value.runtimeType}',
      );
    }
    // Taken out and put back, so the order is the order of last sight.
    final known = _aliases.remove(value);
    if (known != null) return _aliases[value] = known;
    if (_aliases.length >= maxRemembered) _aliases.remove(_aliases.keys.first);
    return _aliases[value] = 'id${++_issued}';
  }
}
