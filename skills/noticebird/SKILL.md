---
name: noticebird
description: >
  Use when integrating or changing crash reporting or user feedback in a Flutter app
  that depends on `noticebird_flutter` (or a Dart program on the `noticebird` client) —
  starting Noticebird, capturing errors, adding breadcrumbs, attaching identity or
  route context, the offline queues, a feedback sheet (bug report, idea, screenshot),
  bloc and navigation breadcrumbs, or native crashes.
  Reach for it for "set up Noticebird", "report this error", "why was my event
  dropped", "how do I add a breadcrumb", "attach the user to crashes", "Noticebird
  sends nothing", "capture a handled error", "test code that reports crashes", "send
  user feedback", "add a report-a-bug button", "attach a screenshot to feedback",
  "verified reporter", "my own zone", "my own bloc observer", "show what a report
  sends", "my own untraced marker", "reset Noticebird between tests".
  Triggers on: noticebird_flutter, NoticebirdFlutter, NoticebirdFlutter.start,
  reportZoneError, installErrorHandlers, observeBlocs, background start,
  apiUrl, hostedApiUrl, NoticebirdNavigatorObserver, NoticebirdBlocObserver, traces,
  UntracedBloc, MultiBlocObserver, reportedContext, ReportedContext, testing.dart,
  NoticebirdRecorder, RecordingCrashTransport, resetForTesting,
  BlocErrorReport, captureBlocError, NoticebirdClient, Noticebird, captureException,
  CaptureOutcome, CaptureResult, discarded, eventIdOf, captureFeedback,
  feedbackMoment, FeedbackMoment, feedback.dart, FeedbackConfig, FeedbackHttpTransport,
  FeedbackKind, FeedbackOutcome, FeedbackDelivered, FeedbackQueued, FeedbackRejected,
  FeedbackRejection, FeedbackContact, FeedbackUserContext, FeedbackDiagnostics,
  contextDiagnostics, reporterAssertion, requireVerified, onSettled, onFeedbackSettled,
  FeedbackSettled, FeedbackOfflineStore, FileFeedbackOfflineStore, pendingFeedbackCount,
  shouldCapture, filtered, hostPlatformMetadata, processSessionId,
  uploadCrashes, platformReadFailures, PlatformReadFailure, tracksRouteTemplate, addBreadcrumb, TypedBreadcrumb,
  BreadcrumbCategory, AllowedTag, setRouteTemplate, isRouteTemplate, setUser, setUserId,
  CrashPrivacyProfile, regulatedStrict, CrashHttpTransport, noticebird_pk_, crash_pk_,
  CrashOfflineStore, FileCrashOfflineStore, flush, close, noticebird_native,
  NativeCrashCapture, nativeCrashes, reportNativeCrashes, NativeCrashCollector,
  NativeCrashRecord, MetricKit, ApplicationExitInfo, native crash, ANR, watchdog.
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
  its `outcome`, do not wrap the call in a `try`. `captureFeedback` answers a
  `FeedbackOutcome`.
- The start never fails on the platform: a plugin that throws or does not answer is done
  without. A missing or malformed key starts a client that uploads nothing (a debug
  build prints why). An argument no start can work with — an `appName` the protocol
  refuses, a cap out of range, an unencrypted store under `regulatedStrict` — throws an
  `ArgumentError` at the start, so an invalid setup fails at bootstrap rather than
  silently dropping every event later.
- The deliberate exceptions throw **in debug builds only**, to surface an integration
  mistake while you are looking: a raw route in `setRouteTemplate` or `feedbackMoment`,
  and a value `captureFeedback` refuses (an empty message, a contact address, a user
  context, a related event id). Release builds drop the value or reject the report.

## Four packages

