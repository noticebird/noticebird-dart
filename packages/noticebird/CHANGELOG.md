## 0.3.0

Breaking changes:

- `captureException`, `captureBlocError` and `reportNativeCrashes` return a
  `CaptureResult` instead of a bare `CaptureOutcome`, on the client and on
  the `Noticebird` facade. Its `outcome` is the unchanged `CaptureOutcome`,
  and its `eventId` the id of the event that stands for the error (this one
  when sent or queued, the earlier one when deduplicated, `null` when nothing
  went), to name the crash a feedback report is about. Migrate by reading
  `.outcome`: `switch ((await client.captureException(e, s)).outcome) { … }`.
- `captureUserReport` is removed, from the client and the `Noticebird`
  facade: send a user's report with `captureFeedback`, which sends a feedback
  report instead of an event.
- `FeedbackHttpTransport` is made from the app's crash transport,
  `FeedbackHttpTransport.of(crashTransport)`, which shares its endpoint,
  publishable key and HTTP client, so they are configured once. Its
  constructor and its `close()` are removed (the HTTP client is the crash
  transport's to close), and so are `requestTimeout`, `uploadTimeout` and
  `defaultRetryAfter`.
- A `FeedbackDelivery` carries only what the client acts on:
  `FeedbackAccepted.replay` and `reportId`, `FeedbackUploadSlot.expiresAt`,
  `FeedbackFinalRefusal.status`, `FeedbackAssertionRefused.reason` and
  `FeedbackTransient.status` are removed.
- `CrashHttpTransport.publishableKeyPattern` is removed.
- `CrashTransport.send` takes the event as the client wrote it, its
  canonical JSON (`String eventJson`), instead of the `CrashEvent`: the
  client checks and writes an event once, and a `flush()` sends a stored
  event as the same text, reading back only its id. A fake transport that
  asserts on what it was sent decodes the JSON. A custom transport that
  posts the event itself posts the given JSON unchanged as the body, and
  never re-encodes it.
- An offline store's entry without an event id is discarded at a `flush()`;
  any other entry is sent as it is stored.
- An event the platform refuses for good — a `CrashTransportException`
  with the new `refusedForGood`, see `CrashTransport.send` — is dropped
  instead of queued: at the capture it is `dropped`, and a `flush()`
  removes it and goes on with the next event instead of stopping at it for
  good.
- Takes `noticebird_protocol` 0.3.0, which builds crash events and feedback
  reports and no longer reads them: `CrashEvent.fromJson`,
  `crashFingerprint`, `privacyViolation` and the value types' `fromJson`
  are removed from what `noticebird.dart` exports, and the value types
  have a `check()` instead; its feedback library's
  `FeedbackDiagnostics.build` refuses a value with a `ProtocolException`
  (see its CHANGELOG).

New:

- User feedback: `NoticebirdClient.captureFeedback` (and
  `Noticebird.captureFeedback`) sends a user's report — a bug, an idea,
  anything else — with an optional screenshot, contact address,
  diagnostics, user context and related event id, and answers a sealed
  `FeedbackOutcome`: `FeedbackDelivered` (with the ticket to show the
  reporter, and whether the reporter was verified), `FeedbackQueued`,
  `FeedbackDisabled` or `FeedbackRejected` with a `FeedbackRejection` and,
  where one is at fault, the JSON path of the value. It never throws: a
  value the host passed that the report refuses throws an `ArgumentError`
  in a debug build only. The client fills in the app, platform, locale,
  session, route template, user and the breadcrumb trail; the message is
  redacted on the device like an event's; the user context is checked for
  its shape and sent as given, for the platform to redact; under
  `regulatedStrict` no user, user context or locale is sent.
  - `NoticebirdConfig.feedback` takes a `FeedbackConfig`: its `transport`
    (`FeedbackHttpTransport.of(crashTransport)` for the hosted API), an
    optional `reporterAssertion` provider, called once per report when it is
    captured, given 5 seconds, and not asked again when the platform
    refuses its assertion; `requireVerified`, which rejects an unverified
    report instead of sending it; and an optional `offlineStore`.
  - `FeedbackScreenshot` carries the screenshot's bytes and type (PNG, JPEG
    or WebP, at most 5 MiB), checked before any request.
    `FeedbackContact.isValid` checks a contact address the way a report
    does, so a form can check it first.
  - A report whose screenshot slot answers `report_conflict` is submitted:
    a replay delivers it with its ticket, and `report_conflict` again, its
    own earlier delivery the platform can no longer compare once retention
    deleted the screenshot, delivers it without one.
- The feedback offline queue: a report that does not get through is kept
  in `FeedbackConfig.offlineStore`, answered `FeedbackQueued`, and sent
  again by `flush()`, with the platform's `Retry-After` or a backoff from
  30 seconds to 6 hours that survives a restart.
  - `FeedbackOfflineStore` is the interface, of `PendingFeedback` entries
    in a stable JSON form, the screenshot kept apart.
    `FileFeedbackOfflineStore(directory)` keeps them as files, unencrypted;
    on the web its calls throw, so a report that does not get through there
    is `FeedbackRejection.noStore`. Under `regulatedStrict` the store must
    be encrypted.
  - The client keeps at most 10 reports and 20 MiB, the oldest evicted
    first (`FeedbackRejection.evicted`), and removes a report 7 days old
    (`FeedbackRejection.expired`).
  - `NoticebirdClient.feedbackDeliveries` streams a `FeedbackSettled` for
    each kept report when it is delivered or rejected for good, and
    `pendingFeedbackCount` says how many wait.
- All feedback types — the ones above, the transport and the report's model
  — are in `package:noticebird/feedback.dart`; the main library exports
  none of them, so they cannot clash with an app's own feedback classes.
- `run()` calls `flush()` once at start, so the events and feedback an
  earlier run queued go out. `flush()` writes the merged event queue back
  to the offline store before it sends, so a process that dies during the
  send keeps the stored events; a second `flush()` while one runs skips
  only what that one is still sending, instead of returning at once.

## 0.2.0

- Takes `noticebird_protocol` 0.2.0, which adds the feedback report v1 model
  in `package:noticebird_protocol/feedback.dart`.
- The feedback transport, in a library of its own,
  `package:noticebird/feedback.dart` (the main library is unchanged, so its
  names cannot clash with an app's own feedback classes):
  `FeedbackTransport` and `FeedbackHttpTransport`, which request a screenshot
  slot, upload the bytes and submit a report, and turn every answer into one
  `FeedbackDelivery`. The upload URL is resolved against the slot request's
  URL, so a proxy's path prefix survives, and the publishable key goes only
  to the API's own origin. Capturing feedback from the app follows in a later
  release.
- `CrashHttpTransport` refuses a key that is not publishable before it opens
  an HTTP client.

## 0.1.0

First public release.
