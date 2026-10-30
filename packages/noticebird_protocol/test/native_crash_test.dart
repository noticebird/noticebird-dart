// The native block (schema 4) as a client builds it: what toJson writes, the
// marker rule, and NativeCrashInfo.check.

import 'dart:convert';

import 'package:noticebird_protocol/noticebird_protocol.dart';
import 'package:test/test.dart';

import 'support/crash_events.dart';

/// [metricKitCrash] with any field replaced.
NativeCrashInfo _crash({
  NativeCrashKind kind = NativeCrashKind.crash,
  String? machException = 'EXC_BAD_ACCESS',
  String? signal = 'SIGBUS',
  String? code = '0x32',
  String? terminationCode,
  int? durationMs,
  int? bytesWritten,
  List<NativeImage>? images,
  List<NativeFrame>? frames,
}) => NativeCrashInfo(
  kind: kind,
  source: NativeReportSource.metricKit,
  machException: machException,
  signal: signal,
  code: code,
  terminationCode: terminationCode,
  durationMs: durationMs,
  bytesWritten: bytesWritten,
  images: images ?? metricKitCrash.images,
  frames: frames ?? metricKitCrash.frames,
);

/// [crash] refused by its check and by the event's writers.
void _expectRefused(
  NativeCrashInfo crash,
  ProtocolViolation violation,
  String path,
) {
  expect(crash.check, refusedWith(violation, path), reason: path);
  expectRefused(nativeEvent(crash), violation, path);
}

