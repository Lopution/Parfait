import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../../../app/motion/hero_transition.dart';
import '../../../../app/motion/motion_tokens.dart';
import '../../../../app/motion/swipe_paging.dart';
import '../../../../app/scroll_behavior.dart';
import '../../../../core/entity/illust_entity.dart';
import 'detail_page_counter.dart';
import 'page_image.dart';
import '../ugoira_viewer.dart';

/// The two-pane detail page's left pane: a horizontal page pager that keeps
/// each page fitted (contain) inside the pane height, with the shared
/// `DetailPageCounter` overlay and arrow-key paging. Narrow surfaces never
/// see this widget — they keep the vertical image list inside the single
/// scroll view.
class DetailImagePager extends StatefulWidget {
  const DetailImagePager({
    super.key,
    required this.entity,
    required this.detailUrlFor,
    required this.downloadMode,
    required this.selectedPages,
    required this.onToggleSelect,
    required this.onLongPress,
    required this.heroTag,
    required this.heroScope,
    this.heroImageUrl,
    this.heroImageDecodeWidth,
    this.initialPage = 0,
    this.onPageChanged,
  });

  final IllustEntity entity;

  /// Same contract as `_buildContent`'s `detailUrlFor`: detail-quality URL
  /// for [index] once the detail payload has landed, else null.
  final String? Function(int index) detailUrlFor;
  final bool downloadMode;
  final VoidCallback onLongPress;

  /// Selection-mode state owned by the detail page: which page indexes are
  /// selected and the per-page toggle callback.
  final Set<int> selectedPages;
  final ValueChanged<int> onToggleSelect;
  final String heroTag;
  final String heroScope;
  final String? heroImageUrl;
  final int? heroImageDecodeWidth;

  /// The image the pane opens on. The detail page keeps the reader's image
  /// across a switch to the single-column layout and back (NAV-21).
  final int initialPage;

  /// The image the pane settled on, so the detail page can bring the
  /// single-column list back to it.
  final ValueChanged<int>? onPageChanged;

  @override
  State<DetailImagePager> createState() => _DetailImagePagerState();
}

