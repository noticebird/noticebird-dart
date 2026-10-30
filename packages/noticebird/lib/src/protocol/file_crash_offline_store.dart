import 'dart:convert';
import 'dart:io';

import 'noticebird_config.dart';

/// A [CrashOfflineStore] in [directory], on a platform with a file system:
/// one JSON file holding the queued events, written to a temporary file
/// first and then renamed over the old one, so a write that does not end
/// leaves the earlier queue whole. Not encrypted, so not for
/// `CrashPrivacyProfile.regulatedStrict`.
///
/// [read] keeps what it read: the client writes the queue back right after,
/// so a process that ends in between loses nothing. A file that cannot be
/// read is deleted, and read as empty. Give it a directory of its own, such
/// as one under the app's support directory, and each client its own.
///
/// On the web, which has no file system, it compiles and constructs, and
/// each of its calls throws an [UnsupportedError] of `dart:io`: pass none
/// there.
final class FileCrashOfflineStore implements CrashOfflineStore {
  FileCrashOfflineStore(this.directory);

  final Directory directory;

  @override
  bool get isEncrypted => false;

  @override
  Future<void> write(List<String> canonicalEnvelopes) async {
    final temporary = File('${_events.path}.tmp');
    if (canonicalEnvelopes.isEmpty) {
      await _delete(_events);
      await _delete(temporary);
      return;
    }
    await directory.create(recursive: true);
    await temporary.writeAsString(jsonEncode(canonicalEnvelopes), flush: true);
    await temporary.rename(_events.path);
  }

  @override
  Future<List<String>> read() async {
    try {
      final json = jsonDecode(await _events.readAsString());
      if (json is List && json.every((event) => event is String)) {
        return List<String>.unmodifiable(json);
      }
    } on PathNotFoundException {
      return const [];
    } catch (_) {
      // Unreadable or corrupt: deleted below.
    }
    await _delete(_events);
    return const [];
  }

  File get _events =>
      File('${directory.path}${Platform.pathSeparator}events.json');

  static Future<void> _delete(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // Gone already: nothing to keep either way.
    }
  }
}