void main() {
  group('toJson', () {
    test('writes the block, its images and frames as built', () {
      final json = nativeEvent().toJson();

      expect(json['exception'], containsPair('stackTrace', '<native>'));
      expect(json['native'], {
        'kind': 'crash',
        'source': 'metricKit',
        'machException': 'EXC_BAD_ACCESS',
        'signal': 'SIGBUS',
        'code': '0x32',
        'images': [
          {
            'name': 'Flutter',
            'inApp': true,
            'debugId': '4c4c44e555553144a13dcc7994841aac',
            'arch': 'arm64',
          },
          {
            'name': 'libdispatch.dylib',
            'inApp': false,
            'debugId': '8e5c2f1a9b3d47e6a0c4d2b1f7e9a3c5',
            'arch': 'arm64',
          },
        ],
        'frames': [
          <String, Object?>{},
          {'image': 0, 'offset': 10481952},
          {'image': 0, 'offset': 5402168},
          {'image': 1, 'offset': 17104},
        ],
      });
      expect(jsonDecode(nativeEvent().toCanonicalJson()), json);
    });

    test('every kind and every frame shape builds', () {
      for (final kind in NativeCrashKind.values) {
        final info = NativeCrashInfo(
          kind: kind,
          source: NativeReportSource.exitInfo,
          signal: 'SIGSEGV',
          code: '0x1',
          terminationCode: '0x8badf00d',
          durationMs: kind == NativeCrashKind.hang ? 2500 : null,
          bytesWritten: kind == NativeCrashKind.diskWriteException
              ? NativeCrashInfo.maxBytesWritten
              : null,
          images: const [
            NativeImage(
              name: 'libapp.so',
              inApp: true,
              debugId: 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678',
              arch: NativeArch.x86_64,
            ),
            NativeImage(name: 'libc.so', inApp: false),
          ],
          frames: const [
            NativeFrame.inImage(0, 4096),
            NativeFrame.inImage(1, NativeFrame.maxOffset, symbol: 'abort'),
            NativeFrame.symbol(r'com.example.Foo$Bar.lambda$run$0', line: 42),
            NativeFrame.symbol('<init>'),
            NativeFrame.unknown(),
          ],
        );
        info.check();
        expect(nativeEvent(info).toJson()['native'], info.toJson());
      }
    });

    test('a block without images or frames is valid', () {
      const memoryKill = NativeCrashInfo(
        kind: NativeCrashKind.memoryKill,
        source: NativeReportSource.exitInfo,
      );
      expect(nativeEvent(memoryKill).toJson()['native'], {
        'kind': 'memoryKill',
        'source': 'exitInfo',
      });
    });

    test('kinds know whether the process died', () {
      expect(NativeCrashKind.values.where((kind) => !kind.isFatal), [
        NativeCrashKind.hang,
        NativeCrashKind.diskWriteException,
      ]);
    });
  });

  group('the marker and the block require each other', () {
    test('a native event carries the marker', () {
      final unmarked = CrashEvent(
        eventId: '6c3b9f0e-8d2a-8c41-9f5e-2b7d4a1c0e95',
        occurredAt: DateTime.utc(2026, 9, 25, 8, 41, 17),
        severity: CrashSeverity.fatal,
        handled: false,
        exception: const CrashException(
          type: 'SIGSEGV',
          sanitizedMessage: 'SIGSEGV',
          stackTrace: '<no-app-frames>',
        ),
        app: v5App,
        platform: v5Platform,
        routeTemplate: null,
        sessionId: 'run_000640c9e21a4f3b8d17c2a95e04b6f1',
        nativeCrash: metricKitCrash,
      );
      expectRefused(
        unmarked,
        ProtocolViolation.invalidValue,
        r'$.exception.stackTrace',
      );
    });

    test('the marker needs a native block', () {
      expectRefused(
        v5Event(
          exception: const CrashException(
            type: 'StateError',
            sanitizedMessage: 'Bad state',
            stackTrace: nativeStackTraceMarker,
          ),
        ),
        ProtocolViolation.invalidValue,
        r'$.exception.stackTrace',
      );
    });
  });

  group('every rule of the block', () {
    test('exception, signal and code names follow their patterns', () {
      for (final (crash, field) in [
        for (final invalid in ['EXC_bad', 'SIGSEGV', 'EXC_${'A' * 31}'])
          (_crash(machException: invalid), 'machException'),
        for (final invalid in ['SIG', 'sigsegv', 'SIGABCDEFGHI', 'EXC_BAD'])
          (_crash(signal: invalid), 'signal'),
        for (final invalid in ['0X32', '50', '0x', '0x${'f' * 17}', '0xABC'])
          (_crash(code: invalid), 'code'),
        for (final invalid in ['8badf00d', '0x8BADF00D', 'reason'])
          (_crash(terminationCode: invalid), 'terminationCode'),
      ]) {
        _expectRefused(
          crash,
          ProtocolViolation.invalidValue,
          '\$.native.$field',
        );
      }
    });

    test('durationMs is for hangs only and bounded', () {
      _expectRefused(
        _crash(durationMs: 1000),
        ProtocolViolation.invalidValue,
        r'$.native.durationMs',
      );
      for (final invalid in [-1, NativeCrashInfo.maxHangDurationMs + 1]) {
        _expectRefused(
          _crash(kind: NativeCrashKind.hang, durationMs: invalid),
          ProtocolViolation.invalidValue,
          r'$.native.durationMs',
        );
      }
    });

    test('bytesWritten is for disk-write exceptions only and bounded', () {
      _expectRefused(
        _crash(bytesWritten: 1000),
        ProtocolViolation.invalidValue,
        r'$.native.bytesWritten',
      );
      _expectRefused(
        _crash(
          kind: NativeCrashKind.diskWriteException,
          bytesWritten: NativeCrashInfo.maxBytesWritten + 1,
        ),
        ProtocolViolation.invalidValue,
        r'$.native.bytesWritten',
      );
    });

    test('images and frames are bounded', () {
      _expectRefused(
        _crash(
          images: [
            for (var i = 0; i <= NativeCrashInfo.maxImages; i++)
              NativeImage(name: 'lib$i.so', inApp: false),
          ],
          frames: [
            for (var i = 0; i <= NativeCrashInfo.maxImages; i++)
              NativeFrame.inImage(i, 0),
          ],
        ),
        ProtocolViolation.oversized,
        r'$.native.images',
      );
      _expectRefused(
        _crash(
          images: const [],
          frames: List.filled(
            NativeCrashInfo.maxFrames + 1,
            const NativeFrame.unknown(),
          ),
        ),
        ProtocolViolation.oversized,
        r'$.native.frames',
      );
    });

    test('image names are file names, never paths', () {
      for (final invalid in [
        '/private/var/containers/Bundle/Application/X/Runner.app/Frameworks/Flutter',
        'Flutter framework',
        '',
        'x' * (NativeImage.maxNameLength + 1),
      ]) {
        _expectRefused(
          _crash(
            images: [
              NativeImage(name: invalid, inApp: true),
              metricKitCrash.images[1],
            ],
          ),
          ProtocolViolation.invalidValue,
          r'$.native.images[0].name',
        );
      }
    });

    test('debug ids are lowercase hex without dashes', () {
      for (final invalid in [
        '4c4c44e5-5555-3144-a13d-cc7994841aac',
        '4C4C44E555553144A13DCC7994841AAC',
        'abc123',
        'f' * 41,
      ]) {
        _expectRefused(
          _crash(
            images: [
              NativeImage(name: 'Flutter', inApp: true, debugId: invalid),
              metricKitCrash.images[1],
            ],
          ),
          ProtocolViolation.invalidValue,
          r'$.native.images[0].debugId',
        );
      }
    });

    test('an image no frame references is refused', () {
      _expectRefused(
        _crash(
          images: [
            ...metricKitCrash.images,
            const NativeImage(name: 'Unused', inApp: false),
          ],
        ),
        ProtocolViolation.invalidValue,
        r'$.native.images[2]',
      );
    });

    test('frame image indexes stay in range', () {
      for (final invalid in [2, -1]) {
        _expectRefused(
          _crash(
            frames: [
              const NativeFrame.unknown(),
              NativeFrame.inImage(invalid, 1),
              const NativeFrame.inImage(0, 1),
              const NativeFrame.inImage(1, 1),
            ],
          ),
          ProtocolViolation.invalidValue,
          r'$.native.frames[1].image',
        );
      }
    });

    test('offsets are relative and bounded', () {
      for (final invalid in [-1, NativeFrame.maxOffset + 1]) {
        _expectRefused(
          _crash(
            frames: [
              const NativeFrame.unknown(),
              NativeFrame.inImage(0, invalid),
              const NativeFrame.inImage(1, 1),
            ],
          ),
          ProtocolViolation.invalidValue,
          r'$.native.frames[1].offset',
        );
      }
    });

    test('symbols follow the symbol pattern', () {
      for (final invalid in [
        'person@example.com',
        'Bearer abc',
        'main thread',
        'foo(int)',
        '',
        'x' * (NativeFrame.maxSymbolLength + 1),
      ]) {
        _expectRefused(
          _crash(images: const [], frames: [NativeFrame.symbol(invalid)]),
          ProtocolViolation.invalidValue,
          r'$.native.frames[0].symbol',
        );
      }
    });

    test('a line is from 1 to a million', () {
      for (final invalid in [0, NativeFrame.maxLine + 1]) {
        _expectRefused(
          _crash(
            images: const [],
            frames: [NativeFrame.symbol('com.example.Foo.bar', line: invalid)],
          ),
          ProtocolViolation.invalidValue,
          r'$.native.frames[0].line',
        );
      }
    });
  });
}
