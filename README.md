# Noticebird for Dart and Flutter

Crash reporting for Flutter apps, sent to [Noticebird](https://noticebird.com).

This workspace contains the Noticebird packages:

- `packages/noticebird` — the Flutter SDK an app depends on;
- `packages/noticebird_protocol` — the pure-Dart, versioned event protocol it
  writes;
- `packages/noticebird_native` — an optional add-on plugin that delivers the
  native crash reports iOS (MetricKit) and Android (`ApplicationExitInfo`, a
  chaining JVM handler) keep about earlier runs.

Start with [`docs/integration.md`](docs/integration.md) and the package
READMEs. An AI coding agent integrating the SDK can use the
[`noticebird` skill](skills/noticebird/SKILL.md).

## Checks

Run `fvm dart pub get` from the workspace root, then the Flutter tests in
`packages/noticebird` and `packages/noticebird_native` and the Dart tests in
`packages/noticebird_protocol`. The native collectors have their own tests:
`swift test` in
`packages/noticebird_native/ios/noticebird_native/NativeCrashNormalizer` and
`./gradlew :noticebird_native:testDebugUnitTest` in
`packages/noticebird_native/example/android`.
