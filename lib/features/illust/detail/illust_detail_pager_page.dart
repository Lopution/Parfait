import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/home_shell_metrics.dart';
import '../../../app/layout/app_breakpoints.dart';
import '../../../app/layout/input_modality.dart';
import '../../../app/layout/two_pane.dart';
import '../../../app/motion/motion_tokens.dart';
import '../../../app/motion/still_work.dart';
import '../../../app/motion/swipe_paging.dart';
import '../../../app/pixiv_image.dart';
import '../../../app/scroll_behavior.dart';
import '../../../app/widgets/feed/feed_grid.dart';
import '../../../app/widgets/feed/feed_text_warmup.dart';
import '../../../core/entity/illust_store.dart';
import 'detail_page_activity.dart';
import 'illust_detail_page.dart';
import 'widgets/info_block.dart';

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
    this.onActiveChanged,
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

  /// Called when the work the user is reading changes (settled for
  /// [activeDwell], or re-seated by a list change), never mid-drag.
  final ValueChanged<int>? onActiveChanged;

  /// How close to the list end a swipe lands before the pager asks the
  /// feed for its next page.
  static const loadAhead = 4;

  /// How long a page has to stay settled before it counts as the one the
  /// user is reading ([DetailPageActivity]) and its on-screen sections may
  /// send their requests: swiping on through it sends nothing.
  static const activeDwell = Duration(milliseconds: 300);

  @override
  ConsumerState<IllustDetailPagerPage> createState() =>
      _IllustDetailPagerPageState();
}

