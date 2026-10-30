# Integrating Noticebird

This guide covers a full consumer integration of a Flutter app. For the
shortest possible wiring, see the `noticebird_flutter` README; for a runnable
app, see `packages/noticebird_flutter/example`.

## 1. Depend on the SDK

A Flutter app depends on `noticebird_flutter`; the client (`noticebird`) and
the protocol package come with it, and it re-exports both.

The packages are not on pub.dev: an app takes them from the repository, at the
release's tag. A git package's own dependencies are resolved from pub.dev, so
the app also names `noticebird` and `noticebird_protocol` at the same tag, as
`dependency_overrides`:

```yaml
dependencies:
  noticebird_flutter:
    git:
      url: https://github.com/noticebird/noticebird-dart.git
      ref: v0.5.0
      path: packages/noticebird_flutter
  noticebird_native: # only for native crashes, §11
    git:
      url: https://github.com/noticebird/noticebird-dart.git
      ref: v0.5.0
      path: packages/noticebird_native

dependency_overrides:
  noticebird:
    git:
      url: https://github.com/noticebird/noticebird-dart.git
      ref: v0.5.0
      path: packages/noticebird
  noticebird_protocol:
    git:
      url: https://github.com/noticebird/noticebird-dart.git
      ref: v0.5.0
      path: packages/noticebird_protocol
```

Move every `ref` together: the four packages are released as one version.

Native crash capture is a separate add-on package, `noticebird_native`
(§11); a consumer that does not add it carries no native code. A program
outside Flutter uses the pure-Dart client `noticebird` on its own (§12).

## 2. Start

Start Noticebird first, before auth, DI or any other service, so errors
during the rest of startup are already covered:

```dart
import 'package:noticebird_flutter/noticebird_flutter.dart';

Future<void> main() async {
  await NoticebirdFlutter.start(
    apiUrl: CrashHttpTransport.hostedApiUrl,
    publishableKey: const String.fromEnvironment('NOTICEBIRD_KEY'),
    appName: 'my_app',
  );
  runApp(const MyApp());
}

// The app's navigator: navigation breadcrumbs and the screen's route (§3).
MaterialApp(
  navigatorObservers: [NoticebirdNavigatorObserver(tracksRouteTemplate: true)],
);
```

The start:

- makes the client and attaches it to the `Noticebird` facade, so the app
  reports from anywhere (`Noticebird.captureException(…)`); every facade call
  is a no-op while no client is attached;
- names the app `appName`, with the version and build the platform reports,
  and fills each feedback report's locale with the platform's;
- installs the global error handlers and sets `Bloc.observer` (§3);
- keeps what does not get through in the app's support directory
  (`noticebird/crashes`, `noticebird/feedback`), and sends what waits at
  start, each time the app comes back to the foreground, and when the
  connection returns (§8);
- delivers the native crash reports of earlier runs with `nativeCrashes`
  (§11).

It never fails on the platform and never hangs: a plugin read that throws or
does not answer within `NoticebirdFlutter.platformReadTimeout` is done
without (the version is then `unknown`, there is no default store or no
connection trigger). It throws an `ArgumentError` only for an argument no
start can work with: an `appName` the protocol refuses, a `breadcrumbBuffer`
out of range, an unencrypted store under `regulatedStrict`. A second `start`,
also one made while the first is starting, answers the first.

`platformReadFailures` lists the reads the start went on without, each a
`PlatformReadFailure` with its `read` (`packageInfo` or `supportDirectory`),
`error` and `stackTrace` (a `TimeoutException` when it did not answer), for a
host that reports what its start did without:

```dart
final noticebird = await NoticebirdFlutter.start(…);
for (final failure in noticebird.platformReadFailures) {
  Noticebird.captureException(failure.error, failure.stackTrace,
      handled: true, tags: {AllowedTag.operation: 'start.${failure.read}'});
}
```

### The API and the key

