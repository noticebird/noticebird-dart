# noticebird

Privacy-safe Flutter crash capture SDK for Noticebird.

The SDK builds typed events of the protocol's schema 5, applies the
configured privacy profile, keeps bounded breadcrumbs and retries, and sends
events to the Noticebird ingestion endpoint. It has no database or backend SDK
dependency.

## Minimal wiring

```dart
final reporter = NoticebirdClient(
  config: NoticebirdConfig(
    privacyProfile: CrashPrivacyProfile.privacyDefault,
    app: appMetadata,
    // Optional: errors the app reports at a report point of its own, which
    // captures them with `filtered: false`. Every channel honours it.
    shouldCapture: (error) => error is! MyDomainError,
  ),
  transport: CrashHttpTransport(
    publishableKey: 'noticebird_pk_...',
  ),
);

reporter.installGlobalHandlers();
```

Native crash reports of earlier runs — native crashes, watchdog and ANR
kills — are an opt-in add-on: add `noticebird_native` and pass
`nativeCrashes: NativeCrashCapture()` in the config; `run()` delivers them
(see `docs/integration.md` §11).

Consumers should use only publishable ingest keys. The project, environment
and privacy profile are derived by the service from the key and
are never accepted as security claims in an event payload.

The transport sends to `https://api.noticebird.com/v1/envelope` by default;
pass `endpoint` only for a local, staging or self-hosted override.

```dart
CrashHttpTransport(
  endpoint: Uri.parse('https://staging.example.com/v1/envelope'),
  publishableKey: 'noticebird_pk_...',
);
```

`captureException` returns a `CaptureResult`: its `outcome` is the
`CaptureOutcome` (`sent`, `deduplicated`, `queued`, `dropped`, `ignored`),
its `eventId` the id of the event that stands for the error.

## Feedback

A user's feedback report — a bug, an idea, anything else, optionally with a
screenshot — goes to Noticebird with `captureFeedback`. Its types are in a
library of their own, so they cannot clash with an app's own feedback
classes:

```dart
import 'package:noticebird/feedback.dart';

final crashTransport = CrashHttpTransport(publishableKey: 'noticebird_pk_...');
final reporter = NoticebirdClient(
  config: NoticebirdConfig(
    privacyProfile: CrashPrivacyProfile.privacyDefault,
    app: appMetadata,
    feedback: FeedbackConfig(
      // The crash transport's endpoint, key and HTTP client.
      transport: FeedbackHttpTransport.of(crashTransport),
      // Optional: reports that do not get through wait here for a flush.
      offlineStore: FileFeedbackOfflineStore(directory),
    ),
  ),
  transport: crashTransport,
);

final outcome = await reporter.captureFeedback(
  kind: FeedbackKind.bug,
  message: 'Sync keeps failing on Wi-Fi',
);
switch (outcome) {
  case FeedbackDelivered(:final ticket):
    showThanks(ticket?.display); // the ticket to show the reporter
  case FeedbackQueued():
    showThanks(null); // sent on a later flush()
  case FeedbackRejected(:final reason):
    showFailure(reason);
  case FeedbackDisabled():
    break; // no NoticebirdConfig.feedback
}
```

The client adds the app, platform, session, route template, user and the
breadcrumb trail; the message is redacted on the device. `captureFeedback`
never throws. `FeedbackHttpTransport.of` sends to the API of the crash
transport's `endpoint`, with its key, so a local, staging or self-hosted setup
is configured once.

With an `offlineStore`, a report that does not get through is answered
`FeedbackQueued` and sent again by `flush()`, which `run()` calls at start;
call it on resume and when connectivity returns too. `feedbackDeliveries`
tells how each queued report ended, and `pendingFeedbackCount` how many wait:

```dart
reporter.feedbackDeliveries.listen((settled) {
  // settled.reportId as FeedbackQueued named it; settled.outcome is
  // FeedbackDelivered or FeedbackRejected.
});
```

`FileFeedbackOfflineStore` keeps reports unencrypted in a directory of its
own (such as one under the app's support directory), so it is not for
`regulatedStrict`; on the web its calls throw, and a report that does not get
through is `FeedbackRejection.noStore`. See `docs/integration.md` §6 for the
optional screenshot, contact address, diagnostics, user context and
reporter assertion.

## Privacy and reliability

- `regulatedStrict` rejects unencrypted offline stores, removes user identity
  and all free-form `extra` context, and strips identifiers, secrets, and
  health/provider values from the remaining fields.
- Captures accept bounded `extra` JSON context. Sensitive fields are removed;
  identity belongs only in the explicit `user` object.
- Identity is only sent when the consumer calls `setUser` or `setUserId`.
  Those explicit fields are allowed by default for `privacyDefault` and
  `custom`; `CrashPiiConfig` remains available as an optional field filter or
  complete opt-out.
- Medical data and secrets are never allowed, including in `custom` mode.
- Breadcrumbs are typed and bounded to 50 entries.
- Event retries are bounded by `maxPendingEvents`.
- The reporter catches its own failures and never propagates them into the host
  application.
- Route values must be templates, never raw identifiers.

The protocol package is transitively exported as `noticebird_protocol`.