class _IllustDetailPagerPageState extends ConsumerState<IllustDetailPagerPage>
    with StillWork {
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

  /// The work the user is reading: the committed page once it has stayed
  /// settled for [IllustDetailPagerPage.activeDwell]. By id, so a list
  /// shift keeps it on the same work.
  late final ValueNotifier<int> _activeId;
  Timer? _dwell;

  /// Pages allowed to build their detail subtree. The cache extent pulls
  /// the page after next in on the first frame of a swipe; building a
  /// whole detail page there was a 40ms+ swipe hitch on device, so a page
  /// outside this window stays a bare surface until the scroll settles.
  ///
  /// Neighbours join one per frame on a still screen ([StillWork]): a
  /// detail page costs ~11ms of layout on device, and admitting both at the
  /// end of the push transition laid out two of them in one 23ms frame.
  late final ValueNotifier<_ReadyWindow> _ready;

  /// Neighbours wait for the push transition to finish.
  var _routeSettled = false;

  /// The text of the next neighbour still to lay out before it joins
  /// ([InfoBlock.warmTexts]), and the work it belongs to.
  final _texts = Queue<WarmText>();
  int? _textsOf;
  bool _startEdgeHovered = false;
  bool _endEdgeHovered = false;

  @override
  void initState() {
    super.initState();
    final ids = widget.source.ids;
    _initialIndex = math.max(0, ids.indexOf(widget.initialIllustId));
    _index = ValueNotifier(_initialIndex);
    _ready = ValueNotifier((center: _initialIndex, neighbours: const {}));
    _currentId = ids.isEmpty ? widget.initialIllustId : ids[_initialIndex];
    _initialId = _currentId;
    _activeId = ValueNotifier(_currentId)
      ..addListener(() => widget.onActiveChanged?.call(_activeId.value));
    _controller = PageController(initialPage: _initialIndex);
    widget.source.addListener(_onSourceChanged);
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    widget.source.removeListener(_onSourceChanged);
    // After the frame: cards cannot rebuild while the tree is finalized.
    final source = widget.source;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => source.clearHomeFlight(),
    );
    _dwell?.cancel();
    _controller.dispose();
    _index.dispose();
    _activeId.dispose();
    _ready.dispose();
    super.dispose();
  }

  /// Re-centres the window on a new page. Same centre is a no-op: the
  /// window's neighbour set compares by identity, so re-assigning it would
  /// notify every slot and restart admission — a feed rewrite reseats on
  /// every update, and an admitted neighbour can trigger one.
  void _readyAround(int center) {
    if (center == _ready.value.center) return;
    _ready.value = (center: center, neighbours: const {});
    _scheduleAdmit();
  }

  void _onRouteSettled() {
    _routeSettled = true;
    _scheduleAdmit();
  }

  /// The next neighbour to build: the page ahead first, then the one
  /// behind. Null once both are in.
  int? _nextNeighbour() {
    final window = _ready.value;
    for (final index in [window.center + 1, window.center - 1]) {
      if (index < 0 || index >= widget.source.ids.length) continue;
      if (!window.neighbours.contains(index)) return index;
    }
    return null;
  }

  void _scheduleAdmit() {
    if (_routeSettled) scheduleStillWork();
  }

  /// The page's own images are not waited for: a neighbour shows its
  /// image as a stand-in anyway.
  @override
  bool get stillWorkWaitsForImages => false;

  /// A neighbour's text is laid out a paragraph a still frame before it
  /// joins: shaping a title and its tags for the first time inside the
  /// frame that builds the page read their glyphs from the font file
  /// there. A still frame is empty, so a paragraph fits in it.
  @override
  bool runStillWork() {
    final next = _nextNeighbour();
    if (next == null) return false;
    final id = widget.source.ids[next];
    if (id != _textsOf) {
      _textsOf = id;
      final entity = ref.read(illustStoreProvider).get(id);
      _texts
        ..clear()
        ..addAll(entity == null ? [] : InfoBlock.warmTexts(context, entity));
    }
    if (_texts.isNotEmpty) {
      final text = _texts.removeFirst();
      FeedTextWarmup.layOut(
        text,
        textScaler: MediaQuery.textScalerOf(context),
        textDirection: Directionality.of(context),
      );
      return true;
    }
    final window = _ready.value;
    _ready.value = (
      center: window.center,
      neighbours: {...window.neighbours, next},
    );
    return true;
  }

  bool _onScroll(ScrollNotification notification) {
    trackStillScroll(notification);
    if (notification.depth != 0) return false;
    switch (notification) {
      case ScrollStartNotification():
        _dwell?.cancel();
      case ScrollEndNotification() when _controller.hasClients:
        final page = _controller.page;
        if (page != null) {
          _readyAround(page.round());
          _activateAfterDwell(page.round());
        }
      default:
    }
    return false;
  }

  void _activateAfterDwell(int index) {
    final ids = widget.source.ids;
    if (index < 0 || index >= ids.length) return;
    final id = ids[index];
    _dwell?.cancel();
    if (id == _activeId.value) return;
    _dwell = Timer(IllustDetailPagerPage.activeDwell, () {
      if (mounted) _activeId.value = id;
    });
  }

  void _onPageChanged(int index) {
    final ids = widget.source.ids;
    if (index < 0 || index >= ids.length) return;
    _index.value = index;
    _currentId = ids[index];
    widget.source.aimHomeFlight(_currentId);
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
      _dwell?.cancel();
      _activeId.value = _currentId;
      widget.source.aimHomeFlight(_currentId);
    }
    setState(() {});
    if (newIndex != _index.value && _controller.hasClients) {
      _index.value = newIndex;
      _controller.jumpToPage(_index.value);
    }
    _readyAround(_index.value);
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (!mounted || event is! KeyDownEvent) return false;
    if (!TickerMode.valuesOf(context).enabled) return false;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    if (primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() !=
        null) {
      return false;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return false;
    }
    final delta = switch (event.logicalKey) {
      LogicalKeyboardKey.bracketLeft when !keyboard.isShiftPressed => -1,
      LogicalKeyboardKey.bracketRight when !keyboard.isShiftPressed => 1,
      LogicalKeyboardKey.arrowLeft when keyboard.isShiftPressed => -1,
      LogicalKeyboardKey.arrowRight when keyboard.isShiftPressed => 1,
      _ => 0,
    };
    if (delta == 0) return false;
    _turnArtworkBy(delta);
    return true;
  }

  void _turnArtworkBy(int delta) {
    final ids = widget.source.ids;
    if (ids.isEmpty || !_controller.hasClients) return;
    final target = (_index.value + delta).clamp(0, ids.length - 1);
    if (target == _index.value) return;
    turnPage(context, _controller, target);
    if (MotionTokens.resolve(context, MotionTokens.spatial) == Duration.zero) {
      _readyAround(target);
      _activateAfterDwell(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ids = widget.source.ids;
    final pointerMode =
        (InputModalityScope.maybeOf(context) ??
            defaultInputModalityFor(Theme.of(context).platform)) ==
        InputModality.pointer;
    final pager = _AfterRouteTransition(
      onSettled: _onRouteSettled,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        // The paging slop: a swipe leaning towards vertical scrolls the
        // detail instead of turning the page.
        child: PagingSlop(
          // A two-pane page's image pager takes a swipe at its first or
          // last image and hands it on to the next or previous work (B7).
          child: SwipePagerScope(
            canPage: (forward) {
              final ids = widget.source.ids;
              final index = _index.value;
              return forward ? index < ids.length - 1 : index > 0;
            },
            child: PageView.builder(
              controller: _controller,
              physics: const PageSnapPhysics(),
              // Keep adjacent pages built ahead of the swipe — their entities
              // are already in IllustStore from the feed fetch, so the
              // incoming page lands rendered instead of spinning up on first
              // contact. [_ready] decides which of them build a real detail.
              allowImplicitScrolling: true,
              itemCount: ids.length,
              onPageChanged: _onPageChanged,
              // A feed page landing mid-paging can shift the list: built pages
              // move with their work instead of rebuilding as another one.
              findChildIndexCallback: (key) {
                if (key is! ValueKey<int>) return null;
                final index = widget.source.ids.indexOf(key.value);
                return index < 0 ? null : index;
              },
              itemBuilder: (context, index) {
                final landing = ids[index] == _initialId;
                return PagingSlopPage(
                  key: ValueKey(ids[index]),
                  child: _PagerSlot(
                    index: index,
                    ready: _ready,
                    current: _index,
                    activeId: _activeId,
                    illustId: ids[index],
                    heroScope: widget.heroScope,
                    heroImageUrl: landing ? widget.heroImageUrl : null,
                    heroImageDecodeWidth: landing
                        ? widget.heroImageDecodeWidth
                        : null,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    if (!pointerMode || ids.length <= 1) return pager;
    return Stack(
      children: [
        pager,
        ValueListenableBuilder<int>(
          valueListenable: _index,
          builder: (context, index, _) => Stack(
            children: [
              _PagerEdgeNavButton(
                key: const Key('pager-prev-artwork'),
                isStart: true,
                enabled: index > 0,
                hovered: _startEdgeHovered,
                icon: Icons.chevron_left,
                tooltip: MaterialLocalizations.of(context).previousPageTooltip,
                onHoverChanged: (hovered) {
                  if (_startEdgeHovered != hovered) {
                    setState(() => _startEdgeHovered = hovered);
                  }
                },
                onPressed: () => _turnArtworkBy(-1),
              ),
              _PagerEdgeNavButton(
                key: const Key('pager-next-artwork'),
                isStart: false,
                enabled: index + 1 < ids.length,
                hovered: _endEdgeHovered,
                icon: Icons.chevron_right,
                tooltip: MaterialLocalizations.of(context).nextPageTooltip,
                onHoverChanged: (hovered) {
                  if (_endEdgeHovered != hovered) {
                    setState(() => _endEdgeHovered = hovered);
                  }
                },
                onPressed: () => _turnArtworkBy(1),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PagerEdgeNavButton extends StatelessWidget {
  const _PagerEdgeNavButton({
    super.key,
    required this.isStart,
    required this.enabled,
    required this.hovered,
    required this.icon,
    required this.tooltip,
    required this.onHoverChanged,
    required this.onPressed,
  });

  final bool isStart;
  final bool enabled;
  final bool hovered;
  final IconData icon;
  final String tooltip;
  final ValueChanged<bool> onHoverChanged;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final visible = enabled && hovered;
    final colors = Theme.of(context).colorScheme;
    return Positioned.directional(
      textDirection: Directionality.of(context),
      start: isStart ? 0 : null,
      end: isStart ? null : 0,
      top: kToolbarHeight + 48,
      bottom: 88,
      width: 72,
      child: MouseRegion(
        opaque: false,
        onEnter: (event) {
          if (event.kind == PointerDeviceKind.mouse ||
              event.kind == PointerDeviceKind.trackpad) {
            onHoverChanged(true);
          }
        },
        onExit: (_) => onHoverChanged(false),
        child: Center(
          child: ExcludeSemantics(
            excluding: !visible,
            child: IgnorePointer(
              ignoring: !visible,
              child: AnimatedOpacity(
                opacity: visible ? 1 : 0,
                duration: MotionTokens.resolve(context, MotionTokens.chrome),
                child: Material(
                  color: colors.surfaceContainerHigh.withValues(alpha: 0.9),
                  shape: const CircleBorder(),
                  elevation: 2,
                  clipBehavior: Clip.antiAlias,
                  child: IconButton(
                    color: colors.onSurface,
                    tooltip: tooltip,
                    onPressed: onPressed,
                    icon: Icon(icon),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The page in view and the neighbours admitted around it so far.
typedef _ReadyWindow = ({int center, Set<int> neighbours});

/// One pager page: a stand-in until the page has been inside the ready
/// window, the real detail from then on. Latched — a page that has built
/// its detail keeps it for as long as the pager keeps the page.
///
/// The page a swipe settled on builds on screen: its stand-in stays over
/// the new detail and fades off, so the image holds still while the rest
/// of the page fades in around it instead of cutting in.
class _PagerSlot extends StatefulWidget {
  const _PagerSlot({
    required this.index,
    required this.ready,
    required this.current,
    required this.activeId,
    required this.illustId,
    required this.heroScope,
    this.heroImageUrl,
    this.heroImageDecodeWidth,
  });

  final int index;
  final ValueListenable<_ReadyWindow> ready;

  /// The committed page — only its hero is live.
  final ValueListenable<int> current;

  /// The work the user is reading — only its sections request.
  final ValueListenable<int> activeId;

  /// [IllustDetailPage] inputs.
  final int illustId;
  final String heroScope;
  final String? heroImageUrl;
  final int? heroImageDecodeWidth;

  @override
  State<_PagerSlot> createState() => _PagerSlotState();
}

class _PagerSlotState extends State<_PagerSlot>
    with SingleTickerProviderStateMixin {
  var _built = false;

  /// Whether the detail was built on screen, under a fading stand-in.
  var _builtOnScreen = false;

  /// The stand-in's opacity over that detail; null once the fade is over.
  AnimationController? _standInFade;
  late final Listenable _gates = Listenable.merge([
    widget.current,
    widget.activeId,
  ]);

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
    return widget.index == window.center ||
        window.neighbours.contains(widget.index);
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
    _standInFade?.dispose();
    super.dispose();
  }

  void _onReadyChanged() {
    if (!_inWindow) return;
    setState(_latch);
    // Neighbours join off screen; the centre is the page in view.
    if (widget.index == widget.ready.value.center) _fadeStandIn();
  }

  /// Holds the stand-in over the detail for the frame that builds it, then
  /// fades it from there: started inside that long frame, the fade's clock
  /// would run from the frame's start and jump.
  void _fadeStandIn() {
    if (_fadeCurve() == null) return;
    _builtOnScreen = true;
    final fade = _standInFade = AnimationController(vsync: this, value: 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final curve = _fadeCurve();
      if (curve == null) {
        _endStandInFade();
        return;
      }
      final (duration, easing) = curve;
      fade.animateTo(0, duration: duration, curve: easing).whenCompleteOrCancel(
        () {
          if (mounted) _endStandInFade();
        },
      );
    });
  }

  void _endStandInFade() {
    setState(() {
      _standInFade?.dispose();
      _standInFade = null;
    });
  }

  /// The fade's duration and curve; null under reduced motion or a frozen
  /// ticker, where the page shows at once.
  (Duration, Curve)? _fadeCurve() {
    final (duration, curve) = MotionTokens.springCurve(
      context,
      MotionSpring.effectsFast,
    );
    final tickersEnabled = TickerMode.getValuesNotifier(context).value.enabled;
    if (duration == Duration.zero || !tickersEnabled) return null;
    return (duration, curve);
  }

  void _latch() {
    widget.ready.removeListener(_onReadyChanged);
    _built = true;
  }

  @override
  Widget build(BuildContext context) {
    if (!_built) return _SlotStandIn(illustId: widget.illustId);
    // Adjacent pages build heroes with the same feed tag the grid cards
    // carry — left enabled, all three would pair with feed cards and fly
    // together on push/pop. Only the page under the finger owns a live
    // hero; the rest ride HeroMode-disabled.
    //
    // Activity follows the work the user settled on, so deferred network
    // work (comments, related works) never starts on a prebuilt neighbour
    // or a page swiped through.
    //
    // The detail page is the builder's stable [child]: a page change only
    // re-wraps it in a new HeroMode/DetailPageActivity instead of running
    // the whole detail build again; only dependents of the activity scope
    // rebuild.
    final page = ListenableBuilder(
      listenable: _gates,
      child: _detail,
      builder: (context, child) => HeroMode(
        enabled: widget.index == widget.current.value,
        child: DetailPageActivity(
          active: widget.illustId == widget.activeId.value,
          child: child!,
        ),
      ),
    );
    if (!_builtOnScreen) return page;
    final fade = _standInFade;
    // The stack outlives the fade, the detail first in it: dropping the
    // stand-in keeps the detail's element.
    return Stack(
      fit: StackFit.expand,
      children: [
        page,
        if (fade != null)
          IgnorePointer(
            child: ExcludeSemantics(
              child: FadeTransition(
                key: ValueKey('pager-stand-in-${widget.illustId}'),
                opacity: fade,
                child: _SlotStandIn(illustId: widget.illustId),
              ),
            ),
          ),
      ],
    );
  }
}

/// A page not built yet: the work's image where the detail page will draw
/// it ([detailFirstImageFrame]: below the status bar, past a short image's
/// band, a panorama cropped to its viewport) from a decode the feed
/// already made, so a fast swipe shows the artwork in place instead of an
/// empty surface. Bare surface when nothing of it was decoded.
///
/// The two-pane layout draws the same image on its stage, fitted as the
/// image pager fits a page, and leaves the info column as the page's
/// ground — a fast swipe never lands on a blank stage (C10).
class _SlotStandIn extends ConsumerWidget {
  const _SlotStandIn({required this.illustId});

  final int illustId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final background = Theme.of(context).scaffoldBackgroundColor;
    final entity = ref.read(illustStoreProvider).get(illustId);
    final twoPane = AppBreakpoints.useTwoPaneDetailOf(
      context,
      HomeShellChrome.contentSizeOf(context),
    );
    // Cover: a panorama's viewport shows the middle of the image at its
    // height; any other frame has the image's own ratio.
    final image = entity == null
        ? null
        : PixivImage.decodedStandIn(
            context,
            entity.imageTierKeyAt(0),
            fit: BoxFit.cover,
          );
    if (twoPane) {
      final stage = Theme.of(context).colorScheme.surfaceContainerLow;
      return AdaptiveTwoPane(
        primary: ColoredBox(
          key: ValueKey('pager-slot-image-$illustId'),
          color: stage,
          child: entity == null || image == null
              ? null
              : Center(
                  child: AspectRatio(
                    aspectRatio: entity.pageAspectRatioAt(0),
                    child: image,
                  ),
                ),
        ),
        secondary: ColoredBox(
          key: ValueKey('pager-slot-info-$illustId'),
          color: background,
        ),
      );
    }
    if (entity == null) return ColoredBox(color: background);
    final frame = detailFirstImageFrame(context, entity);
    return ColoredBox(
      color: background,
      child: image == null
          ? null
          : Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: EdgeInsets.only(top: frame.top),
                child: SizedBox(
                  width: double.infinity,
                  height: frame.height,
                  child: image,
                ),
              ),
            ),
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
