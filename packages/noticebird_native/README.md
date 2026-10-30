# noticebird_native

Native crash capture for [`noticebird`](../noticebird): the crash
reports iOS and Android keep about earlier runs of your app — native crashes,
uncaught Objective-C and JVM exceptions, watchdog and ANR kills, foreground
low-memory kills — delivered to the Noticebird platform as ordinary
events on the next launch.

```yaml
dependencies:
  noticebird: ^0.3.0
  noticebird_native: ^0.3.0
```

```dart
NoticebirdConfig(
  // …
  nativeCrashes: NativeCrashCapture(),
);
```

`client.run(...)` delivers the reports. A host that owns its bootstrap calls
`Noticebird.reportNativeCrashes()` from its UI start only.

| Platform | Source |
|---|---|
| iOS 15+ | MetricKit crash diagnostics; hang and disk-write diagnostics with `hangs: true` / `diskWrites: true` |
| Android 11+ (API 30) | `ApplicationExitInfo`: native crashes (tombstone frames from API 31), ANR kills, foreground low-memory kills |
| Android, every API level | Uncaught JVM exceptions, through a handler that chains to the previous one |
| Web, desktop | Inert |

Nothing of this package runs inside a crashing process, except the JVM
handler, which writes one bounded record and always chains. Reports are
minimized on the device before they are stored — frames are image offsets, no
absolute addresses, registers, other threads, log buffers, paths or identity —
and kept in app-private storage excluded from backups. Debug builds are
excluded unless `includeDebugBuilds: true`.

Declare **Crash Data** in the App Store privacy details and **Crash logs** in
Google Play's Data safety form. The iOS plugin ships a privacy manifest and
uses no required-reason API. It supports Swift Package Manager and CocoaPods.

Full guide: [`docs/integration.md`](../../docs/integration.md) §11. A crash
lab for device smokes: [`example/`](example).