- `apiUrl` is the API's base: `CrashHttpTransport.hostedApiUrl`
  (`https://api.noticebird.com`), or a local, staging, self-hosted or proxied
  one, a path prefix included (`https://example.com/noticebird`). The SDK
  adds its routes itself — `/v1/envelope` for crash events, the feedback
  routes for feedback — so the URL never names a route: one that ends in
  `/v1`, `/v1/envelope` or `/v1/feedback`, or carries credentials, is
  refused. The SDK never picks an API by itself.
- `publishableKey` must be a publishable key, `<prefix>_pk_<token>`
  (Noticebird issues `noticebird_pk_…` keys); anything else, a secret
  `…_sk_…` key included, is refused.
- Without both an `apiUrl` and a `publishableKey` — either absent or empty,
  as from a missing `--dart-define`, or one that cannot work — the start
  makes a client that uploads nothing and sends no feedback; a debug build
  prints why. The key goes out as
  `Authorization: Bearer <key>`. The project, environment and privacy
  profile are derived server-side from the key and are never trusted from the
  event payload.
- `httpClient` sends over the host's own HTTP stack.
- `uploadCrashes: false` makes a build that uploads no crash events but still
  keeps the breadcrumb trail, the user and the route, and still sends
  feedback: a capture is then `discarded`.

### The start's options

| Option | Default | Notes |
|---|---|---|
| `privacyProfile` | `privacyDefault` | §9. |
| `pii` | all identity fields | §5. |
| `shouldCapture` | none (capture everything) | The capture filter every channel asks; §4. |
| `breadcrumbBuffer` | 100 | The breadcrumbs kept in memory (50–200): the trail of a feedback report. |
| `nativeCrashes` | none (off) | `NativeCrashCapture()` from `noticebird_native`; §11. |
| `reporterAssertion`, `requireVerified`, `onFeedbackSettled` | none, `false`, none | §6. |
| `crashStore`, `feedbackStore` | in the support directory | The host's own stores; §8. |
| `installErrorHandlers`, `observeBlocs`, `blocObserver` | `true`, `true`, a plain observer | §3. |
| `background` | `false` | A headless engine's start; below. |

