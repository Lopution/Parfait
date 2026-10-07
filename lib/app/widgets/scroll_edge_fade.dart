import 'package:material_ui/material_ui.dart';

import '../theme/func_semantic_tokens.dart';

/// Fades whichever end of a horizontal scroller in [child] has content past
/// it, so an item cut at the edge reads as "more this way" rather than a
/// clipped word (H3). A mask, not a painted gradient: tab rows sit on app
/// bars whose colour changes as content scrolls under them.
class ScrollEdgeFade extends StatefulWidget {
  const ScrollEdgeFade({super.key, required this.child});

  final Widget child;

  static const _fadeWidth = FuncSpacing.xl;

  @override
  State<ScrollEdgeFade> createState() => ScrollEdgeFadeState();
}

/// Below this the row counts as resting on its edge.
const _edgeSlop = 0.5;

class ScrollEdgeFadeState extends State<ScrollEdgeFade> {
  var _before = false;
  var _after = false;

  /// Whether the leading / trailing edge, in reading order, is faded.
  @visibleForTesting
  (bool, bool) get fades => (_before, _after);

  bool _onMetrics(ScrollMetrics metrics) {
    if (metrics.axis != Axis.horizontal) return false;
    final before = metrics.extentBefore > _edgeSlop;
    final after = metrics.extentAfter > _edgeSlop;
    if (before != _before || after != _after) {
      setState(() {
        _before = before;
        _after = after;
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    // Leading and trailing in reading order, painted left to right.
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final left = rtl ? _after : _before;
    final right = rtl ? _before : _after;
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) => _onMetrics(notification.metrics),
      child: NotificationListener<ScrollUpdateNotification>(
        onNotification: (notification) => _onMetrics(notification.metrics),
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (bounds) {
            final fade = (ScrollEdgeFade._fadeWidth / bounds.width).clamp(
              0.0,
              0.5,
            );
            const shown = Color(0xFF000000);
            const hidden = Color(0x00000000);
            return LinearGradient(
              colors: [
                left ? hidden : shown,
                shown,
                shown,
                right ? hidden : shown,
              ],
              stops: [0, fade, 1 - fade, 1],
            ).createShader(bounds);
          },
          child: widget.child,
        ),
      ),
    );
  }
}
