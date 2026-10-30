// FileFeedbackOfflineStore in a temporary directory: a report the client
// queued is read back whole by a new store on the same directory, and
// delivered by a new client from it; a corrupt or half-written entry is
// skipped and deleted, and a file the store did not name is left alone; a
// screenshot is read only to be sent, and checked then; and an id that is no
// report id names no file.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:noticebird/feedback.dart';
import 'package:noticebird/noticebird.dart';

import 'support/fake_feedback_transport.dart';

const _app = AppMetadata(
  name: 'test-app',
  version: '1.0.0',
  build: '1',
  release: 'test-app@1.0.0+1',
);
const _platform = PlatformMetadata(
  platform: CrashPlatform.macos,
  osVersion: '15.5',
  deviceClass: 'desktop',
);

final _capturedAt = DateTime.utc(2026, 10, 30, 12);
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, //
  ...List.filled(120, 3),
]);

void main() {
  late Directory directory;
  late FakeFeedbackTransport transport;
  late DateTime now;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('noticebird_feedback_');
    addTearDown(() => directory.delete(recursive: true));
    transport = FakeFeedbackTransport();
    now = _capturedAt;
  });

  NoticebirdClient client({
    FeedbackOfflineStore? store,
    void Function(FeedbackSettled settled)? onSettled,
  }) => NoticebirdClient(
    config: NoticebirdConfig(
      privacyProfile: CrashPrivacyProfile.privacyDefault,
      app: _app,
      platform: _platform,
      sessionIdFactory: () => 'random_session_123456',
      feedback: FeedbackConfig(
        transport: transport,
        offlineStore: store ?? FileFeedbackOfflineStore(directory),
        onSettled: onSettled,
      ),
    ),
    clock: () => now,
  );

  Future<String> queued({Uint8List? screenshot}) async {
    transport.submitAnswers.add(const FeedbackTransient());
    final outcome = await client().captureFeedback(
      kind: FeedbackKind.bug,
      message: 'The list does not load',
      screenshot: screenshot,
    );
    return (outcome as FeedbackQueued).reportId;
  }

  Set<String> files() => {
    for (final entity in directory.listSync()) entity.uri.pathSegments.last,
  };

  test('is not encrypted', () {
    expect(FileFeedbackOfflineStore(directory).isEncrypted, isFalse);
  });

  test('a directory that does not exist holds nothing', () async {
    final missing = Directory('${directory.path}/missing');
    expect(await FileFeedbackOfflineStore(missing).pending(), isEmpty);
  });

  for (final screenshot in [null, _png]) {
    final name = screenshot == null ? 'without' : 'with';
    test('a report $name a screenshot is read back whole by a new store, and '
        'delivered by a new client', () async {
      final reportId = await queued(screenshot: screenshot);
      expect(files(), {
        '$reportId.json',
        if (screenshot != null) '$reportId.bin',
      });

      final store = FileFeedbackOfflineStore(directory);
      final report = (await store.pending()).single;
      expect(report.reportId, reportId);
      expect(report.createdAt, _capturedAt);
      expect(report.attachment, isNull);
      expect(await store.attachment(reportId), screenshot);
      expect(report.attempts, 1);
      expect(jsonDecode(report.reportJson), transport.submitted.single);

      now = report.nextAttemptAt;
      await client().flush();
      expect(transport.submitted, hasLength(2));
      expect(transport.submitted.last, transport.submitted.first);
      if (screenshot != null) expect(transport.uploaded.single, screenshot);
      expect(files(), isEmpty);
    });
  }

  test('put replaces a report, and remove deletes its files', () async {
    final reportId = await queued(screenshot: _png);
    final store = FileFeedbackOfflineStore(directory);

    transport.submitAnswers.add(const FeedbackTransient());
    now = (await store.pending()).single.nextAttemptAt;
    await client().flush();
    expect(transport.submitted, hasLength(2));
    final replaced = (await store.pending()).single;
    expect(replaced.attempts, 2);
    expect(await store.attachment(reportId), _png);
    expect(files(), {'$reportId.json', '$reportId.bin'});

    await store.remove(reportId);
    expect(files(), isEmpty);
    await store.remove(reportId);
  });

  test('a corrupt entry is skipped and deleted, and a file the store did not '
      'name is left alone', () async {
    final good = await queued();
    const corrupt = '6f9619ff-8b86-4011-b42d-00c04fc964ff';
    const orphan = '7f9619ff-8b86-4011-b42d-00c04fc964ff';
    const halfWritten = '8f9619ff-8b86-4011-b42d-00c04fc964ff';
    File('${directory.path}/$corrupt.json').writeAsStringSync('{"format":');
    File('${directory.path}/$orphan.bin').writeAsBytesSync(_png);
    File('${directory.path}/$halfWritten.json.tmp').writeAsStringSync('{');
    File('${directory.path}/notes.json').writeAsStringSync('{}');

    final reports = await FileFeedbackOfflineStore(directory).pending();

    expect(reports.map((report) => report.reportId), [good]);
    expect(files(), {'$good.json', 'notes.json'});
  });

  test('a report whose file names another report is deleted', () async {
    final reportId = await queued();
    const other = '6f9619ff-8b86-4011-b42d-00c04fc964ff';
    File(
      '${directory.path}/$reportId.json',
    ).renameSync('${directory.path}/$other.json');

    expect(await FileFeedbackOfflineStore(directory).pending(), isEmpty);
    expect(files(), isEmpty);
  });

  test('a put with 10 stored screenshots reads no screenshot', () async {
    final reportIds = <String>[];
    for (var index = 0; index < 10; index++) {
      now = _capturedAt.add(Duration(seconds: index));
      reportIds.add(await queued(screenshot: _png));
    }
    // Bytes no report names: a store that read them would find each report
    // corrupt.
    for (final reportId in reportIds) {
      File('${directory.path}/$reportId.bin').writeAsBytesSync([1, 2, 3]);
    }

    now = _capturedAt.add(const Duration(seconds: 10));
    final latest = await queued(screenshot: _png);

    expect(files(), {
      for (final reportId in [...reportIds.skip(1), latest]) ...[
        '$reportId.json',
        '$reportId.bin',
      ],
    });
  });

  test('a screenshot whose bytes are not the report\'s fails the report at '
      'the flush, and removes it', () async {
    final reportId = await queued(screenshot: _png);
    File(
      '${directory.path}/$reportId.bin',
    ).writeAsBytesSync(Uint8List.fromList([..._png]..[20] = 9));
    final settled = <FeedbackSettled>[];
    final reporter = client(onSettled: settled.add);

    now = now.add(const Duration(minutes: 1));
    await reporter.flush();
    await pumpEventQueue();

    expect(settled, [
      FeedbackSettled(
        reportId,
        const FeedbackRejected(FeedbackRejection.failed),
      ),
    ]);
    expect(transport.requests, ['slot', 'upload', 'submit']);
    expect(files(), isEmpty);
  });

  test('remove of an id that is no report id deletes nothing', () async {
    final outside = File('${directory.path}/x.json')..writeAsStringSync('{}');
    final store = FileFeedbackOfflineStore(
      Directory('${directory.path}/store')..createSync(),
    );

    await store.remove('../x');

    expect(outside.existsSync(), isTrue);
  });
}
