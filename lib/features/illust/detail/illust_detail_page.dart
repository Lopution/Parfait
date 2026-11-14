import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../app/navigation/route_animation.dart';
import '../../../app/pixiv_image.dart';
import '../../../app/widgets/ambient_wash.dart';
import '../../../app/widgets/app_top_bar.dart';
import '../../../app/widgets/bookmark_switch_button.dart'
    show BookmarkSwitchButton, showBookmarkEditSheet;
import '../../../app/widgets/card_actions/card_action.dart';
import '../../../app/widgets/card_actions/illust_card_actions.dart';
import '../../../core/auth/account_store.dart';
import '../../../core/bookmark/bookmark_models.dart';
import '../../../core/bookmark/bookmark_store.dart';
import '../../../core/download/download_providers.dart';
import '../../../core/download/download_task.dart'
    show DownloadEvent, DownloadGroupSubmission;
import '../../../core/debug/frame_probe.dart';
import '../../../core/entity/illust_entity.dart';
import '../../../core/entity/illust_store.dart';
import '../../../core/history/history_models.dart';
import '../../../core/history/history_repository.dart';
import '../../../core/history/history_snapshot.dart';
import '../../../core/history/history_visibility.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../core/share/share_service.dart';
import '../../../app/widgets/app_menu_button.dart';
import '../../../app/widgets/selection_app_bar.dart';
import '../../../core/illust/illust_detail_controller.dart';
import '../../../core/illust/illust_download_controller.dart';
import '../../../app/haptics/app_haptics.dart';
import '../../../app/motion/motion_tokens.dart';
import '../../../app/motion/scroll_hide.dart';
import '../../../app/motion/state_fade.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/motion/hero_transition.dart';
import '../../../app/widgets/feed/feed_states.dart';
import 'author_works_section.dart';
import 'comments_preview_section.dart';
import 'detail_page_activity.dart';
import 'related_illusts_section.dart';
import 'widgets/detail_action_bar.dart';
import 'widgets/detail_comment_layer.dart';
import 'widgets/detail_image_pager.dart';
import 'widgets/illust_detail_skeleton.dart';
import 'widgets/detail_page_counter.dart';
import 'widgets/illust_series_section.dart';
import 'widgets/info_block.dart';
import 'widgets/page_image.dart';
import 'ugoira_viewer.dart';
import '../../../app/navigation/routes.dart';
import '../../../app/widgets/app_snack_bar.dart';
import '../../../app/widgets/errors/error_details.dart';
import '../../../l10n/context.dart';
import '../../../app/navigation/home_shell_metrics.dart';
import '../../../app/layout/app_breakpoints.dart';
import '../../../app/layout/content_widths.dart';
import '../../../app/layout/sliver_width_builder.dart';
import '../../../app/layout/deferred_cache_scroll_view.dart';
import '../../../app/layout/two_pane.dart';
import '../../../app/widgets/smooth_wheel_scroll.dart';
import '../../../app/widgets/comment_composer.dart';
part 'illust_detail_content.dart';

class IllustDetailPage extends ConsumerStatefulWidget {
  const IllustDetailPage({
    super.key,
    required this.illustId,
    this.initialEntity,
    this.heroScope = 'feed',
    this.heroImageUrl,
    this.heroImageDecodeWidth,
  });

  final int illustId;
  final IllustEntity? initialEntity;
  final String heroScope;
  final String? heroImageUrl;

  /// The feed card's decode width for [heroImageUrl] — decoding the hero
  /// phase at this width reuses the feed's decoded cache entry, so the
  /// landing frame does not re-decode the same file at screen width.
  final int? heroImageDecodeWidth;

  @override
  ConsumerState<IllustDetailPage> createState() => _IllustDetailPageState();
}

