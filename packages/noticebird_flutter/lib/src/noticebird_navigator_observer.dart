import 'package:flutter/widgets.dart';
import 'package:noticebird/noticebird.dart';

/// Records navigation as breadcrumbs: add one to a navigator's observers
/// (`MaterialApp(navigatorObservers: [NoticebirdNavigatorObserver()])`, a
/// router's `observers`). Each navigator needs its own.
///
/// Every crumb names the route it is about as its component — the pushed,
/// popped, replaced or removed one — and, when there is a route on either
/// side, the step as its operation: `from → to`. A route is named once, when
/// it appears, and keeps that name until it goes:
///
/// - by [describe], when the host gives one and it answers a name: the place
///   for a router's path pattern, which only the host's router knows;
/// - else by its `settings.name`, when that is a template by
///   [NoticebirdClient.isRouteTemplate]: no query or fragment, and no
///   segment of digits or of a long hex id. A router that names its pages
///   by their path pattern (`/lists/:listId`) passes; so does a raw path
///   whose segments are words, such as `/users/jdoe`: an app that pushes
///   such names gives a [describe]. What the platform's firewall rejects in
///   a name (an e-mail address) is redacted before a breadcrumb leaves the
///   device, as in every breadcrumb;
/// - else by its kind (`MaterialPageRoute`).
///
/// With [tracksRouteTemplate], it also keeps the client's route template
/// ([NoticebirdClient.setRouteTemplate]) on the topmost route of its
/// navigator whose name is a template: a page's, not a dialog's or a
/// sheet's, so a feedback sheet opened over a screen leaves the screen's
/// template for the report's moment. Turn it on for one navigator, the one
/// that holds the app's pages; with none whose name is a template, the
/// client has no route template.
///
/// The crumbs go to [client], or the client attached to `Noticebird` when
/// there is none; before one is attached they go nowhere.
class NoticebirdNavigatorObserver extends NavigatorObserver {
  NoticebirdNavigatorObserver({
    this.describe,
    this.tracksRouteTemplate = false,
    NoticebirdClient? client,
    DateTime Function()? clock,
  }) : _client = client,
       _clock = clock ?? DateTime.now;

  /// The host's name for a route, or `null` to leave it to the observer.
  /// What it answers leaves the device: a template or a kind, never a value
  /// the user typed or a token.
  final String? Function(Route<dynamic> route)? describe;

  /// Whether the client's route template follows the topmost page of this
  /// navigator whose name is a template.
  final bool tracksRouteTemplate;

  /// The routes of the navigator, oldest first, as this observer saw them.
  final List<Route<dynamic>> _stack = [];

  final NoticebirdClient? _client;
  final DateTime Function() _clock;
  final Expando<String> _names = Expando('route names');

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _names[route] = _locate(route);
    _stack.add(route);
    _note('route.push', route, from: previousRoute, to: route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _note('route.pop', route, from: route, to: previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _note('route.remove', route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute == null) return;
    _names[newRoute] = _locate(newRoute);
    final at = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (at < 0) {
      _stack.add(newRoute);
    } else {
      _stack[at] = newRoute;
    }
    _note('route.replace', newRoute, from: oldRoute, to: newRoute);
  }

  void _note(
    String action,
    Route<dynamic> route, {
    Route<dynamic>? from,
    Route<dynamic>? to,
  }) {
    try {
      final reporter = _client ?? Noticebird.instance;
      if (reporter == null) return;
      if (tracksRouteTemplate) {
        reporter.setRouteTemplate(
          _stack.reversed
              .map(_name)
              .where(NoticebirdClient.isRouteTemplate)
              .firstOrNull,
        );
      }
      reporter.addBreadcrumb(
        TypedBreadcrumb(
          occurredAt: _clock().toUtc(),
          category: BreadcrumbCategory.navigation,
          action: action,
          data: {
            AllowedTag.component: _name(route),
            if (from != null && to != null)
              AllowedTag.operation: '${_name(from)} → ${_name(to)}',
          },
        ),
      );
    } catch (_) {
      // Reporting must never affect the host application.
    }
  }

  /// The name [route] got when it appeared; one from before this observer
  /// was attached is named now.
  String _name(Route<dynamic> route) => _names[route] ??= _locate(route);

  String _locate(Route<dynamic> route) {
    try {
      if (describe?.call(route) case final described?) return described;
    } catch (_) {
      // A describe that fails leaves the name to the observer.
    }
    final name = route.settings.name;
    if (name != null && NoticebirdClient.isRouteTemplate(name)) return name;
    return _kind(route);
  }

  /// The route's class without its type arguments: what kind of route it is.
  static String _kind(Route<dynamic> route) {
    final type = route.runtimeType.toString();
    final generic = type.indexOf('<');
    return generic < 0 ? type : type.substring(0, generic);
  }
}
