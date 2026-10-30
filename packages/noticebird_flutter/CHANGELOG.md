## 0.4.0

First release: a Flutter app's whole integration with Noticebird.

- `NoticebirdFlutter.start` makes the client from a publishable key and the
  app's name, attaches it to the `Noticebird` facade, and wires what each app
  wired itself: the global error handlers, chained to the ones they replace;
  `Bloc.observer`, beside the observer it found; the app's version and build
  and the platform's locale; offline stores in the support directory (none
  on the web, under `regulatedStrict` or in a `background` start); the
  delivery of what waits, at start, on resume and when the connection
  returns; and the native crash reports of earlier runs with `nativeCrashes`.
  It never fails on the platform: a plugin that throws or does not answer
  within `platformReadTimeout` is done without. `close()` puts back what it
  installed.
- `NoticebirdFlutter.reportZoneError`, the handler of a host's own guarded
  zone.
- `NoticebirdBlocObserver` (in `noticebird` 0.3.0
  `ProtocolNoticebirdBlocObserver`): breadcrumbs of bloc events and changes,
  a bloc's errors captured as handled, and the live blocs per type for a
  feedback report's `blocs` diagnostics group. A bloc that implements
  `UntracedBloc` leaves no breadcrumbs. `BlocErrorReport` and
  `captureBlocError` move here from `noticebird`.
- `NoticebirdNavigatorObserver`: navigation as breadcrumbs, each route named
  by the host's `describe`, its `settings.name` when that is a template, or
  its kind; never by a raw path.
- `package:noticebird_flutter/feedback.dart` re-exports the feedback types of
  `noticebird`.
