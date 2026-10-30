# Integrating `noticebird`

This guide covers a full consumer integration. For the shortest possible
wiring, see the package README; for a runnable app, see
`packages/noticebird/example`.

## 1. Depend on the SDK

Consumers depend only on the capture package; the protocol package is
transitive.

```yaml
dependencies:
  noticebird: ^0.3.0
```

Native crash capture is a separate add-on package, `noticebird_native`
(§11); a consumer that does not add it carries no native code.

## 2. Create the client

```dart
final reporter = NoticebirdClient(
  config: NoticebirdConfig(
    privacyProfile: CrashPrivacyProfile.privacyDefault,
    app: AppMetadata(
      name: 'my_app',
      version: '2.3.0',
      build: '481',
      release: 'my_app@2.3.0+481',
    ),
  ),
  transport: CrashHttpTransport(
    publishableKey: 'noticebird_pk_...',
  ),
);
```

- Noticebird's ingestion route, `https://api.noticebird.com/v1/envelope`, is used by default.
- Pass `endpoint` explicitly only for local, staging, or self-hosted setups.
- `publishableKey` must be a publishable key, `<prefix>_pk_<token>` (Noticebird
  issues `noticebird_pk_…` keys); the transport rejects anything else,
  including a secret `…_sk_…` key. The key goes out as
  `Authorization: Bearer <key>`. The project, environment and privacy profile are derived
  server-side from the key and are never trusted from the event payload.

### Configuration knobs

| Field | Default | Notes |
|---|---|---|
| `maxBreadcrumbs` | 50 | 0–50; the breadcrumbs one event carries: the newest that no sent event carried yet. |
| `breadcrumbBuffer` | `maxBreadcrumbs` | `maxBreadcrumbs`–200; the breadcrumbs kept in memory for `recentBreadcrumbs`. |
| `maxPendingEvents` | 50 | 0–200; bounds the in-memory/offline retry queue. |
| `deduplicationWindow` | 1 minute | A repeat inside the window (the same grouping key, or the same type and top app frames, line numbers aside) is `deduplicated`. |
| `offlineStore` | none | Optional durable queue (see §8). |
| `pii` | all identity fields enabled | Optional identity field filter or complete opt-out. |
| `sessionIdFactory` | `NoticebirdConfig.processSessionId` | One id per app run; pass your own only when a session means something else. |
| `shouldCapture` | none (capture everything) | Capture filter asked on every channel; `false` ignores the capture. See §4. |
| `nativeCrashes` | none (off) | `NativeCrashCapture()` from `noticebird_native`: native crash reports of earlier runs. See §11. |
| `feedback` | none (off) | `FeedbackConfig` from `package:noticebird/feedback.dart`: user feedback reports. See §6. |

For a build that uploads nothing but still keeps the breadcrumb trail, the
user and the route (for a feedback report or an error details view), pass
`transport: const DiscardingCrashTransport()`.

## 3. Install global handlers

Wrap app startup in `run()` so Flutter, platform-dispatcher, and uncaught
zone errors are all captured, and previous handlers are chained and restored:

```dart
void main() {
  Bloc.observer = ProtocolNoticebirdBlocObserver(reporter);
  reporter.run(() => runApp(const MyApp()));
}
```

`run()` calls `installGlobalHandlers()` for you. Use
`uninstallGlobalHandlers()` to restore the previous handlers (for example in
tests). Installation is idempotent.

## 4. Report and annotate

```dart
// Handled error — does not interrupt the user.
await reporter.captureException(
  error,
  stackTrace,
  severity: CrashSeverity.warning,
  handled: true,
  tags: {AllowedTag.feature: 'checkout', AllowedTag.operation: 'submit'},
  extra: {'retry_count': 2, 'checkout_phase': 'confirmation'},
);

// Manual breadcrumb.
reporter.addBreadcrumb(TypedBreadcrumb(
  occurredAt: DateTime.now().toUtc(),
  category: BreadcrumbCategory.navigation,
  action: 'route.push',
));

// Route context must be a template, never a raw id.
reporter.setRouteTemplate('/lists/:listId');
```

