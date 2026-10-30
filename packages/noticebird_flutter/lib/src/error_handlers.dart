import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:noticebird/noticebird.dart';

/// Installs the framework's two global error handlers, each reporting to
/// [client] and chained to the one it replaces: `FlutterError.onError` (an
/// error the framework caught, component its library), and
/// `PlatformDispatcher.onError` (an error nothing caught, fatal). Without a
/// previous `PlatformDispatcher` handler the error is printed to the console
/// and handled, so it cannot take down the app. Returns what puts the
/// previous handlers back.
VoidCallback installErrorHandlers(NoticebirdClient client) {
  final previousFlutterHandler = FlutterError.onError;
  final dispatcher = PlatformDispatcher.instance;
  final previousPlatformHandler = dispatcher.onError;

  FlutterError.onError = (details) {
    unawaited(
      client.captureException(
        details.exception,
        details.stack ?? StackTrace.empty,
        tags: {AllowedTag.component: details.library ?? 'FlutterError'},
      ),
    );
    previousFlutterHandler?.call(details);
  };

  dispatcher.onError = (error, stack) {
    unawaited(
      client.captureException(
        error,
        stack,
        severity: CrashSeverity.fatal,
        tags: const {AllowedTag.component: 'PlatformDispatcher'},
      ),
    );
    if (previousPlatformHandler != null) {
      return previousPlatformHandler(error, stack);
    }
    _present(error, stack, 'uncaught platform error');
    return true;
  };

  return () {
    FlutterError.onError = previousFlutterHandler;
    dispatcher.onError = previousPlatformHandler;
  };
}

/// Reports an error a zone's handler got, as fatal, to [client], and prints
/// it to the console.
void reportZoneError(NoticebirdClient? client, Object error, StackTrace stack) {
  if (client != null) {
    unawaited(
      client.captureException(
        error,
        stack,
        severity: CrashSeverity.fatal,
        tags: const {AllowedTag.component: 'AppZone'},
      ),
    );
  }
  _present(error, stack, 'while running the app zone');
}

/// Prints [error] as the framework prints an error it caught. Not
/// [FlutterError.reportError], which runs `FlutterError.onError` and would
/// report it a second time.
void _present(Object error, StackTrace stack, String description) {
  FlutterError.presentError(
    FlutterErrorDetails(
      exception: error,
      stack: stack,
      context: ErrorDescription(description),
    ),
  );
}
