import 'package:material_ui/material_ui.dart';

/// Shared observer for route-scoped foreground work such as history timing.
/// Tests may use a plain MaterialApp; history still starts on the current
/// route, while the production app supplies this observer for push/pop cover
/// events.
final replicaRouteObserver = RouteObserver<ModalRoute<dynamic>>();

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
