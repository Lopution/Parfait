import 'package:flutter/widgets.dart';

/// Whether the enclosing detail page is the one the user is looking at.
///
/// The detail pager builds its neighbours ahead of the swipe; deferred
/// network work (related works) waits until the page becomes current. A
/// detail route outside the pager has no scope and counts as active.
class DetailPageActivity extends InheritedWidget {
  const DetailPageActivity({
    super.key,
    required this.active,
    required super.child,
  });

  final bool active;

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<DetailPageActivity>()
          ?.active ??
      true;

  @override
  bool updateShouldNotify(DetailPageActivity oldWidget) =>
      active != oldWidget.active;
}
