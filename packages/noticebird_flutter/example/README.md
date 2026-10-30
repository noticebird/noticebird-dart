# noticebird example

A minimal Flutter app showing how a consumer wires up the `noticebird` SDK:

- build `AppMetadata` and `PlatformMetadata`, pick a `CrashPrivacyProfile`, and
  create a `NoticebirdClient` with an HTTP transport using a **publishable**
  ingest key (`noticebird_pk_...`);
- register `ProtocolNoticebirdBlocObserver` so BLoC lifecycle events become
  bounded breadcrumbs;
- wrap the app in `reporter.run(...)` so Flutter, platform, and zone errors are
  captured automatically.

## Run

```sh
flutter run \
  --dart-define=NOTICEBIRD_PUBLISHABLE_KEY=noticebird_pk_your_key
```

Without the define the app uses a placeholder key, so capture succeeds but
delivery fails and events fall back to the in-memory retry queue — which is
still a faithful demonstration of the zero-crash guarantee.

The three buttons demonstrate, in order, breadcrumb capture, a handled error
(`captureException(..., handled: true)`), and an uncaught error that the error
handlers installed by `run()` capture so the app keeps running.
