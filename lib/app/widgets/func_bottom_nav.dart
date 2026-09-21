import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/navigation/route_observer.dart';
import '../../l10n/context.dart';
import '../motion/motion_tokens.dart';
import '../icons/app_icons.dart';
import '../navigation/home_shell_metrics.dart';

/// Primary bottom navigation for narrow layouts.
///
/// Tap feedback and the selection indicator replicate the app bar's `TabBar`
/// exactly: `InkWell` + `overlayColor` (primary 10% pressed, onSurface 8%
/// hovered) with the theme's `InkSparkle`/`InkRipple` splash — which takes
/// its colour from the pressed overlay resolve, like a real `InkResponse`
/// splash — and a 3dp underline whose left/right edges are eased
/// asymmetrically (M3 `TabIndicatorAnimation.elastic`) so the line
/// stretches toward the destination before contracting.
class FuncBottomNav extends StatefulWidget {
  const FuncBottomNav({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    this.visible = true,
    this.replayLandingInk = true,
    this.indicatorAnimation,
  });

  final List<FuncBottomNavDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  /// Continuous strip position for the indicator to track — the branch
  /// pager's `tab.animation`. The shell-level bar passes it so the
  /// underline slides with the finger through a drag exactly like the
  /// TabBar's indicator follows `controller.animation` (Shaft's
  /// BottomNavigationView tracks `onPageScrolled` the same way). Null
  /// keeps the discrete elastic replay used by per-branch bars.
  final Animation<double>? indicatorAnimation;

  /// False while this bar belongs to an IndexedStack branch that is not the
  /// current one — the branch swap rebuilds every branch's bar, but only the
  /// visible one may spend ink on the landing splash.
  final bool visible;

  /// Whether a selection change replays the tapped item's landing ink. The
  /// replay exists for per-branch bars, whose InkWell is discarded by the
  /// branch swap; a shell-level bar survives the switch, so its real ink
  /// is still playing and a replay would double-draw.
  final bool replayLandingInk;

  static const double _height = 64;
  static const double _indicatorHeight = 3;

  @override
  State<FuncBottomNav> createState() => _FuncBottomNavState();
}

