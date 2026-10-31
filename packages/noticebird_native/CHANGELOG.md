## 0.6.0

- Moves with `noticebird` 0.6.0 and `noticebird_protocol` 0.6.0, whose
  removals (`CrashEvent.maxTags`, `TypedBreadcrumb.maxDataTags`,
  `CrashEvent.userId`, `CrashEvent.userIdPattern`) this package never used;
  no change of its own. Through `noticebird` 0.6.0, a breadcrumb of the
  crashed run's trail that the protocol refuses is left out of the native
  crash event alone. The podspec and the Android library read 0.6.0 from
  the pubspec.

## 0.5.0

- Moves with `noticebird` 0.5.0 and `noticebird_flutter` 0.5.0; no change of
  its own. The podspec and the Android library read the package's version
  from its pubspec (they still said 0.3.0). The crash lab example takes
  `NOTICEBIRD_API_URL`, the API's base, in place of `NOTICEBIRD_INGEST_URL`.

## 0.4.0

- Moves with `noticebird` 0.4.0 and the new `noticebird_flutter` 0.4.0; no
  change of its own. `NoticebirdFlutter.start(nativeCrashes:
  NativeCrashCapture())` delivers the reports of earlier runs, in place of
  `noticebird`'s removed `run()`. While crash uploads are off (a client
  without a transport), the client claims no report, so a later build that
  uploads still sends them.

## 0.3.0

- Moves with `noticebird` 0.3.0 and `noticebird_protocol` 0.3.0.
  `reportNativeCrashes` now returns `CaptureResult`s, a change of
  `noticebird`'s API: a host that reads its results reads their `outcome`.
- `NativeCrashCapture.withPlatform`, `NativeCrashCapture.methodChannelName`
  and `NativeCrashCapture.eventChannelName` are no longer public: they were
  the package's own test seams. The channels' names, the native contract,
  are unchanged.
- A native record's images and frames, and the run ledger's app, platform
  and breadcrumbs, are read by the package itself and checked by the
  protocol's `NativeCrashInfo.check`, `AppMetadata.check`,
  `PlatformMetadata.check` and `TypedBreadcrumb.check`, since the protocol
  no longer reads JSON. What a record or a ledger file may hold is
  unchanged.

## 0.2.0

- Moves with `noticebird` 0.2.0 and `noticebird_protocol` 0.2.0; no change of
  its own.

## 0.1.0

First public release.
