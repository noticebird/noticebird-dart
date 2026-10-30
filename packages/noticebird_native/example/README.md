# Native crash lab

The example app of `noticebird_native`: two deliberate native crashes and
a list of what the next launch delivered. It opts into everything
(`hangs`, `diskWrites`, `includeDebugBuilds`) so every smoke is visible, and
runs `client.run(...)`, which delivers the reports of earlier runs.

## Run

```sh
flutter run --profile \
  --dart-define=NOTICEBIRD_INGEST_URL=https://<platform>/v1/envelope \
  --dart-define=NOTICEBIRD_PUBLISHABLE_KEY=noticebird_pk_<test project key>
```

Without the two defines, delivered events are only shown on screen.

## Smokes

Use a **profile or release** build: a debug build run outside the debugger on
iOS 26 crashes on JIT code by itself, and real consumers exclude debug builds.

1. Start the app, tap a crash button — each dies after a second, once the
   trail is written:
   - *abort() through dart:ffi* (SIGABRT) and *Write to address 0* (SIGSEGV,
     `EXC_BAD_ACCESS` on iOS), both platforms;
   - Android: *Uncaught JVM exception*, and *Block the main thread* — then
     touch the screen until the "isn't responding" dialog appears and choose
     *Close app* (an ANR kill; only a killed process leaves an ANR record);
   - iOS: *Uncaught Objective-C exception*, and *Block the main thread 5 s*
     (a hang diagnostic; the app lives on).
2. Start the app again. On iOS, MetricKit delivers the report shortly after
   launch (seconds, sometimes a minute); on Android (API 30+) the exit record
   is read at start. The event appears under *Delivered this run* — fatal,
   `native` kind `crash`, the previous run's session id and its trail
   (`lab.abort` / `lab.null_write`).
3. Start it a third time: nothing new is delivered (the report was settled; a
   resend would be a replay on the platform).

On the platform, the issue shows the *Native* chip, the frames as
`#01  noticebird_native_example  +0x…`, and the trail of the crashed run.

Expected per platform: iOS 15+ delivers both crashes; Android API 31+ delivers
both with frames, API 30 without frames, and below API 30 nothing (only JVM
exceptions are captured there).

## A recorded MetricKit payload for the normalizer's fixtures

On iOS the lab also keeps every MetricKit diagnostic payload it receives, raw,
in its `Documents/metrickit/` folder (only the lab does this; the plugin never
stores a raw report). After a device smoke, copy the files in Finder: the
iPhone → *Files* → *noticebird_native_example* → `metrickit`. Strip the
device-identifying metadata (`deviceType`, `regionFormat`, `osVersion` build,
`bundleIdentifier`) before adding one to
`ios/noticebird_native/NativeCrashNormalizer/Tests/NativeCrashNormalizerTests/Fixtures/`.

