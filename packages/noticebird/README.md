# noticebird

Privacy-safe crash reporting and user feedback for Dart: the client of
Noticebird.

The client builds typed crash events, applies the configured privacy
profile, keeps bounded breadcrumbs and retries, and sends events to a
Noticebird API's ingestion route, and a user's feedback report to its
feedback routes. It is pure Dart: no Flutter, no database or backend SDK.

**A Flutter app depends on [`noticebird_flutter`](../noticebird_flutter)
instead**, whose `NoticebirdFlutter.start` makes this client and wires the
error handlers, breadcrumbs, stores and delivery around it. Build the client
yourself only outside Flutter, or when you own every part of that wiring.

The packages are not on pub.dev: depend on them from the repository at the
release's tag, as [Depend on the SDK](../../docs/integration.md#1-depend-on-the-sdk)
shows.

## The client

```dart
final transport = CrashHttpTransport(
  apiUrl: CrashHttpTransport.hostedApiUrl, // or a staging or self-hosted API
  publishableKey: 'noticebird_pk_...',
);
final client = NoticebirdClient(
  config: NoticebirdConfig(
    privacyProfile: CrashPrivacyProfile.privacyDefault,
    app: appMetadata,
    // Optional: errors the app reports at a report point of its own, which
    // captures them with `filtered: false`. Every channel honours it.
    shouldCapture: (error) => error is! MyDomainError,
    // Optional: where an event that did not get through waits.
    offlineStore: FileCrashOfflineStore(directory),
  ),
  transport: transport, // optional: without one, crash uploads are off
);
Noticebird.attach(client); // the static facade, from anywhere
```

Consumers use only publishable ingest keys. The project, environment and
privacy profile come from the key, never from an event payload. The transport takes the
API's base URL (`CrashHttpTransport.hostedApiUrl`, `https://api.noticebird.com`,
or a staging, self-hosted or proxied one, a path prefix included) and adds the
routes itself; it never picks an API by itself. A client without a `transport`
uploads no crash events but still keeps the trail, the user and the route for
feedback: a capture is `discarded`, the stored queue stays and native reports
stay unclaimed, for a build that uploads.

`captureException` returns a `CaptureResult`: its `outcome` is the
`CaptureOutcome` (`sent`, `deduplicated`, `queued`, `dropped`, `ignored`,
`discarded`), its `eventId` the id of the event that stands for the error.
`eventIdOf(error)` answers that id later from the error alone, also for an
error a global handler captured without waiting; a later capture the filter
ignores (the error rethrown after the host reported it) leaves it.

`reportedContext` says what the client tells about the app and the device:
the app, the platform (operating system, its version, the device class) and
the locale a feedback report carries — for a feedback form that shows what
goes out. No device model leaves the device.

`flush()` sends what waits; the client also drains kept feedback by itself
when it is due. `close()` stops what the client does by itself.

Native crash reports of earlier runs are an opt-in add-on:
[`noticebird_native`](../noticebird_native), passed as
`NoticebirdConfig.nativeCrashes`; the host calls `reportNativeCrashes()` from
the engine that shows the UI.

## Feedback

A user's feedback report — a bug, an idea, anything else, optionally with a
screenshot — goes with `captureFeedback`. Its types are in a library of their
own, so they cannot clash with an app's own feedback classes:

```dart
import 'package:noticebird/feedback.dart';

NoticebirdConfig(
  // …
  feedback: FeedbackConfig(
    // The crash transport's API, key and HTTP client.
    transport: FeedbackHttpTransport.of(transport),
    // Optional: reports that do not get through wait here.
    offlineStore: FileFeedbackOfflineStore(directory),
    // Optional: the end of each kept report.
    onSettled: (settled) {},
  ),
);

// When the feedback form opens, with the app's own diagnostics:
final moment = client.feedbackMoment(diagnostics: {'sync': {'pending': 3}});
// When the user sends it:
final outcome = await client.captureFeedback(
  kind: FeedbackKind.bug,
  message: 'Sync keeps failing on Wi-Fi',
  moment: moment,
);
switch (outcome) {
  case FeedbackDelivered(:final ticket):
    showThanks(ticket?.display); // the ticket to show the reporter
  case FeedbackQueued():
    showThanks(null); // kept, and sent later
  case FeedbackRejected(:final reason):
    showFailure(reason);
  case FeedbackDisabled():
    break; // no NoticebirdConfig.feedback, or one without a transport
}
```

The moment is what the report is about — the route template, the context
diagnostics and the app's own diagnostics when the form opened; the client adds the app, platform,
session, user and the breadcrumb trail, and redacts the message on the
device. `captureFeedback` never throws in a release build (a debug build
throws an `ArgumentError` for input the report refuses, to show it). See
[`docs/integration.md`](../../docs/integration.md) §6 for the screenshot,
contact address, diagnostics, user context and reporter assertion.

## Privacy and reliability

- Every profile redacts identifiers, secrets and health values from the text
  an event carries and cuts tag and breadcrumb strings. `regulatedStrict`
  changes only the message (the error type alone), `extra` (empty) and the
  user (none), and rejects unencrypted offline stores.
- Identity is only sent when the consumer calls `setUser` or `setUserId`;
  `CrashPiiConfig` filters it or opts out.
- Medical data and secrets are never allowed, including in `custom` mode.
- Breadcrumbs are typed and bounded to 50 per event; one the protocol
  refuses (an action such as `Route.Push`) is left out alone. Retries are
  bounded by `maxPendingEvents`.
- The client catches its own failures and never propagates them into the
  host application.
- Route values must be templates, never raw identifiers.

The protocol package is exported as `noticebird_protocol`.

## Testing

`package:noticebird/testing.dart` holds `NoticebirdRecorder`: a real client
whose events are recorded instead of sent, with no network and no
deduplication, so a test sees what the client would send and a report
made twice:

```dart
import 'package:noticebird/testing.dart';

final recorder = NoticebirdRecorder(shouldCapture: myFilter)..attach();
addTearDown(recorder.close);

final error = StateError('boom');
await codeUnderTest(failingWith: error); // reports error, handled
expect(recorder.events.single['handled'], isTrue);
expect(await recorder.eventOf(error), isNotNull);
```

Its `transport`, a `RecordingCrashTransport`, can go into a client a test
builds itself. The recorder sends no feedback. `Noticebird.detach()` resets the facade.
