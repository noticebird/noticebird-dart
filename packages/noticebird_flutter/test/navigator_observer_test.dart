// NoticebirdNavigatorObserver: a breadcrumb per step, named by the host's
// describe, a route name that is a template, or the route's kind, so a raw
// path never reaches the trail by default.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noticebird_flutter/noticebird_flutter.dart';

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

  List<(String, Object?, Object?)> trail() => [
    for (final crumb in client.recentBreadcrumbs)
      (
        crumb.action,
        crumb.data[AllowedTag.component],
        crumb.data[AllowedTag.operation],
      ),
  ];

  test('records push, replace, pop and remove, from and to', () {
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
      ('route.push', '/lists/:listId', '/home → /lists/:listId'),
      (
        'route.replace',
        '/lists/:listId/items/:itemId',
        '/lists/:listId → /lists/:listId/items/:itemId',
      ),
      (
        'route.pop',
        '/lists/:listId/items/:itemId',
        '/lists/:listId/items/:itemId → /home',
      ),
      ('route.remove', '/home', null),
    ]);
  });

  test('a name that is no template is left out for the route\'s kind', () {
    final observer = NoticebirdNavigatorObserver(client: client);

    observer
      ..didPush(_Route('/l/abc?q=secret'), null)
      ..didPush(_Route('/lists/42'), null)
      ..didPush(_Route(null), null);

    expect(trail().map((crumb) => crumb.$2), ['_Route', '_Route', '_Route']);
  });

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
      final sheet = _Route(null);

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
    });

    test('is off by default', () {
      NoticebirdNavigatorObserver(
        client: client,
      ).didPush(_Route('/home'), null);
      expect(client.feedbackMoment().routeTemplate, isNull);
    });
  });
}
