import 'dart:convert';

import 'package:noticebird_protocol/noticebird_protocol.dart';
import 'package:crypto/crypto.dart';

import 'noticebird_config.dart';
import 'native_crash_collector.dart';
import 'text_sanitizer.dart';

/// The protocol event for [record], attributed to the run it happened in
/// among [runs], or null when the report matches no known build — an event
/// under the wrong release breaks symbolication and regression detection,
/// which is worse than a missing one — or belongs to a run that is not
/// [NativeRecordedRun.reportable].
///
/// The event carries the crashed run's app, platform, session, route and
/// trail, never the current run's, and never identity or `extra`. Under
/// [CrashPrivacyProfile.regulatedStrict] it carries no trail and the message
/// is the exception type. Not checked here: the client checks it once, when
/// it writes the event, and drops one the protocol refuses.
CrashEvent? buildNativeCrashEvent(
  NativeCrashRecord record,
  List<NativeRecordedRun> runs, {
  required CrashPrivacyProfile privacyProfile,
}) {
  final context = _attribute(record, runs);
  if (context == null) return null;
  final strict = privacyProfile == CrashPrivacyProfile.regulatedStrict;
  final type = nativeExceptionType(record);
  final message = strict ? type : _message(record, type);
  final engine = context.engine;
  final routeTemplate = context.withTrail ? engine.routeTemplate : null;
  final foreground = record.foreground ?? engine.foreground;
  final kind = record.kind;
  return CrashEvent(
    eventId: nativeCrashEventId(record.recordId),
    occurredAt: context.occurredAt,
    severity: kind.isFatal ? CrashSeverity.fatal : CrashSeverity.warning,
    handled: !kind.isFatal,
    exception: CrashException(
      type: type,
      sanitizedMessage: message.isEmpty ? '<no-message>' : message,
      stackTrace: nativeStackTraceMarker,
    ),
    app: engine.app,
    platform: engine.platform,
    routeTemplate: routeTemplate == null
        ? null
        : sanitizeRouteTemplate(routeTemplate),
    sessionId: context.sessionId,
    tags: {if (foreground != null) AllowedTag.foreground: foreground},
    breadcrumbs: strict || !context.withTrail
        ? const []
        : List.unmodifiable(
            engine.breadcrumbs
                .take(CrashEvent.maxBreadcrumbs)
                .map(sanitizeBreadcrumb)
                .nonNulls,
          ),
    nativeCrash: NativeCrashInfo(
      kind: kind,
      source: record.source,
      machException: record.machException,
      signal: record.signal,
      code: record.code,
      terminationCode: record.terminationCode,
      durationMs: kind == NativeCrashKind.hang ? record.durationMs : null,
      bytesWritten: kind == NativeCrashKind.diskWriteException
          ? record.bytesWritten
          : null,
      images: List.unmodifiable(record.images.map(_platformSafeImage)),
      frames: List.unmodifiable(record.frames.map(_platformSafeFrame)),
    ),
  );
}