Use fixed `AllowedTag` keys for searchable dimensions such as feature,
operation, and component. Pass `groupingKey` (up to 8 short technical parts,
such as an error code and an operation) when the app knows better than the
stack which failures are one issue: Noticebird then groups every event of
the app with that key together, whatever its type or stack. Put bounded diagnostic JSON in `extra`; sensitive
keys and values are removed client-side and rejected again server-side.
`captureException` returns a
`CaptureResult`: its `outcome` describes what happened — `sent`,
`deduplicated`, `queued` (transport failed, retained for retry), `dropped`
(could not be captured, or the platform refused it for good, see
`CrashTransport.send`), or `ignored` (the capture filter declined it) — and
its `eventId` is the id of the event that stands for the error (this one when
sent or queued, the earlier one when deduplicated, `null` when nothing went).

### One report per failure

When the app already reports some errors at a report point of its own (an
error library that reports each failure where it converts it, say), every
other channel must leave them alone. Configure the capture filter once; the
explicit captures, the bloc observer, the global handlers and the zone of
`run()` all honour it, and the report point bypasses it:

```dart
NoticebirdConfig(
  // …
  shouldCapture: (error) => error is! MyDomainError,
);

// The one report point of those errors:
reporter.captureException(error, stack, handled: true, filtered: false);
```

A filter that throws counts as `true`.

## 5. Optional user identity (PII)

PII is only sent when your application explicitly calls `setUser` or
`setUserId`. All structured identity fields are accepted by default for
`privacyDefault` and `custom`; omitting these calls sends no identity:

```dart
final reporter = NoticebirdClient(
  config: NoticebirdConfig(
    privacyProfile: CrashPrivacyProfile.privacyDefault,
    app: appMetadata,
  ),
  transport: transport,
);

reporter.setUser(CrashUser(id: currentUser.id, email: currentUser.email));

// On logout, clear both the identifier and any breadcrumbs from the
// previous session:
reporter.setUser(null);
reporter.clearBreadcrumbs();
```

Use `CrashPiiConfig(enabled: false)` for a complete client-side opt-out, or
provide `allowedFields` to retain only selected identity fields.
`regulatedStrict` always removes identity, because selecting that profile is
the consumer's explicit no-PII policy choice.

Allowed PII fields are `userId`, `email`, `name`, and `ipAddress`. Identity must
never be placed in `extra`. User data does not affect how events are grouped,
so the same crash across different users still groups into one issue. Medical data
and credentials remain forbidden in every profile; there is intentionally no
`sendMedicalData` option.

## 6. User feedback

`captureFeedback` sends a user's feedback report — a bug, an idea, anything
else — to Noticebird, where it is triaged apart from crashes. Its types,
`FeedbackConfig` and `FeedbackHttpTransport` included, are in
`package:noticebird/feedback.dart`, apart from the main library, so they
cannot clash with an app's own feedback classes. Without
`NoticebirdConfig.feedback` it answers `FeedbackDisabled` and sends nothing.

```dart
import 'package:noticebird/feedback.dart';

final crashTransport = CrashHttpTransport(publishableKey: 'noticebird_pk_...');
final reporter = NoticebirdClient(
  config: NoticebirdConfig(
    privacyProfile: CrashPrivacyProfile.privacyDefault,
    app: appMetadata,
    feedback: FeedbackConfig(
      transport: FeedbackHttpTransport.of(crashTransport),
      offlineStore: FileFeedbackOfflineStore(directory), // optional
    ),
  ),
  transport: crashTransport,
);

final outcome = await reporter.captureFeedback(
  kind: FeedbackKind.bug,                  // bug, idea or other
  message: 'Sync keeps failing on Wi-Fi',  // the user's words
  trigger: FeedbackTrigger.manual,         // optional: what opened the form
  screenshot: FeedbackScreenshot(          // optional
    bytes: pngBytes,
    contentType: FeedbackContentType.png,
  ),
  contactEmail: email,                     // optional: only with consent
  relatedEventId: result.eventId,          // optional: the crash it is about
);
```

`FeedbackHttpTransport.of(crashTransport)` sends with the crash transport's
publishable key and HTTP client, to the API of its `endpoint` (the
`/v1/envelope` URL; the feedback routes replace that path, so a proxy prefix
survives): the key, the endpoint and the client are configured once. An app
whose crash events go another way still makes a `CrashHttpTransport` for
it.

