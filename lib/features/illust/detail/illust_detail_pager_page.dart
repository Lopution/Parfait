import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/widgets/feed/feed_grid.dart';
import 'illust_detail_page.dart';

/// Detail host paged horizontally across a feed's work list — Shaft's
/// `VActivity`: a work opened from a grid keeps the feed's ordering, and
/// swiping sideways moves to the previous/next work without returning to
/// the grid.
///
/// The list is shared with the feed through [IllustPagerSource]: swiping
/// close to the loaded edge calls the feed's `loadMore`, so the pager
/// extends instead of stopping, and a feed refresh that rewrites the id
/// list re-seats the viewport on the same work.
class IllustDetailPagerPage extends ConsumerStatefulWidget {
  const IllustDetailPagerPage({
    super.key,
    required this.source,
    required this.initialIllustId,
    this.heroScope = 'feed',
    this.heroImageUrl,
    this.heroImageDecodeWidth,
  });

  /// Feed-order work ids the pager walks, plus the feed's next-page hook.
  final IllustPagerSource source;
  final int initialIllustId;

  /// Hero namespace shared with the feed cards — every page's hero tag is
  /// `heroScope + id`, so popping the route flies whichever page is
  /// showing back into its own card.
  final String heroScope;
  final String? heroImageUrl;
  final int? heroImageDecodeWidth;

  /// How close to the list end a swipe lands before the pager asks the
  /// feed for its next page.
  static const loadAhead = 4;

  @override
  ConsumerState<IllustDetailPagerPage> createState() =>
      _IllustDetailPagerPageState();
}

class _IllustDetailPagerPageState
    extends ConsumerState<IllustDetailPagerPage> {
  late final PageController _controller;

  /// The route's landing page — only it carries the feed card's hero
  /// image url for the push flight.
  late final int _initialIndex;

  /// The work the user is looking at. Tracked by id (not index) so a
  /// mid-paging list mutation can re-seat the viewport on the same work.
  late int _index;
  late int _currentId;

  @override
  void initState() {
    super.initState();
    final ids = widget.source.ids;
    _initialIndex = math.max(0, ids.indexOf(widget.initialIllustId));
    _index = _initialIndex;
    _currentId = ids.isEmpty ? widget.initialIllustId : ids[_index];
    _controller = PageController(initialPage: _index);
    widget.source.addListener(_onSourceChanged);
  }

  @override
  void dispose() {
    widget.source.removeListener(_onSourceChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    final ids = widget.source.ids;
    if (index < 0 || index >= ids.length) return;
    setState(() {
      _index = index;
      _currentId = ids[index];
    });
    if (index >= ids.length - IllustDetailPagerPage.loadAhead) {
      widget.source.onNearEnd?.call();
    }
  }

  /// A feed refresh can rewrite the id list while the pager is open —
  /// keep the viewport on the same work by id, clamping inside the new
  /// bounds when the work disappeared entirely.
  ///
  /// Always post-frame: the feed grid publishes `update()` from inside its
  /// own build (a route push rebuilds the feed under the pager), and a
  /// synchronous setState here would mark a mid-build element dirty.
  bool _reseatScheduled = false;

  void _onSourceChanged() {
    if (!mounted) return;
    // The grid publishes update() from inside its own build (a route push
    // rebuilds the feed under the pager) — a synchronous setState there
    // would mark a mid-build element dirty, so defer it to frame end.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_reseatScheduled) return;
      _reseatScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _reseatScheduled = false;
        _applyReseat();
      });
      return;
    }
    _applyReseat();
  }

  void _applyReseat() {
    if (!mounted) return;
    final ids = widget.source.ids;
    if (ids.isEmpty) return;
    var newIndex = ids.indexOf(_currentId);
    if (newIndex < 0) {
      newIndex = _index.clamp(0, ids.length - 1);
      _currentId = ids[newIndex];
    }
    setState(() {});
    if (newIndex != _index && _controller.hasClients) {
      _index = newIndex;
      _controller.jumpToPage(_index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ids = widget.source.ids;
    return PageView.builder(
      controller: _controller,
      // Build adjacent pages ahead of the swipe — their entities are
      // already in IllustStore from the feed fetch, so the incoming page
      // lands rendered instead of spinning up on first contact.
      allowImplicitScrolling: true,
      itemCount: ids.length,
      onPageChanged: _onPageChanged,
      // Adjacent pages build heroes with the same feed tag the grid cards
      // carry — left enabled, all three would pair with feed cards and fly
      // together on push/pop. Only the page under the finger owns a live
      // hero; the rest ride HeroMode-disabled.
      itemBuilder: (context, index) => HeroMode(
        enabled: index == _index,
        child: IllustDetailPage(
          key: ValueKey(ids[index]),
          illustId: ids[index],
          heroScope: widget.heroScope,
          heroImageUrl:
              index == _initialIndex ? widget.heroImageUrl : null,
          heroImageDecodeWidth:
              index == _initialIndex ? widget.heroImageDecodeWidth : null,
        ),
      ),
    );
  }
}
