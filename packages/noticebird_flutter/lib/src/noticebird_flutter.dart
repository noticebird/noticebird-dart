import 'dart:async';
import 'dart:io' show Directory;

import 'package:bloc/bloc.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:noticebird/feedback.dart';
import 'package:noticebird/noticebird.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'error_handlers.dart' as handlers;
import 'noticebird_bloc_observer.dart';

/// Noticebird in a Flutter app, started once with [start]: the client,
/// attached to the `Noticebird` facade so the app reports and sends
/// feedback from anywhere, and everything around it that each app would
/// otherwise wire itself.
///
/// ```dart
/// Future<void> main() async {
///   await NoticebirdFlutter.start(
///     publishableKey: const String.fromEnvironment('NOTICEBIRD_KEY'),
///     appName: 'my_app',
///   );
///   runApp(const MyApp());
/// }
///
/// // In the feedback sheet: the moment when it opens, the report when it is
/// // sent.
/// final moment = Noticebird.feedbackMoment();
/// await Noticebird.captureFeedback(
///   kind: FeedbackKind.bug,
///   message: text,
///   moment: moment,
///   screenshot: pngBytes,
/// );
/// ```
final class NoticebirdFlutter {
  NoticebirdFlutter._({
    required this.client,
    required this.blocObserver,
    required void Function() stop,
  }) : _stop = stop;

  static NoticebirdFlutter? _running;

  /// How long [start] waits for each platform read — the installed
  /// version, the support directory — before it goes on without it.
  static const platformReadTimeout = Duration(seconds: 2);

  /// The client, attached to the `Noticebird` facade.
  final NoticebirdClient client;

  /// The bloc observer [start] made: `Bloc.observer` unless `observeBlocs`
  /// was off. A host that sets an observer of its own after [start] keeps
  /// this one beside it: `MultiBlocObserver(observers: [blocObserver,
  /// mine])`.
  final NoticebirdBlocObserver blocObserver;

  final void Function() _stop;

