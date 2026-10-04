import 'package:material_ui/material_ui.dart';

import '../motion/motion_tokens.dart';

/// Sideways drag for a page's own tabs. The gesture stops at the first and
/// last tab; it never changes the home branch.
class TabSwipeSwitcher extends StatefulWidget {
  const TabSwipeSwitcher({
    super.key,
    required this.tabController,
    this.onPrepareAdjacent,
    required this.child,
  });

  final TabController tabController;
  final ValueChanged<int>? onPrepareAdjacent;
  final Widget child;

  static const minFlingVelocity = 400.0;
  static const distanceFraction = 0.25;

  @override
  State<TabSwipeSwitcher> createState() => _TabSwipeSwitcherState();
}

class _TabSwipeSwitcherState extends State<TabSwipeSwitcher>
    with SingleTickerProviderStateMixin {
  double _rawDx = 0;
  double _dragOrigin = 0;
  bool _active = false;
  AnimationController? _settle;
  Animation<double>? _settleAnim;
  int _settleTarget = 0;

  TabController get _tc => widget.tabController;
  bool get _ltr => Directionality.of(context) == TextDirection.ltr;

  @override
  void dispose() {
    _settle?.dispose();
    super.dispose();
  }

  void _onDragStart(DragStartDetails details) {
    _active = true;
    _rawDx = 0;
    _settle?.stop();
    if (_tc.indexIsChanging) {
      _tc.index = _tc.animation!.value.round().clamp(0, _tc.length - 1);
    }
    _dragOrigin = _tc.animation?.value ?? _tc.index.toDouble();
    widget.onPrepareAdjacent?.call(_dragOrigin.round());
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _rawDx += details.delta.dx;
    final width = MediaQuery.sizeOf(context).width;
    if (width <= 0 || _tc.length < 2) return;
    final delta = (_ltr ? -details.delta.dx : details.delta.dx) / width;
    final position = _tc.animation?.value ?? _tc.index.toDouble();
    _writeTab((position + delta).clamp(0.0, _tc.length - 1.0));
  }

  void _writeTab(double target) {
    if ((target - _tc.index).abs() > 0.5) {
      _tc.index = target.round().clamp(0, _tc.length - 1);
    }
    _tc.offset = (target - _tc.index).clamp(-1.0, 1.0);
  }

  void _onDragEnd(DragEndDetails details) {
    if (!_active) return;
    _active = false;
    final width = MediaQuery.sizeOf(context).width;
    final velocity = details.primaryVelocity ?? 0;
    final fling = velocity.abs() >= TabSwipeSwitcher.minFlingVelocity;
    final position = _tc.animation?.value ?? _tc.index.toDouble();
    final base = _dragOrigin.round().clamp(0, _tc.length - 1);
    final moved = position - base;
    final committed =
        fling ||
        _rawDx.abs() >= width * TabSwipeSwitcher.distanceFraction ||
        moved.abs() >= TabSwipeSwitcher.distanceFraction;
    if (!committed) {
      _settleTo(base);
      return;
    }
    final forward = ((fling ? velocity : _rawDx) < 0) == _ltr;
    final target = (base + (forward ? 1 : -1)).clamp(0, _tc.length - 1);
    if (target == base) {
      _settleTo(base);
      return;
    }
    _landOn(target);
  }

  void _landOn(int target) {
    if (target == _tc.index) {
      _settleTo(target);
      return;
    }
    _tc.animateTo(
      target,
      duration: MotionTokens.resolve(context, MotionTokens.tabSwitch),
    );
  }

  void _onDragCancel() {
    if (!_active) return;
    _active = false;
    _settle?.stop();
    _settleTo(_tc.index);
  }

  void _settleTo(int target) {
    final from = _tc.animation?.value ?? _tc.index.toDouble();
    _settleTarget = target;
    final duration = MotionTokens.resolve(context, MotionTokens.fast);
    if (duration == Duration.zero || (from - target).abs() < 1e-4) {
      _tc.index = target;
      _tc.offset = 0;
      return;
    }
    final controller = _settle ??= AnimationController(vsync: this)
      ..addListener(_applySettle)
      ..addStatusListener(_finishSettle);
    controller.duration = duration;
    _settleAnim = Tween<double>(begin: from, end: target.toDouble()).animate(
      CurvedAnimation(parent: controller, curve: MotionTokens.fastCurve),
    );
    controller.forward(from: 0);
  }

  void _applySettle() {
    final anim = _settleAnim;
    if (anim == null || _tc.indexIsChanging) return;
    _tc.offset = (anim.value - _tc.index).clamp(-1.0, 1.0);
  }

  void _finishSettle(AnimationStatus status) {
    if (status != AnimationStatus.completed || _tc.indexIsChanging) return;
    _tc.index = _settleTarget;
    _tc.offset = 0;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: _onDragStart,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      onHorizontalDragCancel: _onDragCancel,
      child: widget.child,
    );
  }
}

/// Tab bodies arranged side by side and driven by the tab controller's live
/// animation. Each visited body stays mounted, preserving its scroll state.
class TabSlideStack extends StatelessWidget {
  const TabSlideStack({
    super.key,
    required this.controller,
    required this.children,
  });

  final TabController controller;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final animation = controller.animation;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    Widget stack(double position) => Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.hardEdge,
      children: [
        for (var i = 0; i < children.length; i++)
          Offstage(
            offstage: (i - position).abs() > 1.0,
            child: FractionalTranslation(
              translation: Offset(rtl ? position - i : i - position, 0),
              child: children[i],
            ),
          ),
      ],
    );
    if (animation == null) return stack(controller.index.toDouble());
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) => stack(animation.value),
    );
  }
}
