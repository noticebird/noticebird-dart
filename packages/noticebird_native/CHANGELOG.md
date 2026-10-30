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
