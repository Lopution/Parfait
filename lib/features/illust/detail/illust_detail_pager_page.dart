import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/widgets/feed/feed_grid.dart';
import 'detail_page_activity.dart';
import 'illust_detail_page.dart';

/// Detail host paged horizontally across a feed's work list: a work
/// opened from a grid keeps the feed's ordering, and
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

class _IllustDetailPagerPageState extends ConsumerState<IllustDetailPagerPage> {
  late final PageController _controller;

  /// The route's landing page. Its work alone carries the feed card's hero
  /// image url for the push flight — matched by id, so a head insert that
  /// shifts the indexes keeps the url on the same work.
  late final int _initialIndex;
  late final int _initialId;

  /// The work the user is looking at. Tracked by id (not index) so a
  /// mid-paging list mutation can re-seat the viewport on the same work.
  ///
  /// A notifier, not plain state: committing a swipe only flips the
  /// [HeroMode] gate on the involved pages — the already-built
  /// [IllustDetailPage] subtrees must survive the index change untouched.
  late final ValueNotifier<int> _index;
  late int _currentId;

  /// Pages allowed to build their detail subtree. The cache extent pulls
  /// the page after next in on the first frame of a swipe; building a
  /// whole detail page there was a 40ms+ swipe hitch on device, so a page
  /// outside this window stays a bare surface until the scroll settles.
  /// Neighbours join once the push transition is over, off its frames.
  late final ValueNotifier<_ReadyWindow> _ready;

  @override
  void initState() {
    super.initState();
    final ids = widget.source.ids;
    _initialIndex = math.max(0, ids.indexOf(widget.initialIllustId));
    _index = ValueNotifier(_initialIndex);
    _ready = ValueNotifier((center: _initialIndex, radius: 0));
    _currentId = ids.isEmpty ? widget.initialIllustId : ids[_initialIndex];
    _initialId = _currentId;
    _controller = PageController(initialPage: _initialIndex);
    widget.source.addListener(_onSourceChanged);
  }

  @override
  void dispose() {
    widget.source.removeListener(_onSourceChanged);
    _controller.dispose();
    _index.dispose();
    _ready.dispose();
    super.dispose();
  }

  void _readyAround(int center) {
    _ready.value = (center: center, radius: _ready.value.radius);
  }

  void _readyNeighbours() {
    _ready.value = (center: _ready.value.center, radius: 1);
  }

  bool _onScrollEnd(ScrollEndNotification notification) {
    if (notification.depth == 0 && _controller.hasClients) {
      final page = _controller.page;
      if (page != null) _readyAround(page.round());
    }
    return false;
  }

  void _onPageChanged(int index) {
    final ids = widget.source.ids;
    if (index < 0 || index >= ids.length) return;
    _index.value = index;
    _currentId = ids[index];
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
      newIndex = _index.value.clamp(0, ids.length - 1);
      _currentId = ids[newIndex];
    }
    setState(() {});
    if (newIndex != _index.value && _controller.hasClients) {
      _index.value = newIndex;
      _controller.jumpToPage(_index.value);
    }
    _readyAround(_index.value);
  }

  @override
  Widget build(BuildContext context) {
    final ids = widget.source.ids;
    return _AfterRouteTransition(
      onSettled: _readyNeighbours,
      child: NotificationListener<ScrollEndNotification>(
        onNotification: _onScrollEnd,
        child: PageView.builder(
          controller: _controller,
          // Keep adjacent pages built ahead of the swipe — their entities
          // are already in IllustStore from the feed fetch, so the
          // incoming page lands rendered instead of spinning up on first
          // contact. [_ready] decides which of them build a real detail.
          allowImplicitScrolling: true,
          itemCount: ids.length,
          onPageChanged: _onPageChanged,
          itemBuilder: (context, index) {
            final landing = ids[index] == _initialId;
            return _PagerSlot(
              key: ValueKey(ids[index]),
              index: index,
              ready: _ready,
              current: _index,
              illustId: ids[index],
              heroScope: widget.heroScope,
              heroImageUrl: landing ? widget.heroImageUrl : null,
              heroImageDecodeWidth: landing
                  ? widget.heroImageDecodeWidth
                  : null,
            );
          },
        ),
      ),
    );
  }
}

/// Center page index and how many pages on each side of it may build.
typedef _ReadyWindow = ({int center, int radius});

/// One pager page: a bare surface until the page has been inside the
/// ready window, the real detail from then on. Latched — a page that has
/// built its detail keeps it for as long as the pager keeps the page.
class _PagerSlot extends StatefulWidget {
  const _PagerSlot({
    super.key,
    required this.index,
    required this.ready,
    required this.current,
    required this.illustId,
    required this.heroScope,
    this.heroImageUrl,
    this.heroImageDecodeWidth,
  });