class _FuncBottomNavState extends State<FuncBottomNav>
    with SingleTickerProviderStateMixin {
  late final AnimationController _indicatorController;
  late int _indicatorFrom;

  /// The last selected index shared across bar instances. Each branch-root
  /// page mounts its own bar, so the indicator's "from" index would
  /// otherwise always equal the destination on first build — no elastic
  /// stretch would ever play. Seeding from the static keeps the animation
  /// continuous across the instantaneous branch swap.
  static int? _lastSelectedIndex;

  /// One key per destination so the landing ink can locate the tapped
  /// item's render box after the branch swap.
  late final List<GlobalKey> _itemKeys;

  /// A branch switch discards the tapped item's InkWell along with the old
  /// branch page: its real ink keeps playing in a subtree that is no
  /// longer painted, so the user sees nothing. Re-issuing the same two
  /// features a real press paints — the pressed [InkHighlight] block and
  /// the theme splash — on the destination item restores the landing half
  /// of the tap, identical to what the top TabBar shows (the top bar is
  /// one instance across switches, so it never loses its own ink).
  InteractiveInkFeature? _landingInk;
  InkHighlight? _landingHighlight;
  Timer? _landingInkTimer;

  @override
  void initState() {
    super.initState();
    _itemKeys = [
      for (var i = 0; i < widget.destinations.length; i++) GlobalKey(),
    ];
    // Seeded by the tap that triggered this branch switch — recorded at
    // press time so the ordering cannot race against rebuilds.
    _indicatorFrom = _lastSelectedIndex ?? widget.selectedIndex;
    // Matches the TabBar's kTabScrollDuration sweep above.
    _indicatorController = AnimationController(
      vsync: this,
      duration: MotionTokens.navIndicator,
      value: 1.0,
    );
    if (_indicatorFrom != widget.selectedIndex &&
        widget.indicatorAnimation == null) {
      // This bar mounted because the user switched branches: play the
      // elastic indicator + the landing half of the tap's ink. A tracked
      // indicator needs neither — it paints straight from the strip
      // position.
      _indicatorController.value = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (MotionTokens.enabled(context)) {
          _indicatorController.forward();
          if (widget.replayLandingInk) _spawnLandingInk();
        } else {
          _indicatorController.value = 1;
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant FuncBottomNav oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.destinations.length != widget.destinations.length) {
      // The replay timer and features capture the old item keys' render
      // boxes — release them before the keys are replaced.
      _releaseLandingInk();
      _itemKeys
        ..clear()
        ..addAll([
          for (var i = 0; i < widget.destinations.length; i++) GlobalKey(),
        ]);
    }
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      _indicatorFrom = oldWidget.selectedIndex;
      if (widget.indicatorAnimation == null &&
          MotionTokens.enabled(context)) {
        _indicatorController.forward(from: 0);
        if (widget.replayLandingInk) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _spawnLandingInk();
          });
        }
      } else {
        _indicatorController.value = 1;
      }
    }
  }

  /// Paints the same two ink features a real `InkResponse` press produces
  /// on the destination item: the flat pressed `InkHighlight` plus the
  /// theme's splash (InkSparkle on Android). Both take their colour from
  /// `overlayColor` resolved with `pressed` — primary 10% — exactly as
  /// `InkResponse` colours its own splash, so the replay reads identically
  /// to the pink press the top bar shows. The timing mirrors a real tap:
  /// ~130ms held, then the splash confirms and the highlight fades.
  void _spawnLandingInk() {
    if (!widget.visible) return;
    final index = widget.selectedIndex;
    if (index < 0 || index >= _itemKeys.length) return;
    final itemContext = _itemKeys[index].currentContext;
    if (itemContext == null) return;
    final box = itemContext.findRenderObject() as RenderBox?;
    final material = Material.maybeOf(itemContext);
    if (box == null || !box.attached || !box.hasSize || material == null) {
      return;
    }
    final theme = Theme.of(itemContext);
    final pressedColor =
        _resolveDestinationOverlay(theme.colorScheme, const {
          WidgetState.selected,
          WidgetState.pressed,
        }) ??
        theme.splashColor;
    // Ink features self-register with the controller in their constructor —
    // calling addInkFeature again would double-add the same feature. A
    // confirmed feature removes and disposes itself, so the reference must
    // be cleared via onRemoved rather than re-disposed.
    _releaseLandingInk();
    Rect rectCallback() => Offset.zero & box.size;
    final textDirection = Directionality.of(itemContext);
    InteractiveInkFeature? splash;
    splash = theme.splashFactory.create(
      controller: material,
      referenceBox: box,
      position: box.size.center(Offset.zero),
      color: pressedColor,
      textDirection: textDirection,
      containedInkWell: true,
      rectCallback: rectCallback,
      onRemoved: () {
        if (identical(_landingInk, splash)) _landingInk = null;
      },
    );
    InkHighlight? highlight;
    highlight = InkHighlight(
      controller: material,
      referenceBox: box,
      color: pressedColor,
      shape: BoxShape.rectangle,
      rectCallback: rectCallback,
      onRemoved: () {
        if (identical(_landingHighlight, highlight)) _landingHighlight = null;
      },
      textDirection: textDirection,
      // InkResponse's pressed-highlight fade duration.
      fadeDuration: MotionTokens.inkFade,
    );
    _landingInk = splash;
    _landingHighlight = highlight;
    _landingInkTimer = Timer(MotionTokens.inkHold, () {
      splash?.confirm();
      highlight?.deactivate();
    });
  }

  void _releaseLandingInk() {
    _landingInkTimer?.cancel();
    _landingInkTimer = null;
    _landingInk?.dispose();
    _landingHighlight?.dispose();
  }

  @override
  void deactivate() {
    // The ink feature's tickers are vsync'd on this bar's own Material — a
    // descendant that unmounts before this state. InkWell handles the same
    // teardown in deactivate(): kill the feature here so the inner
    // Material's ticker accounting is already clean by the time it unmounts.
    _releaseLandingInk();
    super.deactivate();
  }

  @override
  void dispose() {
    _releaseLandingInk();
    _indicatorController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The labels are localized. A locale switch rebuilds this stateful bar,
    // so widths measured under the previous language must not drive the new
    // indicator geometry.
    _labelWidths.clear();
  }

  // TabBar elastic edges: the trailing edge accelerates in (ease-in sine)
  // while the leading edge decelerates out (ease-out sine), stretching the
  // line in the direction of travel.
  static double _accelerate(double t) => 1.0 - math.cos(t * math.pi / 2);
  static double _decelerate(double t) => math.sin(t * math.pi / 2);

  Rect _indicatorRect(double itemWidth, int index, double labelWidth) {
    final center = itemWidth * index + itemWidth / 2;
    return Rect.fromCenter(
      center: Offset(center, 0),
      width: labelWidth,
      height: FuncBottomNav._indicatorHeight,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLowest,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: FuncBottomNav._height,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final itemWidth =
                  constraints.maxWidth / widget.destinations.length;
              // Uniform label scale: every destination shares one font
              // size, shrunk until the widest translation fits its slot —
              // no per-locale truncation or mixed sizes.
              final labelFontSize = 12 * _labelScale(context, itemWidth);
              return AnimatedBuilder(
                animation:
                    widget.indicatorAnimation ?? _indicatorController,
                builder: (context, _) {
                  final tracking = widget.indicatorAnimation;
                  late final double left;
                  late final double right;
                  late final int selected;
                  if (tracking != null) {
                    // Continuous strip position — the indicator is a pure
                    // lerp of the two slots it sits between, the same
                    // geometry TabBar paints from controller.animation.
                    final pos = tracking.value.clamp(
                      0.0,
                      widget.destinations.length - 1.0,
                    );
                    final lower = pos.floor();
                    final upper = math.min(
                      pos.ceil(),
                      widget.destinations.length - 1,
                    );
                    final frac = pos - lower;
                    final from = _indicatorRect(
                      itemWidth,
                      lower,
                      _labelWidth(
                        context,
                        lower,
                        itemWidth,
                        labelFontSize,
                      ),
                    );
                    final to = _indicatorRect(
                      itemWidth,
                      upper,
                      _labelWidth(
                        context,
                        upper,
                        itemWidth,
                        labelFontSize,
                      ),
                    );
                    left = from.left + (to.left - from.left) * frac;
                    right = from.right + (to.right - from.right) * frac;
                    // onPageSelected parity: the active item flips at the
                    // midpoint, matching the pager's warped tab.index.
                    selected = pos.round();
                  } else {
                    // The SDK TabController animates the tab value with
                    // Curves.ease (animateTo's default); _IndicatorPainter
                    // then feeds that eased progress into the
                    // accelerate/decelerate sine pair. Ease the raw
                    // controller value the same way — feeding it linearly
                    // shifts the stretch timing off the TabBar's rhythm.
                    final progress = Curves.ease.transform(
                      _indicatorController.value,
                    );
                    final from = _indicatorRect(
                      itemWidth,
                      _indicatorFrom,
                      _labelWidth(
                        context,
                        _indicatorFrom,
                        itemWidth,
                        labelFontSize,
                      ),
                    );
                    final to = _indicatorRect(
                      itemWidth,
                      widget.selectedIndex,
                      _labelWidth(
                        context,
                        widget.selectedIndex,
                        itemWidth,
                        labelFontSize,
                      ),
                    );
                    final movingRight =
                        widget.selectedIndex > _indicatorFrom;
                    final leftT = movingRight
                        ? _accelerate(progress)
                        : _decelerate(progress);
                    final rightT = movingRight
                        ? _decelerate(progress)
                        : _accelerate(progress);
                    left = from.left + (to.left - from.left) * leftT;
                    right = from.right + (to.right - from.right) * rightT;
                    selected = widget.selectedIndex;
                  }
                  return Stack(
                    children: [
                      Row(
                        children: [
                          for (var i = 0; i < widget.destinations.length; i++)
                            Expanded(
                              child: _FuncBottomNavItem(
                                key: _itemKeys[i],
                                destination: widget.destinations[i],
                                fontSize: labelFontSize,
                                selected: i == selected,
                                onTap: () {
                                  // Record the pre-switch index at press
                                  // time: the destination bar mounts in
                                  // the same frame and seeds its elastic
                                  // "from" position from it.
                                  _lastSelectedIndex = widget.selectedIndex;
                                  widget.onSelected(i);
                                },
                              ),
                            ),
                        ],
                      ),
                      Positioned(
                        left: left,
                        // indicatorPadding: EdgeInsets.only(bottom: 5) on
                        // the TabBar above.
                        bottom: 5,
                        width: math.max(0.0, right - left),
                        height: FuncBottomNav._indicatorHeight,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.primary,
                            // M3 primary+label indicator: top corners
                            // rounded by the indicator weight.
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(
                                FuncBottomNav._indicatorHeight,
                              ),
                              topRight: Radius.circular(
                                FuncBottomNav._indicatorHeight,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  // TabBar `indicatorSize: label` — the underline spans the label text, not
  // the whole destination. Measuring the label's intrinsic width keeps the
  // bottom indicator the same proportion as the top bar's.
  final Map<String, double> _labelWidths = {};

  double _measureLabel(BuildContext context, String label, double fontSize) {
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w500,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
      textDirection: Directionality.of(context),
      maxLines: 1,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    return painter.width;
  }

  /// One scale factor shared by every destination label, so all of them
  /// render at the same size in any locale. Never upscales past 1.
  double _labelScale(BuildContext context, double itemWidth) {
    var maxWidth = 0.0;
    for (final destination in widget.destinations) {
      final width = _measureLabel(context, destination.label, 12);
      if (width > maxWidth) maxWidth = width;
    }
    if (maxWidth <= 0) return 1;
    return (math.max(0.0, itemWidth - 12) / maxWidth).clamp(0.55, 1.0);
  }

  double _labelWidth(
    BuildContext context,
    int index,
    double itemWidth,
    double fontSize,
  ) {
    final label = widget.destinations[index].label;
    final measured = _labelWidths.putIfAbsent(
      label,
      () => _measureLabel(context, label, fontSize),
    );
    // Keep the indicator inside the item's hit target even if an extreme
    // translation still overflows after scaling.
    return measured.clamp(0.0, math.max(0.0, itemWidth - 12));
  }
}

class FuncBottomNavDestination {
  const FuncBottomNavDestination({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

/// Destination overlay mirroring `_TabsPrimaryDefaultsM3`: pressed always
/// resolves primary 10%; hover/focus split on selected like the TabBar's
/// tabs. Shared by the item's `InkWell.overlayColor` and the branch-swap
/// landing replay, which resolves `{selected, pressed}` for its ink.
Color? _resolveDestinationOverlay(ColorScheme colors, Set<WidgetState> states) {
  if (states.contains(WidgetState.selected)) {
    if (states.contains(WidgetState.pressed)) {
      return colors.primary.withValues(alpha: 0.1);
    }
    if (states.contains(WidgetState.hovered)) {
      return colors.primary.withValues(alpha: 0.08);
    }
    if (states.contains(WidgetState.focused)) {
      return colors.primary.withValues(alpha: 0.1);
    }
    return null;
  }
  if (states.contains(WidgetState.pressed)) {
    return colors.primary.withValues(alpha: 0.1);
  }
  if (states.contains(WidgetState.hovered)) {
    return colors.onSurface.withValues(alpha: 0.08);
  }
  if (states.contains(WidgetState.focused)) {
    return colors.onSurface.withValues(alpha: 0.1);
  }
  return null;
}

class _FuncBottomNavItem extends StatelessWidget {
  const _FuncBottomNavItem({
    super.key,
    required this.destination,
    required this.fontSize,
    required this.selected,
    required this.onTap,
  });

  final FuncBottomNavDestination destination;
  final double fontSize;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = selected ? colors.primary : colors.onSurfaceVariant;
    // Same ink as the TabBar above: the theme's InkSparkle splash (no
    // splashFactory override) coloured by the pressed overlay resolve, a
    // pink pressed InkHighlight, and overlay states mirroring
    // _TabsPrimaryDefaultsM3 — pressed/hover/focus resolve identically
    // for selected and unselected tabs. `selected` is a widget-side prop
    // InkResponse's controller doesn't know, so it is merged in here.
    final selectedStates = <WidgetState>{if (selected) WidgetState.selected};
    return InkWell(
      onTap: onTap,
      overlayColor: WidgetStateProperty.resolveWith(
        (states) => _resolveDestinationOverlay(
          colors,
          selectedStates.toSet()..addAll(states),
        ),
      ),
      highlightColor: Colors.transparent,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(destination.icon, size: 24, color: color),
          const SizedBox(height: 2),
          Text(
            destination.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

/// The single bottom bar at the home-shell layer — Shaft's
/// BottomNavigationView: a **sibling** of the branch ViewPager, floating
/// over the strip instead of riding inside a page. It never translates
/// with a branch slide; while the current branch's root route is covered
/// by a pushed route (reported by [BranchRootScaffold] into
/// [branchStackCoveredProvider]) it slides away — the same layering Shaft
/// gets by pushing a whole Activity over the home ViewPager.
///
/// It also publishes its measured geometry to [homeShellMetricsProvider]
/// so a Hero flight can clip the returning artwork against the real bar
/// edge.
class FuncShellBottomNav extends ConsumerStatefulWidget {
  const FuncShellBottomNav({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    required this.scrollVisibility,
    required this.indicatorAnimation,
  });

  /// Current branch index — the pager's warped `tab.index`, so the
  /// selected item flips exactly when a drag crosses the midpoint
  /// (ViewPager `onPageSelected` parity).
  final int selectedIndex;

  /// Slot-tap callback — the owning [BranchSlidePager] decides between a
  /// same-branch root reset and an animated slide.
  final ValueChanged<int> onSelected;

  /// 1 = fully shown, 0 = slid entirely below the screen edge. Owned by
  /// [BranchSlideStack], which drives it from scroll deltas bubbling out
  /// of the branch Navigators — the bar floats over the strip, so sliding
  /// never reflows the page underneath.
  final AnimationController scrollVisibility;

  /// The strip's continuous position (the pager's `tab.animation`) — the
  /// indicator tracks it, sliding with the finger like the TabBar's does.
  final Animation<double> indicatorAnimation;

  @override
  ConsumerState<FuncShellBottomNav> createState() =>
      _FuncShellBottomNavState();
}

class _FuncShellBottomNavState extends ConsumerState<FuncShellBottomNav>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  bool _measureScheduled = false;
  bool _published = false;
  void Function(double?, double?)? _publishMetrics;
  late final AnimationController _coveredVisibility;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.scrollVisibility.addListener(_scheduleMeasure);
    _coveredVisibility = AnimationController(
      vsync: this,
      duration: MotionTokens.navBarShow,
      reverseDuration: MotionTokens.navBarHide,
      value: ref
              .read(branchStackCoveredProvider)
              .contains(widget.selectedIndex)
          ? 0
          : 1,
    );
  }

  @override
  void didUpdateWidget(covariant FuncShellBottomNav oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollVisibility != widget.scrollVisibility) {
      oldWidget.scrollVisibility.removeListener(_scheduleMeasure);
      widget.scrollVisibility.addListener(_scheduleMeasure);
    }
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      // A hidden bar must return on a branch switch — Shaft's
      // BottomBarAutoHide.reveal() on ViewPager's onPageSelected.
      if (MotionTokens.enabled(context)) {
        widget.scrollVisibility.forward();
      } else {
        widget.scrollVisibility.value = 1;
      }
      _scheduleMeasure();
      _syncCovered(_isCovered);
    }
  }

  @override
  void dispose() {
    widget.scrollVisibility.removeListener(_scheduleMeasure);
    _coveredVisibility.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() => _scheduleMeasure();

  bool get _isCovered =>
      ref.read(branchStackCoveredProvider).contains(widget.selectedIndex);

  void _syncCovered(bool covered) {
    if (MotionTokens.enabled(context)) {
      if (covered) {
        _coveredVisibility.reverse();
      } else {
        _coveredVisibility.forward();
      }
    } else {
      _coveredVisibility.value = covered ? 0 : 1;
    }
  }

  void _scheduleMeasure() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) return;
      _published = true;
      try {
        _publishMetrics?.call(
          box.localToGlobal(Offset.zero).dy,
          box.size.height,
        );
      } on Object {
        // The provider container can already be gone (test teardown).
      }
    });
  }

  @override
  void deactivate() {
    // The branch stack keeps this widget mounted while a pushed route
    // covers it — only clear the metrics when this bar is actually going
    // away. publish() is deferred: provider writes are illegal inside the
    // deactivate lifecycle.
    if (_published) {
      _published = false;
      final metrics = _publishMetrics;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          metrics?.call(null, 0);
        } on Object {
          // The provider container can already be gone (test teardown).
        }
      });
    }
    super.deactivate();
  }

  @override
  Widget build(BuildContext context) {
    _publishMetrics = ref.read(homeShellMetricsProvider.notifier).publish;
    // Covered state is a provider — watch the slice this bar cares about
    // (is *my* branch covered) so a pushed route inside the branch
    // Navigator rebuilds us and the controller slides away in step.
    // `ref.watch` drives the rebuild declaratively — unlike `ref.listen`,
    // a change that lands between builds can never be dropped.
    final covered = ref.watch(
      branchStackCoveredProvider.select(
        (set) => set.contains(widget.selectedIndex),
      ),
    );
    _syncCovered(covered);
    final labels = [
      context.l10n.homeRecommended,
      context.l10n.homeRanking,
      context.l10n.newTitle,
      context.l10n.searchTitle,
      context.l10n.settingsTitle,
    ];
    // Shaft parity: the bar is an overlay that *slides* out of the screen —
    // the strip uses a full-height layout so nothing reflows under the
    // finger. Two stacked transitions: covered (pushed route) over scroll
    // (auto-hide), either one wins the hide.
    return SlideTransition(
      position: CurvedAnimation(
        parent: _coveredVisibility,
        curve: MotionTokens.navBarShowCurve,
        reverseCurve: MotionTokens.navBarHideCurve,
      ).drive(Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)),
      child: SlideTransition(
        position: CurvedAnimation(
          parent: widget.scrollVisibility,
          curve: MotionTokens.navBarShowCurve,
          reverseCurve: MotionTokens.navBarHideCurve,
        ).drive(Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)),
        child: FuncBottomNav(
          selectedIndex: widget.selectedIndex,
          onSelected: widget.onSelected,
          // One persistent instance — the real tap ink survives the branch
          // switch, so the landing replay would double-draw; the indicator
          // tracks the strip position directly instead of replaying.
          replayLandingInk: false,
          indicatorAnimation: widget.indicatorAnimation,
          destinations: [
            for (var i = 0; i < labels.length; i++)
              FuncBottomNavDestination(icon: _icons[i], label: labels[i]),
          ],
        ),
      ),
    );
  }

  static const _icons = [
    AppIcons.home,
    AppIcons.ranking,
    AppIcons.n,
    AppIcons.search,
    Icons.settings_outlined,
  ];
}

/// Trailing spacer for branch-root scrollables. The navigation bar floats
/// over the body ([Scaffold.extendBody]), so lists pad their tail by the
/// measured bar height — the same inset redistribution Shaft applies to its
/// overlay bar. Reports zero on rail layouts, where no bar exists.
class FuncNavBarSpacer extends ConsumerWidget {
  const FuncNavBarSpacer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final height = ref.watch(
      homeShellMetricsProvider.select((m) => m.bottomNavHeight),
    );
    return SizedBox(height: height ?? 0);
  }
}

