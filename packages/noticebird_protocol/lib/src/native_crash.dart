import 'protocol_exception.dart';

/// The `exception.stackTrace` of an event that carries a [NativeCrashInfo].
///
/// A native event's frames live structured in [NativeCrashInfo.frames], never
/// as text: the platform's privacy firewall scans the stack trace text for
/// identifiers, and raw native data (dashed image UUIDs, long decimal
/// addresses) would trip it. The marker and the block require each other.
const String nativeStackTraceMarker = '<native>';

/// What ended the process, or — for [hang] and [diskWriteException] — what
/// the operating system diagnosed while it lived on.
enum NativeCrashKind {
  /// A signal, a Mach exception, or an uncaught Objective-C, Swift or JVM
  /// exception.
  crash,

  /// Killed by the system watchdog (iOS termination code `0x8badf00d`).
  watchdogKill,

  /// Killed for not responding (an Android ANR).
  anr,

  /// Killed for memory while in the foreground.
  memoryKill,

  /// The main thread hung; the app lived on.
  hang,

  /// The app wrote more to disk than the system allows; it lived on.
  diskWriteException;

  /// Whether the process died of it. [hang] and [diskWriteException] are
  /// diagnostics of a process that kept running.
  bool get isFatal => this != hang && this != diskWriteException;
}

/// Where the operating system reported a native crash from.
enum NativeReportSource {
  /// iOS MetricKit diagnostics, delivered on a later launch.
  metricKit,

  /// Android `ApplicationExitInfo`, read on a later launch.
  exitInfo,

  /// The SDK's chaining JVM uncaught-exception handler on Android.
  jvm,
}

/// The CPU architecture of a [NativeImage].
enum NativeArch {
  arm64('arm64'),
  arm64e('arm64e'),
  armv7('armv7'),
  // The wire name, which the enum mirrors.
  // ignore: constant_identifier_names
  x86_64('x86_64'),
  x86('x86');

  const NativeArch(this.wireName);

  /// The value on the wire.
  final String wireName;
}

/// One binary image a [NativeFrame] points into.
///
/// Only images a frame references are listed, and only by file name: full
/// paths carry install-directory ids and never leave the device.
final class NativeImage {
  const NativeImage({
    required this.name,
    required this.inApp,
    this.debugId,
    this.arch,
  });

  /// The image's file name (`Flutter`, `libapp.so`), never a path.
  final String name;

  /// Whether the image ships with the app (engine, Dart AOT code, plugins)
  /// rather than with the operating system.
  final bool inApp;

  /// The image's build identity in lowercase hex without dashes: the Mach-O
  /// UUID or the ELF build id. What symbolication looks debug files up by.
  final String? debugId;
  final NativeArch? arch;

  static const maxNameLength = 100;

  /// A file name of 1 to [maxNameLength] characters, never a path.
  static final namePattern = RegExp('^[A-Za-z0-9_.+-]{1,$maxNameLength}\$');

  /// 32 to 40 lowercase hex digits without dashes.
  static final debugIdPattern = RegExp(r'^[0-9a-f]{32,40}$');

  Map<String, Object?> toJson() => {
    'name': name,
    'inApp': inApp,
    if (debugId != null) 'debugId': debugId,
    if (arch != null) 'arch': arch!.wireName,
  };

  void _check(String path) {
    if (!namePattern.hasMatch(name)) {
      throw ProtocolException(
        ProtocolViolation.invalidValue,
        '$path.name',
        'Expected an image file name',
      );
    }
    if (debugId case final debugId? when !debugIdPattern.hasMatch(debugId)) {
      throw ProtocolException(
        ProtocolViolation.invalidValue,
        '$path.debugId',
        'Expected 32 to 40 lowercase hex digits without dashes',
      );
    }
  }
}

/// One frame of the crashed (or hang-attributed, or ANR main) thread.
///
/// Four shapes, and no absolute address in any of them: an offset into an
/// image ([NativeFrame.inImage], optionally with the symbol the device
/// knew), a JVM or system symbol with an optional line ([NativeFrame.symbol]),
/// or a frame in no known image — JIT code — ([NativeFrame.unknown]).
final class NativeFrame {
  const NativeFrame.inImage(int this.image, int this.offset, {this.symbol})
    : line = null;

  const NativeFrame.symbol(String this.symbol, {this.line})
    : image = null,
      offset = null;

  const NativeFrame.unknown()
    : image = null,
      offset = null,
      symbol = null,
      line = null;

  /// Index into [NativeCrashInfo.images].
  final int? image;

  /// Offset of the instruction from the image's load address.
  final int? offset;
  final String? symbol;
  final int? line;

  /// Largest [offset]: 2^48, beyond any image's text segment. A literal, not
  /// a shift, because shifts are 32-bit on the web.
  static const maxOffset = 281474976710656;
  static const maxLine = 1000000;
  static const maxSymbolLength = 200;

  /// A symbol of 1 to [maxSymbolLength] characters: no whitespace, no
  /// parentheses, no `@`.
  static final symbolPattern = RegExp(
    '^[A-Za-z0-9_\$.<>:~]{1,$maxSymbolLength}\$',
  );

  Map<String, Object?> toJson() => {
    if (image != null) 'image': image,
    if (offset != null) 'offset': offset,
    if (symbol != null) 'symbol': symbol,
    if (line != null) 'line': line,
  };

