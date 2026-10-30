import 'package:noticebird/noticebird.dart';
import 'package:noticebird_native/src/native_crash_record_codec.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> validRecord() => {
  'recordVersion': 1,
  'recordId': 'ab' * 32,
  'kind': 'crash',
  'source': 'metricKit',
  'occurredAtMs': 1790325677000,
  'machException': 'EXC_BAD_ACCESS',
  'signal': 'SIGBUS',
  'code': '0x32',
  'images': [
    {
      'name': 'Flutter',
      'debugId': '4c4c44e555553144a13dcc7994841aac',
      'arch': 'arm64',
      'inApp': true,
    },
  ],
  'frames': [
    <String, Object?>{},
    {'image': 0, 'offset': 10481952},
  ],
  'pid': 4312,
  'appVersion': '1.3.0',
  'appBuild': '130',
};

void main() {
  test('a contract record decodes into a record the core can build', () {
    final record = decodeNativeCrashRecord(validRecord())!;

    expect(record.recordId, 'ab' * 32);
    expect(record.kind, NativeCrashKind.crash);
    expect(record.source, NativeReportSource.metricKit);
    expect(record.occurredAt, DateTime.utc(2026, 9, 25, 8, 41, 17));
    expect(record.occurredAt.isUtc, isTrue);
    expect(record.images.single.debugId, '4c4c44e555553144a13dcc7994841aac');
    expect(record.frames[1].offset, 10481952);
    expect(record.pid, 4312);
    expect(record.appBuild, '130');
  });

  test('every kind and every optional field decodes', () {
    for (final kind in NativeCrashKind.values) {
      final json = {
        ...validRecord(),
        'kind': kind.name,
        'source': 'exitInfo',
        'terminationCode': '0x8badf00d',
        'exceptionClass': r'java.lang.IllegalStateException$Inner',
        'exceptionMessage': 'm' * 1024,
        if (kind == NativeCrashKind.hang) 'durationMs': 2500,
        if (kind == NativeCrashKind.diskWriteException)
          'bytesWritten': 4294967296,
        'runId': 'c' * 32,
        'foreground': false,
        'frames': [
          {'image': 0, 'offset': 1},
          {'symbol': 'com.example.Foo.bar', 'line': 42},
        ],
      };
      final record = decodeNativeCrashRecord(json);
      expect(record, isNotNull, reason: kind.name);
      expect(record!.runId, 'c' * 32);
      expect(record.foreground, isFalse);
    }
  });

  group('anything off-contract rejects the whole record', () {
    final mutations = <String, void Function(Map<String, Object?>)>{
      'not a map': (_) {},
      'unknown key': (json) => json['threads'] = <Object?>[],
      'null value': (json) => json['signal'] = null,
      'wrong version': (json) => json['recordVersion'] = 2,
      'missing id': (json) => json.remove('recordId'),
      'short id': (json) => json['recordId'] = 'ab',
      'uppercase id': (json) => json['recordId'] = 'AB' * 32,
      'unknown kind': (json) => json['kind'] = 'oom',
      'unknown source': (json) => json['source'] = 'crashpad',
      'time as string': (json) => json['occurredAtMs'] = '1790325677000',
      'lowercase signal': (json) => json['signal'] = 'sigbus',
      'uppercase code': (json) => json['code'] = '0X32',
      'duration on a crash': (json) => json['durationMs'] = 10,
      'dashed debug id': (json) =>
          ((json['images']! as List).first as Map)['debugId'] =
              '4c4c44e5-5555-3144-a13d-cc7994841aac',
      'path as image name': (json) =>
          ((json['images']! as List).first as Map)['name'] =
              '/private/var/containers/Flutter',
      'image out of range': (json) =>
          ((json['frames']! as List)[1] as Map)['image'] = 3,
      'unreferenced image': (json) =>
          (json['images']! as List).add({'name': 'Other', 'inApp': false}),
      'absolute address': (json) =>
          ((json['frames']! as List)[1] as Map)['address'] = 4295032832,
      '65 frames': (json) =>
          json['frames'] = List.filled(65, <String, Object?>{}),
      'bad exception class': (json) =>
          json['exceptionClass'] = 'java.lang.Error with spaces',
      'long message': (json) => json['exceptionMessage'] = 'm' * 1025,
      'bad run id': (json) => json['runId'] = 'not-a-run',
      'foreground as string': (json) => json['foreground'] = 'yes',
      'pid as double': (json) => json['pid'] = 1.5,
    };
    for (final entry in mutations.entries) {
      test(entry.key, () {
        final json = validRecord();
        entry.value(json);
        final Object input = entry.key == 'not a map' ? ['crash'] : json;
        expect(decodeNativeCrashRecord(input), isNull);
      });
    }
  });

  test('the id of an undecodable record is still readable to settle it', () {
    expect(
      nativeCrashRecordIdOf({'recordId': 'ab' * 32, 'kind': 'x'}),
      'ab' * 32,
    );
    expect(nativeCrashRecordIdOf({'recordId': 'nope'}), isNull);
    expect(nativeCrashRecordIdOf('ab'), isNull);
  });
}