| Package | Depend on it when |
|---|---|
| `noticebird_flutter` | You are a Flutter app. This is the normal case: one start wires everything. |
| `noticebird_native` | You also want native crashes, watchdog and ANR kills (iOS MetricKit, Android `ApplicationExitInfo`). An add-on with native code; see *Native crashes*. |
| `noticebird` | You are a Dart program outside Flutter: the pure-Dart client the start makes. `noticebird_flutter` re-exports it. |
| `noticebird_protocol` | You build the wire format yourself (a tool, or a client of your own). `noticebird` re-exports it. |

The four are versioned together: the repository tag `v<version>` tracks them.

## Bootstrap

Start first — before auth, DI, or any other service — so errors during the rest of
startup are already covered.

```dart
import 'package:noticebird_flutter/noticebird_flutter.dart';

Future<void> main() async {
  await NoticebirdFlutter.start(
    apiUrl: CrashHttpTransport.hostedApiUrl, // the API's base; the SDK adds its routes
    publishableKey: const String.fromEnvironment('NOTICEBIRD_KEY'),
    appName: 'myapp',                   // version and build come from the platform
    shouldCapture: (error) => error is! ReportedElsewhere, // optional
    nativeCrashes: NativeCrashCapture(), // optional, noticebird_native
  );
  runApp(const MyApp());
}

// The navigator that holds the app's pages: breadcrumbs, and the screen's route.
MaterialApp(navigatorObservers: [NoticebirdNavigatorObserver(tracksRouteTemplate: true)]);
```

The packages are not on pub.dev: the app depends on `noticebird_flutter` (and
`noticebird_native`) from the repository at the release's tag, with `noticebird` and
`noticebird_protocol` at the same tag as `dependency_overrides` — the YAML is in the
repository's `docs/integration.md`, §1 "Depend on the SDK".

The start makes the client and attaches it to the `Noticebird` facade, installs
`FlutterError.onError` and `PlatformDispatcher.onError` (each chained to the one it
replaces), sets `Bloc.observer`, fills each feedback report's locale and `blocs`
diagnostics group, keeps unsent events and reports in the support directory, and sends
what waits at start, on resume and when the connection returns. A second `start` answers
the first. It answers a `NoticebirdFlutter`: its `client`, its `blocObserver`, its
`platformReadFailures` (each `PlatformReadFailure` a read it went on without —
`packageInfo` or `supportDirectory` — with its `error` and `stackTrace`, for a host that
reports them), and `close()`, which puts back what it installed (each only while it is
still the start's) and detaches the client; the host's `httpClient` stays open. Do not use
the old `client` after `close()`: a later start makes its own, on the same stores.

`apiUrl` is the API's base (`CrashHttpTransport.hostedApiUrl`, or a staging,
self-hosted or proxied one with its path prefix), never a route: the SDK adds
`/v1/envelope` and the feedback routes itself, and refuses a URL that ends in
`/v1/envelope`. Without both an `apiUrl` and a `publishableKey` (absent, empty — a missing
`--dart-define` — or one that cannot work) the client uploads nothing and sends no
feedback; the SDK never picks an API by itself.