/// Shell for a branch-root page: reports through RouteAware whether the
/// branch's root route is covered by a route pushed inside the branch
/// Navigator, so the shell-level [FuncShellBottomNav] slides away while it
/// is — replacing the physical cover a page-local bar used to get for
/// free.
///
/// `didPushNext`/`didPopNext` fire at push/pop start (RouteObserver
/// notifies synchronously), so the bar animates in step with the route
/// transition rather than after it.
class BranchRootScaffold extends ConsumerStatefulWidget {
  const BranchRootScaffold({
    super.key,
    required this.branchIndex,
    required this.child,
  });

  final int branchIndex;
  final Widget child;

  @override
  ConsumerState<BranchRootScaffold> createState() =>
      _BranchRootScaffoldState();
}

class _BranchRootScaffoldState extends ConsumerState<BranchRootScaffold>
    with RouteAware {
  RouteObserver<ModalRoute<dynamic>>? _observer;
  ModalRoute<dynamic>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final observer = RouteObserverScope.maybeOf(context);
    final route = ModalRoute.of(context);
    if (identical(observer, _observer) && identical(route, _route)) return;
    _unsubscribe();
    _observer = observer;
    _route = route;
    if (observer != null && route != null) {
      observer.subscribe(this, route);
    }
  }

  void _unsubscribe() {
    final observer = _observer;
    final route = _route;
    if (observer != null && route != null) observer.unsubscribe(this);
  }

  @override
  void didPushNext() => _recheckCovered();

  @override
  void didPopNext() => _recheckCovered();

  /// Navigator._updatePages replays synthetic push observations when a
  /// branch rebuild hands the Navigator new pages — didPushNext/didPopNext
  /// fire with no real stack change behind them. Verify a frame later,
  /// once the stack has settled: covered simply means the root route is
  /// no longer the branch Navigator's current route.
  void _recheckCovered() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _setCovered(!(_route?.isCurrent ?? true));
    });
  }

  void _setCovered(bool covered) {
    try {
      ref
          .read(branchStackCoveredProvider.notifier)
          .setCovered(widget.branchIndex, covered);
    } on Object {
      // The provider container can already be gone (test teardown).
    }
  }

  @override
  void dispose() {
    _setCovered(false);
    _unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
