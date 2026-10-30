---
name: noticebird
description: >
  Use when integrating or changing crash reporting in a Flutter app that depends on the
  `noticebird` package — bootstrapping the client, capturing errors, adding
  breadcrumbs, attaching identity or route context, wiring the offline queue, or
  sending a user's feedback report (bug report, idea, screenshot).
  Reach for it for "report this error", "why was my event dropped", "how do I add a
  breadcrumb", "attach the user to crashes", "Noticebird sends nothing",
  "capture a handled error", "test code that reports crashes", "send user feedback",
  "add a report-a-bug button", "attach a screenshot to feedback", "verified reporter".
  Triggers on: NoticebirdClient, Noticebird, captureException,
  captureFeedback, feedback.dart, FeedbackConfig, FeedbackHttpTransport, FeedbackKind,
  FeedbackOutcome, FeedbackDelivered, FeedbackQueued, FeedbackRejected, FeedbackRejection,
  FeedbackScreenshot, FeedbackContact, FeedbackUserContext, FeedbackDiagnostics,
  reporterAssertion, requireVerified, FeedbackOfflineStore, FileFeedbackOfflineStore,
  feedbackDeliveries, FeedbackSettled, pendingFeedbackCount,
  CaptureOutcome, CaptureResult, shouldCapture, filtered, hostPlatformMetadata, processSessionId,
  DiscardingCrashTransport, addBreadcrumb, TypedBreadcrumb, BreadcrumbCategory, AllowedTag,
  setRouteTemplate, setUser, setUserId, CrashPrivacyProfile, regulatedStrict,
  CrashHttpTransport, noticebird_pk_, crash_pk_, CrashOfflineStore, flush, installGlobalHandlers,
  ProtocolNoticebirdBlocObserver, noticebird_native, NativeCrashCapture,
  nativeCrashes, reportNativeCrashes, NativeCrashCollector, NativeCrashRecord,
  MetricKit, ApplicationExitInfo, native crash, ANR, watchdog.
user-invocable: true
---

# Noticebird SDK

Privacy-safe crash reporting and user feedback for Flutter apps. The client builds a
validated, versioned event and posts it as a canonical-JSON envelope over plain HTTP. It
has no dependency beyond the pub packages its pubspec lists.

## The prime directive

**Noticebird must never crash the host application.** Every public method wraps
its body in `try { … } catch (_) {}`. That is not defensive noise — it is the contract,
and it changes how you use the API:

- A failure is never thrown at you. `captureException` returns a `CaptureResult`; read
  its `outcome`, do not wrap the call in a `try`.
- A misconfiguration surfaces at construction time instead. `NoticebirdConfig` and
  `CrashHttpTransport` throw `ArgumentError` in their constructors, so an invalid setup
  fails at bootstrap rather than silently dropping every event later.
- The one deliberate exception: `setRouteTemplate` throws on a raw route **in debug
  builds only**, to surface the integration mistake while you are looking. Release builds
  drop the value.

When you add code to this SDK, keep that shape: swallow inside, validate at the edges.

## Three packages

| Package | Depend on it when |
|---|---|
| `noticebird` | You are a Flutter app capturing crashes. This is the normal case. |
| `noticebird_native` | You also want native crashes, watchdog and ANR kills (iOS MetricKit, Android `ApplicationExitInfo`). An add-on with native code; see *Native crashes*. |
| `noticebird_protocol` | You build the wire format outside Flutter (a tool, or a client of your own). |

`noticebird` re-exports the whole protocol package, so an app never needs both. The
three are versioned together: the repository tag `v<version>` tracks `noticebird`.

## Bootstrap

Initialize first — before auth, DI, or any other service — so errors during the rest of
startup are already covered.

```dart
final client = NoticebirdClient(
  config: NoticebirdConfig(
    privacyProfile: CrashPrivacyProfile.privacyDefault,
    app: AppMetadata(name: 'myapp', version: '1.4.0', build: '412', release: 'myapp@1.4.0+412'),
    // sessionIdFactory defaults to NoticebirdConfig.processSessionId:
    // one id per app run. Pass your own (16-64 chars of [A-Za-z0-9_-]) only
    // when a session means something else to the host.
    offlineStore: myEncryptedStore,           // optional
    shouldCapture: (error) => error is! ReportedElsewhere, // optional
  ),
  transport: CrashHttpTransport(publishableKey: 'noticebird_pk_…'),
  eventIdFactory: () => uuidV7(),             // prefer this over the built-in fallback
);

Noticebird.attach(client);                 // enables the static facade
await client.run(() async => runApp(const MyApp()));
```