  /// Starts Noticebird for this app, once: a second call while one runs
  /// answers the running one.
  ///
  /// It makes the client and attaches it to the `Noticebird` facade, and:
  ///
  /// - sends crash events and feedback to the API of [publishableKey] (a
  ///   publishable key, `<prefix>_pk_…`), at [endpoint] (its `/v1/envelope`
  ///   URL; by default the hosted API), over [httpClient] when the host
  ///   has its own. Crash events go only while [uploadCrashes]; feedback
  ///   goes either way, since a user asked for it. A [publishableKey] that
  ///   is empty or malformed, as from a missing `--dart-define`, starts a
  ///   client that uploads nothing and sends no feedback;
  /// - names the app [appName], with the version and build the platform
  ///   reports (`unknown` when it does not answer);
  /// - installs the global error handlers ([installErrorHandlers]),
  ///   chained to the ones they replace, and sets `Bloc.observer` to
  ///   [blocObserver] beside the observer it found ([observeBlocs]); a
  ///   host with a zone of its own passes [reportZoneError] as its handler;
  /// - keeps what does not get through in the app's support directory
  ///   (`noticebird/crashes` and `noticebird/feedback`), unless the host
  ///   passes [crashStore] or [feedbackStore]. None on the web, and none
  ///   under `regulatedStrict`, whose stores must be encrypted: pass your
  ///   own there;
  /// - delivers the native crash reports of earlier runs of
  ///   [nativeCrashes] (`NativeCrashCapture()` of `noticebird_native`),
  ///   and what earlier runs left queued, now, each time the app comes
  ///   back to the foreground, and when the connection returns;
  /// - fills each feedback report's `blocs` diagnostics group with the live
  ///   blocs per type, and its locale with the platform's.
  ///
  /// [privacyProfile], [pii], [shouldCapture] and [breadcrumbBuffer] are
  /// the client's ([NoticebirdConfig]); [reporterAssertion],
  /// [requireVerified] and [onFeedbackSettled] are its feedback's
  /// ([FeedbackConfig]).
  ///
  /// [background] starts the client of a headless background engine: it
  /// reports, but delivers nothing of earlier runs, flushes nothing by
  /// itself and keeps no store (two engines must not share one), so an
  /// event it cannot send is kept in memory only.
  ///
  /// It never fails on the platform: a read that throws or does not answer
  /// within [platformReadTimeout] is done without. It throws an
  /// [ArgumentError] only for arguments no start can work with, as
  /// [NoticebirdConfig] does: an [appName] the protocol refuses, a
  /// [breadcrumbBuffer] out of range, an unencrypted store passed under
  /// `regulatedStrict`.
  static Future<NoticebirdFlutter> start({
    required String publishableKey,
    required String appName,
    Uri? endpoint,
    http.Client? httpClient,
    bool uploadCrashes = true,
    CrashPrivacyProfile privacyProfile = CrashPrivacyProfile.privacyDefault,
    CrashPiiConfig pii = const CrashPiiConfig(),
    bool Function(Object error)? shouldCapture,
    int breadcrumbBuffer = FeedbackReport.maxTrailItems,
    NativeCrashCollector? nativeCrashes,
    Future<String?> Function()? reporterAssertion,
    bool requireVerified = false,
    void Function(FeedbackSettled settled)? onFeedbackSettled,
    CrashOfflineStore? crashStore,
    FeedbackOfflineStore? feedbackStore,
    bool installErrorHandlers = true,
    bool observeBlocs = true,
    bool background = false,
  }) async {
    final running = _running;
    if (running != null) return running;
    final binding = WidgetsFlutterBinding.ensureInitialized();

    CrashHttpTransport? ingest;
    FeedbackHttpTransport? feedbackTransport;
    try {
      ingest = CrashHttpTransport(
        endpoint: endpoint,
        publishableKey: publishableKey.trim(),
        httpClient: httpClient,
      );
      feedbackTransport = FeedbackHttpTransport.of(ingest);
    } on ArgumentError catch (error) {
      _debugNote('no uploads and no feedback: $error');
    }

    final strict = privacyProfile == CrashPrivacyProfile.regulatedStrict;
    final keepsStores = !kIsWeb && !background && !strict;
    final (packageInfo, supportDirectory) = await (
      _read(PackageInfo.fromPlatform),
      keepsStores
          ? _read(getApplicationSupportDirectory)
          : Future<Directory?>.value(),
    ).wait;
    Directory? storeIn(String name) => supportDirectory == null
        ? null
        : Directory('${supportDirectory.path}/noticebird/$name');
    final defaultCrashStore = storeIn('crashes');
    final defaultFeedbackStore = storeIn('feedback');

    final blocObserver = NoticebirdBlocObserver();
    final config = NoticebirdConfig(
      privacyProfile: privacyProfile,
      app: _app(appName, packageInfo),
      pii: pii,
      shouldCapture: shouldCapture,
      breadcrumbBuffer: breadcrumbBuffer,
      nativeCrashes: nativeCrashes,
      offlineStore:
          crashStore ??
          (defaultCrashStore == null
              ? null
              : FileCrashOfflineStore(defaultCrashStore)),
      locale: () => binding.platformDispatcher.locale.toLanguageTag(),
      feedback: feedbackTransport == null
          ? null
          : FeedbackConfig(
              transport: feedbackTransport,
              reporterAssertion: reporterAssertion,
              requireVerified: requireVerified,
              offlineStore:
                  feedbackStore ??
                  (defaultFeedbackStore == null
                      ? null
                      : FileFeedbackOfflineStore(defaultFeedbackStore)),
              onSettled: onFeedbackSettled,
              contextDiagnostics: () => {
                'blocs': blocObserver.liveBlocCounts(),
              },
            ),
    );
    final client = NoticebirdClient(
      config: config,
      transport: uploadCrashes && ingest != null
          ? ingest
          : const DiscardingCrashTransport(),
    );
    Noticebird.attach(client);

    final restoreHandlers = installErrorHandlers
        ? handlers.installErrorHandlers(client)
        : null;
    final previousObserver = Bloc.observer;
    final observer = MultiBlocObserver(
      observers: [blocObserver, previousObserver],
    );
    if (observeBlocs) Bloc.observer = observer;

    AppLifecycleListener? lifecycle;
    StreamSubscription<List<ConnectivityResult>>? connectivity;
    if (!background) {
      unawaited(client.reportNativeCrashes());
      unawaited(client.flush());
      lifecycle = AppLifecycleListener(
        binding: binding,
        onResume: () => unawaited(client.flush()),
      );
      try {
        connectivity = Connectivity().onConnectivityChanged.listen(
          (results) {
            if (results.any((result) => result != ConnectivityResult.none)) {
              unawaited(client.flush());
            }
          },
          // Without the plugin the connection trigger is all that is lost.
          onError: (Object _) {},
        );
      } catch (_) {
        // Without the plugin the connection trigger is all that is lost.
      }
    }

    late final NoticebirdFlutter started;
    var stopped = false;
    void stop() {
      if (stopped) return;
      stopped = true;
      lifecycle?.dispose();
      unawaited(connectivity?.cancel());
      restoreHandlers?.call();
      if (identical(Bloc.observer, observer)) Bloc.observer = previousObserver;
      client.close();
      if (identical(Noticebird.instance, client)) Noticebird.detach();
      if (identical(_running, started)) _running = null;
      ingest?.close();
    }

    return _running = started = NoticebirdFlutter._(
      client: client,
      blocObserver: blocObserver,
      stop: stop,
    );
  }

  /// Reports an error a zone's handler got, as fatal, to the started
  /// client, and prints it as the framework prints an error: the handler of
  /// a host's own guarded zone, `runZonedGuarded(body,
  /// NoticebirdFlutter.reportZoneError)`. Before [start] it only prints.
  static void reportZoneError(Object error, StackTrace stack) => handlers
      .reportZoneError(_running?.client ?? Noticebird.instance, error, stack);

  /// Stops what [start] set up: the handlers and the bloc observer it
  /// installed go back to the ones it found, the foreground and connection
  /// triggers and the client's own schedule stop, and the client is
  /// detached from the facade. A later [start] starts anew. Idempotent.
  void close() => _stop();

  static AppMetadata _app(String name, PackageInfo? info) {
    String part(String? value) =>
        value == null || value.trim().isEmpty ? 'unknown' : value.trim();
    final version = part(info?.version);
    final build = part(info?.buildNumber);
    final app = AppMetadata(
      name: name,
      version: version,
      build: build,
      release: '$name@$version+$build',
    );
    try {
      app.check();
      return app;
    } on ProtocolException {
      // What the platform reported is no version the protocol takes; the
      // name is the host's, and checked by the config.
      return AppMetadata(
        name: name,
        version: 'unknown',
        build: 'unknown',
        release: '$name@unknown+unknown',
      );
    }
  }

  static Future<T?> _read<T>(Future<T> Function() read) async {
    try {
      return await read().timeout(platformReadTimeout);
    } catch (error) {
      _debugNote('a platform read did without: $error');
      return null;
    }
  }
}

void _debugNote(String note) {
  if (kDebugMode) debugPrint('noticebird: $note');
}
