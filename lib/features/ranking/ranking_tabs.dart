import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/haptics/app_haptics.dart';
import '../../app/widgets/app_menu_button.dart';
import '../../app/widgets/app_tab_bar.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/func_bottom_nav.dart';
import '../../app/widgets/home_branch_stack.dart';
import '../../app/widgets/ranking_category_sheet.dart';
import '../../app/widgets/settings/persist_settings.dart';
import '../../app/widgets/tab_swipe_switcher.dart';
import '../../core/log.dart';
import '../../core/network/pixiv_client_identity.dart';
import '../../core/ranking/ranking_catalog.dart';
import '../../core/ranking/ranking_category.dart';
import '../../core/settings/arrangement.dart';
import '../../core/settings/settings_controller.dart';
import '../../l10n/context.dart';
import '../../l10n/lookup.dart';
import 'ranking_date.dart';

/// Records the page's mode and ranking day (null is the latest) in the
/// route.
typedef RankingRouteChanged<M> = void Function(M mode, DateTime? date);

/// Builds the feed of one category on one day.
typedef RankingBodyBuilder<M> =
    Widget Function(M mode, DateTime? date, ScrollController scrollController);

/// The frame both ranking pages share: the user's categories as tabs (the
/// arrangement minus the local block), one cached body per visited
/// category, the date bar and the category sheet. Only the selected
/// category is built; visited ones keep their feed and scroll position. A
/// past day ([date]) applies to every category.
class RankingTabs<M extends RankingCategory> extends ConsumerStatefulWidget {
  const RankingTabs({
    super.key,
    required this.catalog,
    required this.routeMode,
    required this.date,
    required this.onRouteChanged,
    required this.switchLabel,
    required this.switchIcon,
    required this.onSwitch,
    required this.bodyBuilder,
  });

  final RankingCatalog<M> catalog;

  /// The route's `?mode=`; null opens on the last category viewed.
  final M? routeMode;

  /// The ranking day from the route; null is the latest.
  final DateTime? date;
  final RankingRouteChanged<M>? onRouteChanged;

  /// The sheet's row to the other kind of ranking.
  final String switchLabel;
  final IconData switchIcon;
  final void Function(BuildContext context) onSwitch;
  final RankingBodyBuilder<M> bodyBuilder;

  @override
  ConsumerState<RankingTabs<M>> createState() => _RankingTabsState<M>();
}

enum _TabAction { moveToFront, hide, edit }

