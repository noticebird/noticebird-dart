# noticebird_flutter

Noticebird for a Flutter app: privacy-safe crash reporting, breadcrumbs,
offline delivery and user feedback, started with one call.

The packages are not on pub.dev: depend on them from the repository at the
release's tag, as [Depend on the SDK](../../docs/integration.md#1-depend-on-the-sdk)
shows.

## The whole integration

```dart
import 'package:noticebird_flutter/noticebird_flutter.dart';

Future<void> main() async {
  await NoticebirdFlutter.start(
    publishableKey: const String.fromEnvironment('NOTICEBIRD_KEY'),
    appName: 'my_app',
  );
  runApp(const MyApp());
}

// Anywhere in the app, through the facade:
await Noticebird.captureException(error, stack, handled: true);
```

The start makes the client and attaches it to the `Noticebird` facade,
installs the global error handlers, sets `Bloc.observer`, keeps what does not
get through in the app's support directory, and sends what waits at start,
each time the app comes back to the foreground and when the connection
returns. It reads the app's version and build and the platform's locale
itself. It never fails on the platform and never hangs: a plugin that throws
or does not answer within `NoticebirdFlutter.platformReadTimeout` is done
without.

Navigation becomes breadcrumbs with an observer on each navigator; on the
one that holds the app's pages, `tracksRouteTemplate: true` also keeps the
client's route template on the topmost page (past dialogs and sheets; a
page whose name is no template leaves none), so events and feedback reports name their screen
without the host setting a route:

```dart
MaterialApp(
  navigatorObservers: [NoticebirdNavigatorObserver(tracksRouteTemplate: true)],
);
```

A route is named by its `settings.name` when that is a template
(`/lists/:listId`; `NoticebirdClient.isRouteTemplate`), else by its kind
(`MaterialPageRoute`). The rule is one of shape: a path with a query or an
id-like segment never passes, a path of words (`/users/jdoe`) does. A router
that knows its path patterns, or an app that pushes such names, names its
routes with `describe`.

### A feedback sheet

The sheet is the app's own; the SDK has no widgets. Take the moment when the
sheet opens, so the report is about the screen and the state the user was in,
and send it with the report. The app's own diagnostics go into the moment:

```dart
import 'package:noticebird_flutter/feedback.dart';

// When the sheet opens:
final moment = Noticebird.feedbackMoment(
  diagnostics: {'sync': {'pending': 3}}, // optional: content-free values
);

// When the user sends:
final outcome = await Noticebird.captureFeedback(
  kind: FeedbackKind.bug,
  message: text,
  moment: moment,
  screenshot: pngBytes, // optional: PNG, JPEG or WebP bytes
);
```

The sheet's bloc or cubit implements `UntracedBloc`, so the user's typing
leaves no breadcrumbs and does not push out the steps that led to the report:

```dart
class FeedbackFormCubit extends Cubit<FeedbackFormState>
    implements UntracedBloc { … }
```

`captureFeedback` never throws in a release build (in a debug build, input
the report refuses throws an `ArgumentError`, to show it); its
`FeedbackOutcome` says what became of the report, `FeedbackDisabled` while
no client is attached. The feedback types are in `package:noticebird_flutter/feedback.dart`,
apart from the main library, so they cannot clash with an app's own.

## The start's options

`publishableKey` and `appName` are required. A key that is empty or malformed
(a missing `--dart-define`) starts a client that uploads nothing and sends no
feedback; a debug build prints why.

| Concern | Options |
|---|---|
| Where it sends | `endpoint` (the `/v1/envelope` URL; by default the hosted API), `httpClient` (the host's HTTP stack), `uploadCrashes` (`false`: crash events are discarded, feedback is still sent) |
| What an event carries | `privacyProfile`, `pii`, `shouldCapture`, `breadcrumbBuffer` |
| Feedback | `reporterAssertion`, `requireVerified`, `onFeedbackSettled` |
| Native crashes | `nativeCrashes`: `NativeCrashCapture()` of `noticebird_native` |
| Storage | `crashStore`, `feedbackStore`: the host's own stores in place of the default ones |
| What it installs | `installErrorHandlers`, `observeBlocs`, `blocObserver` |
| Engine | `background` |

`start` answers a `NoticebirdFlutter` with the `client`, the `blocObserver`,
the `platformReadFailures` (each `PlatformReadFailure` a read it went on
without — `packageInfo` or `supportDirectory` — with its `error` and
`stackTrace`, for a host that reports them) and `close()`, which puts back
what the start installed (only while it is still the start's) and detaches
the client; the `httpClient` stays the host's. A later `start` makes a client
of its own on the same stores: do not use the old `client` after `close()`. A second `start`, also one made
while the first is starting, answers the first. It throws an `ArgumentError`
only for an argument no start can work with, such as an `appName` the
protocol refuses or an unencrypted store under `regulatedStrict`.

### A background engine

A headless engine (a background task) starts with `background: true` and the
same arguments: its client reports, but it delivers nothing of earlier runs,
flushes nothing by itself and keeps no store, since two engines must not share
one. An event it cannot send is kept in memory only.

### A zone of the host's own

The start installs no zone: `PlatformDispatcher.onError` catches what nothing
else does. A host that runs its app in a guarded zone of its own reports from
it with `reportZoneError`:

```dart
runZonedGuarded(() async {
  await NoticebirdFlutter.start(publishableKey: key, appName: 'my_app');
  runApp(const MyApp());
}, NoticebirdFlutter.reportZoneError);
```

### Error handlers the host keeps

The start installs `FlutterError.onError` and `PlatformDispatcher.onError`,
each chained to the handler it replaces. A host whose own handlers stay in
place passes `installErrorHandlers: false` and reports from them with
`Noticebird.captureException`.

### Bloc

The start sets `Bloc.observer` to bloc's `MultiBlocObserver` of its
`NoticebirdBlocObserver` and the observer it found. A host that sets an
observer after the start keeps the SDK's beside it:

```dart
final noticebird = await NoticebirdFlutter.start(…);
Bloc.observer = MultiBlocObserver(
  observers: [noticebird.blocObserver, MyObserver()],
);
```

Each bloc event and state change becomes a breadcrumb named by its runtime
type, a bloc's `addError` is captured as handled (wrap it in a
`BlocErrorReport` to set its severity, tags or extra), and each feedback
report's `blocs` diagnostics group counts the live blocs per type.
A host whose breadcrumbs say more about a step subclasses
`NoticebirdBlocObserver` (`describeEvent`, `describeChange`, `describeState`)
and passes it as `blocObserver:`; the start sets and counts that one.
`observeBlocs: false` leaves `Bloc.observer` to the host, and the report goes
without that group.

## On the web and under `regulatedStrict`

There are no default stores on the web, which has no file system, and none
under `regulatedStrict`, whose stores must be encrypted: pass your own
`crashStore` and `feedbackStore` there. Without one an event that did not get
through is kept in memory only, and a feedback report is
`FeedbackRejected(FeedbackRejection.noStore)`.

## Dependencies

`noticebird` (the pure-Dart client, re-exported), `bloc`, `path_provider` (the
support directory), `package_info_plus` (the version and build),
`connectivity_plus` (the connection's return) and `http`.

Full guide: [`docs/integration.md`](../../docs/integration.md). A runnable app:
[`example/`](example).
