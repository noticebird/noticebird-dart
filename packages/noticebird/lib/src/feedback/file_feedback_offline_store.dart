import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:noticebird_protocol/feedback.dart';

import 'feedback_offline_store.dart';

/// A [FeedbackOfflineStore] in [directory], on a platform with a file
/// system: a JSON file per report and a binary file for its screenshot,
/// named after the report's id, each written to a temporary file first and
/// then renamed over the old one, so a write that does not end leaves the
/// earlier file whole. Not encrypted, so not for
/// `CrashPrivacyProfile.regulatedStrict`.
///
/// [pending] reads the JSON files only, and deletes a report it cannot
/// read, and what a write that did not end left behind. Files not named as
/// this store names them are left alone, but give the store a directory of
/// its own, such as one under the app's support directory, and each client
/// its own. A report id that is not a [FeedbackReport.uuidV4] names no
/// file: [put] throws an [ArgumentError] for it, [attachment] answers
/// `null` and [remove] deletes nothing.
///
/// On the web, which has no file system, it compiles and constructs, and
/// each of its file system calls throws an [UnsupportedError] of `dart:io`:
/// the client keeps no report there, and one that does not get through is
/// `FeedbackRejection.noStore`. Pass a store of the browser's there, or
/// none.
final class FileFeedbackOfflineStore implements FeedbackOfflineStore {
  FileFeedbackOfflineStore(this.directory);

  final Directory directory;

  @override
  bool get isEncrypted => false;

  @override
  Future<void> put(PendingFeedback report) async {
    if (!FeedbackReport.uuidV4.hasMatch(report.reportId)) {
      throw ArgumentError.value(report.reportId, 'reportId');
    }
    await directory.create(recursive: true);
    final attachment = report.attachment;
    final binary = _file(report.reportId, _binary);
    if (attachment != null) await _write(binary, attachment);
    await _write(
      _file(report.reportId, _json),
      utf8.encode(jsonEncode(report.toJson())),
    );
    if (attachment == null) await _delete(binary);
  }

  @override
  Future<List<PendingFeedback>> pending() async {
    if (!await directory.exists()) return const [];
    final names = <String>{
      await for (final entity in directory.list(followLinks: false))
        if (entity is File) entity.uri.pathSegments.last,
    };
    final reports = <PendingFeedback>[];
    for (final name in names) {
      final dot = name.indexOf('.');
      final reportId = dot < 0 ? name : name.substring(0, dot);
      final match = _suffix.firstMatch(name.substring(reportId.length));
      if (match == null || !FeedbackReport.uuidV4.hasMatch(reportId)) {
        continue;
      }
      if (match[2] != null) {
        // A write that did not end.
        await _delete(File(_path(name)));
      } else if (match[1] == _binary) {
        if (!names.contains('$reportId.$_json')) {
          await _delete(File(_path(name)));
        }
      } else {
        final report = await _read(reportId);
        if (report != null) reports.add(report);
      }
    }
    return reports;
  }

  @override
  Future<Uint8List?> attachment(String reportId) async {
    if (!FeedbackReport.uuidV4.hasMatch(reportId)) return null;
    try {
      return await _file(reportId, _binary).readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<void> remove(String reportId) async {
    if (!FeedbackReport.uuidV4.hasMatch(reportId)) return;
    // The JSON file first: without it the screenshot is no report.
    await _delete(_file(reportId, _json));
    await _delete(_file(reportId, _binary));
  }

  /// The report [reportId], or `null` when it cannot be read, after its
  /// files are deleted.
  Future<PendingFeedback?> _read(String reportId) async {
    try {
      final json = jsonDecode(await _file(reportId, _json).readAsString());
      final report = PendingFeedback.fromJson(json as Map<String, Object?>);
      if (report.reportId == reportId) return report;
    } catch (_) {
      // Unreadable or corrupt: deleted below.
    }
    await remove(reportId);
    return null;
  }

  static const _json = 'json';
  static const _binary = 'bin';

  /// What follows the report's id in `<reportId>.json` or
  /// `<reportId>.bin`, with `.tmp` while it is written.
  static final _suffix = RegExp(r'^\.(json|bin)(\.tmp)?$');

  String _path(String name) =>
      '${directory.path}${Platform.pathSeparator}$name';

  File _file(String reportId, String kind) => File(_path('$reportId.$kind'));

  static Future<void> _write(File file, Uint8List bytes) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
  }

  static Future<void> _delete(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // Gone already, or not ours to delete: nothing to keep either way.
    }
  }
}
