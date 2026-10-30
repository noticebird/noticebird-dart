# noticebird

Privacy-safe crash reporting and user feedback for Dart: the client of
Noticebird.

The client builds typed events of the protocol's schema 5, applies the
configured privacy profile, keeps bounded breadcrumbs and retries, and sends
events to the Noticebird ingestion endpoint, and a user's feedback report to
its feedback routes. It is pure Dart: no Flutter, no database or backend SDK.

**A Flutter app depends on [`noticebird_flutter`](../noticebird_flutter)
instead**, whose `NoticebirdFlutter.start` makes this client and wires the
error handlers, breadcrumbs, stores and delivery around it. Build the client
yourself only outside Flutter, or when you own every part of that wiring.

## The client

```dart
final transport = CrashHttpTransport(publishableKey: 'noticebird_pk_...');
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
  transport: transport,
);
Noticebird.attach(client); // the static facade, from anywhere
```

Consumers use only publishable ingest keys. The project, environment and
privacy profile are derived by the service from the key and are never
accepted as security claims in an event payload. The transport sends to
`https://api.noticebird.com/v1/envelope` by default; pass `endpoint` only for
a local, staging or self-hosted override.

`captureException` returns a `CaptureResult`: its `outcome` is the
`CaptureOutcome` (`sent`, `deduplicated`, `queued`, `dropped`, `ignored`,
`discarded`), its `eventId` the id of the event that stands for the error.
`eventIdOf(error)` answers that id later from the error alone, also for an
error a global handler captured without waiting.

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
    // The crash transport's endpoint, key and HTTP client.
    transport: FeedbackHttpTransport.of(transport),
    // Optional: reports that do not get through wait here.
    offlineStore: FileFeedbackOfflineStore(directory),
    // Optional: the end of each kept report.
    onSettled: (settled) {},
  ),
);

// When the feedback form opens:
final moment = client.feedbackMoment();
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
    break; // no NoticebirdConfig.feedback
}
```

The moment is what the report is about — the route template and the context
diagnostics when the form opened; the client adds the app, platform,
session, user and the breadcrumb trail, and redacts the message on the
device. `captureFeedback` never throws in a release build (a debug build
throws an `ArgumentError` for input the report refuses, to show it). See
[`docs/integration.md`](../../docs/integration.md) §6 for the screenshot,
contact address, diagnostics, user context and reporter assertion.

## Privacy and reliability

- `regulatedStrict` rejects unencrypted offline stores, removes user identity
  and all free-form `extra` context, and strips identifiers, secrets, and
  health/provider values from the remaining fields.
- Identity is only sent when the consumer calls `setUser` or `setUserId`;
  `CrashPiiConfig` filters it or opts out.
- Medical data and secrets are never allowed, including in `custom` mode.
- Breadcrumbs are typed and bounded to 50 per event; retries are bounded by
  `maxPendingEvents`.
- The client catches its own failures and never propagates them into the
  host application.
- Route values must be templates, never raw identifiers.

The protocol package is exported as `noticebird_protocol`.