class _DetailImagePagerState extends State<DetailImagePager>
    with SingleTickerProviderStateMixin, SwipePaging {
  late final PageController _controller = PageController(
    initialPage: _clamp(widget.initialPage),
  );
  final FocusNode _focusNode = FocusNode();

  /// How far the set is pulled past its first or last image, in pages. The
  /// controller stays between those; the pane slides by this instead.
  final ValueNotifier<double> _overscroll = ValueNotifier(0);

  late int _page = _clamp(widget.initialPage);

  IllustEntity get entity => widget.entity;

  int get _count => entity.isUgoira ? 1 : entity.pageCount;

  int _clamp(int page) =>
      page.clamp(0, entity.isUgoira ? 0 : entity.pageCount - 1);

  @override
  int get pageCount => _count;

  @override
  double get pagePosition {
    if (!_controller.hasClients) return _page.toDouble();
    return _controller.page ?? _page.toDouble();
  }

  @override
  void showPagePosition(double position) {
    final inRange = position.clamp(0.0, _count - 1.0);
    _overscroll.value = position - inRange;
    if (!_controller.hasClients) return;
    final extent = _controller.position.viewportDimension;
    if (extent <= 0) return;
    _controller.jumpTo(inRange * extent);
  }

  @override
  void landOnPage(int page) {
    _overscroll.value = 0;
    if (!_controller.hasClients) {
      _setPage(page);
      return;
    }
    _controller.jumpToPage(page);
    _setPage(page);
  }

  void _setPage(int page) {
    if (_page == page) return;
    setState(() => _page = page);
    widget.onPageChanged?.call(page);
  }

  /// At the first or last image a swipe outwards goes to the enclosing work
  /// pager when it has a work that way (B7), and otherwise pulls the pane
  /// on a rubber band.
  bool _yieldsTo(double dx) {
    final forward =
        (dx < 0) == (Directionality.of(context) == TextDirection.ltr);
    final edge = forward ? _count - 1.0 : 0.0;
    if (pageSettling || (pagePosition - edge).abs() > 1e-3) return false;
    return SwipePagerScope.maybeOf(context)?.canPage(forward) ?? false;
  }

  /// The paging slop: a sideways swipe takes twice the device's touch slop,
  /// as Android's ViewPager does (MOTION-18).
  @override
  DeviceGestureSettings? pagingGestureSettingsOf(BuildContext context) =>
      pagingGestureSettings(MediaQuery.maybeGestureSettingsOf(context));

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _overscroll.dispose();
    super.dispose();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final next = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowLeft => _page - 1,
      LogicalKeyboardKey.arrowRight => _page + 1,
      _ => null,
    };
    if (next == null) return KeyEventResult.ignored;
    if (next < 0 || next >= entity.pageCount) return KeyEventResult.handled;
    turnPage(context, _controller, next);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final count = _count;
    final ltr = Directionality.of(context) == TextDirection.ltr;
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: swipeGestures(
        yieldsTo: _yieldsTo,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ValueListenableBuilder<double>(
              valueListenable: _overscroll,
              builder: (context, overscroll, child) => FractionalTranslation(
                translation: Offset(ltr ? -overscroll : overscroll, 0),
                child: child,
              ),
              child: PageView.builder(
                controller: _controller,
                // The drag is the paging gesture above, which can hand a
                // swipe at either end to the enclosing work pager.
                physics: const NeverScrollableScrollPhysics(),
                itemCount: count,
                onPageChanged: _setPage,
                itemBuilder: (context, index) {
                  final child = entity.isUgoira
                      ? UgoiraViewer(
                          illustId: entity.id,
                          previewUrl: entity.imageUrls.large,
                          detailUrl: widget.detailUrlFor(0),
                          heroImageUrl: widget.heroImageUrl,
                          heroTier: widget.heroImageUrl == null
                              ? null
                              : entity.imageTierOf(widget.heroImageUrl!),
                          width: entity.width,
                          height: entity.height,
                          // Ugoira has no pages: it never participates in
                          // the selection mode and keeps its export action
                          // always visible instead.
                          heroTag: widget.heroTag,
                          flightShuttleBuilder: illustHeroFlightShuttleBuilder,
                          heroDecodeWidth: widget.heroImageDecodeWidth,
                          heroPopUrl: widget.heroImageUrl,
                          heroPopDecodeWidth: widget.heroImageDecodeWidth,
                          tier: entity.imageTierOf(
                            widget.detailUrlFor(0) ?? entity.imageUrls.large,
                          ),
                        )
                      : DetailPageImage(
                          key: ValueKey<Object?>(
                            'illust-page-${entity.id}-$index',
                          ),
                          entity: entity,
                          index: index,
                          heroTag: index == 0
                              ? widget.heroTag
                              : '${widget.heroTag}-$index',
                          heroScope: widget.heroScope,
                          heroImageUrl: index == 0 ? widget.heroImageUrl : null,
                          heroImageDecodeWidth: index == 0
                              ? widget.heroImageDecodeWidth
                              : null,
                          detailUrl: widget.detailUrlFor(index),
                          downloadMode: widget.downloadMode,
                          selected: widget.selectedPages.contains(index),
                          onToggleSelect: () => widget.onToggleSelect(index),
                          onLongPress: widget.onLongPress,
                        );
                  // Contain inside the fixed-height pane: AspectRatio picks
                  // the largest centred box that preserves the page's own
                  // ratio, so tall pages cannot overflow vertically.
                  return Center(
                    child: AspectRatio(
                      aspectRatio: entity.pageAspectRatioAt(index),
                      child: child,
                    ),
                  );
                },
              ),
            ),
            // The overlay hides itself for single-page works and ugoira
            // (count collapses to 1 above) and waits out the entry flight.
            // Selection mode hides it: the page's badge takes the same
            // top-end corner.
            if (!widget.downloadMode)
              Positioned.fill(
                child: DetailPageCounter(page: _page, count: count),
              ),
          ],
        ),
      ),
    );
  }
}