/// A UUID-shaped (version 8) event id derived from [recordId], so every
/// resend of one report is the same event and the platform answers it as a
/// replay.
String nativeCrashEventId(String recordId) {
  final bytes = sha256
      .convert(utf8.encode('noticebird.native:$recordId'))
      .bytes
      .sublist(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x80;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// The fixed, obfuscation-proof exception type of a native report.
String nativeExceptionType(NativeCrashRecord record) {
  final exceptionClass = record.exceptionClass?.replaceAll(
    RegExp(r'[^A-Za-z0-9_$.]'),
    '',
  );
  if (exceptionClass != null && exceptionClass.isNotEmpty) {
    return truncateCrashText(exceptionClass, CrashException.maxTypeLength);
  }
  return switch (record.kind) {
    NativeCrashKind.crash => switch ((record.machException, record.signal)) {
      (final mach?, final signal?) => '$mach/$signal',
      (final mach?, null) => mach,
      (null, final signal?) => signal,
      (null, null) => 'NativeCrash',
    },
    NativeCrashKind.watchdogKill => 'WatchdogTermination',
    NativeCrashKind.anr => 'ApplicationNotResponding',
    NativeCrashKind.memoryKill => 'LowMemoryKill',
    NativeCrashKind.hang => 'Hang',
    NativeCrashKind.diskWriteException => 'DiskWriteException',
  };
}

/// The message: an exception's own message through the sanitizer, otherwise
/// one composed from enumerated fields only, followed by a native abort
/// message when there is one. Numbers stay short, because a run of ten or
/// more digits reads as a phone number.
String _message(NativeCrashRecord record, String type) {
  final exceptionMessage = record.exceptionMessage?.trim();
  final detail = exceptionMessage == null || exceptionMessage.isEmpty
      ? null
      : exceptionMessage;
  if (record.exceptionClass != null && detail != null) {
    return sanitizeCrashText(
      detail,
      maxLength: CrashException.maxMessageLength,
    );
  }
  final code = record.code;
  final shortCode = code != null && code.length <= 10 ? ' code $code' : '';
  final terminationCode = record.terminationCode;
  final shortTermination =
      terminationCode != null && terminationCode.length <= 10
      ? ' ($terminationCode)'
      : '';
  final composed = switch (record.kind) {
    NativeCrashKind.crash => switch ((record.machException, record.signal)) {
      (final mach?, final signal?) => '$mach ($signal)$shortCode',
      (final mach?, null) => '$mach$shortCode',
      (null, final signal?) => '$signal$shortCode',
      (null, null) =>
        record.exceptionClass != null ? type : 'Native crash$shortCode',
    },
    NativeCrashKind.watchdogKill => 'Watchdog termination$shortTermination',
    NativeCrashKind.anr => 'Application not responding',
    NativeCrashKind.memoryKill => 'Killed for memory in the foreground',
    NativeCrashKind.hang => switch (record.durationMs) {
      final duration? =>
        'Main thread hung for ${(duration / 1000).toStringAsFixed(1)} s',
      null => 'Main thread hung',
    },
    NativeCrashKind.diskWriteException => switch (record.bytesWritten) {
      final bytes? when bytes >= 1000000000 =>
        'Wrote ${(bytes / 1000000000).toStringAsFixed(1)} GB to disk',
      final bytes? => 'Wrote ${(bytes / 1000000).round()} MB to disk',
      null => 'Excessive disk writes',
    },
  };
  // A native abort message (Android) follows the composed part.
  return detail == null
      ? composed
      : sanitizeCrashText(
          '$composed: $detail',
          maxLength: CrashException.maxMessageLength,
        );
}

/// [frame] with a symbol that reads as no personal data, spelled so that it
/// keeps every word ([respellSymbol]).
///
/// Compilers first suffix local symbols with hashes (`.__uniq.1124354180…`,
/// `.llvm.1592601173…`): digit runs that read as phone numbers, which change
/// with every build and would only split groups, so they go.
NativeFrame _platformSafeFrame(NativeFrame frame) {
  final symbol = frame.symbol;
  if (symbol == null) return frame;
  final safe = respellSymbol(symbol.replaceAll(_compilerHashSuffix, ''));
  if (safe == symbol) return frame;
  final image = frame.image;
  return image == null
      ? NativeFrame.symbol(safe, line: frame.line)
      : NativeFrame.inImage(image, frame.offset!, symbol: safe);
}

/// [image] with a name that reads as no personal data: a run of ten digits
/// is cut to nine, as in a symbol, and whatever the name still holds
/// (an IPv4 address, a UUID, a phone number) is redacted to `redacted`, the
/// name's characters allowing no `[REDACTED]`.
NativeImage _platformSafeImage(NativeImage image) {
  final name = sanitizeCrashText(
    shortenDigitRuns(image.name),
    maxLength: NativeImage.maxNameLength,
    replacement: 'redacted',
  );
  return name == image.name
      ? image
      : NativeImage(
          name: name,
          inApp: image.inApp,
          debugId: image.debugId,
          arch: image.arch,
        );
}

final _compilerHashSuffix = RegExp(r'\.(?:__uniq|llvm)\.\d+');

/// Which run a report belongs to and what its event carries of that run.
final class _Context {
  const _Context({
    required this.engine,
    required this.sessionId,
    required this.occurredAt,
    required this.withTrail,
  });

  final NativeEngineRecord engine;
  final String sessionId;
  final DateTime occurredAt;

  /// False when [engine] only lends its metadata to a run in which no Dart
  /// ran: its route and trail belong to another run.
  final bool withTrail;
}

/// Matches [record] to its run, strongest evidence first: the run id the OS
/// named; the process id of a run that started before the crash; the time
/// window alone; and finally the most recent run of the same version and
/// build (a crash before Dart started, or a run the ledger no longer holds).
_Context? _attribute(NativeCrashRecord record, List<NativeRecordedRun> runs) {
  final ordered = [...runs]..sort((a, b) => a.startedAt.compareTo(b.startedAt));
  NativeRecordedRun? nextOf(NativeRecordedRun run) {
    final index = ordered.indexOf(run);
    return index + 1 < ordered.length ? ordered[index + 1] : null;
  }

  bool sameBuild(NativeRecordedRun run) =>
      (record.appVersion == null ||
          run.appVersion == null ||
          record.appVersion == run.appVersion) &&
      (record.appBuild == null ||
          run.appBuild == null ||
          record.appBuild == run.appBuild);

  bool inWindow(NativeRecordedRun run) {
    if (run.startedAt.isAfter(record.occurredAt)) return false;
    final next = nextOf(run);
    return next == null || record.occurredAt.isBefore(next.startedAt);
  }

  final earlier = ordered.where((run) => !run.isCurrent && sameBuild(run));
  final runId = record.runId;
  final pid = record.pid;
  NativeRecordedRun? crashed = runId == null
      ? null
      : ordered.where((run) => run.runId == runId).firstOrNull;
  // Process ids are reused, but hardly ever within the few runs the ledger
  // keeps; the window is not required here, so a timestamp slightly past the
  // next start still finds its process.
  crashed ??= pid == null
      ? null
      : earlier
            .where(
              (run) =>
                  run.pid == pid && !run.startedAt.isAfter(record.occurredAt),
            )
            .lastOrNull;
  crashed ??= earlier.where(inWindow).lastOrNull;
  if (crashed == null && record.appVersion != null && record.appBuild != null) {
    crashed = earlier
        .where(
          (run) =>
              run.appVersion == record.appVersion &&
              run.appBuild == record.appBuild,
        )
        .lastOrNull;
  }

  if (crashed != null && !crashed.reportable) return null;

  final occurredAt = crashed == null
      ? record.occurredAt.toUtc()
      : _clamp(
          record.occurredAt,
          crashed.startedAt,
          nextOf(crashed)?.startedAt,
        );

  final engine = crashed == null ? null : _representative(crashed.engines);
  if (crashed != null && engine != null) {
    return _Context(
      engine: engine,
      sessionId: engine.sessionId,
      occurredAt: occurredAt,
      withTrail: true,
    );
  }

  // No Dart ran in the crashed run: borrow the app and platform metadata of
  // the most recent run of the same build that recorded an engine.
  final version = crashed?.appVersion ?? record.appVersion;
  final build = crashed?.appBuild ?? record.appBuild;
  if (version == null || build == null) return null;
  final donor = ordered
      .where(
        (run) =>
            run.engines.isNotEmpty &&
            run.appVersion == version &&
            run.appBuild == build,
      )
      .lastOrNull;
  if (donor == null) return null;
  return _Context(
    engine: _representative(donor.engines)!,
    sessionId: _nativeSessionId(crashed?.runId ?? record.recordId),
    occurredAt: occurredAt,
    withTrail: false,
  );
}

/// The engine that speaks for a run: one that delivered (the UI engine)
/// wins over a headless one.
NativeEngineRecord? _representative(List<NativeEngineRecord> engines) =>
    engines.where((engine) => engine.delivers).firstOrNull ??
    engines.firstOrNull;

DateTime _clamp(DateTime value, DateTime lower, DateTime? upper) {
  final utc = value.toUtc();
  if (utc.isBefore(lower)) return lower.toUtc();
  if (upper != null && utc.isAfter(upper)) return upper.toUtc();
  return utc;
}

/// A protocol-valid session id for a run in which no Dart ran.
String _nativeSessionId(String source) {
  final digest = sha256.convert(utf8.encode(source)).toString();
  return 'native_${digest.substring(0, 32)}';
}