The other options: `httpClient` (the host's HTTP stack),
`uploadCrashes: false` (crash events `discarded`, feedback still sent), `privacyProfile`,
`pii`, `breadcrumbBuffer`, `reporterAssertion`, `requireVerified`, `onFeedbackSettled`,
`crashStore` and `feedbackStore` (your own stores), `installErrorHandlers`, `observeBlocs`,
`blocObserver` (a subclass of your own), `background`.

- **A zone of your own.** The start installs none; `PlatformDispatcher.onError` catches
  what nothing else does. A host with its own guarded zone starts inside it and passes
  `NoticebirdFlutter.reportZoneError` as its handler:
  `runZonedGuarded(() async { await NoticebirdFlutter.start(…); runApp(…); }, NoticebirdFlutter.reportZoneError)`.
- **Handlers you keep.** `installErrorHandlers: false` leaves `FlutterError.onError` and
  `PlatformDispatcher.onError` to the host, which reports from them with
  `Noticebird.captureException`.
- **A background engine** (a headless task) starts with the same arguments and
  `background: true`: it reports and records its run, but delivers nothing of earlier
  runs, flushes nothing by itself and keeps no store, so an event it cannot send is kept
  in memory only.

### The facade is a convenience, not the object

`NoticebirdClient` stays a plain constructor-injected instance so it is trivially
testable. `Noticebird` is a static facade over whichever client was `attach`ed (the
start attaches its own), so call sites can write `Noticebird.captureException(…)`
without resolving DI every time. Every facade member no-ops when nothing is attached —
before the start, or in tests that never attach. `Noticebird.instance` is the client
itself, for what the facade does not carry (`flush`, `close`).

## Capturing

```dart
final result = await noticebird.client.captureException(
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
repeats when `deduplicated`, `null` when nothing went (`dropped`, `ignored`, `discarded`,
or a repeat of a dropped event). `client.eventIdOf(error)` answers the same id later from
the error alone, once its capture settled — also for an error a global handler captured
without waiting; a later capture the filter ignores (the error rethrown after its report)
leaves it. Pass it as a feedback report's `relatedEventId`.

| `CaptureOutcome` | Meaning |
|---|---|
| `sent` | Delivered to the transport. Its breadcrumbs count as sent: the next event starts after them. |
| `deduplicated` | The same error already captured inside the deduplication window (default 1 minute): the same `groupingKey`, or without one the same exception type and top app frames, line numbers aside. |
| `queued` | Transport failed; the event sits in the retry queue for the next flush. |
| `dropped` | Could not be captured at all — protocol violation in config metadata, `maxPendingEvents: 0`, or the platform refused the event for good (see `CrashTransport.send`; a flush drops it too). |
| `ignored` | The host's `shouldCapture` declined the error. |
| `discarded` | Crash uploads are off (`uploadCrashes: false`, a key that cannot work, or a client built without a `transport`): no event was made. |

### One report per failure: one filter, one bypass

Deduplication recognises a repeat of the *same* capture. It cannot tell that a
repository's capture, a bloc observer's and a caller's are one failure — each carries a
different stack and often a different object — and the SDK does not try to.

When the host already reports some errors at a report point of its own — an error library
that reports at the conversion into its own error type, say — every other channel must
leave them alone. That is `shouldCapture`, the capture filter every crash SDK offers:
asked once per capture on **every** channel — an explicit `captureException`, the
`NoticebirdBlocObserver`, the handlers the start installs and `reportZoneError` — and
`false` drops the capture as `ignored`. The report point itself captures with
`filtered: false`:

```dart
await NoticebirdFlutter.start(
  // …
  shouldCapture: (error) => error is! MyDomainError, // reported at its conversion
);

// The host's one report point for those errors:
Noticebird.captureException(error, stack, handled: true, filtered: false);
```

Set it once and the stock observer and handlers need no type check of their own, and a
channel added later cannot report such an error twice. The live-debug sync is never
filtered; a filter that throws counts as `true`, so a failing filter never costs a report.
The SDK stays generic: the predicate is the host's, the SDK only asks it. A user's own
report is `captureFeedback` (*Feedback*), never an event.

Set `handled: true` for anything you caught and turned into an error state. Leave it
`false` only for errors that actually reached a global handler.

## Breadcrumbs

A bounded buffer of the newest breadcrumbs (`breadcrumbBuffer`; the start keeps the 100 a
feedback report's trail holds, at most 200). Each event carries the newest of those **no
sent event carried yet**, at most 50 (the protocol's `CrashEvent.maxBreadcrumbs`), each
value redacted (an id in a route or a bloc state becomes `[REDACTED]`) and shortened to
the protocol's 100 characters. A sent event does not empty the buffer; it only moves the
start of the next event's breadcrumbs past what it carried.

```dart
Noticebird.addBreadcrumb(TypedBreadcrumb(
  occurredAt: DateTime.now().toUtc(),
  category: BreadcrumbCategory.ui,           // fixed enum, never a free-form string
  action: 'checkout.confirm',                // must match ^[a-z][a-z0-9_.-]*$
  data: {AllowedTag.component: 'CheckoutPage'}, // AllowedTag keys, scalar values, max 8
));
```

Categories are `bloc`, `navigation`, `http`, `ui`, `auth`, `lifecycle`, `system`. There is
no escape hatch — an arbitrary category or a non-allowlisted tag key is rejected by the
protocol, which means the event is dropped, not truncated. Navigation and bloc
breadcrumbs come from the observers (*Route context*, *Bloc integration*); do not add
them by hand on top.

Call `clearBreadcrumbs()` on logout: the trail leading to the next event should not carry
the previous user's session.

`recentBreadcrumbs` gives a read-only snapshot of the whole buffer for host-app
diagnostics, such as an error dialog showing the trail. Values keep up to
`NoticebirdClient.maxBufferedTagValueLength` (1000) characters there, as recorded; only an
event or a report redacts and shortens them. Reading it sends nothing.

## Identity

Two ways in, and they are mutually exclusive per event:

- `setUserId(String?)` — the account id, sent as given in the protocol's shape: characters
  outside `[A-Za-z0-9_-]` are stripped and the result is cut to 100. A UUID or numeric id
  stays intact.
- `setUser(CrashUser?)` — explicit identity (`id`, `email`, `name`, `ipAddress`).

Sending identity is the host's choice, made once: `pii` (`CrashPiiConfig`) decides which
fields leave the device (`allowedFields`, or `enabled: false` for none), for both calls
alike — the SDK does not judge an id by its content. `regulatedStrict` drops identity
altogether. Who may *see* it is the platform's access control, not the SDK's. The user
set here is also whose reporter assertion the client holds (*Feedback*).

**Medical data and credentials never belong here** — not in identity, not in tags, not in
`extra`. The ingestion privacy firewall rejects them for every profile.

## Route context

Navigation becomes breadcrumbs with an observer on each navigator:

```dart
MaterialApp(navigatorObservers: [NoticebirdNavigatorObserver(tracksRouteTemplate: true)]);
GoRouter(observers: [NoticebirdNavigatorObserver(describe: (route) => …)], …);
```

It names a route by `describe` when the host gives one and it answers — the place for a
router's path pattern, which only the router knows — else by its `settings.name` when that
is a template (no query, fragment or id-like segment), else by its kind
(`MaterialPageRoute`). The rule is one of shape: a path of words (`/users/jdoe`) passes it,
so an app that pushes such names gives a `describe`.
What `describe` answers leaves the device: a template or a kind, never a value the user
typed.

The route events and reports carry is the client's route template. With
`tracksRouteTemplate: true` the observer keeps it on the topmost page of its navigator
(a `PageRoute`, past dialogs and sheets), so a feedback sheet opened over a screen leaves
the screen's template for the report; a page whose name is no template leaves none. It is off by default:
turn it on for one navigator, the one that holds the app's pages. Without it, the host
sets the route itself:

```dart
Noticebird.setRouteTemplate('/lists/:listId');   // template only
```

`NoticebirdClient.isRouteTemplate(route)` is the rule: it starts with `/`, has no query or
fragment, and no segment that looks like an id (16+ hex-ish characters, or 2+ digits). A
raw route throws in debug and is dropped in release. It is a rule of shape: a segment that
is a word (`/users/jdoe`) passes.

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
| offline stores | the start's, in the support directory | none by default; your own must report `isEncrypted`, or the start throws |

Sanitization is regex-based redaction of emails, JWTs, `bearer`/`token`/`secret`/
`password`/`api_key`/`authorization` assignments, UUIDs, phone numbers, IPv4 addresses and
a set of health terms — built from the protocol's `PrivacyPatterns`, so it covers every
pattern the platform's firewall rejects an event over. It runs on messages, tag strings,
breadcrumb data and `extra` values in every profile, when an event is built.

## Offline queues and flush

The start keeps an event that did not get through in a `FileCrashOfflineStore`, and a
feedback report in a `FileFeedbackOfflineStore`, both in the app's support directory —
unencrypted, so none under `regulatedStrict`, and none on the web or in a `background`
start. Without a store an event waits in memory only, and a feedback report is
`FeedbackRejected(noStore)`. Pass `crashStore` and `feedbackStore` to use your own (an
encrypted one under `regulatedStrict`).

The queue is capped at 50 events and drops **oldest first**. A flush merges the store into
the in-memory queue, de-duplicates by `eventId`, and sends from the front, stopping at the
first failure that may still succeed, so ordering is preserved (an event the platform
refuses for good is dropped and the flush goes on: `CrashTransport.send`).

**You do not flush.** The start flushes at start, on resume and when the connection
returns, and the client drains a kept feedback report by itself when it is due. A flush
asked while one runs runs again after it, so none is lost and no event is sent twice.
While crash uploads are off, the stored queue is kept for a build that uploads.

A store of your own implements `CrashOfflineStore`: `isEncrypted`, `write` (replace what
it holds) and `read` (what the last `write` left, kept). The client calls one method at a
time and writes the queue back right after each `read`, so a process that ends in between
loses nothing.

## Feedback

Use `captureFeedback` when the *user* reports something — a "report a bug" or "send
feedback" action, a shake gesture, a button on an error screen. It is not an event: the
report goes to the platform's feedback triage, with a ticket for the reporter, and is
never deduplicated or filtered. Errors the app catches stay `captureException`.

The sheet is the app's own; the SDK has no widgets. Its types live in their own library,
so they cannot clash with an app's own feedback classes; import it where you mean them.
Take the **moment** when the sheet opens — the route template, the context diagnostics
(the live blocs), your own diagnostics and when — so the report is about the screen and
the state the user was in, not the sheet, and send it with the report:

```dart
import 'package:noticebird_flutter/feedback.dart';

// initState of the sheet:
_moment = Noticebird.feedbackMoment(
  diagnostics: {'sync': {'pending': 3, 'online': false}}, // content-free values only
);

// On send:
final outcome = await Noticebird.captureFeedback(
  kind: FeedbackKind.bug,                     // bug, idea, other
  message: text,                              // the user's words
  moment: _moment,                            // without one, taken now
  trigger: FeedbackTrigger.manual,            // optional: manual, shake, errorScreen, other
  screenshot: pngBytes,                       // optional: PNG, JPEG or WebP bytes
  contactEmail: consented ? email : null,     // only with the user's consent
  userContext: {'plan': 'pro'},               // what the app tells about its user
  relatedEventId: eventId,                    // the crash it is about
);
```

The sheet's bloc or cubit implements `UntracedBloc`, so the user's typing leaves no
breadcrumbs and does not push out the steps that led to the report: the trail is taken at
the capture. `relatedEventId` is a `CaptureResult.eventId`, or
`await Noticebird.eventIdOf(error)` for the error an error screen shows.
`Noticebird.reportedContext` answers the app, the platform (operating system, its
version, the device class) and the locale as a report sent now carries them: show those in
the sheet's "what is sent" disclosure rather than reading your own copy. No device model
leaves the device.

The client fills in the app, platform, locale, session, the `setUser` user and the newest
breadcrumbs (redacted as in an event; a report does not count them as sent). The moment's
route is checked where the report is built, by `isRouteTemplate`, and redacted as
`setRouteTemplate`'s is: a raw route given to `feedbackMoment(routeTemplate:)` throws in a
debug build and is left out in release. `FeedbackDisabled` comes from a start without an
API URL or a usable key, a client without a `FeedbackConfig` or one without a
`transport`, and the facade while no client is attached.

| `FeedbackOutcome` | Meaning |
|---|---|
| `FeedbackDelivered(ticket, verified)` | The platform has it. Show `ticket.display` (such as `FB-12`) as it is; `ticket` is `null` when the answer named none, such as for a resent report the platform stored already but can no longer compare. |
| `FeedbackQueued(reportId)` | Not through yet; kept in the store and sent when due. |
| `FeedbackDisabled` | No client attached, no feedback config, or one without a transport (no API URL or no usable key). |
| `FeedbackRejected(reason, path, code)` | Never delivered. `reason` is a `FeedbackRejection`: `invalidInput`, `unverified`, `strictProject`, `clock`, `notAccepted`, `noStore`, `evicted`, `expired`, `refused`, `failed`. |

**Sanitised, never refused.** The `screenshot` and the moment's `diagnostics` never cost
the report: a screenshot of no known type or too large, and a diagnostics key, value, group
or size the report does not take, is left out, and the report says so in the client's own
diagnostics group `noticebird` (`dropped_values`, `screenshot_dropped`, and
`moment_taken_at` for a moment passed in and taken before the capture); a debug build
prints it. Do not name a group `noticebird`, or after a context group (`blocs`): it is left
out. An enum goes as its name, a `DateTime` in UTC. What *is* refused — an empty message, a
contact address, a user context, a related event id — throws `ArgumentError` in a **debug
build only**, and is `FeedbackRejected(invalidInput, path)` in release. Check a form's
input first with `FeedbackContact.isValid(email)` and `FeedbackUserContext.check(values)`.

**The reporter assertion** is a signed token from your backend that lets the platform show
the reporter as verified: pass `reporterAssertion` to the start. The client holds one per
user (`setUser` / `setUserId`) until 5 minutes before its `exp`, and reports captured at
once share one call; it asks again for another user, after `setUser(null)`, and after the
platform refused the one it held. Without a user it asks for every report. A provider that
throws, answers `null` or is late (5 seconds) leaves the report unverified; with
`requireVerified` such a report is `FeedbackRejected(unverified)`.

**The queue.** A report that does not get through is `FeedbackQueued` and sent when due —
after the platform's `Retry-After` or a backoff, kept across restarts — by the client
itself. Each kept report's end goes to `onFeedbackSettled` as a
`FeedbackSettled(reportId, outcome)` (without it, a debug build prints a rejected one);
`await Noticebird.pendingFeedbackCount` says how many wait.

**Privacy.**

- The message is redacted on the device like an exception message.
- `userContext` is checked for its shape only and sent as given: the platform drops the
  credential and health values it may not keep. Still send only what you mean to.
- Under `regulatedStrict` no `user`, no `userContext` and no locale are sent; the reporter
  assertion, when one is configured, is the one identity such a report carries.
- `contactEmail` is the user's consent to be contacted: pass it only when they gave it.
- `diagnostics` are content-free: booleans, numbers, timestamps, UUIDs and short tokens,
  never free text.

The exact limits are in `reference/privacy-and-limits.md`.

## Bloc integration

The start sets `Bloc.observer` to bloc's `MultiBlocObserver` of its
`NoticebirdBlocObserver` and the observer it found. It turns every bloc event and state
change into a breadcrumb named by runtime types (never content), captures a bloc's
`addError` as `handled: true`, and counts the live blocs per type for each feedback report's `blocs`
group. The capture goes through `shouldCapture`, so an error the host reports elsewhere
is not reported here again. An error thrown in a bloc's event handler reaches `onError`
too, and bloc rethrows it after: the platform handler's later capture of it is
deduplicated against the handled one.

A host with an observer of its own sets it after the start, beside the SDK's:

```dart
final noticebird = await NoticebirdFlutter.start(…);
Bloc.observer = MultiBlocObserver(
  observers: [noticebird.blocObserver, MyObserver()],
);
```

A subclass of `NoticebirdBlocObserver` that names its steps in more detail
(`describeEvent`, `describeChange`, `describeState`) is passed as `blocObserver:`; the
start sets and counts that one. `observeBlocs: false` leaves `Bloc.observer` to the host
entirely; reports then go without the `blocs` group. A bloc that implements `UntracedBloc` leaves no breadcrumbs (its errors
are still captured, and it is still counted): use it for a bloc that changes with every
keystroke, such as a feedback sheet's. The observer asks `traces(bloc)`: a subclass with
an untraced marker of its own overrides it (`super.traces(bloc) && bloc is! MyUntraced`)
rather than `onEvent`/`onChange`.

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
judges the cause. A host that starts with `observeBlocs: false` and reports bloc errors
from an observer of its own calls `client.captureBlocError(bloc, error, stack)` there, so
a report reads the same either way.

Note the cost: every event **and** every state change writes a breadcrumb, so a chatty
bloc can push the 50 breadcrumbs an event carries over before the actual crash. Make such
a bloc an `UntracedBloc`, and do not add manual `bloc.*` breadcrumbs on top.

## Live debug sessions

`startLiveDebugSession(sessionId:, expiresAt:)` bypasses deduplication and
streams every `addBreadcrumb` immediately as a synthetic event, so support can watch a session without
waiting for a crash. Eligibility, tokens and TTL policy are the host app's problem — the
client only tracks whether a session is active until `expiresAt`, and expires it lazily on
the next check. It ends on `stopLiveDebugSession()`.

This multiplies traffic. Never leave it on by default.

## Native crashes

`noticebird` defines the seam; `noticebird_native` collects.

```dart
await NoticebirdFlutter.start(
  // …
  nativeCrashes: NativeCrashCapture(), // hangs, diskWrites, includeDebugBuilds: all false
);
```

- **The start delivers.** It runs in the engine that shows the UI and delivers the
  reports of earlier runs; a `background: true` start only records its run — a headless
  engine may have seconds to live. Pass `nativeCrashes` to every engine's start: each
  records its run, only the UI start delivers. A host that builds its client itself calls
  `Noticebird.reportNativeCrashes()` from its **UI start only**.
- **Nothing runs while the app dies** except the Android JVM handler, which chains. The OS
  keeps the report; the next launch reads it.
- **The event is the crashed run's**: its app, platform, session, route and trail from the
  run ledger, never the current run's. Unmatched build → dropped. Debug-build runs →
  dropped unless `includeDebugBuilds`.
- **One crash, one event**: the event id derives from the report; a resend is a replay.
  Native reports skip the deduplication window, are capped at 10 per batch, leave the live
  trail alone, and `shouldCapture` sees the `NativeCrashRecord`. While crash uploads are
  off, no report is claimed, so a build that uploads still sends them.
- **Coverage**: iOS 15+ (not OOM kills, not crash-on-launch loops); Android API 30+ for
  native crashes, ANRs and foreground low-memory kills, JVM crashes on every level; inert
  on web and desktop.
- Consumers declare "Crash Data" (App Store) and "Crash logs" (Play Data safety).

## Testing

Test support is in `package:noticebird_flutter/testing.dart` (`package:noticebird/testing.dart`
outside Flutter). `NoticebirdRecorder` is a real client whose events are recorded instead
of sent: built, sanitized and checked as in the app, without a network, and without
deduplication, so a report made twice shows as two. Hand its `client` to what the test
pumps — `NoticebirdBlocObserver(client: …)` (or the app's subclass) as `Bloc.observer`,
`NoticebirdNavigatorObserver(client: …)` in the navigator, the app's own adapter — or
`attach()` it to the facade, so code that calls `Noticebird.*` reports to it.

```dart
import 'package:noticebird_flutter/testing.dart';

final recorder = NoticebirdRecorder(shouldCapture: myCaptureFilter)..attach();
addTearDown(recorder.close);                 // closes it and detaches it from the facade
Bloc.observer = NoticebirdBlocObserver(client: recorder.client);

cubit.addError(StateError('boom'));
expect(recorder.events.single['handled'], isTrue); // the event as the platform receives it
expect(await recorder.eventOf(error), isNotNull);  // by eventIdOf
```

An event reaches the recorder while its capture runs. Its `transport`, a
`RecordingCrashTransport` (`sent`: the canonical JSON; `events`: decoded), goes into a
`NoticebirdClient` a test builds itself when it needs another config: a `FeedbackConfig`
with a fake feedback transport, `clock` and `eventIdFactory` for deterministic ids and
deduplication windows, or no transport at all (captures `discarded`).

A test that calls `NoticebirdFlutter.start` ends with
`await NoticebirdFlutter.resetForTesting()`, which closes it (a start still under way
included) so the next one starts anew; `Noticebird.detach()` resets the facade.

Feedback: implement `FeedbackTransport` (`requestSlot`, `upload`, `submit`). `submit` gets
the report as `FeedbackReport.toJsonString` wrote it, validated already; `jsonDecode` it to
assert on its fields, and answer `FeedbackAccepted(verified: false, …)`, or a
`FeedbackTransient` to see a report queued.

Native capture: implement `NativeCrashCollector` with a fake that emits
`NativeCrashBatch`es (records plus the run ledger), pass it as the config's
`nativeCrashes`, and assert what the transport receives.

## Pitfalls

| Symptom | Cause |
|---|---|
| Every capture is `discarded`, and feedback is `FeedbackDisabled` | The start got no `apiUrl` or no usable key — a missing `--dart-define`, a secret `_sk_` key, or an `apiUrl` that names `/v1/envelope`. A debug build printed why. |
| A capture comes back `ignored` | `shouldCapture` declined it — the error is reported at the host's own report point, which captures with `filtered: false`. |
| The same failure arrives twice | No `shouldCapture` declines the type the host reports elsewhere, so a channel (observer, handler, explicit capture) reports it again. |
| Every event is `dropped` | `app`/`platform` metadata violates the protocol, or a client's `sessionIdFactory` returns something outside `^[A-Za-z0-9_-]{16,64}$`. |
| Nothing sends, no error | No client attached to the facade — every `Noticebird.*` call is a silent no-op until the start. |
| My own `Bloc.observer` lost the breadcrumbs | It replaced the start's: compose with `MultiBlocObserver(observers: [noticebird.blocObserver, mine])`. |
| A route shows as `MaterialPageRoute` | Its name is a raw path or none: give the observer a `describe`, or name routes by their template. |
| A feedback report names the sheet's route, or the trail is full of typing | The moment was taken at send rather than when the sheet opened; the sheet's bloc is not an `UntracedBloc`. |
| Stack trace is `<no-app-frames>` | Only app frames are kept — `package:` frames and, on the web, the frames of the compiled `<name>.dart.js` and its parts — and the trace held none, such as one from the engine or `canvaskit.js` alone. |
| A tag or `extra` key vanished | Not in `AllowedTag`, or caught by the forbidden-key list. |
| `setRouteTemplate` throws | A raw route with an id, a query or a fragment in it — pass the template. |
| Breadcrumbs missing from an event | A previous event carried them, or a chatty bloc pushed them out (make it an `UntracedBloc`). |
| The start throws | Deliberate: an unencrypted store under `regulatedStrict`, an `appName` the protocol refuses, or a cap outside its range. |
| A report's diagnostics or screenshot are missing | Left out by the sanitising; its `noticebird` group says what (`dropped_values`, `screenshot_dropped`). |
| `FeedbackConfig` or `FeedbackKind` is not found | They are in `package:noticebird_flutter/feedback.dart`, not the main library. |
| Feedback is `FeedbackRejected(noStore)` offline | No feedback store: on the web, under `regulatedStrict` or in a `background` start without one of your own. |
| Feedback is `FeedbackRejected(strictProject)` | The project is `regulatedStrict` and the client's config is not: configure the same profile. |
| Native crashes never arrive | No `nativeCrashes` at the UI start (or a client built without the start that never calls `reportNativeCrashes()`), crash uploads are off, it is a debug build without `includeDebugBuilds`, or the crash was on iOS 14 / below Android API 30 (JVM crashes excepted). |
| A native crash arrives with no trail | Under `regulatedStrict` none is persisted; otherwise the crash came within 500 ms of the last change, or before Dart started. |