  final int index;
  final ValueListenable<_ReadyWindow> ready;

  /// The committed page — only its hero is live.
  final ValueListenable<int> current;

  /// [IllustDetailPage] inputs.
  final int illustId;
  final String heroScope;
  final String? heroImageUrl;
  final int? heroImageDecodeWidth;

  @override
  State<_PagerSlot> createState() => _PagerSlotState();
}

class _PagerSlotState extends State<_PagerSlot> {
  var _built = false;

  /// Kept across slot updates while the inputs hold: a pager rebuild (a
  /// feed page landing mid-paging) hands every slot a new widget, and a
  /// new detail instance would rebuild each built page in full.
  late IllustDetailPage _detail = _createDetail();

  IllustDetailPage _createDetail() => IllustDetailPage(
    illustId: widget.illustId,
    heroScope: widget.heroScope,
    heroImageUrl: widget.heroImageUrl,
    heroImageDecodeWidth: widget.heroImageDecodeWidth,
  );

  bool get _inWindow {
    final window = widget.ready.value;
    return (widget.index - window.center).abs() <= window.radius;
  }

  @override
  void initState() {
    super.initState();
    _built = _inWindow;
    if (!_built) widget.ready.addListener(_onReadyChanged);
  }

  @override
  void didUpdateWidget(_PagerSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.illustId != oldWidget.illustId ||
        widget.heroScope != oldWidget.heroScope ||
        widget.heroImageUrl != oldWidget.heroImageUrl ||
        widget.heroImageDecodeWidth != oldWidget.heroImageDecodeWidth) {
      _detail = _createDetail();
    }
    // A feed rewrite can move this work to a new index.
    if (!_built && _inWindow) _latch();
  }

  @override
  void dispose() {
    widget.ready.removeListener(_onReadyChanged);
    super.dispose();
  }

  void _onReadyChanged() {
    if (_inWindow) setState(_latch);
  }

  void _latch() {
    widget.ready.removeListener(_onReadyChanged);
    _built = true;
  }

  @override
  Widget build(BuildContext context) {
    if (!_built) {
      return ColoredBox(color: Theme.of(context).scaffoldBackgroundColor);
    }
    // Adjacent pages build heroes with the same feed tag the grid cards
    // carry — left enabled, all three would pair with feed cards and fly
    // together on push/pop. Only the page under the finger owns a live
    // hero; the rest ride HeroMode-disabled.
    //
    // The same flag tells the page whether it is current, so deferred
    // network work (related works) never starts on a prebuilt neighbour.
    //
    // The detail page is the builder's stable [child]: a page change only
    // re-wraps it in a new HeroMode/DetailPageActivity instead of running
    // the whole detail build again; only dependents of the activity scope
    // rebuild.
    return ValueListenableBuilder<int>(
      valueListenable: widget.current,
      child: _detail,
      builder: (context, current, child) {
        final active = widget.index == current;
        return HeroMode(
          enabled: active,
          child: DetailPageActivity(active: active, child: child!),
        );
      },
    );
  }
}

/// Calls [onSettled] once the enclosing route's push transition is over —
/// right away when there is none. A separate element so the route-status
/// dependency rebuilds only this wrapper, never the pager's pages.
class _AfterRouteTransition extends StatefulWidget {
  const _AfterRouteTransition({required this.onSettled, required this.child});

  final VoidCallback onSettled;
  final Widget child;

  @override
  State<_AfterRouteTransition> createState() => _AfterRouteTransitionState();
}

class _AfterRouteTransitionState extends State<_AfterRouteTransition> {
  ModalRoute<Object?>? _route;
  var _settled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_settled) return;
    final route = ModalRoute.of(context);
    if (!identical(route, _route)) {
      _route?.animation?.removeStatusListener(_onStatus);
      _route = route;
      route?.animation?.addStatusListener(_onStatus);
    }
    _check();
  }

  @override
  void dispose() {
    _route?.animation?.removeStatusListener(_onStatus);
    super.dispose();
  }

  void _onStatus(AnimationStatus _) => _check();

  /// A hero push lays out its first frame with the route offstage, and the
  /// route's animation reads as completed for that frame — the transition
  /// has not even started.
  void _check() {
    if (_settled) return;
    final route = _route;
    if (route != null &&
        (route.offstage || !(route.animation?.isCompleted ?? true))) {
      return;
    }
    _route?.animation?.removeStatusListener(_onStatus);
    _settled = true;
    widget.onSettled();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
