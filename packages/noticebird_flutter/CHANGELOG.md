## 0.6.0

Moves with `noticebird` 0.6.0 and `noticebird_protocol` 0.6.0.

Breaking changes:

- The removals of `noticebird_protocol` 0.6.0, which this package
  re-exports: `CrashEvent.maxTags`, `TypedBreadcrumb.maxDataTags`,
  `CrashEvent.userId` and `CrashEvent.userIdPattern`. `setUserId` is
  unchanged.

Fixes:

- Through `noticebird` 0.6.0: a breadcrumb the protocol refuses, such as a
  manual one whose action is `Route.Push`, is left out of a crash event
  alone instead of dropping the event.

## 0.5.0

Breaking changes:

- `NoticebirdFlutter.start` takes the API's base, `apiUrl`, in place of
  `endpoint`, and `publishableKey` is optional. Without both an `apiUrl`
  and a `publishableKey` — either absent or empty, or one that cannot work
  — the start makes a client that uploads nothing and sends no feedback:
  the SDK no longer sends to the hosted API by default. Migrate by passing
  `apiUrl: CrashHttpTransport.hostedApiUrl` (or your API's base, without
  `/v1/envelope`). A build that must not send now leaves out `apiUrl` or
  `publishableKey`; an empty one still sends nothing.

Changes:

- `NoticebirdBlocObserver.traces(bloc)`, a protected hook: whether a bloc's
  events and changes leave a breadcrumb, by default every bloc but an
  `UntracedBloc`. A subclass leaves a marker of its own out of the trail by
  overriding it, instead of `onEvent` and `onChange`; that bloc's errors
  are still captured and it is still counted.
- `NoticebirdFlutter.resetForTesting()` closes what `start` started, a start
  still under way included, so a test's next start starts anew.
- `package:noticebird_flutter/testing.dart` re-exports `noticebird`'s test
  support: `NoticebirdRecorder`, to which the SDK's bloc observer reports
  without a network.

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
  within `platformReadTimeout` is done without, and `platformReadFailures`
  says which (`PlatformReadFailure`). A host whose breadcrumbs say more
  passes its own subclass of `NoticebirdBlocObserver` as `blocObserver`.
  `close()` puts back what it installed, detaches the client and closes the
  HTTP client the start made (one the host passed as `httpClient` stays
  open); the old client is not to be used after it.
- `NoticebirdFlutter.reportZoneError`, the handler of a host's own guarded
  zone.
- `NoticebirdBlocObserver` (in `noticebird` 0.3.0
  `ProtocolNoticebirdBlocObserver`): breadcrumbs of bloc events and changes,
  a bloc's errors captured as handled, and the live blocs per type for a
  feedback report's `blocs` diagnostics group. A bloc that implements
  `UntracedBloc` leaves no breadcrumbs. `BlocErrorReport` and
  `captureBlocError` move here from `noticebird`.
- `NoticebirdNavigatorObserver`: navigation as breadcrumbs, each route named
  by the host's `describe`, its `settings.name` when that is a template by
  `NoticebirdClient.isRouteTemplate` (a rule of shape: no query or fragment,
  no id-like segment; a path of words passes, so an app that pushes such names
  gives a `describe`), or its kind. With `tracksRouteTemplate: true` it keeps
  the client's route template on the topmost page (past dialogs and
  sheets): its template, or none.
- `package:noticebird_flutter/feedback.dart` re-exports the feedback types of
  `noticebird`.
