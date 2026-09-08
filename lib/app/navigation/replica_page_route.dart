import 'package:flutter/material.dart';

/// Replica navigation rhythm (detail-viewer R8): pages slide in from the
/// right and slide back out to the right on pop — no Material default
/// vertical/zoom drift.
class ReplicaPageRoute<T> extends PageRouteBuilder<T> {
  ReplicaPageRoute({required WidgetBuilder builder, super.settings})
      : super(
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeInOutCubic,
            );
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(1, 0),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            );
          },
          transitionDuration: const Duration(milliseconds: 300),
          reverseTransitionDuration: const Duration(milliseconds: 300),
        );
}
