import 'package:flutter/rendering.dart'
    show ScrollCacheExtent, SliverPaintOrder, ViewportOffset;
import 'package:flutter/widgets.dart';

/// A scroll view whose first frame builds only what is on screen: its
/// [ScrollView.scrollCacheExtent] applies from the frame after it mounts.
///
/// A feed or a settings list mounts on a busy frame, the one that pushes
/// its page, switches to its branch or lands its first data, and building
/// the cache area there too took 13–25 ms. Only the viewport waits; the
/// slivers are the same widgets on the next frame, so it builds just the
/// children the cache area adds. Shrink-wrapped views build as usual.
mixin DeferredCacheExtent on ScrollView {
  @override
  Widget buildViewport(
    BuildContext context,
    ViewportOffset offset,
    AxisDirection axisDirection,
    List<Widget> slivers,
  ) {
    if (shrinkWrap) {
      return super.buildViewport(context, offset, axisDirection, slivers);
    }
    return _DeferredCacheViewport(
      axisDirection: axisDirection,
      offset: offset,
      slivers: slivers,
      scrollCacheExtent: scrollCacheExtent,
      center: center,
      anchor: anchor,
      paintOrder: paintOrder,
      clipBehavior: clipBehavior,
    );
  }
}

/// A [CustomScrollView] with a [DeferredCacheExtent].
class DeferredCacheScrollView extends CustomScrollView
    with DeferredCacheExtent {
  const DeferredCacheScrollView({
    super.key,
    super.controller,
    super.physics,
    super.scrollCacheExtent,
    super.restorationId,
    super.slivers,
  });
}

/// A [ListView] with a [DeferredCacheExtent].
class DeferredCacheListView extends ListView with DeferredCacheExtent {
  DeferredCacheListView({
    super.key,
    super.padding,
    super.scrollCacheExtent,
    super.children,
  });

  DeferredCacheListView.builder({
    super.key,
    super.controller,
    super.physics,
    super.scrollCacheExtent,
    super.restorationId,
    required super.itemCount,
    required super.itemBuilder,
  }) : super.builder();
}

class _DeferredCacheViewport extends StatefulWidget {
  const _DeferredCacheViewport({
    required this.axisDirection,
    required this.offset,
    required this.slivers,
    required this.scrollCacheExtent,
    required this.center,
    required this.anchor,
    required this.paintOrder,
    required this.clipBehavior,
  });

  final AxisDirection axisDirection;
  final ViewportOffset offset;
  final List<Widget> slivers;
  final ScrollCacheExtent? scrollCacheExtent;
  final Key? center;
  final double anchor;
  final SliverPaintOrder paintOrder;
  final Clip clipBehavior;

  @override
  State<_DeferredCacheViewport> createState() => _DeferredCacheViewportState();
}

class _DeferredCacheViewportState extends State<_DeferredCacheViewport> {
  static const _onScreen = ScrollCacheExtent.pixels(0);

  bool _deferred = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _deferred = false);
    });
  }

  @override
  Widget build(BuildContext context) => Viewport(
    axisDirection: widget.axisDirection,
    offset: widget.offset,
    slivers: widget.slivers,
    scrollCacheExtent: _deferred ? _onScreen : widget.scrollCacheExtent,
    center: widget.center,
    anchor: widget.anchor,
    paintOrder: widget.paintOrder,
    clipBehavior: widget.clipBehavior,
  );
}
