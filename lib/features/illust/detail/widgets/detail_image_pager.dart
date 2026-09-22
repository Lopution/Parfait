import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../../../app/motion/hero_transition.dart';
import '../../../../core/entity/illust_entity.dart';
import 'page_image.dart';
import '../ugoira_viewer.dart';

/// The two-pane detail page's left pane: a horizontal page pager that keeps
/// each page fitted (contain) inside the pane height, with a `n / total`
/// indicator and arrow-key paging. Narrow surfaces never see this widget —
/// they keep the vertical image list inside the single scroll view.
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

  @override
  State<DetailImagePager> createState() => _DetailImagePagerState();
}

class _DetailImagePagerState extends State<DetailImagePager> {
  late final PageController _controller = PageController();
  final FocusNode _focusNode = FocusNode();
  int _page = 0;

  IllustEntity get entity => widget.entity;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
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
    _controller.animateToPage(
      next,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final count = entity.isUgoira ? 1 : entity.pageCount;
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Stack(
        fit: StackFit.expand,
        children: [
          PageView.builder(
            controller: _controller,
            itemCount: count,
            onPageChanged: (page) => setState(() => _page = page),
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
                      downloadMode: widget.downloadMode,
                      onLongPress: widget.onLongPress,
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
                      key: ValueKey<Object?>('illust-page-${entity.id}-$index'),
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
              // Contain inside the fixed-height pane: AspectRatio picks the
              // largest centred box that preserves the page's own ratio, so
              // tall pages cannot overflow vertically.
              return Center(
                child: AspectRatio(
                  aspectRatio: entity.pageAspectRatioAt(index),
                  child: child,
                ),
              );
            },
          ),
          if (count > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 12,
              child: IgnorePointer(
                child: Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                          .withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      child: Text(
                        '${_page + 1} / $count',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
