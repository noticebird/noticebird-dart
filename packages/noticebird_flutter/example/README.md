# noticebird_flutter example

A minimal Flutter app on `noticebird_flutter`:

- `NoticebirdFlutter.start` in `main`, before `runApp`: the client, the error
  handlers, the bloc breadcrumbs, the offline stores and their delivery;
- `NoticebirdNavigatorObserver` in the app's `navigatorObservers`;
- a cubit whose changes become breadcrumbs;
- a handled error (`captureException(..., handled: true)`), an uncaught one
  that the start's handlers capture so the app keeps running, a feedback
  report sent with its moment (`feedbackMoment`, `captureFeedback`), a login
  that sets the user id, and a live debug session.

## Run

```sh
flutter run \
  --dart-define=NOTICEBIRD_PUBLISHABLE_KEY=noticebird_pk_your_key
```

Without the define the app uses a placeholder key, so capture succeeds but
delivery fails, and events wait in the store in the support directory for the
next flush.

`test/example_smoke_test.dart` pumps the app with a client of its own on fake
transports and asserts on the events and the feedback report they receive.
