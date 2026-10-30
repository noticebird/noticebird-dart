# Noticebird for Dart and Flutter

Crash reporting and user feedback for Flutter apps, sent to
[Noticebird](https://noticebird.com).

A Flutter app depends on `noticebird_flutter` and starts it once:

```dart
Future<void> main() async {
  await NoticebirdFlutter.start(
    publishableKey: const String.fromEnvironment('NOTICEBIRD_KEY'),
    appName: 'my_app',
  );
  runApp(const MyApp());
}

// The navigator that holds the app's pages:
MaterialApp(
  navigatorObservers: [NoticebirdNavigatorObserver(tracksRouteTemplate: true)],
);
```

The packages are not on pub.dev: an app depends on them from this repository
at a release's tag, as [Depend on the SDK](docs/integration.md#1-depend-on-the-sdk)
shows.

This workspace contains the Noticebird packages:

- `packages/noticebird_flutter` — the package a Flutter app depends on: one
  start wires the client, the error handlers, bloc and navigation
  breadcrumbs, the offline stores and their delivery;
- `packages/noticebird` — the pure-Dart client it starts: capture,
  breadcrumbs, identity, the offline queues and user feedback;
- `packages/noticebird_protocol` — the pure-Dart, versioned event protocol it
  writes;
- `packages/noticebird_native` — an optional add-on plugin that delivers the
  native crash reports iOS (MetricKit) and Android (`ApplicationExitInfo`, a
  chaining JVM handler) keep about earlier runs.

Start with [`docs/integration.md`](docs/integration.md) and the package
READMEs. An AI coding agent integrating the SDK can use the
[`noticebird` skill](skills/noticebird/SKILL.md).

## Checks

Run `fvm flutter pub get` from the workspace root, then the Dart tests in
`packages/noticebird_protocol` and `packages/noticebird`, and the Flutter
tests in `packages/noticebird_flutter`, `packages/noticebird_native` and
their examples. The native collectors have their own tests: `swift test` in
`packages/noticebird_native/ios/noticebird_native/NativeCrashNormalizer` and
`./gradlew :noticebird_native:testDebugUnitTest` in
`packages/noticebird_native/example/android`. [`CONTRIBUTING.md`](CONTRIBUTING.md)
lists the commands.