`start` answers a `NoticebirdFlutter`: its `client`, its `blocObserver`, its
`platformReadFailures`, and `close()`, which puts back the handlers and the
bloc observer it installed (each only while it is still the start's), stops
its triggers and detaches the client. The HTTP client of `httpClient` stays
the host's. A later `start` starts anew, with a client of its own on the same
stores: do not use the old `client` after `close()`.

### A background engine

A headless engine (a background task) starts with the same arguments and
`background: true`. Its client reports and records its run for native
crashes, but delivers nothing of earlier runs, flushes nothing by itself and
keeps no store, since two engines must not share one: an event it cannot send
is kept in memory only.

## 3. Error handlers, zones, blocs and navigation

The start installs `FlutterError.onError` (an error the framework caught,
tagged with its library) and `PlatformDispatcher.onError` (an error nothing
caught, fatal), each chained to the handler it replaces. Without a previous
`PlatformDispatcher` handler, the error is printed and handled, so it cannot
take down the app.

The start installs no zone: `PlatformDispatcher.onError` catches what nothing
else does. A host that runs its app in a guarded zone of its own starts
inside it and reports from its handler with `reportZoneError`:

```dart
runZonedGuarded(() async {
  await NoticebirdFlutter.start(apiUrl: api, publishableKey: key, appName: 'my_app');
  runApp(const MyApp());
}, NoticebirdFlutter.reportZoneError);
```

A host whose own handlers stay in place passes `installErrorHandlers: false`
and reports from them with `Noticebird.captureException`.

### Blocs

The start sets `Bloc.observer` to bloc's `MultiBlocObserver` of its
`NoticebirdBlocObserver` and the observer it found. A host that sets an
observer after the start keeps the SDK's beside it:

```dart
final noticebird = await NoticebirdFlutter.start(…);
Bloc.observer = MultiBlocObserver(
  observers: [noticebird.blocObserver, MyObserver()],
);
```

Each bloc event and state change becomes a breadcrumb named by the bloc's and
the step's runtime type, never their content. A bloc that implements
`UntracedBloc` leaves none — a feedback sheet's, so the user's typing does not
push out the steps that led to the report (§6). The observer asks
`traces(bloc)`; a host with an untraced marker of its own overrides it in its
subclass (`super.traces(bloc) && bloc is! MyUntraced`), and that bloc's
errors are still captured. A bloc's `addError` is
captured as handled, tagged with the bloc; a bloc that knows more wraps the
error:

```dart
addError(
  BlocErrorReport(
    error,
    severity: CrashSeverity.warning,
    tags: const {AllowedTag.operation: 'sync.pull'},
  ),
  stack,
);
```

The observer also counts the live blocs per type, for each feedback report's
`blocs` diagnostics group. A subclass of `NoticebirdBlocObserver` that names
its steps in more detail (`describeEvent`, `describeChange`, `describeState`)
is passed as `blocObserver:`, and the start sets and counts that one.
`observeBlocs: false` leaves `Bloc.observer` to the host, and reports go
without that group.

### Navigation

```dart
MaterialApp(
  navigatorObservers: [NoticebirdNavigatorObserver(tracksRouteTemplate: true)],
);
```

Each navigator needs its own observer (a router's `observers`). With
`tracksRouteTemplate: true` the observer also keeps the client's route
template (`setRouteTemplate`) on the topmost page of its navigator (a
`PageRoute`, past dialogs and sheets; a page whose name is no template leaves
none), so events and feedback
reports name the screen without the host setting a route. It is off by
default: turn it on for one navigator, the one that holds the app's pages. A route is
named by `describe`, when the host gives one — the place for a router's path
pattern — else by its `settings.name` when that is a template
(`NoticebirdClient.isRouteTemplate`: no query or fragment, no id-like
segment), else by its kind (`MaterialPageRoute`). The rule is one of shape: a
path whose segments are words (`/users/jdoe`) passes it, so an app that pushes
such names gives a `describe`.

## 4. Report and annotate

```dart
// Handled error — does not interrupt the user.
await Noticebird.captureException(
  error,
  stackTrace,
  severity: CrashSeverity.warning,
  handled: true,
  tags: {AllowedTag.feature: 'checkout', AllowedTag.operation: 'submit'},
  extra: {'retry_count': 2, 'checkout_phase': 'confirmation'},
);

// Manual breadcrumb.
Noticebird.addBreadcrumb(TypedBreadcrumb(
  occurredAt: DateTime.now().toUtc(),
  category: BreadcrumbCategory.ui,
  action: 'checkout.confirm',
));

// Route context must be a template, never a raw id.
Noticebird.setRouteTemplate('/lists/:listId');
```

Use fixed `AllowedTag` keys for searchable dimensions such as feature,
operation, and component. Pass `groupingKey` (up to 8 short technical parts,
such as an error code and an operation) when the app knows better than the
stack which failures are one issue: Noticebird then groups every event of
the app with that key together, whatever its type or stack. Put bounded
diagnostic JSON in `extra`; sensitive keys and values are removed client-side
and rejected again server-side.

`captureException` returns a `CaptureResult`: its `outcome` describes what
happened — `sent`, `deduplicated`, `queued` (transport failed, retained for
retry), `dropped` (could not be captured, or the platform refused it for
good, see `CrashTransport.send`), `ignored` (the capture filter declined it)
or `discarded` (crash uploads are off) — and its `eventId` is the id of the
event that stands for the error (this one when sent or queued, the earlier
one when deduplicated, `null` when nothing went). `client.eventIdOf(error)`
answers the same id later from the error alone, also for an error a global
handler captured. A capture the filter ignores is no capture: an error the
host reported at its own report point and rethrew keeps the id of that
report when a global channel sees it again.

### One report per failure

When the app already reports some errors at a report point of its own (an
error library that reports each failure where it converts it, say), every
other channel must leave them alone. Configure the capture filter once; the
explicit captures, the bloc observer, the global handlers and
`reportZoneError` all honour it, and the report point bypasses it:

```dart
await NoticebirdFlutter.start(
  // …
  shouldCapture: (error) => error is! MyDomainError,
);

// The one report point of those errors:
Noticebird.captureException(error, stack, handled: true, filtered: false);
```

A filter that throws counts as `true`.

## 5. Optional user identity (PII)

PII is only sent when your application explicitly calls `setUser` or
`setUserId`. All structured identity fields are accepted by default for
`privacyDefault` and `custom`; omitting these calls sends no identity:

```dart
Noticebird.setUser(CrashUser(id: currentUser.id, email: currentUser.email));

// On logout, clear both the identifier and any breadcrumbs from the
// previous session:
Noticebird.setUser(null);
Noticebird.clearBreadcrumbs();
```

Pass `pii: CrashPiiConfig(enabled: false)` to the start for a complete
client-side opt-out, or `allowedFields` to retain only selected identity
fields. `regulatedStrict` always removes identity, because selecting that
profile is the consumer's explicit no-PII policy choice.

Allowed PII fields are `userId`, `email`, `name`, and `ipAddress`. Identity must
never be placed in `extra`. User data does not affect how events are grouped,
so the same crash across different users still groups into one issue. Medical data
and credentials remain forbidden in every profile; there is intentionally no
`sendMedicalData` option.

## 6. User feedback

`captureFeedback` sends a user's feedback report — a bug, an idea, anything
else — to Noticebird, where it is triaged apart from crashes. Its types are in
`package:noticebird_flutter/feedback.dart`, apart from the main library, so
they cannot clash with an app's own feedback classes. The start sends
feedback to the API at `apiUrl`; a start without an API URL, with one it
cannot send to, or without a usable key answers `FeedbackDisabled`.

The feedback sheet is the app's own. Take the moment when it opens — the
route template, the context diagnostics (the `blocs` group), the host's own
diagnostics and when — so the report is about the screen and the state the
user was in, not the sheet; send it with the report:

```dart
import 'package:noticebird_flutter/feedback.dart';

// When the sheet opens:
final moment = Noticebird.feedbackMoment(
  diagnostics: {'sync': {'pending': 3}},   // optional: content-free values
);

// When the user sends:
final outcome = await Noticebird.captureFeedback(
  kind: FeedbackKind.bug,                  // bug, idea or other
  message: 'Sync keeps failing on Wi-Fi',  // the user's words
  moment: moment,                          // without one, taken now
  trigger: FeedbackTrigger.manual,         // optional: what opened the form
  screenshot: pngBytes,                    // optional: the picture's bytes
  contactEmail: email,                     // optional: only with consent
  relatedEventId: eventId,                 // optional: the crash it is about
);
```

The sheet's bloc or cubit implements `UntracedBloc`, so the user's typing
leaves no breadcrumbs. The trail itself is taken at the capture. The moment's
route is the client's route template unless `feedbackMoment(routeTemplate:)`
names one; it is checked where the report is built, by
`NoticebirdClient.isRouteTemplate` and redacted as `setRouteTemplate`'s is: a
raw route throws in a debug build and is left out in a release build.
`Noticebird.captureFeedback` answers `FeedbackDisabled` while no client is
attached.

The client fills in the app, platform, locale, session, the user of `setUser`
and the newest breadcrumbs, redacted as in an event. `Noticebird.reportedContext`
(`client.reportedContext`) answers the app, the platform and the locale as a
report sent now carries them, for a sheet that shows the user what goes out
with the report; the SDK sends no device model. The message is redacted
on the device like an exception message. What the host passes is sanitised,
never refused:

- `screenshot` is PNG, JPEG or WebP by its bytes' signature; bytes of another
  type, or too many, are left out.
- the moment's `diagnostics` are content-free values in named groups: a
  boolean, a finite number, an enum (sent as its name), a `DateTime` (sent in
  UTC), a UUID or a short token. They follow the context groups, and a group
  of a context group's name is left out; a key or value the report does not
  take, and a group or value past the limits, is left out.

The report then says what was left out in a diagnostics group of the
client's own, `noticebird` (`dropped_values`, `screenshot_dropped`, and
`moment_taken_at` for a moment passed in and taken before the capture); a
host's group of that name is
left out, and a debug build prints what went. `userContext` is what the app
tells about its user on purpose; the client checks its shape
(`FeedbackUserContext.check`) and sends it as given, and the platform drops
what it may not keep. Under `regulatedStrict` no user, user context or locale
is sent; the reporter assertion, when one is configured, is the one identity
such a report carries. The exact limits are in the skill's
[privacy and limits reference](../skills/noticebird/reference/privacy-and-limits.md).

`relatedEventId` names the crash a report is about: a `CaptureResult`'s
`eventId`, or `Noticebird.eventIdOf(error)` for the error an error
screen shows.

The outcome is sealed:

| `FeedbackOutcome` | Meaning |
|---|---|
| `FeedbackDelivered` | The platform has the report; `ticket.display` (such as `FB-12`) is for the reporter, `verified` says whether the reporter assertion was accepted. `ticket` is `null` when the answer named none, such as for a resent report the platform stored already but can no longer compare, its screenshot deleted by retention. |
| `FeedbackQueued` | It did not get through yet and waits in the offline store, under `reportId`. |
| `FeedbackDisabled` | No client is attached, or the client has no feedback config or no feedback transport (a start without an API URL, with one it cannot send to, or without a usable key). |
| `FeedbackRejected` | Not delivered, and never will be: `reason` (a `FeedbackRejection`) says why, `path` names the value at fault. |

`captureFeedback` never throws in a release build. A value the app passed that the report
refuses (an empty message, a contact address, a user context, a related event
id) throws an `ArgumentError` in a debug build, to show the mistake, and is
`FeedbackRejected(FeedbackRejection.invalidInput)` in a release build. A form
can check a contact address first with `FeedbackContact.isValid`.

### Verified reporters

To show a reporter as verified, pass `reporterAssertion`: a function that asks
your backend for a signed assertion of the signed-in user, given 5 seconds;
one that throws, answers `null` or takes longer leaves the report unverified.
The client holds an assertion for the user set with `setUser` or `setUserId`
until 5 minutes before its `exp`, and sends it with each report of that user
meanwhile; reports captured at once share one call. It asks again for
another user, after `setUser(null)`, and once the platform refused the one it
held; without a user it asks for every report. When the platform refuses the
assertion the report is sent unverified, or, with `requireVerified: true`,
rejected as `FeedbackRejection.unverified`.

### The feedback queue

A report that does not get through (no network, a server error, a rate limit)
is kept in the feedback store and answered `FeedbackQueued`. The client sends
it when it is due — after the platform's `Retry-After` or a backoff that
survives a restart — by itself, and at every flush (§8). It bounds the store,
evicting the oldest first (`FeedbackRejection.evicted`), and removes a report
too old to be accepted (`FeedbackRejection.expired`). Without a store, such a
report is `FeedbackRejection.noStore`.

`onFeedbackSettled` is told each kept report's end — delivered, or rejected
for good; without it a debug build prints a rejected one. A report delivered
or rejected at once is not told there: its outcome says so.

```dart
await NoticebirdFlutter.start(
  // …
  onFeedbackSettled: (settled) {
    // settled.reportId as FeedbackQueued named it; settled.outcome is
    // FeedbackDelivered or FeedbackRejected.
  },
);
final waiting = await Noticebird.pendingFeedbackCount;
```

## 7. Live debug sessions

While a live debug session is active, the deduplication window is bypassed
(every capture sends) and every `addBreadcrumb` call also streams immediately
as a synthetic event, so a support engineer can watch breadcrumbs arrive
without waiting for a real crash — no new transport or wire format involved.

```dart
Noticebird.startLiveDebugSession(
  sessionId: sessionId,
  expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 15)),
);
// ... later, or automatically once expiresAt passes:
Noticebird.stopLiveDebugSession();
```

Eligibility, tokens, and TTL policy are entirely the host app's concern — the
client only tracks whether a session id is active until `expiresAt`. Wire
`startLiveDebugSession`/`stopLiveDebugSession` to whatever mechanism your
platform uses to authorize a session (for example a server-controlled
allowlist your app polls).

## 8. The offline queues

When the transport fails, events are queued (bounded by the client's
`maxPendingEvents`) and persisted in the crash store; a feedback report that
does not get through waits in the feedback store (§6). The start keeps both in
the app's support directory, as `FileCrashOfflineStore` and
`FileFeedbackOfflineStore`: unencrypted, so there are none under
`regulatedStrict`, and none on the web, which has no file system, or in a
`background` start. Without a crash store an event that did not get through is
kept in memory only.

The start flushes at start, each time the app comes back to the foreground,
and when the connection returns. A flush asked while one runs runs again
after it. A stored event is sent again as the text the client wrote; an entry
without an event id is discarded. While crash uploads are off the stored
queue is kept, for a later build that uploads.

Pass your own `crashStore` and `feedbackStore` where the default ones do not
fit — an encrypted one under `regulatedStrict`. The SDK never derives or
hardcodes an encryption key, so encryption is supplied by your platform
keystore adapter:

```dart
final class KeystoreOfflineStore implements CrashOfflineStore {
  @override
  bool get isEncrypted => true; // backed by Keychain/Keystore/WebCrypto

  @override
  Future<void> write(List<String> canonicalEnvelopes) async { /* replace */ }

  @override
  Future<List<String>> read() async { /* what the last write left */ }
}
```

The client calls one method of a store at a time, and writes the queue back
right after each `read`: a `read` keeps what it read, so a process that ends
in between loses nothing. `regulatedStrict` refuses an unencrypted store.

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

`package:noticebird_flutter/testing.dart` (`package:noticebird/testing.dart`
outside Flutter) holds `NoticebirdRecorder`: a real client whose events are
recorded instead of sent, without a network. Its client builds, sanitizes and
checks each event as the app's does, and does not deduplicate, so a test sees
a report made twice. The SDK's observers report to it as they do in the app:

```dart
import 'package:noticebird_flutter/testing.dart';

final recorder = NoticebirdRecorder(shouldCapture: myCaptureFilter)..attach();
addTearDown(recorder.close); // closes it, and detaches it from the facade
Bloc.observer = NoticebirdBlocObserver(client: recorder.client); // or the app's subclass
// MaterialApp(navigatorObservers: [NoticebirdNavigatorObserver(client: recorder.client)])

// A bloc reads Bloc.observer when it is made: make it after the line above.
final error = StateError('boom');
final cubit = ListCubit(load: () => throw error);
await cubit.load(); // catches the error into a state, and calls addError
final event = recorder.events.single; // the event as the platform receives it
expect(event['handled'], isTrue);
expect((await recorder.eventOf(error))?['eventId'], event['eventId']);
```

An event reaches the recorder while its capture runs, before the capture's
future completes. `recorder.transport`, a `RecordingCrashTransport`, goes
into a client a test builds itself (`NoticebirdClient(config: …, transport:
…)`); it keeps each event's canonical JSON (`sent`) and the decoded events
(`events`).

A test that calls `NoticebirdFlutter.start` ends with
`await NoticebirdFlutter.resetForTesting()`, which closes it — a start still
under way included — so the next test starts anew. `Noticebird.detach()`
resets the facade.

The recorder sends no feedback. For feedback, build a client with a fake
`FeedbackTransport` in its `FeedbackConfig`: the client hands `submit` the report as
`FeedbackReport.toJsonString` wrote it, validated already; decode it to
assert on its fields, and answer a `FeedbackAccepted`, or a
`FeedbackTransient` to see a report queued. The example's smoke test does
this for its feedback button.

The reporter guarantees zero-crash behavior: capture, transport, queue, and
flush failures are swallowed and never propagate into the host application.

## 11. Native crashes (`noticebird_native`)

A process that dies underneath the Dart isolate — a signal or Mach-exception
crash in the engine, a plugin, Dart AOT code or a system library; an uncaught
Objective-C or JVM exception; a watchdog or ANR kill; a foreground
low-memory kill — never reaches a Dart handler. The operating system keeps a
report of it; `noticebird_native` reads that report on a later launch and
the client delivers it as a schema-5 event with a `native` block.

### Opt in: one argument

Add `noticebird_native` beside `noticebird_flutter`, at the same tag (§1).

```dart
await NoticebirdFlutter.start(
  // …
  nativeCrashes: NativeCrashCapture(), // hangs: false, diskWrites: false,
                                       // includeDebugBuilds: false
);
```

- The start delivers the reports of earlier runs: it runs in the engine that
  shows the UI. A `background: true` start only records its run, since a
  headless engine may have seconds to live.
- Pass `nativeCrashes` to every engine's start. Each engine with a collector
  records its run (session, app, platform, route, trail); only the UI start
  delivers. A crash inside a headless background run is attributed to that
  run.
- While crash uploads are off, no report is claimed: a later build that
  uploads still sends them.

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
persisted. When the host stops starting native capture (the argument is
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
returns `NativeCrashBatch`es into a client of your own and assert the events
your transport receives. `packages/noticebird_native/example` is a native
crash lab with deliberate crashes for device and emulator smokes.

## 12. The client without the start

`noticebird` is the pure-Dart client the start makes. A program outside
Flutter, or a host that owns every part of the wiring, builds it itself:

It depends on `noticebird` and `noticebird_protocol` from the repository, at
the release's tag (§1, without `noticebird_flutter`).

```dart
final transport = CrashHttpTransport(
  apiUrl: CrashHttpTransport.hostedApiUrl,
  publishableKey: 'noticebird_pk_...',
);
final client = NoticebirdClient(
  config: NoticebirdConfig(
    privacyProfile: CrashPrivacyProfile.privacyDefault,
    app: AppMetadata(
      name: 'my_tool',
      version: '2.3.0',
      build: '481',
      release: 'my_tool@2.3.0+481',
    ),
    offlineStore: FileCrashOfflineStore(directory), // optional
    feedback: FeedbackConfig(                        // optional
      transport: FeedbackHttpTransport.of(transport),
    ),
  ),
  transport: transport, // optional: without one, crash uploads are off
);
Noticebird.attach(client);
```

Such a host installs its own error handlers, calls `flush()` when it wants
what waits sent (a kept feedback report is still drained when it is due),
calls `reportNativeCrashes()` from the engine that shows the UI, and
`close()` when it is done. A client without a `transport` uploads no crash
events: a capture is `discarded`, the stored queue is kept and native reports
stay unclaimed, while the trail, the user and the route are still kept for
feedback. A `FeedbackConfig` without a `transport` sends no feedback
(`FeedbackDisabled`), and the rest of it is still checked. The config's other
knobs:

| Field | Default | Notes |
|---|---|---|
| `maxBreadcrumbs` | 50 | 0–50; the breadcrumbs one event carries: the newest that no sent event carried yet. |
| `breadcrumbBuffer` | `maxBreadcrumbs` | `maxBreadcrumbs`–200; the breadcrumbs kept in memory for `recentBreadcrumbs`. |
| `maxPendingEvents` | 50 | 0–200; bounds the in-memory/offline retry queue. |
| `deduplicationWindow` | 1 minute | A repeat inside the window (the same grouping key, or the same type and top app frames, line numbers aside) is `deduplicated`. |
| `sessionIdFactory` | `NoticebirdConfig.processSessionId` | One id per app run; pass your own only when a session means something else. |
| `locale` | none | The app's locale for each feedback report. |
| `feedback` | none (off) | `FeedbackConfig` from `package:noticebird/feedback.dart`: transport, `reporterAssertion`, `requireVerified`, `offlineStore`, `onSettled`, `contextDiagnostics`. |
