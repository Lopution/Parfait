import 'package:flutter/widgets.dart';

import 'motion_tokens.dart';

/// How a [Removable] leaves.
enum RemovalStyle {
  /// List row: the height collapses while it fades, so the rows below
  /// slide up under it.
  row,

  /// Grid tile: shrinks to [_tileExitScale] while it fades; the grid
  /// reflows once the data drops it (a grid cell cannot collapse).
  tile,
}

const _tileExitScale = 0.9;

/// Plays list-item exits ahead of the data change. The list stays driven by
/// its provider: a page first awaits [playExit] for the ids it is about to
/// delete, then commits the delete, and calls [restore] when the commit
/// fails. Owned by the page state and handed down by a [RemovalScope].
class RemovalController {
  final Map<Object, _RemovableState> _items = {};

  /// Plays the exit of every built [Removable] among [ids]; ids not on
  /// screen are skipped. Completes at once under reduced motion.
  Future<void> playExit(Iterable<Object> ids) =>
      Future.wait([for (final id in ids) ?_items[id]?._animateTo(0)]);

  /// Brings back items whose delete failed after [playExit].
  void restore(Iterable<Object> ids) {
    for (final id in ids) {
      _items[id]?._animateTo(1);
    }
  }

  void _register(Object id, _RemovableState item) => _items[id] = item;

  void _unregister(Object id, _RemovableState item) {
    if (identical(_items[id], item)) _items.remove(id);
  }
}

/// Hands a [RemovalController] to the [Removable]s below it.
class RemovalScope extends InheritedWidget {
  const RemovalScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final RemovalController controller;

  static RemovalController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RemovalScope>()?.controller;

  /// For event handlers (a row's delete action): looks the controller up
  /// without registering a rebuild dependency.
  static RemovalController of(BuildContext context) {
    final controller = context
        .getInheritedWidgetOfExactType<RemovalScope>()
        ?.controller;
    assert(controller != null, 'No RemovalScope above this context');
    return controller!;
  }

  @override
  bool updateShouldNotify(RemovalScope oldWidget) =>
      controller != oldWidget.controller;
}

/// One removable list item, registered under [id] with the nearest
/// [RemovalScope]. Collapses (row) or shrinks (tile) and fades on the
/// [MotionSpring.spatialFast] spring when its exit plays. A recycled slot
/// that now shows another id starts fully present. Without a scope it
/// renders [child] unchanged.
class Removable extends StatefulWidget {
  const Removable({
    super.key,
    required this.id,
    this.style = RemovalStyle.row,
    this.animateIn = false,
    required this.child,
  });

  final Object id;
  final RemovalStyle style;

  /// Plays the exit backwards when first built: for rows a user action
  /// inserts (a group expanding). Rows a lazy list builds on scroll pass
  /// false and appear as they are.
  final bool animateIn;
  final Widget child;

  @override
  State<Removable> createState() => _RemovableState();
}

class _RemovableState extends State<Removable>
    with SingleTickerProviderStateMixin {
  /// 1 present, 0 gone; linear in time, shaped by [_shaped].
  late final AnimationController _presence = AnimationController(
    vsync: this,
    value: widget.animateIn ? 0 : 1,
  );

  /// Curves are set per run: they follow the animation speed setting.
  late final CurvedAnimation _shaped = CurvedAnimation(
    parent: _presence,
    curve: Curves.linear,
  );
  RemovalController? _controller;
  late bool _pendingEnter = widget.animateIn;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The spring needs the motion scope, so the entrance starts here.
    if (_pendingEnter) {
      _pendingEnter = false;
      _animateTo(1);
    }
    final controller = RemovalScope.maybeOf(context);
    if (controller == _controller) return;
    _controller?._unregister(widget.id, this);
    _controller = controller?.._register(widget.id, this);
  }

  @override
  void didUpdateWidget(Removable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id == widget.id) return;
    _controller
      ?.._unregister(oldWidget.id, this)
      .._register(widget.id, this);
    _presence.value = 1;
  }

  @override
  void dispose() {
    _controller?._unregister(widget.id, this);
    _shaped.dispose();
    _presence.dispose();
    super.dispose();
  }

  /// Runs to [target] (0 or 1) over the spring's settle time. Leaving runs
  /// the controller in reverse, where the flipped curve makes the exit start
  /// fast and settle at zero, like the spring itself.
  Future<void> _animateTo(double target) async {
    final (duration, curve) = MotionTokens.springCurve(
      context,
      MotionSpring.spatialFast,
    );
    if (duration == Duration.zero) {
      _presence.value = target;
      return;
    }
    _shaped
      ..curve = curve
      ..reverseCurve = curve.flipped;
    _presence.duration = duration;
    // reverse()/forward() rather than animateTo: the curve follows the
    // controller's direction, and animateTo always reports forward.
    final run = target == 0 ? _presence.reverse() : _presence.forward();
    try {
      await run.orCancel;
    } on TickerCanceled {
      // Disposed mid-exit (the data already dropped it): nothing to wait on.
    }
  }

  @override
  Widget build(BuildContext context) {
    final shaped = switch (widget.style) {
      RemovalStyle.row => SizeTransition(
        sizeFactor: _shaped,
        child: widget.child,
      ),
      RemovalStyle.tile => ScaleTransition(
        scale: Tween(begin: _tileExitScale, end: 1.0).animate(_shaped),
        child: widget.child,
      ),
    };
    return FadeTransition(opacity: _shaped, child: shaped);
  }
}
