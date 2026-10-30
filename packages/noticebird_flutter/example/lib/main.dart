import 'package:bloc/bloc.dart';
import 'package:flutter/material.dart';
import 'package:noticebird_flutter/feedback.dart';
import 'package:noticebird_flutter/noticebird_flutter.dart';

/// Publishable ingest key for a single project/environment, issued by the
/// Noticebird platform. Override it with
/// `--dart-define=NOTICEBIRD_PUBLISHABLE_KEY=noticebird_pk_...`. Only
/// publishable keys belong in a client; never embed a secret key.
const _publishableKey = String.fromEnvironment(
  'NOTICEBIRD_PUBLISHABLE_KEY',
  defaultValue: 'noticebird_pk_example00000000000000000',
);

Future<void> main() async {
  // One start: the client, the error handlers, the bloc breadcrumbs, the
  // offline stores in the support directory, and delivery at start, on
  // resume and when the connection returns. It never throws on the
  // platform, and the client never rethrows into the app.
  final noticebird = await NoticebirdFlutter.start(
    publishableKey: _publishableKey,
    appName: 'noticebird_example',
  );
  runApp(ExampleApp(reporter: noticebird.client));
}

/// A trivial cubit whose transitions the observer records as breadcrumbs.
final class CounterCubit extends Cubit<int> {
  CounterCubit() : super(0);

  void increment() => emit(state + 1);
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({required this.reporter, super.key});

  final NoticebirdClient reporter;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'noticebird example',
    navigatorObservers: [NoticebirdNavigatorObserver(client: reporter)],
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
    home: HomePage(reporter: reporter),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({required this.reporter, super.key});

  final NoticebirdClient reporter;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final CounterCubit _counter = CounterCubit();
  String? _status;
  bool _loggedIn = false;
  bool _liveSessionActive = false;

  @override
  void dispose() {
    _counter.close();
    super.dispose();
  }

  void _toggleLogin() {
    // A bounded, opaque id only — never an email or free-form profile.
    widget.reporter.setUserId(_loggedIn ? null : 'demo_user_42');
    if (_loggedIn) widget.reporter.clearBreadcrumbs();
    setState(() {
      _loggedIn = !_loggedIn;
      _status = _loggedIn ? 'Logged in as demo_user_42' : 'Logged out';
    });
  }

  Future<void> _sendFeedback() async {
    // A feedback report, triaged apart from crashes: the client adds the app,
    // platform, session, route and breadcrumb trail, and redacts the message
    // on the device. It never throws; the outcome says what became of it.
    // A real sheet takes the moment when it opens, and passes it on here.
    final moment = widget.reporter.feedbackMoment();
    final outcome = await widget.reporter.captureFeedback(
      kind: FeedbackKind.bug,
      message: 'Example feedback: sync keeps failing',
      moment: moment,
    );
    if (!mounted) return;
    setState(
      () => _status = switch (outcome) {
        FeedbackDelivered(:final ticket) =>
          ticket == null
              ? 'Feedback sent'
              : 'Feedback sent as ${ticket.display}',
        FeedbackQueued() => 'Feedback queued for retry',
        FeedbackDisabled() => 'Feedback is not configured',
        FeedbackRejected(:final reason) => 'Feedback rejected: ${reason.name}',
      },
    );
  }

  void _toggleLiveDebugSession() {
    if (_liveSessionActive) {
      widget.reporter.stopLiveDebugSession();
    } else {
      // Eligibility/tokens are the host app's concern; the client only knows
      // a session id is active until this expiry.
      widget.reporter.startLiveDebugSession(
        sessionId: 'demo-session',
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
      );
    }
    setState(() {
      _liveSessionActive = !_liveSessionActive;
      _status = _liveSessionActive
          ? 'Live debug session started — breadcrumbs sync immediately'
          : 'Live debug session stopped';
    });
  }

  Future<void> _reportHandledError() async {
    // A handled error is captured without interrupting the user. Passing the
    // current stack groups its occurrences into one issue.
    final result = await widget.reporter.captureException(
      StateError('example handled failure'),
      StackTrace.current,
      severity: CrashSeverity.warning,
      handled: true,
      tags: const {AllowedTag.feature: 'example', AllowedTag.operation: 'demo'},
    );
    if (!mounted) return;
    setState(
      () => _status = switch (result.outcome) {
        CaptureOutcome.sent => 'Handled error reported',
        CaptureOutcome.deduplicated => 'Duplicate report suppressed',
        CaptureOutcome.queued => 'Report queued for retry',
        CaptureOutcome.dropped => 'Report dropped',
        CaptureOutcome.ignored => 'Report ignored by the capture filter',
        CaptureOutcome.discarded => 'Crash uploads are off',
      },
    );
  }

  void _triggerUnhandledError() {
    // Thrown from a callback with no try/catch. Flutter routes it to the error
    // handler NoticebirdFlutter.start installed, so the reporter records it
    // and the app keeps running instead of crashing.
    throw StateError('example unhandled failure');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('noticebird example')),
    body: Center(
      child: StreamBuilder<int>(
        initialData: _counter.state,
        stream: _counter.stream,
        builder: (context, snapshot) => Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            Text(
              'Breadcrumb count: ${snapshot.data}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            FilledButton(
              onPressed: _counter.increment,
              child: const Text('Add breadcrumb'),
            ),
            OutlinedButton(
              onPressed: _reportHandledError,
              child: const Text('Report handled error'),
            ),
            OutlinedButton(
              onPressed: _triggerUnhandledError,
              child: const Text('Trigger unhandled error'),
            ),
            OutlinedButton(
              onPressed: _toggleLogin,
              child: Text(_loggedIn ? 'Simulate logout' : 'Simulate login'),
            ),
            OutlinedButton(
              onPressed: _sendFeedback,
              child: const Text('Send feedback'),
            ),
            OutlinedButton(
              onPressed: _toggleLiveDebugSession,
              child: Text(
                _liveSessionActive
                    ? 'Stop live debug session'
                    : 'Start live debug session',
              ),
            ),
            if (_status != null) Text(_status!),
          ],
        ),
      ),
    ),
  );
}
