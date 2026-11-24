import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';

/// The animation of the route a page is in, provided by [FuncPage] so a
/// widget can listen to its route's transition without depending on the
/// route's status.
///
/// `ModalRoute.of(context)` rebuilds its caller whenever the route's
/// `isCurrent` or `canPop` changes: at the start of every pop and whenever
/// a page is pushed above. A detail page that only wanted the animation
/// rebuilt in full as it left, with both neighbours, in the first frame of
/// the back transition. The animation is one object for the route's life,
/// so a dependency on it never fires.
///
/// [FuncPage] provides its controller, not `ModalRoute.animation`: that
/// proxy reports `completed` for the offstage frame a Hero measures an
/// opening page in, the frame the flight takes the page's Hero child from.
class RouteAnimationScope extends InheritedWidget {
  const RouteAnimationScope({
    super.key,
    required this.animation,
    this.popGesture,
    required super.child,
  });

  final Animation<double> animation;

  /// Whether an interactive iOS edge swipe-back gesture is driving [animation].
  final ValueListenable<bool>? popGesture;

  static RouteAnimationScope? _sameNavigatorScope(BuildContext context) {
    final scope = context
        .getElementForInheritedWidgetOfExactType<RouteAnimationScope>();
    if (scope != null &&
        identical(
          scope.findAncestorStateOfType<NavigatorState>(),
          context.findAncestorStateOfType<NavigatorState>(),
        )) {
      context.dependOnInheritedElement(scope);
      return scope.widget as RouteAnimationScope;
    }
    return null;
  }

  /// The animation of the route [context] is in. A route that is not a
  /// [FuncPage] (a dialog, a test's `MaterialPageRoute`) provides no scope
  /// of its own, so the nearest one would belong to a route further out;
  /// those fall back to `ModalRoute.of` and its status dependency.
  static Animation<double>? of(BuildContext context) =>
      _sameNavigatorScope(context)?.animation ??
      ModalRoute.of(context)?.animation;

  /// Interactive iOS pop-gesture state for the enclosing [FuncPage] route, or
  /// `null` outside a [FuncPage].
  static ValueListenable<bool>? popGestureOf(BuildContext context) =>
      _sameNavigatorScope(context)?.popGesture;

  @override
  bool updateShouldNotify(RouteAnimationScope oldWidget) =>
      !identical(animation, oldWidget.animation) ||
      !identical(popGesture, oldWidget.popGesture);
}
