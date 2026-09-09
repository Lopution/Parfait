import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';

class HeroRectClip extends SingleChildRenderObjectWidget {
  const HeroRectClip({
    super.key,
    required this.globalRect,
    required super.child,
  });

  final Rect globalRect;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderHeroRectClip(globalRect);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderHeroRectClip).globalRect = globalRect;
  }
}

class _RenderHeroRectClip extends RenderProxyBox {
  _RenderHeroRectClip(this._globalRect);

  Rect _globalRect;
  Rect? _lastPaintClipRect;

  Rect get globalRect => _globalRect;

  /// Actual global clip used by the last paint pass. Tests use this to catch
  /// render-time changes that are invisible if they only inspect the widget's
  /// input rectangle.
  Rect? get debugLastPaintClipRect => _lastPaintClipRect;

  set globalRect(Rect value) {
    if (value == _globalRect) return;
    _globalRect = value;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null || size.isEmpty) {
      _lastPaintClipRect = Rect.zero;
      return;
    }
    final globalOrigin = localToGlobal(Offset.zero);
    final clipRect = _globalRect;
    // Keep the boundary itself rather than intersecting it with the current
    // shuttle bounds. The latter changes every frame by design; the former
    // is the UI occlusion contract we need to keep stable in both directions.
    _lastPaintClipRect = clipRect;
    final localClip = clipRect
        .shift(-globalOrigin)
        .intersect(Offset.zero & size);
    if (localClip.isEmpty) return;
    context.pushClipRect(
      needsCompositing,
      offset,
      localClip,
      super.paint,
      clipBehavior: Clip.hardEdge,
    );
  }
}