class _RankingTabsState<M extends RankingCategory>
    extends ConsumerState<RankingTabs<M>>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabController;
  late List<M> _modes;
  late M _selected;

  /// A hidden category the route opened: shown first for this visit and
  /// not saved, until the user shows or hides it.
  M? _routeExtra;
  final _scrollControllers = <M, ScrollController>{};
  final _loadedModes = <M>{};

  /// One body instance per mode, reused across page builds: an identical
  /// widget short-circuits the element update, so the tab hop, route echo
  /// and drag warm-up that rebuild this page mid-swipe no longer rebuild
  /// every loaded feed (and its visible cards) inside the swipe frame.
  final _bodies = <M, Widget>{};
  DateTime? _date;

  /// A context inside the Scaffold's notification scope, captured from the
  /// body's Builder: scroll announcements dispatched from here reach the
  /// app bar's ScrollNotificationObserver without passing the feeds' own
  /// NotificationListeners — a synthetic update must not trip load-more.
  late BuildContext _notificationContext;
  ReTapChannel? _reTapChannel;
  bool _suppressRouteEcho = false;

  /// Off when a background branch or a page above hides this one.
  ValueListenable<TickerModeData>? _onScreen;

  /// A route write [_writeRoute] held back while the page was off screen.
  bool _routeStale = false;

  /// For the write in [dispose], where `ref` is gone.
  late final ProviderContainer _container;

  RankingCatalog<M> get _catalog => widget.catalog;

  @override
  void initState() {
    super.initState();
    _date = widget.date;
    _routeExtra = _hiddenOrNull(widget.routeMode);
    _modes = _visibleModes();
    _selected = initialRankingCategory(
      _modes,
      routeMode: widget.routeMode,
      lastViewed: ref.read(_catalog.lastViewedProvider),
    );
    _tabController = _controllerOn(_selected);
    _loadedModes.add(_selected);
    _container = ProviderScope.containerOf(context, listen: false);
    WidgetsBinding.instance.addObserver(this);
    ref.listenManual(_catalog.arrangementProvider, (_, _) => _refreshModes());
    ref.listenManual(rankingBlockProvider, (_, _) => _refreshModes());
  }

  @override
  void didUpdateWidget(RankingTabs<M> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // context.replace keeps the page, so a route write lands here as a
    // widget update. The echo of our own write names the category on
    // screen and changes nothing; another one (a link while the page is
    // open) is selected without writing the route back.
    final mode = widget.routeMode;
    if (mode != null && mode != oldWidget.routeMode && mode != _selected) {
      _routeStale = false;
      _showRouteMode(mode);
    }
    if (widget.date != _date) _resetForDate(widget.date);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final channel = HomeBranchStack.reTapOf(context);
    if (identical(channel, _reTapChannel)) return;
    _reTapChannel?.removeListener(_onBranchReTap);
    _reTapChannel = channel;
    _reTapChannel?.addListener(_onBranchReTap);
    final onScreen = TickerMode.getValuesNotifier(context);
    if (!identical(onScreen, _onScreen)) {
      _onScreen?.removeListener(_onScreenChanged);
      _onScreen = onScreen..addListener(_onScreenChanged);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden) _remember();
  }

  @override
  void dispose() {
    _remember();
    WidgetsBinding.instance.removeObserver(this);
    _reTapChannel?.removeListener(_onBranchReTap);
    _onScreen?.removeListener(_onScreenChanged);
    _tabController
      ..removeListener(_handleTabChanged)
      ..dispose();
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  M? _hiddenOrNull(M? mode) =>
      mode != null &&
          !ref.read(_catalog.arrangementProvider).shown.contains(mode)
      ? mode
      : null;

  List<M> _visibleModes() {
    final block = ref.read(rankingBlockProvider);
    return visibleRankingCategories(
      ref.read(_catalog.arrangementProvider).shown,
      blockR18: block.r18,
      blockAI: block.ai,
      fallback: _catalog.fallback,
      routeMode: _routeExtra,
    );
  }

  TabController _controllerOn(M mode) => TabController(
    length: _modes.length,
    vsync: this,
    initialIndex: _modes.indexOf(mode),
  )..addListener(_handleTabChanged);

  /// An edit or a block change: the new list keeps the category on screen,
  /// or lands on the one that took its place.
  void _refreshModes() {
    if (_routeExtra case final extra?
        when ref.read(_catalog.arrangementProvider).shown.contains(extra)) {
      _routeExtra = null;
    }
    final modes = _visibleModes();
    if (listEquals(modes, _modes)) return;
    final previous = _selected;
    setState(() => _replaceModes(modes));
    if (_selected != previous) _afterSelect();
  }

  /// A [TabController]'s length is fixed: a new list gets a new controller.
  void _replaceModes(List<M> modes, {M? select}) {
    final index = _modes.indexOf(_selected);
    final selected =
        select ??
        (modes.contains(_selected)
            ? _selected
            : modes[index.clamp(0, modes.length - 1)]);
    final stale = _tabController..removeListener(_handleTabChanged);
    final dropped = [
      for (final mode in _scrollControllers.keys)
        if (!modes.contains(mode)) mode,
    ];
    final staleScrolls = [
      for (final mode in dropped) _scrollControllers.remove(mode)!,
    ];
    for (final mode in _modes) {
      if (!modes.contains(mode)) {
        _bodies.remove(mode);
        _loadedModes.remove(mode);
      }
    }
    _modes = modes;
    _selected = selected;
    _loadedModes.add(selected);
    _tabController = _controllerOn(selected);
    // The outgoing tab bar and lists still hold these until the next frame
    // unmounts them.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      stale.dispose();
      for (final controller in staleScrolls) {
        controller.dispose();
      }
    });
  }

  void _showRouteMode(M mode) {
    if (!_modes.contains(mode)) {
      _routeExtra = _hiddenOrNull(mode);
      final modes = _visibleModes();
      // A blocked category stays out.
      if (!modes.contains(mode)) return;
      _replaceModes(modes, select: mode);
      _withoutRouteEcho(_afterSelect);
      return;
    }
    _withoutRouteEcho(() => _tabController.index = _modes.indexOf(mode));
  }

  /// The route already names the category: selecting it must not write the
  /// route back.
  void _withoutRouteEcho(VoidCallback select) {
    _suppressRouteEcho = true;
    try {
      select();
    } finally {
      _suppressRouteEcho = false;
    }
  }

  /// A different day is a different list in every mode: drop the cached
  /// bodies and scroll positions, keep only the tab on screen loaded.
  void _resetForDate(DateTime? date) {
    final stale = _scrollControllers.values.toList();
    _scrollControllers.clear();
    _bodies.clear();
    _loadedModes
      ..clear()
      ..add(_selected);
    _date = date;
    // The outgoing lists still hold these until the next frame unmounts
    // them.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final controller in stale) {
        controller.dispose();
      }
    });
  }

  void _changeDate(DateTime? date) {
    if (date == _date) return;
    setState(() => _resetForDate(date));
    _writeRoute();
  }

  void _handleTabChanged() {
    final mode = _modes[_tabController.index];
    if (mode == _selected) return;
    setState(() {
      _selected = mode;
      _loadedModes.add(mode);
    });
    _afterSelect();
  }

  void _afterSelect() {
    // The app bar's scrolled-under state must follow the tab now on
    // screen, not the last list that scrolled.
    announceTabScroll(_notificationContext, _scrollControllerFor(_selected));
    if (!_suppressRouteEcho) _writeRoute();
  }

  /// Writes the category and day on screen into the route. An edit or a
  /// block change made elsewhere (the settings branch) reaches this page
  /// off screen, where replacing the route would pull the user back here:
  /// the write waits until the page shows again.
  void _writeRoute() {
    if (_onScreen?.value.enabled ?? true) {
      _routeStale = false;
      widget.onRouteChanged?.call(_selected, _date);
    } else {
      _routeStale = true;
    }
  }

  void _onScreenChanged() {
    if (!_routeStale || _onScreen?.value.enabled != true) return;
    // The notifier flips while the tree builds; navigate after the frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _routeStale && _onScreen?.value.enabled == true) {
        _writeRoute();
      }
    });
  }

  /// Saves the category on screen as where a ranking opened without a mode
  /// lands next time. Saved when the app leaves the screen or the page
  /// closes, not on every switch: a settings write rebuilds the app root.
  /// A lost write only loses that landing: logged, not shown.
  void _remember() {
    final mode = _selected;
    if (_container.read(_catalog.lastViewedProvider) == mode) return;
    unawaited(
      _catalog
          .saveLastViewed(_container.read(settingsProvider.notifier), mode)
          .catchError((Object error, _) {
            log('ranking category not remembered: $error');
          }),
    );
  }

  ScrollController _scrollControllerFor(M mode) {
    return _scrollControllers.putIfAbsent(
      mode,
      () => ScrollController(
        onAttach: (_) {
          // A first-visited tab's list mounts after the tab-change
          // announce has already fired — re-announce so the app bar's
          // scrolled-under state still lands on the tab on screen.
          if (mode == _selected) {
            announceTabScroll(_notificationContext, _scrollControllers[mode]!);
          }
        },
      ),
    );
  }

  /// Every drag start lands here; only a first visit to a neighbour needs
  /// a rebuild.
  void _prepareAdjacent(int index) {
    final last = _modes.length - 1;
    final neighbours = {
      _modes[(index - 1).clamp(0, last)],
      _modes[(index + 1).clamp(0, last)],
    };
    if (_loadedModes.containsAll(neighbours)) return;
    setState(() => _loadedModes.addAll(neighbours));
  }

  /// Branch-level re-tap (bottom bar same-destination tap): the channel
  /// fired after the branch stack popped, so the scroll lands post-frame
  /// on the now-visible root — a vetoed pop leaves a pushed route on top
  /// and `isCurrent` fails the scroll harmlessly. A pushed ranking page is
  /// not a branch root and ignores it.
  void _onBranchReTap() {
    if (_reTapChannel?.branch !=
        BranchRootScope.maybeOf(context)?.branchIndex) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      reTapScrollToTop(context, _scrollControllerFor(_selected));
    });
  }

  void _openSheet({bool editing = false}) {
    unawaited(
      showRankingCategorySheet(
        context,
        catalog: _catalog,
        editing: editing,
        page: RankingSheetPage(
          tabs: () => (modes: _modes, selected: _selected),
          onSelect: _jumpTo,
          switchLabel: widget.switchLabel,
          switchIcon: widget.switchIcon,
          onSwitch: () => widget.onSwitch(context),
          dateLabel: rankingDateText(context, _date),
          onPickDate: () => unawaited(
            pickRankingDate(context, date: _date, onPicked: _changeDate),
          ),
        ),
      ),
    );
  }

  /// A pick from the sheet, not a tab tap: the strip animates here.
  void _jumpTo(M mode) {
    final index = _modes.indexOf(mode);
    if (index >= 0) _tabController.animateTo(index);
  }

  Future<void> _saveArrangement(Arrangement<M> next) => persistSettings(
    context,
    () => _catalog.saveArrangement(ref.read(settingsProvider.notifier), next),
  );

  void _onTabAction(M mode, _TabAction action, Arrangement<M> arrangement) {
    switch (action) {
      case _TabAction.moveToFront:
        unawaited(_saveArrangement(arrangement.moveToFront(mode)));
      case _TabAction.hide when mode == _routeExtra:
        _routeExtra = null;
        _refreshModes();
      case _TabAction.hide:
        unawaited(_saveArrangement(arrangement.hide(mode)));
      case _TabAction.edit:
        _openSheet(editing: true);
    }
  }

  Widget _tabMenu(Arrangement<M> arrangement, int index, Widget label) {
    final l10n = context.l10n;
    final mode = _modes[index];
    final canHide =
        _modes.length > 1 && (mode == _routeExtra || arrangement.canHide);
    return AppMenuButton<_TabAction>(
      edge: AppMenuEdge.start,
      entries: [
        AppMenuEntry(
          value: _TabAction.moveToFront,
          label: l10n.rankingMoveToFront,
          icon: Icons.first_page,
          enabled: index > 0,
        ),
        AppMenuEntry(
          value: _TabAction.hide,
          label: l10n.rankingHideCategory,
          icon: Icons.visibility_off_outlined,
          enabled: canHide,
        ),
        AppMenuEntry(
          value: _TabAction.edit,
          label: l10n.rankingEditCategories,
          icon: Icons.edit_outlined,
        ),
      ],
      onSelected: (_, action) => _onTabAction(mode, action, arrangement),
      anchorBuilder: (context, toggle) => GestureDetector(
        onLongPress: () {
          AppHaptics.longPress();
          toggle();
        },
        onSecondaryTap: toggle,
        child: label,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The tab menu offers what the arrangement allows now.
    final arrangement = ref.watch(_catalog.arrangementProvider);
    return Scaffold(
      // Root pages own no inline composer: leaving the default `true`
      // would subscribe this whole subtree to per-frame viewInsets churn
      // every time the IME animates (e.g. the push that hides the search
      // keyboard) — a relayout storm across all five live branches.
      resizeToAvoidBottomInset: false,
      appBar: AppTopBar(
        titleSpacing: 0,
        actions: [
          IconButton(
            tooltip: context.l10n.rankingAllCategories,
            onPressed: _openSheet,
            icon: const Icon(Icons.grid_view_outlined),
          ),
        ],
        title: AppTabBar(
          controller: _tabController,
          onTap: (index) {
            // TabBar already ran controller.animateTo before this
            // callback — and TabController._changeIndex early-returns on
            // a same-index tap, so indexIsChanging is still false only
            // for a re-tap. That is the in-page re-tap contract: scroll
            // the current mode's feed to top, nothing else.
            if (!_tabController.indexIsChanging) {
              reTapScrollToTop(context, _scrollControllerFor(_modes[index]));
            }
          },
          labels: [
            for (final mode in _modes) l10nLookup(context.l10n, mode.labelKey),
          ],
          labelWrapper: (index, label) => _tabMenu(arrangement, index, label),
        ),
      ),
      body: Builder(
        builder: (context) {
          _notificationContext = context;
          final tabs = TabSwipeSwitcher(
            tabController: _tabController,
            // Warm the neighbor slots before a drag uncovers them — the
            // strip slide shows real feeds instead of blank placeholders.
            onPrepareAdjacent: _prepareAdjacent,
            child: TabSlideStack(
              controller: _tabController,
              children: [
                for (final mode in _modes)
                  if (_loadedModes.contains(mode))
                    _bodies.putIfAbsent(
                      mode,
                      () => KeyedSubtree(
                        key: ValueKey((mode, _date)),
                        child: widget.bodyBuilder(
                          mode,
                          _date,
                          _scrollControllerFor(mode),
                        ),
                      ),
                    )
                  else
                    const SizedBox.shrink(),
              ],
            ),
          );
          // Always a Column, so the bar coming and going keeps the tab
          // strip's element.
          return Column(
            children: [
              if (_date case final date?)
                RankingDateBar(
                  date: date,
                  onBackToLatest: () => _changeDate(null),
                ),
              Expanded(child: tabs),
            ],
          );
        },
      ),
    );
  }
}

/// pixiv web's viewing settings, where an account turns R-18G on.
final _viewingSettings = Uri.https(
  PixivClientIdentity.webHost,
  '/settings/viewing',
);

/// The empty state of a category. An R-18G ranking comes back empty, not
/// failed, while the account has R-18G off on pixiv web: say so and link
/// the setting.
Widget rankingEmpty(
  BuildContext context,
  RankingCategory mode,
  Future<void> Function() onRefresh,
) {
  final l10n = context.l10n;
  if (mode.rating != RankingRating.r18g) {
    return FeedEmpty(
      title: l10n.rankingEmpty,
      retryLabel: l10n.refresh,
      onRefresh: onRefresh,
    );
  }
  return FeedEmpty(
    icon: Icons.visibility_off_outlined,
    title: l10n.rankingR18gHint,
    retryLabel: l10n.refresh,
    onRefresh: onRefresh,
    actionLabel: l10n.rankingR18gOpenSettings,
    actionIcon: Icons.open_in_new,
    // Fire-and-forget like the other outbound links: the browser owns the
    // failure surface.
    onAction: () => unawaited(
      launchUrl(_viewingSettings, mode: LaunchMode.externalApplication),
    ),
  );
}

/// The load failure title, naming the category.
String rankingLoadFailedTitle(BuildContext context, RankingCategory mode) =>
    context.l10n.rankingLoadFailed(l10nLookup(context.l10n, mode.labelKey));