  void _check(String path, {required int imageCount}) {
    if (symbol case final symbol? when !symbolPattern.hasMatch(symbol)) {
      throw ProtocolException(
        ProtocolViolation.invalidValue,
        '$path.symbol',
        'Invalid symbol',
      );
    }
    if (line case final line? when line < 1 || line > maxLine) {
      throw ProtocolException(
        ProtocolViolation.invalidValue,
        '$path.line',
        'Expected a line number from 1 to $maxLine',
      );
    }
    if (image case final image? when image < 0 || image >= imageCount) {
      throw ProtocolException(
        ProtocolViolation.invalidValue,
        '$path.image',
        'Image index out of range',
      );
    }
    if (offset case final offset? when offset < 0 || offset > maxOffset) {
      throw ProtocolException(
        ProtocolViolation.invalidValue,
        '$path.offset',
        'Expected an offset from 0 to 2^48',
      );
    }
  }
}

/// The native part of a crash event: a fully enumerated description of a
/// crash the operating system reported, with no free-form bag anywhere.
final class NativeCrashInfo {
  const NativeCrashInfo({
    required this.kind,
    required this.source,
    this.machException,
    this.signal,
    this.code,
    this.terminationCode,
    this.durationMs,
    this.bytesWritten,
    this.images = const [],
    this.frames = const [],
  });

  final NativeCrashKind kind;
  final NativeReportSource source;

  /// The Mach exception name (`EXC_BAD_ACCESS`); iOS only.
  final String? machException;

  /// The signal name (`SIGBUS`).
  final String? signal;

  /// The exception or signal code in lowercase hex (`0x32`).
  final String? code;

  /// The termination reason's code in lowercase hex (`0x8badf00d`).
  final String? terminationCode;

  /// How long the main thread hung; [NativeCrashKind.hang] only.
  final int? durationMs;

  /// How many bytes the app wrote; [NativeCrashKind.diskWriteException] only.
  final int? bytesWritten;

  /// The images [frames] point into, each referenced by at least one frame.
  final List<NativeImage> images;

  /// The attributed thread's frames, top first.
  final List<NativeFrame> frames;

  static const maxImages = 32;
  static const maxFrames = 64;
  static const maxHangDurationMs = 600000;

  /// 2^53, the largest integer every JSON reader represents exactly.
  static const maxBytesWritten = 9007199254740992;

  static final machExceptionPattern = RegExp(r'^EXC_[A-Z_]{1,30}$');
  static final signalPattern = RegExp(r'^SIG[A-Z0-9]{2,8}$');

  /// A [code] or [terminationCode]: lowercase hex with `0x`.
  static final hexCodePattern = RegExp(r'^0x[0-9a-f]{1,16}$');

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'source': source.name,
    if (machException != null) 'machException': machException,
    if (signal != null) 'signal': signal,
    if (code != null) 'code': code,
    if (terminationCode != null) 'terminationCode': terminationCode,
    if (durationMs != null) 'durationMs': durationMs,
    if (bytesWritten != null) 'bytesWritten': bytesWritten,
    if (images.isNotEmpty)
      'images': images.map((image) => image.toJson()).toList(),
    if (frames.isNotEmpty)
      'frames': frames.map((frame) => frame.toJson()).toList(),
  };

  /// Refuses this block as an event's `native` refuses it, with a
  /// [ProtocolException] at `$.native`: the names and codes by their
  /// patterns, [durationMs] for a [NativeCrashKind.hang] and [bytesWritten]
  /// for a [NativeCrashKind.diskWriteException] only and within their
  /// bounds, at most [maxImages] images and [maxFrames] frames, each by its
  /// rules, and every image referenced by a frame.
  void check() {
    const path = r'$.native';
    _checkPattern(machException, 'machException', machExceptionPattern);
    _checkPattern(signal, 'signal', signalPattern);
    _checkPattern(code, 'code', hexCodePattern);
    _checkPattern(terminationCode, 'terminationCode', hexCodePattern);
    _checkBounded(
      durationMs,
      'durationMs',
      max: maxHangDurationMs,
      allowedFor: NativeCrashKind.hang,
    );
    _checkBounded(
      bytesWritten,
      'bytesWritten',
      max: maxBytesWritten,
      allowedFor: NativeCrashKind.diskWriteException,
    );
    if (images.length > maxImages) {
      throw const ProtocolException(
        ProtocolViolation.oversized,
        '$path.images',
        'Maximum is $maxImages',
      );
    }
    for (final (index, image) in images.indexed) {
      image._check('$path.images[$index]');
    }
    if (frames.length > maxFrames) {
      throw const ProtocolException(
        ProtocolViolation.oversized,
        '$path.frames',
        'Maximum is $maxFrames',
      );
    }
    for (final (index, frame) in frames.indexed) {
      frame._check('$path.frames[$index]', imageCount: images.length);
    }
    final referenced = {for (final frame in frames) ?frame.image};
    for (var index = 0; index < images.length; index++) {
      if (!referenced.contains(index)) {
        throw ProtocolException(
          ProtocolViolation.invalidValue,
          '$path.images[$index]',
          'Every image must be referenced by a frame',
        );
      }
    }
  }

  static void _checkPattern(String? value, String key, RegExp pattern) {
    if (value != null && !pattern.hasMatch(value)) {
      throw ProtocolException(
        ProtocolViolation.invalidValue,
        '\$.native.$key',
        'Invalid value',
      );
    }
  }

  void _checkBounded(
    int? value,
    String key, {
    required int max,
    required NativeCrashKind allowedFor,
  }) {
    if (value == null) return;
    if (kind != allowedFor) {
      throw ProtocolException(
        ProtocolViolation.invalidValue,
        '\$.native.$key',
        'Only allowed for kind ${allowedFor.name}',
      );
    }
    if (value < 0 || value > max) {
      throw ProtocolException(
        ProtocolViolation.invalidValue,
        '\$.native.$key',
        'Expected an integer from 0 to $max',
      );
    }
  }
}
