import 'package:flutter/widgets.dart';
import 'package:noticebird/noticebird.dart';

/// Records navigation as breadcrumbs: add one to a navigator's observers
/// (`MaterialApp(navigatorObservers: [NoticebirdNavigatorObserver()])`, a
/// router's `observers`). Each navigator needs its own.
///
/// Every crumb, in category `navigation`, says what happened to which kind
/// of route — `Opened page`, `Closed dialog`, `Replaced page`, `Removed
/// popup` (a page is a `PageRoute`, a dialog a `RawDialogRoute`, a popup
/// any other `PopupRoute`, such as a sheet or a menu; anything else a
/// route) — with the action `route.push`, `route.pop`, `route.replace` or
/// `route.remove`, and as its details the route on top of the navigator after the
/// step (`route`) and the one on top before it (`from`), each by its name,
/// for every step alike. A step below the top — a route removed or
/// replaced under another — leaves the top as it was, so `route` and
/// `from` are the same; a step that leaves no route on top has no `route`.
/// A route is named once, when it appears, and keeps that name until it
/// goes:
///
/// - by [describe], when the host gives one and it answers a name: the place
///   for a router's path pattern, which only the host's router knows;
/// - else by its `settings.name`, when that is a template by
///   [NoticebirdClient.isRouteTemplate]: no query or fragment, and no
///   segment of digits or of a long hex id. A router that names its pages
///   by their path pattern (`/lists/:listId`) passes; so does a raw path
///   whose segments are words, such as `/users/jdoe`: an app that pushes
///   such names gives a [describe]. A name that is no breadcrumb detail value
///   (`TypedBreadcrumb.isDetailValue`, such as one with a space or more than
///   64 characters), or that reads as an identifier, is left out of the
///   step before it is sent, as in every breadcrumb;
/// - else by its kind (`MaterialPageRoute`).
///
/// With [tracksRouteTemplate], it also keeps the client's route template
/// ([NoticebirdClient.setRouteTemplate]) on the topmost page of its
/// navigator (a `PageRoute`, past dialogs and sheets), so a feedback sheet
/// opened over a screen leaves the screen's template for the report's
/// moment. A topmost page whose name is no template leaves the client with
/// none. Turn it on for one navigator, the one that holds the app's pages.
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
  /// navigator (a `PageRoute`, past dialogs and sheets): its template, or
  /// none.
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
    _note('push', 'Opened', route, top: route, from: previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _note('pop', 'Closed', route, top: previousRoute, from: route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final from = _stack.lastOrNull ?? route;
    _stack.remove(route);
    _note('remove', 'Removed', route, top: _stack.lastOrNull, from: from);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute == null) return;
    _names[newRoute] = _locate(newRoute);
    final from = _stack.lastOrNull ?? oldRoute;
    final at = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (at < 0) {
      _stack.add(newRoute);
    } else {
      _stack[at] = newRoute;
    }
    _note('replace', 'Replaced', newRoute, top: _stack.last, from: from);
  }

  /// Leaves the crumb of [step] (`push`, …) about [route], its message
  /// [verb] and the route's kind, `route` the name of [top] and `from` the
  /// name of [from].
  void _note(
    String step,
    String verb,
    Route<dynamic> route, {
    required Route<dynamic>? top,
    Route<dynamic>? from,
  }) {
    try {
      final reporter = _client ?? Noticebird.instance;
      if (reporter == null) return;
      if (tracksRouteTemplate) {
        // The topmost page, past dialogs and sheets: its template, or none.
        final page = _stack.reversed
            .whereType<PageRoute<dynamic>>()
            .firstOrNull;
        final name = page == null ? null : _name(page);
        reporter.setRouteTemplate(
          name != null && NoticebirdClient.isRouteTemplate(name) ? name : null,
        );
      }
      reporter.addBreadcrumb(
        '$verb ${_kindWord(route)}',
        action: 'route.$step',
        category: 'navigation',
        level: BreadcrumbLevel.info,
        details: {'route': ?_nameOf(top), 'from': ?_nameOf(from)},
        at: _clock(),
      );
    } catch (_) {
      // Reporting must never affect the host application.
    }
  }

  /// What kind of route [route] is, as a crumb's message says it.
  static String _kindWord(Route<dynamic> route) => switch (route) {
    PageRoute() => 'page',
    RawDialogRoute() => 'dialog',
    PopupRoute() => 'popup',
    _ => 'route',
  };

  String? _nameOf(Route<dynamic>? route) => route == null ? null : _name(route);

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