`run()` installs the `FlutterError`, `PlatformDispatcher` and zone handlers and runs the
body inside a guarded zone — one call replaces all three. Use
`install/uninstallGlobalHandlers()` directly only when you need the handlers without
owning the zone; both are idempotent and reversible, and the previous handlers are
chained, not replaced.

### The facade is a convenience, not the object

`NoticebirdClient` stays a plain constructor-injected instance so it is trivially
testable. `Noticebird` is a static facade over whichever client was `attach`ed, so
call sites can write `Noticebird.captureException(…)` without resolving DI every time.
Every facade member no-ops when nothing is attached — before bootstrap, or in tests that
never attach. In tests, construct your own client and never touch the facade; if you do
attach one, `Noticebird.detach()` in teardown.

## Capturing

```dart
final result = await client.captureException(
  error,
  stackTrace,
  severity: CrashSeverity.error,
  handled: true,                                    // it did not take the app down
  tags: {AllowedTag.feature: 'lists'},
  extra: {'listCount': 12},
  groupingKey: ['lists', 'load', 'E42'],            // optional: the host's own issue
);
```

Without `groupingKey` the platform groups events into issues itself. With one, every
event of this app with the same key is one issue, whatever its type or stack, and the
client deduplicates by it too. Use it when the stack says *where* a failure was
reported rather than *what* it is — one report point for many server codes, say — and
build it from bounded, technical values (a code, a reason, an operation), never an id:
its parts are redacted and cut like tag values (`reference/privacy-and-limits.md`).

`result.outcome` is a `CaptureOutcome`, and `result.eventId` the id of the event that
stands for the error — of this event when it is `sent` or `queued`, of the earlier one it
repeats when `deduplicated`, `null` when nothing went (`dropped`, `ignored`, or a repeat
of a dropped event). Pass it as a feedback report's `relatedEventId`.

| `CaptureOutcome` | Meaning |
|---|---|
| `sent` | Delivered to the transport. Its breadcrumbs count as sent: the next event starts after them. |
| `deduplicated` | The same error already captured inside the deduplication window (default 1 minute): the same `groupingKey`, or without one the same exception type and top app frames, line numbers aside. |
| `queued` | Transport failed; the event sits in the retry queue for the next `flush()`. |
| `dropped` | Could not be captured at all — protocol violation in config metadata, `maxPendingEvents: 0`, or the platform refused the event for good (see `CrashTransport.send`; a `flush()` drops it too). |
| `ignored` | The host's `shouldCapture` declined the error. |

### One report per failure: one filter, one bypass

Deduplication recognises a repeat of the *same* capture. It cannot tell that a
repository's capture, a bloc observer's and a caller's are one failure — each carries a
different stack and often a different object — and the SDK does not try to.

When the host already reports some errors at a report point of its own — an error library
that reports at the conversion into its own error type, say — every other channel must
leave them alone. That is `NoticebirdConfig.shouldCapture`, the capture filter every
crash SDK offers: asked once per capture on **every** channel — an explicit
`captureException`, `ProtocolNoticebirdBlocObserver`, the handlers
`installGlobalHandlers()` installs and the zone of `run()` — and `false` drops the capture
as `ignored`. The report point itself captures with `filtered: false`:

```dart
NoticebirdConfig(
  // …
  shouldCapture: (error) => error is! MyDomainError, // reported at its conversion
);

// The host's one report point for those errors:
client.captureException(error, stack, handled: true, filtered: false);
```

Set it once and the stock observer and handlers need no type check of their own, and a
channel added later cannot report such an error twice. The live-debug sync is never
filtered; a filter that throws counts as `true`, so a failing filter never costs a report.
The SDK stays generic: the predicate is the host's, the SDK only asks it. A user's own
report is `captureFeedback` (*Feedback*), never an event.