class _IllustDetailPageState extends ConsumerState<IllustDetailPage>
    with TickerProviderStateMixin {
  /// Page indexes selected in the explicit download-selection mode;
  /// `null` means the mode is off. A non-null empty set means the mode is
  /// on with nothing selected yet — "Done" stays disabled until n > 0.
  Set<int>? _selectedPages;

  /// Page-counter overlay data: the topmost image page currently in
  /// view feeds the `n / m` pill (VisibilityDetector per page — the pill
  /// hides for a single page). Empty set
  /// means nothing artwork is on screen (scrolled into the meta tail).
  final Set<int> _visiblePages = <int>{};

  /// The pill's page, kept out of this State: the trackers report on their
  /// own timer, typically while a swipe settles, and a page setState would
  /// rebuild every built page, the info block and the related grid just to
  /// move a counter.
  final ValueNotifier<int?> _topVisiblePage = ValueNotifier<int?>(null);

  /// The image the reader is on, shared by the two layouts: the top image
  /// in view in the single column, the image pager's page in the two-pane
  /// layout. A switch between them opens on the same image (NAV-21).
  int _imageIndex = 0;

  /// The layout the last build used; a switch to the single column brings
  /// its list back to [_imageIndex].
  bool? _lastTwoPane;

  /// One key per image page, so the single column can be brought to an
  /// image the two-pane layout was showing.
  final Map<int, GlobalKey> _pageKeys = {};

  /// Whether the collapse button after the last page is on screen: the
  /// floating one under the count steps aside then, so only one shows.
  /// Read from the button's box, not a VisibilityDetector: a sliver child
  /// scrolled off but still laid out stops painting and never reports.
  final ValueNotifier<bool> _pagesToggleOnScreen = ValueNotifier(false);
  final GlobalKey _pagesToggleKey = GlobalKey();
  final GlobalKey _infoAnchorKey = GlobalKey();

  /// Passed to the narrow layout's [SmoothWheelScroll] `controller:`
  /// parameter so the artwork-info jump can walk the lazily-built page
  /// list until the InfoBlock anchor exists. The component then uses this
  /// as its scroll controller — it only builds an internal one when none
  /// is passed — so we never touch a controller the component owns (R9).
  final ScrollController _narrowScroll = ScrollController();

  /// Two-pane right column scroll controller — kept explicit so resizing across
  /// the two-pane breakpoint preserves the user's meta/caption/comments offset.
  final ScrollController _metaScroll = ScrollController();
  double _lastMetaOffset = 0;
  double? _narrowInfoStartOffset;

  /// The floating action bar's presence (1 shown): it slides away while
  /// reading down and returns on the way back up, like the shell's bar.
  /// The Hero image flying in from a card or back to it is drawn above the
  /// page, so with a card the bar rises only once the route has landed and
  /// slides away as soon as the route starts to leave.
  late final AnimationController _barVisibility = AnimationController(
    vsync: this,
    value: widget.heroImageUrl == null ? 1 : 0,
  );
  final _scrollHide = ScrollHideTracker();

  /// Whether the in-place comment composer is up ([DetailCommentLayer]).
  bool _composing = false;
  final _composerKey = GlobalKey<CommentComposerState>();

  /// TalkBack is exploring: chrome that slides away cannot be found, so
  /// the bar stays.
  bool _touchExploration = false;

  /// How drawn the top bar is over the narrow layout's first image: 0
  /// while the image is under it, 1 once the image has scrolled away
  /// (see [AppTopBar.immersion]).
  final _immersion = ValueNotifier<double>(0);

  /// Scroll offset where the top bar starts drawing; set by each build
  /// from the first image's height.
  double _immersionStart = 0;

  /// Status bar plus toolbar over the narrow layout's artwork; 0 in the
  /// two-pane layout, whose pages sit below an opaque bar.
  double _topChromeExtent = 0;

  /// The top bar's arrival: it fades in with the page flying in from a
  /// card (see [AppTopBar.entrance]); without a card it is there at once.
  late final AnimationController _topBarEntrance = AnimationController(
    vsync: this,
    value: widget.heroImageUrl == null ? 1 : 0,
  );
  Animation<double>? _routeAnimation;

  /// Whether the route has started showing the page.
  bool _entered = false;

  /// The layout switch's fade: a window crossing the two-pane breakpoint
  /// fades the page in instead of swapping it in one frame. Running from
  /// part-way when a drag crosses back and forth, so the page does not
  /// flash between the two layouts.
  late final AnimationController _layoutFade = AnimationController(
    vsync: this,
    value: 1,
  );
  late final Animation<double> _layoutFadeOpacity = Tween(
    begin: 0.55,
    end: 1.0,
  ).animate(_layoutFade);

  @override
  void initState() {
    super.initState();
    _narrowScroll
      ..addListener(_updateImmersion)
      ..addListener(_schedulePagesToggleCheck)
      ..addListener(_updateNarrowInfoStartOffset);
    _metaScroll.addListener(_onMetaScrollChanged);
  }

  void _onMetaScrollChanged() {
    if (_metaScroll.hasClients) {
      _lastMetaOffset = _metaScroll.offset;
    }
  }

  void _updateNarrowInfoStartOffset([double? topChromeExtent]) {
    final infoCtx = _infoAnchorKey.currentContext;
    if (infoCtx == null || !infoCtx.mounted || !_narrowScroll.hasClients) {
      return;
    }
    final infoRo = infoCtx.findRenderObject();
    final scrollRo = _narrowScroll.position.context.notificationContext
        ?.findRenderObject();
    if (infoRo is! RenderBox ||
        !infoRo.hasSize ||
        scrollRo is! RenderBox ||
        !scrollRo.hasSize) {
      return;
    }
    final topEdge =
        scrollRo.localToGlobal(Offset.zero).dy +
        (topChromeExtent ?? _topChromeExtent);
    _narrowInfoStartOffset =
        _narrowScroll.offset + (infoRo.localToGlobal(Offset.zero).dy - topEdge);
  }

  double _captureNarrowMetaOffset(double topChromeExtent) {
    _updateNarrowInfoStartOffset(topChromeExtent);
    final infoStart = _narrowInfoStartOffset;
    if (!_narrowScroll.hasClients || infoStart == null) return 0;
    return math.max(0.0, _narrowScroll.offset - infoStart);
  }

  void _scheduleMetaSync(double target) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_metaScroll.hasClients) return;
      _metaScroll.jumpTo(
        target.clamp(0.0, _metaScroll.position.maxScrollExtent),
      );
    });
  }

  void _scheduleNarrowMetaSync(double targetMetaOffset) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      while (mounted &&
          _infoAnchorKey.currentContext == null &&
          _narrowScroll.hasClients) {
        final position = _narrowScroll.position;
        if (position.pixels >= position.maxScrollExtent) break;
        position.jumpTo(
          math.min(
            position.pixels + position.viewportDimension,
            position.maxScrollExtent,
          ),
        );
        await WidgetsBinding.instance.endOfFrame;
      }
      if (!mounted || !_narrowScroll.hasClients) return;
      _updateNarrowInfoStartOffset();
      final infoStart = _narrowInfoStartOffset;
      if (infoStart == null) return;
      final target = (infoStart + targetMetaOffset).clamp(
        0.0,
        _narrowScroll.position.maxScrollExtent,
      );
      _narrowScroll.jumpTo(target);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _barVisibility.duration = MotionTokens.resolve(
      context,
      MotionTokens.chrome,
    );
    _touchExploration = MediaQuery.accessibleNavigationOf(context);
    if (_touchExploration && !_downloadMode && !_composing) {
      _barVisibility.value = 1;
    }
    _topBarEntrance.duration = MotionTokens.resolve(
      context,
      MotionTokens.chrome,
    );
    final route = RouteAnimationScope.of(context);
    if (!identical(route, _routeAnimation)) {
      _routeAnimation?.removeStatusListener(_onRouteStatus);
      _routeAnimation = route?..addStatusListener(_onRouteStatus);
      // Read after the first frame: a route that is not a FuncPage provides
      // its proxy, which reports a completed placeholder until the push
      // starts.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _onRouteStatus(_routeAnimation?.status ?? AnimationStatus.completed);
        }
      });
    }
  }

  /// The top bar and the action bar enter with the page, not after its
  /// landing: waiting held the page's controls back until the image had
  /// flown in. Leaving, they stay and go with the page: sliding the action
  /// bar down on its own read as a second, smaller exit under the page's
  /// fade.
  void _onRouteStatus(AnimationStatus status) {
    // Only the first forward is the page entering.
    final entering = status == AnimationStatus.forward && !_entered;
    if (!entering && !status.isCompleted) return;
    _entered = true;
    _topBarEntrance.forward();
    if (!_touchExploration) {
      slideChrome(context, _barVisibility, hidden: false);
    }
  }

  /// The bar draws over the last toolbar height before the first image
  /// leaves the screen top, so it is solid by the time content would
  /// scroll under it.
  void _updateImmersion() {
    if (!_narrowScroll.hasClients) return;
    final drawn = (_narrowScroll.offset - _immersionStart) / kToolbarHeight;
    _immersion.value = drawn.clamp(0.0, 1.0).toDouble();
  }

  bool _pagesToggleCheckScheduled = false;

  /// A scroll is reported before the frame lays it out: the button's box
  /// is read once that frame is done.
  void _schedulePagesToggleCheck() {
    if (_pagesToggleCheckScheduled) return;
    _pagesToggleCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pagesToggleCheckScheduled = false;
      if (mounted) _updatePagesToggleOnScreen();
    });
  }

  /// At least half of the button inside the scroll view counts as on
  /// screen.
  void _updatePagesToggleOnScreen() {
    final box = _pagesToggleKey.currentContext?.findRenderObject();
    final Object? viewport = box == null
        ? null
        : RenderAbstractViewport.maybeOf(box);
    if (box is! RenderBox || !box.hasSize || viewport is! RenderBox) {
      _pagesToggleOnScreen.value = false;
      return;
    }
    final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
    final height = box.size.height;
    final shown =
        math.min(top + height, viewport.size.height) - math.max(top, 0.0);
    _pagesToggleOnScreen.value = shown >= height / 2;
  }

  /// Folds an expanded set back to page 1. A reader already past page 1
  /// lands where the shorter list now ends — page 1's bottom under the top
  /// bar, the expand button and info right below — instead of wherever
  /// the list happens to clamp.
  void _collapsePages(double firstPageEnd) {
    if (_narrowScroll.hasClients && _narrowScroll.offset > firstPageEnd) {
      _narrowScroll.jumpTo(firstPageEnd);
    }
    setState(() => _pagesExpanded = false);
  }

  bool _onBarScroll(ScrollNotification notification) {
    if (_touchExploration || _downloadMode || _composing) return false;
    final hide = _scrollHide.update(
      notification,
      _barVisibility,
      travel: DetailActionBar.restingExtent(context),
    );
    if (hide != null) slideChrome(context, _barVisibility, hidden: hide);
    return false;
  }

  void _onPageVisibility(int index, VisibilityInfo info) {
    // A detector torn down with the page still reports once more.
    if (!mounted) return;
    // The narrow layout runs under the see-through top bar: a page leaving
    // the top whose last strip sits behind the bar is not on screen to the
    // reader, and the count must not hang over the info below it.
    final bounds = info.visibleBounds;
    final behindTopChrome = bounds.top > 0 && bounds.height <= _topChromeExtent;
    if (info.visibleFraction > 0 && !behindTopChrome) {
      _visiblePages.add(index);
    } else {
      _visiblePages.remove(index);
    }
    _topVisiblePage.value = _visiblePages.isEmpty
        ? null
        : _visiblePages.reduce(math.min);
    // Scrolled into the meta tail, the last image read stays the one a
    // switch to the two-pane layout opens on.
    final top = _topVisiblePage.value;
    if (top != null) _imageIndex = top;
  }

  /// The image at the top of the single column right now, read from the
  /// pages already laid out. The visibility trackers report on their own
  /// timer, so a switch to the two-pane layout cannot wait for them
  /// (NAV-21); the boxes still hold the single column's last frame.
  int? _narrowTopImage(_FirstImageLayout layout) {
    int? top;
    for (final entry in _pageKeys.entries) {
      final box = entry.value.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      final visible =
          rect.bottom > layout.topChrome && rect.top < _narrowBottom;
      if (!visible) continue;
      if (top == null || entry.key < top) top = entry.key;
    }
    return top;
  }

  /// The bottom of the single column's viewport in global coordinates.
  double get _narrowBottom {
    if (!_narrowScroll.hasClients) return MediaQuery.sizeOf(context).height;
    final viewport = _narrowScroll.position.context.notificationContext
        ?.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) {
      return MediaQuery.sizeOf(context).height;
    }
    return viewport.localToGlobal(Offset.zero).dy + viewport.size.height;
  }

  /// The ⋮ menu's artwork-info item scrolls the InfoBlock into view.
  /// The InfoBlock's parts are built
  /// lazily below the page list, so on long works the narrow scroll first
  /// steps one viewport at a time until its first part exists — each step's
  /// viewport is contiguous with the previous one, so every section gets
  /// built as we pass. ensureVisible uses the target's own context
  /// (risks R9 — we never touch SmoothWheelScroll's controller).
  Future<void> _scrollToInfo() async {
    while (_infoAnchorKey.currentContext == null && _narrowScroll.hasClients) {
      final position = _narrowScroll.position;
      if (position.pixels >= position.maxScrollExtent) break;
      position.jumpTo(
        math.min(
          position.pixels + position.viewportDimension,
          position.maxScrollExtent,
        ),
      );
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    final anchor = _infoAnchorKey.currentContext;
    if (anchor == null || !anchor.mounted) return;
    await Scrollable.ensureVisible(
      anchor,
      duration: MotionTokens.resolve(anchor, MotionTokens.spatial),
    );
  }

  bool _revealScheduled = false;

  /// Plays the layout switch's fade. A switch while one is still running
  /// continues from the current opacity rather than restarting, so a drag
  /// back and forth over the breakpoint does not flash the page.
  void _fadeLayoutIn(BuildContext context) {
    final duration = MotionTokens.resolve(context, MotionTokens.branchSwitch);
    if (duration == Duration.zero) {
      _layoutFade.value = 1;
      return;
    }
    if (_layoutFade.value >= 1) _layoutFade.value = 0;
    FrameProbe.instance.enter('detail layout');
    final fade = _layoutFade.animateTo(
      1,
      duration: duration,
      curve: MotionTokens.branchSwitchCurve,
    );
    fade.whenCompleteOrCancel(() => FrameProbe.instance.exit('detail layout'));
    unawaited(fade);
  }

  /// A switch from the two-pane layout to the single column brings its
  /// list back to the image the pager was showing (NAV-21). The list is
  /// lazy, so the target page is walked into view first; a collapsed set
  /// opens before the page exists at all.
  void _scheduleNarrowReveal(IllustEntity entity) {
    if (_revealScheduled) return;
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _revealScheduled = false;
      if (!mounted) return;
      final index = _imageIndex;
      if (index <= 0) return;
      final layout = _FirstImageLayout.of(
        context,
        entity,
        expanded: _pagesExpanded,
      );
      if (index >= layout.shownPages) {
        setState(() => _pagesExpanded = true);
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
      }
      await _revealNarrowPage(index);
    });
  }

  Future<void> _revealNarrowPage(int index) async {
    while (mounted && _narrowScroll.hasClients) {
      final page = _pageKeys[index]?.currentContext;
      if (page != null && page.mounted) break;
      final position = _narrowScroll.position;
      if (position.pixels >= position.maxScrollExtent) break;
      position.jumpTo(
        math.min(
          position.pixels + position.viewportDimension,
          position.maxScrollExtent,
        ),
      );
      await WidgetsBinding.instance.endOfFrame;
    }
    final page = _pageKeys[index]?.currentContext;
    if (page == null || !page.mounted) return;
    await Scrollable.ensureVisible(
      page,
      duration: MotionTokens.resolve(page, MotionTokens.spatial),
    );
  }

  bool _blockMode = false;

  /// Whether a multi-image illustration shows every page. Lives with this
  /// page only: a new visit starts collapsed again.
  bool _pagesExpanded = false;
  StreamSubscription<DownloadEvent>? _downloadEvents;

  @override
  void dispose() {
    unawaited(_downloadEvents?.cancel());
    _narrowScroll.dispose();
    _metaScroll.dispose();
    _topVisiblePage.dispose();
    _pagesToggleOnScreen.dispose();
    _barVisibility.dispose();
    _immersion.dispose();
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    _topBarEntrance.dispose();
    _layoutFade.dispose();
    super.dispose();
  }

  /// Download badge states derive from live manager tasks; without this
  /// subscription the Provider-backed snapshot would never notify the UI.
  void _ensureDownloadListener() {
    // Only this work's: a batch elsewhere rebuilt every open detail page
    // once per saved page.
    _downloadEvents ??= ref.read(downloadManagerProvider).events.listen((
      event,
    ) {
      if (mounted && event.snapshot.illustId == widget.illustId) {
        setState(() {});
      }
    });
  }

  bool get _downloadMode => _selectedPages != null;

  /// Raises the comment composer on [surface] in place of the action bar;
  /// signed out, opens the sign-in instead.
  void _openComposer(CommentComposerInputState surface) {
    final signedIn =
        ref.read(accountStoreProvider).value?.usableCurrent != null;
    if (!signedIn) {
      unawaited(openLogin(context));
      return;
    }
    if (!_composing) {
      setState(() => _composing = true);
      slideChrome(context, _barVisibility, hidden: true);
    }
    // The composer exists from the next frame.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _composerKey.currentState?.open(surface),
    );
  }

  void _closeComposer() {
    if (!_composing || !mounted) return;
    setState(() => _composing = false);
    // Opening hid the bar under touch exploration too. The selection bar
    // keeps it hidden while that mode is on.
    if (!_downloadMode) slideChrome(context, _barVisibility, hidden: false);
  }

  /// Entering the mode is a management-mode transition → confirm haptic.
  void _enterDownloadMode() {
    if (_downloadMode) return;
    AppHaptics.confirm();
    // Every page has to be on screen to be picked.
    setState(() {
      _selectedPages = <int>{};
      _pagesExpanded = true;
    });
    // The selection brings its own download; the bar slides aside.
    slideChrome(context, _barVisibility, hidden: true);
  }

  /// Any exit path (cancel button, blank tap, system back) is a light
  /// confirmation. In-flight download tasks are owned by DownloadManager
  /// and are never touched here — the mode is only a selection layer.
  void _exitDownloadMode() {
    if (!_downloadMode) return;
    AppHaptics.select();
    setState(() => _selectedPages = null);
    slideChrome(context, _barVisibility, hidden: false);
  }

  void _togglePageSelected(int index) {
    final selected = _selectedPages;
    if (selected == null) return;
    AppHaptics.select();
    setState(() {
      if (!selected.remove(index)) selected.add(index);
    });
  }

  void _selectAllPages(IllustEntity entity) {
    if (_selectedPages == null) return;
    AppHaptics.select();
    setState(() {
      _selectedPages = {for (var i = 0; i < entity.pageCount; i++) i};
    });
  }

  /// "Done" submits every selected page through the download controller
  /// (dedupe/retry-safe). Success exits the mode; failure keeps the mode
  /// and the selection so the user can retry the remainder.
  Future<void> _submitSelection(IllustEntity entity) async {
    final selected = _selectedPages;
    if (selected == null || selected.isEmpty) return;
    final download = ref.read(illustDownloadControllerProvider);
    try {
      for (final index in selected.toList()..sort()) {
        await download.download(entity, index);
      }
    } catch (error) {
      if (!mounted) return;
      AppHaptics.error();
      showErrorSnackBar(
        context,
        action: context.l10n.downloadSubmissionFailed,
        error: error,
      );
      return;
    }
    if (!mounted) return;
    showDownloadSubmittedSnackBar(context);
    setState(() => _selectedPages = null);
    if (!_composing) slideChrome(context, _barVisibility, hidden: false);
  }

  @override
  Widget build(BuildContext context) {
    _ensureDownloadListener();
    final async = ref.watch(illustDetailControllerProvider(widget.illustId));
    final entity = _entityOf(async);
    // The narrow layout opens on the artwork under a see-through bar —
    // the skeleton too, so content arriving never shifts it.
    final immersive =
        !AppBreakpoints.useTwoPaneDetailOf(
          context,
          HomeShellChrome.contentSizeOf(context),
        ) &&
        (entity == null ? async.isLoading : _rendersContent(async, entity));
    return PopScope(
      // While the selection mode is on, system back exits the mode instead
      // of leaving the page, like the selection bar's close button.
      // In-flight downloads are untouched — the mode is only a UI
      // selection layer.
      // Back sends the comment composer down first.
      canPop: !_downloadMode && !_composing,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_composing) {
          final composer = _composerKey.currentState;
          composer == null ? _closeComposer() : composer.dismiss();
        } else {
          _exitDownloadMode();
        }
      },
      child: Scaffold(
        // The comment composer takes the keyboard's inset itself; the
        // page under it keeps its size (LAYOUT-10's overlay exception).
        resizeToAvoidBottomInset: false,
        extendBodyBehindAppBar: immersive,
        appBar: _downloadMode && entity != null
            ? _buildSelectionAppBar(context, entity)
            : _buildAppBar(context, async, immersive: immersive),
        body: _fadeStates(
          async.when(
            // U5 (R7): AsyncNotifier.build() returns a Future, so the first
            // frame is ALWAYS AsyncLoading — a spinner here would hide the
            // store snapshot the feed already placed in IllustStore, and the
            // Hero destination would not exist on the first frame. Render the
            // snapshot immediately; the controller's IllustDetailLoading state
            // stays as the no-snapshot first-load signal.
            loading: () {
              final snapshot = _snapshotEntity();
              if (snapshot != null) {
                return _buildContent(context, ref, snapshot);
              }
              return const IllustDetailSkeleton();
            },
            error: (Object error, StackTrace _) => FeedError(
              title: context.l10n.illustDetailLoadFailed,
              error: error,
              retryLabel: context.l10n.retry,
              onRetry: () => ref
                  .read(
                    illustDetailControllerProvider(widget.illustId).notifier,
                  )
                  .reload(),
            ),
            data: (state) {
              // Snapshot-first (R1): the shared store renders stale data behind
              // any in-flight refresh; the controller state drives the terminal
              // surfaces (the loading branch above reads the store directly).
              return switch (state) {
                IllustDetailRestricted(:final entity) => FeedEmpty(
                  icon: Icons.visibility_off_outlined,
                  title: context.l10n.illustDetailRestricted(entity.id),
                ),
                IllustDetailNotFound() => FeedEmpty(
                  icon: Icons.search_off,
                  title: context.l10n.illustDetailNotFound,
                ),
                IllustDetailReady(:final entity) => _buildContent(
                  context,
                  ref,
                  entity,
                  detailReady: true,
                ),
                IllustDetailError(:final error, :final snapshot) =>
                  _errorOrSnapshot(context, ref, error, snapshot),
              };
            },
          ),
        ),
      ),
    );
  }

  /// The no-snapshot skeleton hands over to the content with a fade. Empty
  /// and error states fade in by themselves; the snapshot-first path never
  /// shows the skeleton, so the Hero destination is never faded.
  Widget _fadeStates(Widget body) =>
      StateFade(kind: body is IllustDetailSkeleton, child: body);

  /// The page-selection mode's top bar: the count, select all, and
  /// download; close (or system back) leaves the mode.
  PreferredSizeWidget _buildSelectionAppBar(
    BuildContext context,
    IllustEntity entity,
  ) {
    final l10n = context.l10n;
    final selected = _selectedPages ?? const <int>{};
    return selectionAppBar(
      context,
      count: selected.length,
      onClose: _exitDownloadMode,
      actions: [
        IconButton(
          tooltip: l10n.selectAll,
          onPressed: () => _selectAllPages(entity),
          icon: const Icon(Icons.select_all),
        ),
        IconButton(
          tooltip: l10n.downloadSelectedPages,
          onPressed: selected.isEmpty
              ? null
              : () => unawaited(_submitSelection(entity)),
          icon: const Icon(Icons.download_outlined),
        ),
      ],
    );
  }

  bool _rendersContent(
    AsyncValue<IllustDetailState> async,
    IllustEntity? entity,
  ) =>
      entity != null &&
      async.value is! IllustDetailRestricted &&
      async.value is! IllustDetailNotFound;

  PreferredSizeWidget _buildAppBar(
    BuildContext context,
    AsyncValue<IllustDetailState> async, {
    required bool immersive,
  }) {
    final entity = _entityOf(async);
    // Restricted and not-found states render a FeedEmpty body without an
    // InfoBlock — the menu's artwork-info item only exists while the
    // content actually renders.
    final rendersContent = _rendersContent(async, entity);
    final twoPane = AppBreakpoints.useTwoPaneDetailOf(
      context,
      HomeShellChrome.contentSizeOf(context),
    );
    return AppTopBar(
      // Over the artwork the bar shows nothing but controls; the work's
      // title fades in with the surface once the image scrolls away. The
      // opaque layouts keep a generic label: the real title wraps freely
      // in InfoBlock.
      title: Text(
        immersive && entity != null
            ? entity.title
            : context.l10n.illustDetailTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      immersion: immersive ? _immersion : null,
      // Nothing to lift the controls off while page 1 sits below the bar.
      overArtwork:
          entity == null ||
          _FirstImageLayout.of(
            context,
            entity,
            expanded: _pagesExpanded,
          ).artworkUnderBar,
      entrance: immersive ? _topBarEntrance : null,
      // In single-column mode, overflow actions sit on the top bar while
      // download and bookmark float in DetailActionBar. In two-pane/tabletop,
      // the secondary inspector owns the single ⋮ menu and Share button
      // (FB-03) so the screen never carries duplicate menu triggers.
      actions: [
        if (entity != null && (!twoPane || !rendersContent))
          _buildMoreMenu(
            entity,
            rendersContent: rendersContent,
            twoPane: twoPane,
          ),
      ],
    );
  }

  Widget _buildMoreMenu(
    IllustEntity entity, {
    required bool rendersContent,
    required bool twoPane,
  }) {
    return _DetailMoreMenu(
      entity: entity,
      actions: [
        if (!twoPane || !rendersContent) _DetailMenuAction.share,
        if (rendersContent) ...[
          _DetailMenuAction.editBookmark,
          watchLaterCardAction,
        ],
        if (entity.pageCount > 1 && !entity.isUgoira)
          _DetailMenuAction.selectPages,
        if (rendersContent) ...[
          if (!twoPane) _DetailMenuAction.info,
          ...muteCardActions,
        ],
      ],
      onSelected: (BuildContext buttonContext, _DetailMenuAction action) =>
          switch (action) {
            _DetailMenuAction.share => unawaited(
              _share(buttonContext, ref, entity),
            ),
            _DetailMenuAction.editBookmark => unawaited(
              showBookmarkEditSheet(
                context,
                BookmarkKey(BookmarkEntityType.illust, entity.id),
                title: entity.title,
              ),
            ),
            _DetailMenuAction.selectPages => _enterDownloadMode(),
            _DetailMenuAction.info => unawaited(_scrollToInfo()),
          },
    );
  }

  /// Every page, deduplicated by the manager. Any submission failure is
  /// shown: manager, ownership and channel errors would otherwise vanish.
  Future<void> _downloadAll(IllustEntity entity) async {
    final DownloadGroupSubmission submission;
    try {
      submission = await ref
          .read(illustDownloadControllerProvider)
          .downloadAll(entity);
    } catch (error) {
      if (!mounted) return;
      AppHaptics.error();
      showErrorSnackBar(
        context,
        action: context.l10n.downloadSubmissionFailed,
        error: error,
      );
      return;
    }
    if (!mounted) return;
    showDownloadSubmittedSnackBar(
      context,
      alreadyQueued: submission.group == null,
    );
  }

  Future<void> _share(
    BuildContext context,
    WidgetRef ref,
    IllustEntity entity,
  ) async {
    final outcome = await ref
        .read(shareServiceProvider)
        .share(
          SharePayload.illust(
            id: entity.id,
            title: entity.title,
            author: entity.user.name,
          ),
          sharePositionOrigin: shareOriginOf(context),
        );
    if (outcome == ShareOutcome.copiedToClipboard && context.mounted) {
      showAppSnackBar(context, context.l10n.linkCopied);
    }
  }

  IllustEntity? _entityOf(AsyncValue<IllustDetailState> async) {
    final state = async.value;
    return switch (state) {
      IllustDetailReady(:final entity) => entity,
      IllustDetailRestricted(:final entity) => entity,
      IllustDetailError(:final snapshot) => snapshot ?? _snapshotEntity(),
      _ => _snapshotEntity(),
    };
  }

  IllustEntity? _snapshotEntity() =>
      ref.read(illustStoreProvider).get(widget.illustId) ??
      widget.initialEntity;

  Widget _errorOrSnapshot(
    BuildContext context,
    WidgetRef ref,
    Object error,
    IllustEntity? snapshot,
  ) {
    final entity = snapshot ?? _snapshotEntity();
    if (entity != null) return _buildContent(context, ref, entity);
    return FeedError(
      title: context.l10n.illustDetailLoadFailed,
      error: error,
      retryLabel: context.l10n.retry,
      onRetry: () => ref
          .read(illustDetailControllerProvider(widget.illustId).notifier)
          .reload(),
    );
  }

  void _expandPages() => setState(() => _pagesExpanded = true);

  void _toggleBlockMode() => setState(() => _blockMode = !_blockMode);
}