The client fills in the app, platform, locale, session, route template, the
user of `setUser` and the newest 100 breadcrumbs, redacted as in an event.
The message is redacted on the device like an exception message and cut to
4,000 characters. `diagnostics` (built with `FeedbackDiagnostics.build`) are
content-free values: booleans, numbers, timestamps, UUIDs and short tokens.
`userContext` is what the app tells about its user on purpose; the client
checks its shape (`FeedbackUserContext.check`) and sends it as given, and the
platform drops what it may not keep, such as credentials and health values.
Under `regulatedStrict` no user, user context or locale is sent.

The outcome is sealed:

| `FeedbackOutcome` | Meaning |
|---|---|
| `FeedbackDelivered` | The platform has the report; `ticket.display` (such as `FB-12`) is for the reporter, `verified` says whether the reporter assertion was accepted. `ticket` is `null` when the answer named none, such as for a resent report the platform stored already but can no longer compare, its screenshot deleted by retention. |
| `FeedbackQueued` | It did not get through yet and waits in the offline store, under `reportId`. |
| `FeedbackDisabled` | No `NoticebirdConfig.feedback`. |
| `FeedbackRejected` | Not delivered, and never will be: `reason` (a `FeedbackRejection`) says why, `path` names the value at fault. |

`captureFeedback` never throws. A value the app passed that the report
refuses (a contact address, diagnostics, a user context, a screenshot whose
bytes are too many or not its type, a message empty after redaction) throws
an `ArgumentError` in a debug build, to show the mistake, and is
`FeedbackRejected(FeedbackRejection.invalidInput)` in a release build. A form
can check a contact address first with `FeedbackContact.isValid`.

### Verified reporters

To show a reporter as verified, pass `reporterAssertion`: a function that asks
your backend for a signed assertion of the signed-in user. It is called once
per report, when the report is captured, and given 5 seconds; one that
throws, answers `null` or takes longer leaves the report unverified. When the
platform refuses the assertion it is not asked for again: the report is sent
unverified, or, with `requireVerified: true`, rejected as
`FeedbackRejection.unverified`.

### The feedback queue

With an `offlineStore`, a report that does not get through (no network, a
server error, a rate limit) is kept and answered `FeedbackQueued`. `flush()`
sends what is due, after the platform's `Retry-After` or a backoff from 30
seconds to 6 hours that survives a restart; `run()` calls it at start, and
the app calls it on resume and after connectivity returns, as for crash
events. The client keeps at most 10 reports and 20 MiB, evicting the oldest
first (`FeedbackRejection.evicted`), and removes a report after 7 days
(`FeedbackRejection.expired`). Without a store, such a report is
`FeedbackRejection.noStore`.

```dart
reporter.feedbackDeliveries.listen((settled) {
  // A queued report's end: settled.reportId, and settled.outcome,
  // FeedbackDelivered or FeedbackRejected.
});
final waiting = await reporter.pendingFeedbackCount;
```

`FileFeedbackOfflineStore(directory)` keeps each report as files in a
directory, which should be the store's own (one under the app's support
directory, say). It is not encrypted, so `regulatedStrict` refuses it: pass
an encrypted `FeedbackOfflineStore` of your own there. On the web its calls
throw, so it keeps nothing, and a report that does not get through is
`FeedbackRejection.noStore`.

## 7. Live debug sessions

While a live debug session is active, the deduplication window is bypassed
(every capture sends) and every `addBreadcrumb` call also streams immediately
as a synthetic event, so a support engineer can watch breadcrumbs arrive
without waiting for a real crash — no new transport or wire format involved.

```dart
reporter.startLiveDebugSession(
  sessionId: sessionId,
  expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 15)),
);
// ... later, or automatically once expiresAt passes:
reporter.stopLiveDebugSession();
```

Eligibility, tokens, and TTL policy are entirely the host app's concern — the
client only tracks whether a session id is active until `expiresAt`. Wire
`startLiveDebugSession`/`stopLiveDebugSession` to whatever mechanism your
platform uses to authorize a session (for example a server-controlled
allowlist your app polls).

