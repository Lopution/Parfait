import 'package:material_ui/material_ui.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'detail_page_activity.dart';

/// A detail-page section that starts its request only once it is on screen
/// on the page the user is looking at ([DetailPageActivity]). Swiping
/// through the detail pager, which prebuilds neighbours, sends nothing.
///
/// Until then it is the static [placeholder] box — no spinner: an idle one
/// below the fold would keep producing frames. Once on screen, or when
/// [alreadyRequested] reports the data exists, it builds [sliver].
class OnDemandSliver extends StatefulWidget {
  const OnDemandSliver({
    super.key,
    required this.id,
    required this.alreadyRequested,
    required this.placeholder,
    required this.sliver,
  });

  /// The section and work, e.g. `related-42`; a new id starts over. The
  /// placeholder's visibility detector is keyed `<id>-trigger`.
  final String id;

  /// Read when the section mounts or its [id] changes.
  final bool Function() alreadyRequested;
  final Widget placeholder;
  final WidgetBuilder sliver;

  @override
  State<OnDemandSliver> createState() => _OnDemandSliverState();
}

class _OnDemandSliverState extends State<OnDemandSliver> {
  late bool _requested = widget.alreadyRequested();
  bool _visible = false;
  bool _active = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _active = DetailPageActivity.of(context);
    // A build follows right away, no setState needed.
    if (_visible && _active) _requested = true;
  }

  @override
  void didUpdateWidget(OnDemandSliver oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) {
      _requested = widget.alreadyRequested();
      _visible = false;
    }
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    if (!mounted) return;
    _visible = info.visibleFraction > 0;
    if (_visible && _active && !_requested) {
      setState(() => _requested = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_requested) return widget.sliver(context);
    return SliverToBoxAdapter(
      child: VisibilityDetector(
        key: ValueKey('${widget.id}-trigger'),
        onVisibilityChanged: _onVisibilityChanged,
        child: widget.placeholder,
      ),
    );
  }
}
