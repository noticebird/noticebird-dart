import 'dart:async';
import 'dart:convert';

import 'package:noticebird/noticebird.dart';
import 'package:noticebird_native/noticebird_native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ffi_crashes.dart' if (dart.library.js_interop) 'ffi_crashes_web.dart';

/// The platform's API URL (its base, such as `https://api.noticebird.com`)
/// and a publishable key of a test project. Without both, delivered events
/// are only shown on screen.
const _apiUrl = String.fromEnvironment('NOTICEBIRD_API_URL');
const _publishableKey = String.fromEnvironment('NOTICEBIRD_PUBLISHABLE_KEY');

/// Every event this run delivered, as the wire carries it, newest last: the
/// native reports of earlier runs arrive here right after launch.
final delivered = ValueNotifier<List<Map<String, dynamic>>>(const []);

/// Shows every event on screen and, when configured, forwards it.
final class LabTransport implements CrashTransport {
  LabTransport(this._next);

  final CrashTransport? _next;

  @override
  Future<void> send(String eventJson) async {
    await _next?.send(eventJson);
    delivered.value = [
      ...delivered.value,
      jsonDecode(eventJson) as Map<String, dynamic>,
    ];
  }
}

void main() {
  final client = NoticebirdClient(
    config: NoticebirdConfig(
      privacyProfile: CrashPrivacyProfile.privacyDefault,
      // Version and build match pubspec.yaml's 1.0.0+1, which is what the
      // app bundle reports natively.
      app: const AppMetadata(
        name: 'noticebird_native_example',
        version: '1.0.0',
        build: '1',
        release: 'noticebird_native_example@1.0.0+1',
      ),
      platform: hostPlatformMetadata(),
      // The one line native capture takes. The lab also reports hangs and
      // disk writes, and runs in debug builds, so every smoke is visible.
      nativeCrashes: NativeCrashCapture(
        hangs: true,
        diskWrites: true,
        includeDebugBuilds: true,
      ),
    ),
    transport: LabTransport(
      _apiUrl.isEmpty || _publishableKey.isEmpty
          ? null
          : CrashHttpTransport(
              apiUrl: Uri.parse(_apiUrl),
              publishableKey: _publishableKey,
            ),
    ),
  );
  Noticebird.attach(client);
  // The lab sends through a transport of its own, so it builds its client
  // itself rather than with NoticebirdFlutter.start: it delivers the native
  // reports of earlier runs from this engine, the one that shows the UI.
  unawaited(client.reportNativeCrashes());
  runApp(const CrashLabApp());
}

class CrashLabApp extends StatelessWidget {
  const CrashLabApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Native crash lab',
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.deepOrange),
    home: const CrashLabPage(),
  );
}

/// Deliberate native crashes. Each one kills the process; the report arrives
/// on the next launch, in the list below the buttons.
class CrashLabPage extends StatefulWidget {
  const CrashLabPage({super.key});

  @override
  State<CrashLabPage> createState() => _CrashLabPageState();
}

class _CrashLabPageState extends State<CrashLabPage> {
  @override
  void initState() {
    super.initState();
    Noticebird.setRouteTemplate('/lab');
  }

  void _crash(String action, void Function() crash) {
    // The trail of this run travels with the native report of its crash.
    Noticebird.addBreadcrumb(
      TypedBreadcrumb(
        occurredAt: DateTime.now().toUtc(),
        category: BreadcrumbCategory.ui,
        action: action,
      ),
    );
    // Give the ledger's debounced write time to land before the process dies.
    Future<void>.delayed(const Duration(seconds: 1), crash);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Native crash lab')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (kIsWeb)
          const Text('The web has no native crashes: the collector is inert.'),
        if (!kIsWeb) ...[
          FilledButton(
            onPressed: () => _crash('lab.abort', NativeCrashes.abort),
            child: const Text('abort() through dart:ffi (SIGABRT)'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () => _crash('lab.null_write', NativeCrashes.nullWrite),
            child: const Text('Write to address 0 (SIGSEGV)'),
          ),
        ],
        if (defaultTargetPlatform == TargetPlatform.android) ...[
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () =>
                _crash('lab.jvm_exception', NativeCrashes.jvmException),
            child: const Text('Uncaught JVM exception'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () =>
                _crash('lab.block_main', NativeCrashes.blockMainThread),
            child: const Text('Block the main thread (touch the screen: ANR)'),
          ),
        ],
        if (defaultTargetPlatform == TargetPlatform.iOS) ...[
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () =>
                _crash('lab.objc_exception', NativeCrashes.objcException),
            child: const Text('Uncaught Objective-C exception'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () =>
                _crash('lab.block_main', NativeCrashes.blockMainThread),
            child: const Text('Block the main thread 5 s (hang)'),
          ),
        ],
        const SizedBox(height: 24),
        Text(
          _apiUrl.isEmpty
              ? 'Delivered this run (shown only)'
              : 'Delivered this run (also sent to $_apiUrl)',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        ValueListenableBuilder<List<Map<String, dynamic>>>(
          valueListenable: delivered,
          builder: (context, events, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (events.isEmpty) const Text('Nothing yet.'),
              for (final event in events.reversed) EventTile(event: event),
            ],
          ),
        ),
      ],
    ),
  );
}

class EventTile extends StatelessWidget {
  const EventTile({required this.event, super.key});

  /// The event as the wire carries it.
  final Map<String, dynamic> event;

  @override
  Widget build(BuildContext context) {
    final exception = event['exception'] as Map<String, dynamic>;
    final native = event['native'] as Map<String, dynamic>?;
    final breadcrumbs = event['breadcrumbs'] as List? ?? const [];
    return Card(
      child: ListTile(
        title: Text(exception['type'] as String),
        subtitle: Text(
          [
            exception['sanitizedMessage'],
            if (native != null)
              '${native['kind']} · ${native['source']} · '
                  '${(native['frames'] as List? ?? const []).length} frames',
            'session ${event['sessionId']}',
            '${breadcrumbs.length} breadcrumbs · ${event['occurredAt']}',
          ].join('\n'),
        ),
        isThreeLine: true,
      ),
    );
  }
}

/// Crashes the process natively: from Dart through `dart:ffi`, or through
/// the example app's own native code (`MainActivity`, `AppDelegate`) — never
/// through plugin code.
abstract final class NativeCrashes {
  static const _lab = MethodChannel('noticebird_native_example/lab');

  /// `abort()` from the C library: SIGABRT.
  static void abort() => ffiAbort();

  /// A write to address zero: SIGSEGV (`EXC_BAD_ACCESS` on iOS).
  static void nullWrite() => ffiNullWrite();

  /// An uncaught exception on the Android main thread.
  static void jvmException() => _lab.invokeMethod<void>('jvmException');

  /// An uncaught `NSException` on the iOS main thread.
  static void objcException() => _lab.invokeMethod<void>('objcException');

  /// Blocks the platform main thread: an ANR on Android once input arrives,
  /// a hang diagnostic on iOS.
  static void blockMainThread() => _lab.invokeMethod<void>('blockMainThread');
}
