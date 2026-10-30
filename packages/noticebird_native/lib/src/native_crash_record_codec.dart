import 'package:noticebird/noticebird.dart';

/// The record version this package reads (the native contract).
const nativeCrashRecordVersion = 1;

const _keys = {
  'recordVersion',
  'recordId',
  'kind',
  'source',
  'occurredAtMs',
  'machException',
  'signal',
  'code',
  'terminationCode',
  'exceptionClass',
  'exceptionMessage',
  'durationMs',
  'bytesWritten',
  'images',
  'frames',
  'runId',
  'pid',
  'appVersion',
  'appBuild',
  'foreground',
};

final _recordIdPattern = RegExp(r'^[0-9a-f]{64}$');
final _runIdPattern = RegExp(r'^[0-9a-f]{32}$');
final _exceptionClassPattern = RegExp(r'^[A-Za-z0-9_$.]{1,160}$');

/// Decodes one record of a `claim` reply, or returns null when it is not a
/// version-1 record exactly as the native contract describes: an unknown key,
/// a wrong type or a value outside its pattern rejects the whole record.
/// The enumerated fields, images and frames are checked by the protocol's
/// own [NativeCrashInfo.check], so a record that decodes here builds a valid
/// event.
NativeCrashRecord? decodeNativeCrashRecord(Object? value) {
  try {
    if (value is! Map) return null;
    final json = Map<String, Object?>.from(value);
    // Unknown keys and explicit nulls both mean a writer that does not
    // follow the contract: an unknown value is omitted, never null.
    if (json.entries.any(
      (entry) => !_keys.contains(entry.key) || entry.value == null,
    )) {
      return null;
    }
    if (json['recordVersion'] != nativeCrashRecordVersion) return null;
    final recordId = json['recordId'];
    if (recordId is! String || !_recordIdPattern.hasMatch(recordId)) {
      return null;
    }
    final kind = _enum(NativeCrashKind.values, json['kind']);
    final source = _enum(NativeReportSource.values, json['source']);
    final occurredAtMs = json['occurredAtMs'];
    if (kind == null || source == null || occurredAtMs is! int) return null;

    final rawImages = json['images'] ?? const <Object?>[];
    final rawFrames = json['frames'] ?? const <Object?>[];
    if (rawImages is! List || rawFrames is! List) return null;
    if (rawImages.length > NativeCrashInfo.maxImages ||
        rawFrames.length > NativeCrashInfo.maxFrames) {
      return null;
    }
    final images = rawImages.map(_image).toList();
    final frames = rawFrames.map(_frame).toList();

    final exceptionClass = _optionalString(json, 'exceptionClass');
    if (exceptionClass != null &&
        !_exceptionClassPattern.hasMatch(exceptionClass)) {
      return null;
    }
    final exceptionMessage = _optionalString(json, 'exceptionMessage');
    if (exceptionMessage != null && exceptionMessage.length > 1024) {
      return null;
    }
    final runId = _optionalString(json, 'runId');
    if (runId != null && !_runIdPattern.hasMatch(runId)) return null;
    final foreground = json['foreground'];
    if (foreground != null && foreground is! bool) return null;

    final record = NativeCrashRecord(
      recordId: recordId,
      kind: kind,
      source: source,
      occurredAt: DateTime.fromMillisecondsSinceEpoch(
        occurredAtMs,
        isUtc: true,
      ),
      machException: _optionalString(json, 'machException'),
      signal: _optionalString(json, 'signal'),
      code: _optionalString(json, 'code'),
      terminationCode: _optionalString(json, 'terminationCode'),
      exceptionClass: exceptionClass,
      exceptionMessage: exceptionMessage,
      durationMs: _optionalInt(json, 'durationMs'),
      bytesWritten: _optionalInt(json, 'bytesWritten'),
      images: List.unmodifiable(images),
      frames: List.unmodifiable(frames),
      runId: runId,
      pid: _optionalInt(json, 'pid'),
      appVersion: _optionalString(json, 'appVersion'),
      appBuild: _optionalString(json, 'appBuild'),
      foreground: foreground as bool?,
    );
    // The enumerated fields follow the protocol's own rules: check them
    // where they will be checked anyway, but now, so a bad record is
    // rejected here instead of failing as an event.
    NativeCrashInfo(
      kind: record.kind,
      source: record.source,
      machException: record.machException,
      signal: record.signal,
      code: record.code,
      terminationCode: record.terminationCode,
      durationMs: record.durationMs,
      bytesWritten: record.bytesWritten,
      images: record.images,
      frames: record.frames,
    ).check();
    return record;
  } catch (_) {
    return null;
  }
}

/// The record id of [value] when it has a well-formed one, so an undecodable
/// record can still be settled away.
String? nativeCrashRecordIdOf(Object? value) {
  if (value is! Map) return null;
  final recordId = value['recordId'];
  return recordId is String && _recordIdPattern.hasMatch(recordId)
      ? recordId
      : null;
}

const _imageKeys = {'name', 'inApp', 'debugId', 'arch'};
const _frameKeys = {'image', 'offset', 'symbol', 'line'};

/// One image of a record: a file name, whether it is the app's, and an
/// optional debug id and architecture.
NativeImage _image(Object? value) {
  if (value case {
    'name': final String name,
    'inApp': final bool inApp,
  } when value.keys.every(_imageKeys.contains)) {
    final arch = value['arch'];
    return NativeImage(
      name: name,
      inApp: inApp,
      debugId: value['debugId'] as String?,
      arch: arch == null
          ? null
          : NativeArch.values.firstWhere(
              (candidate) => candidate.wireName == arch,
            ),
    );
  }
  throw const FormatException('Invalid image');
}

/// One frame of a record, in one of the protocol's four shapes: an offset
/// into an image with an optional symbol, a symbol with an optional line, or
/// nothing known.
NativeFrame _frame(Object? value) {
  if (value is! Map || !value.keys.every(_frameKeys.contains)) {
    throw const FormatException('Invalid frame');
  }
  return switch ((
    value['image'] as int?,
    value['offset'] as int?,
    value['symbol'] as String?,
    value['line'] as int?,
  )) {
    (final int image, final int offset, final symbol, null) =>
      NativeFrame.inImage(image, offset, symbol: symbol),
    (null, null, final String symbol, final line) => NativeFrame.symbol(
      symbol,
      line: line,
    ),
    (null, null, null, null) => const NativeFrame.unknown(),
    _ => throw const FormatException('Invalid frame'),
  };
}

T? _enum<T extends Enum>(List<T> values, Object? name) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || value.isEmpty) {
    throw FormatException('Invalid $key');
  }
  return value;
}

int? _optionalInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! int) throw FormatException('Invalid $key');
  return value;
}
