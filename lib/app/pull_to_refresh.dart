import 'dart:math' as math;

import 'package:flutter/material.dart';

/// RefreshIndicator with the small interaction correction used by Pixiv
/// feeds: an armed pull follows the finger back below the threshold instead
/// of staying pinned until release.
///
/// The framework's no-spinner variant still owns the refresh lifecycle and
/// trigger semantics. This wrapper only renders the same progress indicator
/// from the scroll notifications, so a reverse drag can be represented
/// continuously without copying the framework implementation.
class PullToRefresh extends StatefulWidget {
  const PullToRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
  });

  final RefreshCallback onRefresh;
  final Widget child;

  @override
  State<PullToRefresh> createState() => _PullToRefreshState();
}

class _PullToRefreshState extends State<PullToRefresh>
    with SingleTickerProviderStateMixin {
  static const _dragContainerExtentPercentage = 0.25;
  // Keep the same overshoot limit as Flutter's RefreshIndicator. Unlike the
  // framework's armed state, our visual value is allowed to come back down
  // while the pointer is still held.
  static const _dragSizeFactorLimit = 1.5;
  static const _indicatorTravel = 56.0;

  late final AnimationController _dismissController;
  Animation<double>? _dismissAnimation;
  double _dragOffset = 0;
  double _indicatorOffset = 0;
  double _viewportDimension = 1;
  double _progress = 0;
  bool _tracking = false;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _dismissController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 200),
        )..addListener(() {
          final animation = _dismissAnimation;
          if (animation == null || !mounted) return;
          setState(() => _progress = animation.value);
        });
  }

  @override
  void dispose() {
    _dismissController.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical ||
        _refreshing) {
      return false;
    }

    final metrics = notification.metrics;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null &&
        metrics.axisDirection == AxisDirection.down &&
        metrics.extentBefore == 0) {
      _stopDismissAnimation();
      _tracking = true;
      _dragOffset = 0;
      _indicatorOffset = 0;
      _viewportDimension = metrics.viewportDimension;
      _setIndicatorOffset(0);
      return false;
    }

    if (metrics.axisDirection != AxisDirection.down) {
      return false;
    }

    if (notification is ScrollUpdateNotification && _tracking) {
      _viewportDimension = metrics.viewportDimension;
      _applyDragDelta(-(notification.scrollDelta ?? 0));
    } else if (notification is OverscrollNotification &&
        notification.overscroll < 0) {
      _tracking = true;
      _viewportDimension = metrics.viewportDimension;
      _applyDragDelta(-notification.overscroll);
    }

    if (notification is ScrollEndNotification) {
      _tracking = false;
    }
    return false;
  }

  void _applyDragDelta(double delta) {
    _dragOffset = math.max(0, _dragOffset + delta);
    final maxIndicatorOffset = _refreshThreshold * _dragSizeFactorLimit;
    _setIndicatorOffset(
      (_indicatorOffset + delta).clamp(0.0, maxIndicatorOffset).toDouble(),
    );
  }

  void _setIndicatorOffset(double value) {
    _indicatorOffset = math.max(0, value);
    final threshold = math.max(
      1,
      _viewportDimension * _dragContainerExtentPercentage,
    );
    final nextProgress = _indicatorOffset / threshold;
    if ((nextProgress - _progress).abs() < 0.001 || !mounted) return;
    setState(() => _progress = nextProgress);
  }

  void _stopDismissAnimation() {
    if (!_dismissController.isAnimating) return;
    _dismissController.stop();
    _dismissAnimation = null;
  }

  void _animateDismiss() {
    if (_progress <= 0) {
      if (mounted) setState(() => _progress = 0);
      return;
    }
    _dismissController
      ..stop()
      ..value = 0;
    _dismissAnimation = Tween<double>(begin: _progress, end: 0).animate(
      CurvedAnimation(parent: _dismissController, curve: Curves.easeOut),
    );
    _dismissController.forward();
  }

  void _onStatusChange(RefreshIndicatorStatus? status) {
    if (status == RefreshIndicatorStatus.refresh) {
      if (!_refreshing && _dragOffset >= _refreshThreshold) {
        setState(() {
          _refreshing = true;
          _progress = 1;
        });
      }
      return;
    }
    if (status == RefreshIndicatorStatus.canceled) {
      _tracking = false;
      _animateDismiss();
    }
  }

  double get _refreshThreshold =>
      math.max(1, _viewportDimension * _dragContainerExtentPercentage);

  Future<void> _handleRefresh() async {
    // RefreshIndicator keeps `armed` at its minimum visual offset after the
    // user reverses. Gate the callback with our actual finger distance so a
    // below-threshold release is a visual cancellation, not a refresh.
    if (_dragOffset < _refreshThreshold) {
      _tracking = false;
      _animateDismiss();
      return;
    }
    setState(() {
      _refreshing = true;
      _progress = 1;
    });
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) {
        setState(() {
          _refreshing = false;
          _dragOffset = 0;
        });
        _animateDismiss();
      }
    }
  }

  Widget _buildIndicator(BuildContext context) {
    if (_progress <= 0 && !_refreshing) return const SizedBox.shrink();
    final opacity = _refreshing ? 1.0 : (_progress * 1.5).clamp(0.0, 1.0);
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Align(
          alignment: Alignment.topCenter,
          child: Transform.translate(
            offset: Offset(0, 8 + _indicatorTravel * _progress),
            child: Opacity(
              opacity: opacity,
              child: RefreshProgressIndicator(
                value: _refreshing
                    ? null
                    : (_progress.clamp(0.0, 1.0).toDouble() * 0.75),
                color: Theme.of(context).colorScheme.primary,
                backgroundColor: Theme.of(context).colorScheme.surface,
                elevation: 2,
                strokeWidth: 3,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        RefreshIndicator.noSpinner(
          onRefresh: _handleRefresh,
          onStatusChange: _onStatusChange,
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: widget.child,
          ),
        ),
        _buildIndicator(context),
      ],
    );
  }
}
