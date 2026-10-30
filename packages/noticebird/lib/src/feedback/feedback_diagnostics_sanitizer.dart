import 'package:noticebird_protocol/feedback.dart';
import 'package:noticebird_protocol/noticebird_protocol.dart';

/// The name of the diagnostics group in which the client notes what it left
/// out of a report ([sanitizeDiagnostics]). A host's group of that name is
/// left out.
const clientNoteGroup = 'noticebird';

/// [context] and then [host], the diagnostics groups of a report, as values
/// the report takes, with what was left out noted in the group
/// [clientNoteGroup] together with [notes].
///
/// Nothing a host passes refuses a report; what the report's rules refuse
/// is left out and counted (`dropped_values` in the note):
///
/// - a group whose name is no key ([FeedbackDiagnostics.keyPattern]), that
///   repeats a name taken before it ([context] comes first), or is named
///   [clientNoteGroup];
/// - the groups past [FeedbackReport.maxDiagnosticGroups], one group's room
///   kept for the note, and the values of a group past
///   [FeedbackReport.maxDiagnosticValues];
/// - a value whose key is no key, and a value the report does not take: free
///   text, a map, a list, a number that is not finite;
/// - the last groups, until the whole fits
///   [FeedbackReport.maxDiagnosticsBytes].
///
/// An [Enum] is sent as its name and a [DateTime] in UTC; every other value
/// as [FeedbackDiagnostics.build] types it.
///
/// [notes] are the client's own values for the note group (a dropped
/// screenshot, when the moment was taken). [dropped] is told how many values
/// were left out.
Map<String, Map<String, DiagnosticValue>> sanitizeDiagnostics({
  Map<String, Map<String, Object?>> context = const {},
  Map<String, Map<String, Object?>> host = const {},
  Map<String, Object> notes = const {},
  void Function(int dropped)? dropped,
}) {
  var droppedValues = 0;
  final groups = <String, Map<String, DiagnosticValue>>{};
  for (final source in [context, host]) {
    for (final MapEntry(key: name, value: values) in source.entries) {
      if (name == clientNoteGroup ||
          groups.containsKey(name) ||
          !FeedbackDiagnostics.keyPattern.hasMatch(name) ||
          groups.length >= FeedbackReport.maxDiagnosticGroups - 1) {
        droppedValues += values.length;
        continue;
      }
      final group = <String, DiagnosticValue>{};
      for (final MapEntry(:key, :value) in values.entries) {
        final typed = group.length < FeedbackReport.maxDiagnosticValues
            ? _typed(name, key, value)
            : null;
        if (typed == null) {
          droppedValues++;
        } else {
          group[key] = typed;
        }
      }
      if (group.isNotEmpty) groups[name] = group;
    }
  }

  Map<String, Map<String, DiagnosticValue>> withNote() {
    final note = <String, Object>{
      ...notes,
      if (droppedValues > 0) 'dropped_values': droppedValues,
    };
    return {
      ...groups,
      if (note.isNotEmpty)
        clientNoteGroup: {
          for (final MapEntry(:key, :value) in note.entries)
            key: _typed(clientNoteGroup, key, value)!,
        },
    };
  }

  for (;;) {
    final result = withNote();
    try {
      final built = FeedbackDiagnostics.build({
        for (final MapEntry(key: name, value: group) in result.entries)
          name: {
            for (final MapEntry(:key, :value) in group.entries) key: value.json,
          },
      });
      dropped?.call(droppedValues);
      return built;
    } on ProtocolException {
      if (groups.isEmpty) {
        // The note alone never outgrows the limit; nothing else is left.
        dropped?.call(droppedValues);
        return const {};
      }
      final last = groups.keys.last;
      droppedValues += groups.remove(last)!.length;
    }
  }
}

/// [value] under [key] of the group [name] as a value the report takes, or
/// `null` when it takes none.
DiagnosticValue? _typed(String name, String key, Object? value) {
  final converted = switch (value) {
    Enum() => value.name,
    DateTime() => value.toUtc(),
    _ => value,
  };
  try {
    return FeedbackDiagnostics.build({
      name: {key: converted},
    })[name]![key];
  } on ProtocolException {
    return null;
  }
}
