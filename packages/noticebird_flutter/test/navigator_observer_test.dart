// NoticebirdNavigatorObserver: a breadcrumb per step — a message of what
// happened to which kind of route, an action per step, and the routes on top
// after and before it as data — named by the host's describe, a route name
// that is a template, or the route's kind, so a raw path never reaches the
// trail by default.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noticebird_flutter/noticebird_flutter.dart';
import 'package:noticebird_flutter/testing.dart';

final class _Sheet extends PopupRoute<void> {
  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => null;

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> a,
    Animation<double> b,
  ) => const SizedBox();
}

final class _Route extends PageRouteBuilder<void> {
  _Route(String? name)
    : super(
        settings: RouteSettings(name: name),
        pageBuilder: (_, _, _) => const SizedBox(),
      );
}

void main() {
  late NoticebirdClient client;

  setUp(() {
    client = NoticebirdClient(
      config: NoticebirdConfig(
        privacyProfile: CrashPrivacyProfile.privacyDefault,
        app: const AppMetadata(
          name: 'test',
          version: '1.0.0',
          build: '1',
          release: 'test@1.0.0+1',
        ),
        platform: const PlatformMetadata(
          platform: CrashPlatform.unknown,
          osVersion: 'test',
          deviceClass: 'test',
        ),
      ),
    );
  });

  List<(String?, Object?, Object?)> trail() => [
    for (final crumb in client.recentBreadcrumbs)
      (crumb.action, crumb.data['route'], crumb.data['from']),
  ];

  test('records push, replace, pop and remove, the route on top after the '
      'step and before it', () {
    final observer = NoticebirdNavigatorObserver(client: client);
    final home = _Route('/home');
    final list = _Route('/lists/:listId');
    final detail = _Route('/lists/:listId/items/:itemId');

    observer
      ..didPush(home, null)
      ..didPush(list, home)
      ..didReplace(newRoute: detail, oldRoute: list)
      ..didPop(detail, home)
      ..didRemove(home, null);

    expect(trail(), [
      ('route.push', '/home', null),
      ('route.push', '/lists/:listId', '/home'),
      ('route.replace', '/lists/:listId/items/:itemId', '/lists/:listId'),
      ('route.pop', '/home', '/lists/:listId/items/:itemId'),
      ('route.remove', null, '/home'),
    ]);
    expect(
      [for (final crumb in client.recentBreadcrumbs) crumb.message],
      [
        'Opened page',
        'Opened page',
        'Replaced page',
        'Closed page',
        'Removed page',
      ],
    );
    for (final crumb in client.recentBreadcrumbs) {
      expect(crumb.category, 'navigation');
      expect(crumb.level, BreadcrumbLevel.info);
    }
  });

  test('a step below the top leaves route and from both the top', () {
    final observer = NoticebirdNavigatorObserver(client: client);
    final home = _Route('/home');
    final list = _Route('/lists/:listId');
    final detail = _Route('/lists/:listId/items/:itemId');
    final other = _Route('/settings');

    observer
      ..didPush(home, null)
      ..didPush(list, home)
      ..didPush(detail, list)
      ..didReplace(newRoute: other, oldRoute: list)
      ..didRemove(home, null)
      ..didRemove(detail, other);

    expect(trail().skip(3), [
      (
        'route.replace',
        '/lists/:listId/items/:itemId',
        '/lists/:listId/items/:itemId',
      ),
      (
        'route.remove',
        '/lists/:listId/items/:itemId',
        '/lists/:listId/items/:itemId',
      ),
      ('route.remove', '/settings', '/lists/:listId/items/:itemId'),
    ]);
  });

  test('the message names the kind of route', () {
    final observer = NoticebirdNavigatorObserver(client: client);
    final home = _Route('/home');
    final sheet = _Sheet();
    final dialog = RawDialogRoute<void>(
      pageBuilder: (_, _, _) => const SizedBox(),
    );

    observer
      ..didPush(home, null)
      ..didPush(sheet, home)
      ..didPop(sheet, home)
      ..didPush(dialog, home)
      ..didPop(dialog, home);

    expect(
      [for (final crumb in client.recentBreadcrumbs) crumb.message],
      [
        'Opened page',
        'Opened popup',
        'Closed popup',
        'Opened dialog',
        'Closed dialog',
      ],
    );
    expect(client.recentBreadcrumbs[1].data, {
      'route': '_Sheet',
      'from': '/home',
    });
    expect(client.recentBreadcrumbs[2].data, {
      'route': '/home',
      'from': '_Sheet',
    });
  });

  test('a name that is no template is left out for the route\'s kind', () {
    final observer = NoticebirdNavigatorObserver(client: client);

    observer
      ..didPush(_Route('/l/abc?q=secret'), null)
      ..didPush(_Route('/lists/42'), null)
      ..didPush(_Route(null), null);

    expect(trail().map((crumb) => crumb.$2), ['_Route', '_Route', '_Route']);
  });

  test(
    'a name the event does not take is left out of it, not the step',
    () async {
      final transport = RecordingCrashTransport();
      final sending = NoticebirdClient(
        config: NoticebirdConfig(
          privacyProfile: CrashPrivacyProfile.privacyDefault,
          app: const AppMetadata(
            name: 'test',
            version: '1.0.0',
            build: '1',
            release: 'test@1.0.0+1',
          ),
          platform: const PlatformMetadata(
            platform: CrashPlatform.unknown,
            osVersion: 'test',
            deviceClass: 'test',
          ),
          sessionIdFactory: () => 'test_session_1234567890',
        ),
        transport: transport,
      );
      NoticebirdNavigatorObserver(
        client: sending,
        describe: (route) => 'the list page',
      ).didPush(_Route('/lists'), null);

      await sending.captureException(StateError('boom'), StackTrace.empty);

      final step = (transport.events.single['breadcrumbs']! as List).single;
      expect(step, {
        'at': (step as Map)['at'],
        'message': 'Opened page',
        'action': 'route.push',
        'category': 'navigation',
        'level': 'info',
      });
    },
  );

  test('the host\'s describe names a route first', () {
    final observer = NoticebirdNavigatorObserver(
      client: client,
      describe: (route) =>
          route.settings.name == '/lists/42' ? '/lists/:listId' : null,
    );

    observer
      ..didPush(_Route('/lists/42'), null)
      ..didPush(_Route('/home'), null);

    expect(trail().map((crumb) => crumb.$2), ['/lists/:listId', '/home']);
  });

  test('without a client it goes to the attached one, or nowhere', () {
    final observer = NoticebirdNavigatorObserver();
    observer.didPush(_Route('/home'), null);
    expect(client.recentBreadcrumbs, isEmpty);

    Noticebird.attach(client);
    addTearDown(Noticebird.detach);
    observer.didPush(_Route('/next'), null);

    expect(trail().single.$2, '/next');
  });

  group('with tracksRouteTemplate', () {
    late NoticebirdNavigatorObserver observer;
    setUp(
      () => observer = NoticebirdNavigatorObserver(
        client: client,
        tracksRouteTemplate: true,
      ),
    );

    test('the client\'s route follows the topmost page, past a sheet', () {
      final home = _Route('/home');
      final list = _Route('/lists/:listId');
      final sheet = _Sheet();

      observer.didPush(home, null);
      observer.didPush(list, home);
      expect(client.feedbackMoment().routeTemplate, '/lists/:listId');

      observer.didPush(sheet, list);
      expect(client.feedbackMoment().routeTemplate, '/lists/:listId');

      observer
        ..didPop(sheet, list)
        ..didPop(list, home);
      expect(client.feedbackMoment().routeTemplate, '/home');

      observer.didReplace(newRoute: _Route('/l/abc?q=1'), oldRoute: home);
      expect(client.feedbackMoment().routeTemplate, isNull);

      // A page without a template is no template, not the one below it.
      observer
        ..didReplace(newRoute: _Route('/home'), oldRoute: null)
        ..didPush(_Route(null), null);
      expect(client.feedbackMoment().routeTemplate, isNull);
    });

    test('is off by default', () {
      NoticebirdNavigatorObserver(
        client: client,
      ).didPush(_Route('/home'), null);
      expect(client.feedbackMoment().routeTemplate, isNull);
    });
  });
}