Set `handled: true` for anything you caught and turned into an error state. Leave it
`false` only for errors that actually reached a global handler.

## Breadcrumbs

A bounded buffer of the newest breadcrumbs (`breadcrumbBuffer`, default `maxBreadcrumbs`,
at most 200). Each event carries the newest of those **no sent event carried yet**, at most
`maxBreadcrumbs` (default and hard maximum 50, the protocol's `CrashEvent.maxBreadcrumbs`),
each value redacted (an id in a route or a bloc state becomes `[REDACTED]`) and shortened
to the protocol's 100 characters. A sent event does not empty the
buffer; it only moves the start of the next event's breadcrumbs past what it carried.

```dart
client.addBreadcrumb(TypedBreadcrumb(
  occurredAt: DateTime.now().toUtc(),
  category: BreadcrumbCategory.navigation,   // fixed enum, never a free-form string
  action: 'route.push',                      // must match ^[a-z][a-z0-9_.-]*$
  data: {AllowedTag.component: 'ListsPage'}, // AllowedTag keys, scalar values, max 8
));
```

Categories are `bloc`, `navigation`, `http`, `ui`, `auth`, `lifecycle`, `system`. There is
no escape hatch — an arbitrary category or a non-allowlisted tag key is rejected by the
protocol, which means the event is dropped, not truncated.

Call `clearBreadcrumbs()` on logout: the trail leading to the next event should not carry
the previous user's session.

`recentBreadcrumbs` gives a read-only snapshot of the whole buffer for host-app
diagnostics — an error dialog showing the trail, or a user's feedback report that sends it
to the host's own backend. Values keep up to `NoticebirdClient.maxBufferedTagValueLength`
(1000) characters there, as recorded; only an event redacts and shortens them. Reading it sends nothing. A host that
wants a longer trail than one event may carry raises `breadcrumbBuffer`, not
`maxBreadcrumbs`.

## Identity

Two ways in, and they are mutually exclusive per event:

- `setUserId(String?)` — the account id, sent as given in the protocol's shape: characters
  outside `[A-Za-z0-9_-]` are stripped and the result is cut to 100. A UUID or numeric id
  stays intact.
- `setUser(CrashUser?)` — explicit identity (`id`, `email`, `name`, `ipAddress`).

Sending identity is the host's choice, made once: `CrashPiiConfig` decides which fields
leave the device (`allowedFields`, or `enabled: false` for none), for both calls alike —
the SDK does not judge an id by its content. `regulatedStrict` drops identity altogether.
Who may *see* it is the platform's access control, not the SDK's.

**Medical data and credentials never belong here** — not in identity, not in tags, not in
`extra`. The ingestion privacy firewall rejects them for every profile.

## Route context

```dart
client.setRouteTemplate('/lists/:listId');   // template only
```

A raw route (`/lists/8a3f…`) throws in debug and is dropped in release. The check rejects
any segment that looks like an id: 16+ hex-ish characters, or 2+ consecutive digits.

## Tags and extra

`tags` keys come from the fixed `AllowedTag` enum (`feature`, `operation`, `component`,
`connectivity`, `foreground`, `retryCount`) with scalar values only. Anything else is a
protocol violation.

`extra` is free-form but heavily policed — forbidden key substrings, a key pattern, a
depth limit and per-value caps, all applied silently before send. See
`reference/privacy-and-limits.md` for the exact rules; the short version is that
`extra` is for small technical context, and a key containing `email`, `token`, `patient`,
`ecg` or similar is dropped without telling you.

## Privacy profiles

`regulatedStrict` is not a slider — it is a different event:

| | `privacyDefault` / `custom` | `regulatedStrict` |
|---|---|---|
| `exception.sanitizedMessage` | sanitized `error.toString()` | the exception **type** only |
| `extra` | sanitized | dropped entirely |
| `user` | filtered by `pii` | never sent |
| tags / breadcrumb data | strings redacted | strings redacted |
| offline store | any | must report `isEncrypted` — the config constructor throws otherwise |

Sanitization is regex-based redaction of emails, JWTs, `bearer`/`token`/`secret`/
`password`/`api_key`/`authorization` assignments, UUIDs, phone numbers, IPv4 addresses and
a set of health terms — built from the protocol's `PrivacyPatterns`, so it covers every
pattern the platform's firewall rejects an event over. It
runs on messages, tag strings, breadcrumb data and `extra` values in every profile, when
an event is built.

## Offline queue and flush

Implement `CrashOfflineStore` (`isEncrypted`, `write`, `readAndClear`) to survive process
death. The queue is capped at `maxPendingEvents` (default 50, max 200) and drops **oldest
first**. `flush()` merges the store into the in-memory queue, de-duplicates by
`eventId`, writes the queue back to the store, and sends from the front, stopping at the
first failure that may still succeed, so ordering is preserved (an event the platform
refuses for good is dropped and the flush goes on: `CrashTransport.send`); a process that dies during the send keeps the
stored events.

`run()` calls `flush()` once at start, so what an earlier run queued goes out. Call
`flush()` on app resume and after connectivity returns too. It is re-entrant-safe: a
second call while one is running skips what that one is still sending, so it never sends
an event twice.

## Feedback

Use `captureFeedback` when the *user* reports something — a "report a bug" or "send
feedback" action, a shake gesture, a button on an error screen. It is not an event: the
report goes to the platform's feedback triage, with a ticket for the reporter, and is
never deduplicated or filtered. Errors the app catches stay `captureException`.

Its types live in their own library, so they cannot clash with an app's own feedback
classes; import it where you mean them:

```dart
import 'package:noticebird/feedback.dart';

final crashTransport = CrashHttpTransport(publishableKey: 'noticebird_pk_…');

NoticebirdConfig(
  // …
  feedback: FeedbackConfig(
    transport: FeedbackHttpTransport.of(crashTransport), // its key, endpoint and client
    offlineStore: FileFeedbackOfflineStore(directory), // optional; not for regulatedStrict
    reporterAssertion: () => backend.feedbackAssertion(), // optional: a verified reporter
    requireVerified: false,                            // true: reject what is not verified
  ),
);

final outcome = await client.captureFeedback(
  kind: FeedbackKind.bug,                     // bug, idea, other
  message: text,                              // the user's words
  trigger: FeedbackTrigger.manual,            // optional: manual, shake, errorScreen, other
  screenshot: FeedbackScreenshot(bytes: png, contentType: FeedbackContentType.png),
  contactEmail: consented ? email : null,     // only with the user's consent
  diagnostics: {'sync': {'pending': 3, 'online': false}}, // content-free values only
  userContext: {'plan': 'pro'},               // what the app tells about its user
  relatedEventId: result.eventId,             // the crash it is about, from a CaptureResult
);
```

Without `NoticebirdConfig.feedback` it answers `FeedbackDisabled`. The client fills in the
app, platform, locale, session, route template, the `setUser` user and the newest 100
breadcrumbs (redacted as in an event; a report does not count them as sent).

| `FeedbackOutcome` | Meaning |
|---|---|
| `FeedbackDelivered(ticket, verified)` | The platform has it. Show `ticket.display` (such as `FB-12`) as it is; `ticket` is `null` when the answer named none, such as for a resent report the platform stored already but can no longer compare. |
| `FeedbackQueued(reportId)` | Not through yet; kept in the offline store for a later `flush()`. |
| `FeedbackDisabled` | No `NoticebirdConfig.feedback`. |
| `FeedbackRejected(reason, path, code)` | Never delivered. `reason` is a `FeedbackRejection`: `invalidInput`, `unverified`, `strictProject`, `clock`, `notAccepted`, `noStore`, `evicted`, `expired`, `refused`, `failed`. |

It never throws, by the prime directive. A value *you* passed that the report refuses —
a contact address, diagnostics, user context, a screenshot too large or not of its type, a
message left empty — throws `ArgumentError` in a **debug build only**, and is
`FeedbackRejected(invalidInput, path)` in release. Check a form's input first with
`FeedbackContact.isValid(email)`; `FeedbackUserContext.check(values)` and
`FeedbackDiagnostics.build(groups)` throw a `ProtocolException` with the path of the value
they refuse.

**The reporter assertion** is a signed token from your backend that lets the platform show
the reporter as verified. The provider is called once per report, at capture, with a
5-second timeout; a provider that throws, answers `null` or is late leaves the report
unverified. A refusal by the platform is not retried: the report goes on unverified, or
under `requireVerified` is `FeedbackRejected(unverified)`.

**The queue.** With an `offlineStore`, a report that does not get through is
`FeedbackQueued`; without one it is `FeedbackRejected(noStore)`. `flush()` (which `run()`
calls at start) sends what is due after the platform's `Retry-After` or a backoff of
30 s … 6 h, kept across restarts. The client bounds the store (10 reports, 20 MiB, the
oldest `evicted` first; `expired` after 7 days). Each kept report's end arrives on
`client.feedbackDeliveries` as a `FeedbackSettled(reportId, outcome)` — a broadcast
stream, so listen before you flush — and `await client.pendingFeedbackCount` says how many
wait. `FileFeedbackOfflineStore(directory)` stores files unencrypted in a directory of its
own; on the web its calls throw, so it keeps nothing. Under `regulatedStrict` the store must be an encrypted
`FeedbackOfflineStore` of your own, or the config throws.

**Privacy.**

- The message is redacted on the device like an exception message, and cut to 4000
  characters.
- `userContext` is checked for its shape only and sent as given: the platform drops the
  credential and health values it may not keep. Still send only what you mean to.
- Under `regulatedStrict` no `user`, no `userContext` and no locale are sent.
- `contactEmail` is the user's consent to be contacted: pass it only when they gave it.
- `diagnostics` are content-free: booleans, numbers, timestamps, UUIDs and short tokens,
  never free text, and never shortened.

The exact limits are in `reference/privacy-and-limits.md`.

## Bloc integration

`ProtocolNoticebirdBlocObserver` turns every bloc event and state change into a
breadcrumb and reports `onError` as `handled: true` — the bloc caught it into an error
state, so by definition it did not crash the app. The capture goes through
`shouldCapture`, so an error the host reports elsewhere is not reported here again.

```dart
Bloc.observer = ProtocolNoticebirdBlocObserver(client);
```

A bloc reports a caught error through `addError`, never with `captureException` beside
the observer — that is a second path, and it skips the bloc's tag. When the failure
deserves more than the default (`CrashSeverity.error`, tagged with the bloc), wrap it:

```dart
addError(
  BlocErrorReport(
    error,
    severity: CrashSeverity.warning,
    tags: const {AllowedTag.operation: 'sync.pull'},
    extra: {'pending': pending},
  ),
  stack,
);
```

The observer captures the cause, so the event groups as the error itself and the filter
judges the cause. A host with an observer of its own calls
`client.captureBlocError(bloc, error, stack)` from its `onError`, so both read a report
the same way.

Note the cost: every event **and** every state change writes a breadcrumb, so a chatty
bloc can push the 50 breadcrumbs an event carries over before the actual crash. Keep
`maxBreadcrumbs` at the default and do not add manual `bloc.*` breadcrumbs on top.

## Live debug sessions

`startLiveDebugSession(sessionId:, expiresAt:)` bypasses deduplication and
streams every `addBreadcrumb` immediately as a synthetic event, so support can watch a session without
waiting for a crash. Eligibility, tokens and TTL policy are the host app's problem — the
client only tracks whether a session is active until `expiresAt`, and expires it lazily on
the next check. It ends on `stopLiveDebugSession()`.

This multiplies traffic. Never leave it on by default.

## Native crashes

`noticebird` stays pure Dart and defines the seam; `noticebird_native` collects.

```dart
NoticebirdConfig(
  // …
  nativeCrashes: NativeCrashCapture(), // hangs, diskWrites, includeDebugBuilds: all false
);
```

- **Delivery is explicit.** `run()` calls `reportNativeCrashes()`. A host with its own
  bootstrap calls `Noticebird.reportNativeCrashes()` from its **UI start only** —
  never from a headless background engine. Every engine with a collector records its run;
  only the one that asks delivers. The SDK does not guess which engine shows UI.
- **Nothing runs while the app dies** except the Android JVM handler, which chains. The OS
  keeps the report; the next launch reads it.
- **The event is the crashed run's**: its app, platform, session, route and trail from the
  run ledger, never the current run's. Unmatched build → dropped. Debug-build runs →
  dropped unless `includeDebugBuilds`.
- **One crash, one event**: the event id derives from the report; a resend is a replay.
  Native reports skip the deduplication window, are capped at 10 per batch, leave the live
  trail alone, and `shouldCapture` sees the `NativeCrashRecord`.
- **Coverage**: iOS 15+ (not OOM kills, not crash-on-launch loops); Android API 30+ for
  native crashes, ANRs and foreground low-memory kills, JVM crashes on every level; inert
  on web and desktop.
- Consumers declare "Crash Data" (App Store) and "Crash logs" (Play Data safety).

## Testing

A fake transport gets each event as the client wrote it — its canonical JSON, validated
when the event was built, so an event the protocol refuses is `dropped` before it gets
there — and decodes it to assert on its fields:

```dart
final class FakeTransport implements CrashTransport {
  final sent = <Map<String, dynamic>>[];
  @override
  Future<void> send(String eventJson) async {
    sent.add(jsonDecode(eventJson) as Map<String, dynamic>);
  }
}
```

A `flush()` sends a stored event as the same text. Inject `clock` and `eventIdFactory` for
deterministic assertions on deduplication windows and event ids.

Feedback: implement `FeedbackTransport` (`requestSlot`, `upload`, `submit`). `submit` gets
the report as `FeedbackReport.toJsonString` wrote it, validated already; `jsonDecode` it to
assert on its fields, and answer `FeedbackAccepted(verified: false, …)`, or a
`FeedbackTransient` to see a report queued.

Native capture: implement `NativeCrashCollector` with a fake that emits
`NativeCrashBatch`es (records plus the run ledger) and assert what the transport receives.

Run `dart test` in `packages/noticebird_protocol`, `flutter test` in
`packages/noticebird`, `packages/noticebird/example`,
`packages/noticebird_native` and its `example`; `swift test` in
`packages/noticebird_native/ios/noticebird_native/NativeCrashNormalizer`; and
`./gradlew :noticebird_native:testDebugUnitTest` in
`packages/noticebird_native/example/android`.

## Pitfalls

| Symptom | Cause |
|---|---|
| A capture comes back `ignored` | `shouldCapture` declined it — the error is reported at the host's own report point, which captures with `filtered: false`. |
| The same failure arrives twice | No `shouldCapture` declines the type the host reports elsewhere, so a channel (observer, handler, explicit capture) reports it again. |
| Every event is `dropped` | `app`/`platform` metadata violates the protocol, or `sessionIdFactory` returns something outside `^[A-Za-z0-9_-]{16,64}$`. |
| Nothing sends, no error | No client attached to the facade — every `Noticebird.*` call is a silent no-op. |
| Stack trace is `<no-app-frames>` | Only app frames are kept — `package:` frames and, on the web, the frames of the compiled `<name>.dart.js` and its parts — and the trace held none, such as one from the engine or `canvaskit.js` alone. |
| A tag or `extra` key vanished | Not in `AllowedTag`, or caught by the forbidden-key list. |
| `setRouteTemplate` throws | A raw route with an id in it — pass the template. |
| Breadcrumbs missing from an event | A previous event carried them, or a chatty bloc observer pushed them out. |
| Config constructor throws | Deliberate: an unencrypted offline store under `regulatedStrict`, or a cap outside its range. |
| `captureFeedback` answers `FeedbackDisabled` | No `NoticebirdConfig.feedback`. |
| `FeedbackConfig` or `FeedbackKind` is not found | They are in `package:noticebird/feedback.dart`, not the main library. |
| Feedback is `FeedbackRejected(noStore)` offline | No `FeedbackConfig.offlineStore`, or on the web, where the calls of `FileFeedbackOfflineStore` throw. |
| Feedback is `FeedbackRejected(strictProject)` | The project is `regulatedStrict` and the client's config is not: configure the same profile. |
| Native crashes never arrive | Nobody calls `reportNativeCrashes()` (a host with its own bootstrap), it is a debug build without `includeDebugBuilds`, or the crash was on iOS 14 / below Android API 30 (JVM crashes excepted). |
| A native crash arrives with no trail | Under `regulatedStrict` none is persisted; otherwise the crash came within 500 ms of the last change, or before Dart started. |