## 8. Optional offline queue

When the transport fails, events are queued (bounded by `maxPendingEvents`) and,
if an `offlineStore` is configured, persisted as canonical envelopes. `run()`
calls `flush()` once at start, so what an earlier run queued goes out; call
`flush()` on resume/connectivity too. A flush writes the queue back to the
store before it sends, so a process that dies during the send keeps the stored
events. A stored event is sent again as the text the client wrote; an entry
without an event id is discarded.

Implement `CrashOfflineStore`; the SDK never derives or hardcodes an encryption
key, so encryption is supplied by your platform keystore adapter:

```dart
final class KeystoreOfflineStore implements CrashOfflineStore {
  @override
  bool get isEncrypted => true; // backed by Keychain/Keystore/WebCrypto

  @override
  Future<void> write(List<String> canonicalEnvelopes) async { /* ... */ }

  @override
  Future<List<String>> readAndClear() async { /* ... */ }
}
```

`CrashPrivacyProfile.regulatedStrict` rejects an unencrypted offline store at
construction time.

## 9. Privacy profiles

- `privacyDefault` sanitizes messages, tags, breadcrumbs and stack frames: it
  redacts emails, JWTs, bearer/token/secret/password/api-key/authorization
  patterns, UUIDs, phone numbers, IPv4 addresses and health values (the
  protocol's `PrivacyPatterns`), and keeps only the app's stack frames:
  `package:` frames and, in a web build, the frames of the compiled dart2js
  script with its file name alone, never its host or path.
- `regulatedStrict` additionally replaces the exception message with the error
  type only, removes user identity and all free-form `extra` context, and
  truncates allowlisted scalar tags for regulated/medical apps.
- `custom` supports project-specific privacy policies, but still never permits
  medical data or secrets. Use `CrashPiiConfig` to filter or disable explicitly
  supplied identity fields on the client.

The service enforces the same versioned privacy contract independently — its
privacy firewall rejects every event that holds what these patterns match — so
a client bug cannot persist restricted data.

## 10. Testing

Inject a fake `CrashTransport` to assert capture behavior without a network —
see `packages/noticebird/example/test/example_smoke_test.dart`. The client
hands `send` the event as it wrote it, its canonical JSON, validated already
(an event with an invalid session id or metadata is `dropped` before it gets
there); decode it to assert on its fields:

```dart
final class RecordingTransport implements CrashTransport {
  final events = <Map<String, dynamic>>[];
  @override
  Future<void> send(String eventJson) async {
    events.add(jsonDecode(eventJson) as Map<String, dynamic>);
  }
}
```

For feedback, implement `FeedbackTransport` the same way: the client hands
`submit` the report as `FeedbackReport.toJsonString` wrote it, validated
already; decode it to assert on its fields, and answer a
`FeedbackAccepted`. The example's smoke test does this for its feedback
button.

The reporter guarantees zero-crash behavior: capture, transport, queue, and
flush failures are swallowed and never propagate into the host application.

## 11. Native crashes (`noticebird_native`)

A process that dies underneath the Dart isolate — a signal or Mach-exception
crash in the engine, a plugin, Dart AOT code or a system library; an uncaught
Objective-C or JVM exception; a watchdog or ANR kill; a foreground
low-memory kill — never reaches a Dart handler. The operating system keeps a
report of it; `noticebird_native` reads that report on a later launch and
the client delivers it as a schema-5 event with a `native` block.

### Opt in: one line, plus one call if you own your bootstrap

```yaml
dependencies:
  noticebird: ^0.3.0
  noticebird_native: ^0.3.0
```

```dart
NoticebirdConfig(
  // …
  nativeCrashes: NativeCrashCapture(), // hangs: false, diskWrites: false,
                                       // includeDebugBuilds: false
);
```

- A host that starts with `reporter.run(...)` needs nothing else: `run()`
  wraps `runApp`, so it is the engine that shows the UI, and it calls
  `reportNativeCrashes()`.
- A host that builds its own zone adds one call to its **UI start only**:
  `Noticebird.reportNativeCrashes()` (or the client's method). Never call it
  from a headless background engine — it may have seconds to live.
- Share one config between every engine. Each engine with a collector records
  its run (session, app, platform, route, trail); only the engine that asks
  delivers. A crash inside a headless background run is attributed to that
  run.

### What is captured

| | Captured | Not captured |
|---|---|---|
| iOS 15+ | MetricKit crash diagnostics (signals, Mach exceptions, uncaught Objective-C/Swift exceptions, watchdog kills `0x8badf00d`); with `hangs: true` hang diagnostics, with `diskWrites: true` disk-write exceptions | Out-of-memory (jetsam) kills; crash-on-launch loops (likely never delivered); iOS 14 and older (inert). iOS 17.2–17.5 has a reported MetricKit bug that withholds diagnostics on relaunch. |
| Android 11+ (API 30) | Native crashes (from API 31 with the tombstone's frames), ANR kills (main thread), low-memory kills while foreground or visible | Background low-memory kills (normal lifecycle), user-requested and self exits |
| Android, every API level | Uncaught JVM exceptions, through a handler that chains to whatever was installed before | Native crashes and ANRs below API 30 |
| Web, desktop | — (the collector is inert) | |

Nothing of it runs inside the crashing process except the JVM handler, which
writes one bounded record and always calls the previous handler. Debug builds
are excluded by default (`includeDebugBuilds: false`): a debug build run
outside the debugger crashes on JIT code by design, and a crash of a debug run
is dropped even when a later release run delivers it.

### What a native event carries

- `severity: fatal`, `handled: false` for crashes and kills; `warning`,
  `handled: true` for hangs and disk writes (the app lived on).
- A fixed exception type (`EXC_BAD_ACCESS/SIGBUS`, `SIGSEGV`, the exception
  class, `WatchdogTermination`, `ApplicationNotResponding`, `LowMemoryKill`,
  `Hang`, `DiskWriteException`) and a message composed from enumerated fields;
  an exception's own message goes through the sanitizer. Under
  `regulatedStrict` the message is the type.
- The **crashed run's** app, platform, session, route and trail — not the
  current run's; the app may have been updated since. A report that matches
  no known build is dropped rather than filed under the wrong release.
- `native`: kind, source, Mach exception, signal, codes, and the crashed
  thread's frames as image offsets with each image's file name, debug id,
  architecture and in-app flag. No absolute addresses, registers, other
  threads, log buffers, full paths or identity — ever. No `user`, `userId` or
  `extra`.
- A deterministic event id derived from the report, so a resend is a replay for
  Noticebird: one crash, one event. Native reports bypass the deduplication
  window, are capped at 10 per launch, and `shouldCapture` is asked with the
  `NativeCrashRecord`.

On the device the collector keeps an inbox (≤ 20 reports, ≤ 30 days, deleted
once delivered) and a run ledger (≤ 5 runs, ≤ 16 KB per engine), both in
app-private storage excluded from backups; under `regulatedStrict` no trail is
persisted. When the host stops starting native capture (the config line is
removed), the native side purges both after three launches without it.

### What you must declare

The reports are personal data (Apple DTS confirms MetricKit is not gated by the
"Share With App Developers" setting): declare **Crash Data** in the App Store
privacy details (not linked to identity, not used for tracking, app
functionality) and **Crash logs** in Google Play's Data safety form. The
plugin ships a privacy manifest declaring crash data collection and uses no
required-reason API.

### Symbols

Frames arrive unsymbolicated — image name, debug id and offset — until
Noticebird's debug-file upload and symbolication are available. Keep, per
release: on iOS the archive's dSYMs, including `App.framework.dSYM` and
`Flutter.framework.dSYM` (and `app.ios-arm64.symbols` with
`--split-debug-info`); on Android the native debug symbols (`libapp.so`
`.symbols` from `--split-debug-info`, the engine's `libflutter.so` symbols,
plugin `.so` files) and the R8 `mapping.txt`.

### Testing

The collector is an interface, `NativeCrashCollector`: inject a fake that
returns `NativeCrashBatch`es and assert the events your transport receives.
`packages/noticebird_native/example` is a native crash lab with deliberate
crashes for device and emulator smokes.

