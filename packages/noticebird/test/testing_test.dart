// The test support a host imports from package:noticebird/testing.dart: a
// recorder whose real client reports to memory.

import 'package:noticebird/noticebird.dart';
import 'package:noticebird/testing.dart';
import 'package:test/test.dart';

final _stack = StackTrace.fromString('#0 A.b (package:app/a.dart:1:1)');

void main() {
  tearDown(Noticebird.detach);

  test('records each report as the platform would receive it, while the '
      'capture runs', () {
    final recorder = NoticebirdRecorder();

    final capture = recorder.client.captureException(
      StateError('boom'),
      _stack,
      handled: true,
      tags: const {AllowedTag.component: 'ListCubit'},
    );

    expect(capture, isA<Future<CaptureResult>>());
    final event = recorder.events.single;
    expect(event['handled'], isTrue);
    expect(event['app'], NoticebirdRecorder.app.toJson());
    expect((event['exception']! as Map)['type'], 'StateError');
    expect((event['tags']! as Map)['component'], 'ListCubit');
    expect(recorder.transport.sent, hasLength(1));
  });

  test('records a report made twice twice', () async {
    final recorder = NoticebirdRecorder();
    final error = StateError('boom');

    await recorder.client.captureException(error, _stack);
    await recorder.client.captureException(error, _stack);

    expect(recorder.events, hasLength(2));
  });

  test('answers the event of an error, and none for one the filter '
      'ignored', () async {
    final ignored = StateError('converted');
    final recorder = NoticebirdRecorder(
      shouldCapture: (error) => !identical(error, ignored),
    );
    final error = StateError('boom');

    final result = await recorder.client.captureException(error, _stack);
    await recorder.client.captureException(ignored, _stack);

    expect((await recorder.eventOf(error))?['eventId'], result.eventId);
    expect(await recorder.eventOf(ignored), isNull);
    expect(recorder.events, hasLength(1));
  });

  test('attaches to the facade, and detaches when closed', () async {
    final recorder = NoticebirdRecorder()..attach();
    await Noticebird.captureException(StateError('boom'), _stack);
    expect(recorder.events, hasLength(1));

    recorder.close();
    expect(Noticebird.instance, isNull);

    final other = NoticebirdRecorder()..attach();
    recorder.close();
    expect(Noticebird.instance, same(other.client));
  });
}
