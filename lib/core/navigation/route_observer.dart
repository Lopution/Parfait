/// Route visibility observer used by history and other foreground work.
/// The core navigation domain exposes observation only; route construction is
/// owned by the app routes facade. See `guides/architecture.md`.
library;

import 'package:material_ui/material_ui.dart';

/// Shared observer for route-scoped foreground work such as history timing.
/// Tests may use a plain MaterialApp; history still starts on the current
/// route, while the production app supplies this observer for push/pop cover
/// events.
final replicaRouteObserver = ExitAwareRouteObserver();

/// A [RouteObserver] that also names the route a pop removes, for the
/// subscribers [RouteAware.didPopNext] reaches: the route below is current
/// again from the pop's first frame, while the popped one may still be
/// animating out over it — and a popup does not drive the route below's
/// secondary animation, so nothing else tells it so.
class ExitAwareRouteObserver extends RouteObserver<ModalRoute<dynamic>> {
  Route<dynamic>? _popping;

  /// The route being popped. Set only while [didPop] notifies, so it is
  /// read from [RouteAware.didPopNext]; null anywhere else.
  Route<dynamic>? get popping => _popping;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _popping = route;
    try {
      super.didPop(route, previousRoute);
    } finally {
      _popping = null;
    }
  }
}

class RouteObserverScope extends InheritedWidget {
  const RouteObserverScope({
    super.key,
    required this.observer,
    required super.child,
  });

  final RouteObserver<ModalRoute<dynamic>> observer;

  static RouteObserver<ModalRoute<dynamic>>? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<RouteObserverScope>()
        ?.observer;
  }

  @override
  bool updateShouldNotify(RouteObserverScope oldWidget) =>
      !identical(observer, oldWidget.observer);
}
