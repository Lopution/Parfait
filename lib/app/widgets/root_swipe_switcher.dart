import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';

import '../motion/motion_tokens.dart';
import 'branch_slide_stack.dart';

/// Sideways drag on a branch-root page: the page's own top tabs follow the
/// finger first; at the tab strip's edge a committed same-direction drag
/// carries over to the next bottom-nav branch — the inner→outer ViewPager
/// chaining Shaft gets for free from nested pagers.
///
/// The drag is live: `TabController.offset` keeps `controller.animation`
/// tracking the finger, so [TabSlideStack] slides the tab bodies under the
/// touch and the TabBar indicator follows with no extra plumbing. Vertical
/// gestures never reach the horizontal recognizer, and deeper horizontal
/// scrollables (rails, carousels) claim their own swipes first.
class RootSwipeSwitcher extends StatefulWidget {
  const RootSwipeSwitcher({
    super.key,
    this.tabController,
    this.onPrepareAdjacent,
    required this.child,
  });

  /// The page's top tab strip, when it has one. Pages without tabs fall
  /// straight through to the branch step.
  final TabController? tabController;

  /// Called once on drag start with the strip's current position — pages
  /// lazily create tab bodies, so the neighbors about to slide into view
  /// need their first build scheduled before the finger moves.
  final ValueChanged<int>? onPrepareAdjacent;

  final Widget child;

  /// ViewPager's MIN_FLING_VELOCITY — a committed flick, not finger drift.
  static const minFlingVelocity = 400.0;

  /// A slow but deliberate sideways drag still switches past a quarter of
  /// the screen. ViewPager commits past half a page; a discrete switch
  /// reads better with a lower bar.
  static const distanceFraction = 0.25;

  @override
  State<RootSwipeSwitcher> createState() => _RootSwipeSwitcherState();
}

/// Which layer owns the in-flight horizontal gesture. A nested ViewPager
/// intercepts once and holds the touch until release — the same lock here:
/// once the branch pager takes over, a reverse drag reels *it* back
/// instead of leaking deltas back into the tab strip (which is what used
/// to freeze the half-slid outer page).
enum _DragOwner { undecided, tabs, branch }

class _RootSwipeSwitcherState extends State<RootSwipeSwitcher>
    with SingleTickerProviderStateMixin {
  /// Cumulative raw drag distance in px — the tab-strip commit check reads
  /// total finger travel, not just the strip's net displacement.
  double _rawDx = 0;

  /// Continuous tab position when the drag started — the finger can grab
  /// the strip mid-settle, so this is not necessarily an integer.
  double _dragOrigin = 0;

  /// Gesture owner for the current touch — decided by the first delta that
  /// can actually move a layer, then locked until release/cancel.
  _DragOwner _owner = _DragOwner.undecided;

  /// True between `onStart` and `onEnd`/`onCancel` — this engine's
  /// `_checkCancel` invokes `onCancel` unconditionally when the recognizer
  /// loses the arena (e.g. every vertical scroll on the page), so a bare
  /// "cancel" does not imply this recognizer ever owned the touch.
  bool _active = false;

  /// The reel-in after a release without a commit (or a commit that a
  /// mid-drag warp already landed on): `TabController.animateTo` early-
  /// returns when the target index is already current, so these frames
  /// walk `animation.value` back by hand through `offset`.
  AnimationController? _settle;
  Animation<double>? _settleAnim;
  int _settleTarget = 0;

  TabController? get _tc => widget.tabController;

  BranchSlidePager? get _branch => BranchSlideStack.maybeOf(context);

  bool get _ltr => Directionality.of(context) == TextDirection.ltr;

  @override
  void dispose() {
    _settle?.dispose();
    super.dispose();
  }

  void _onDragStart(DragStartDetails details) {
    _active = true;
    _rawDx = 0;
    _owner = _DragOwner.undecided;
    // A grab mid-settle takes over — otherwise the settle's offset ticks
    // would fight the finger's for `animation.value`.
    _settle?.stop();
    _branch?.beginDrag();
    final tc = _tc;
    if (tc == null) {
      _dragOrigin = 0;
      return;
    }
    // A grab during animateTo inherits the in-flight position: pin the
    // index so `offset` (which asserts !indexIsChanging) stays writable.
    if (tc.indexIsChanging) {
      tc.index = tc.animation!.value.round().clamp(0, tc.length - 1);
    }
    _dragOrigin = tc.animation?.value ?? tc.index.toDouble();
    widget.onPrepareAdjacent?.call(_dragOrigin.round());
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _rawDx += details.delta.dx;
    final width = MediaQuery.sizeOf(context).width;
    if (width <= 0) return;
    final pageDelta = (_ltr ? -details.delta.dx : details.delta.dx) / width;
    final tc = _tc;

    if (_owner == _DragOwner.undecided) {
      // The first delta decides the owner: a page without a strip hands
      // straight out; a strip with room to move takes it; a strip already
      // at its edge hands the whole gesture to the outer pager.
      if (tc == null || tc.length < 2) {
        _owner = _DragOwner.branch;
      } else {
        final probe = (tc.animation?.value ?? tc.index.toDouble()) + pageDelta;
        _owner = (probe < 0 || probe > tc.length - 1)
            ? _DragOwner.branch
            : _DragOwner.tabs;
      }
    }

    if (_owner == _DragOwner.branch) {
      _branch?.dragBy(pageDelta);
      return;
    }

    final target = (tc!.animation?.value ?? tc.index.toDouble()) + pageDelta;
    final max = tc.length - 1.0;
    if (target < 0 || target > max) {
      // The strip just ran out of track: pin it on the edge, hand the
      // gesture to the outer pager — and lock the owner, so the rest of
      // this touch slides branches even if the finger turns back.
      _owner = _DragOwner.branch;
      final clamped = target.clamp(0.0, max);
      _writeTab(clamped);
      _branch?.dragBy(target - clamped);
      return;
    }
    _writeTab(target);
  }

  /// Finger-following write shared by the live drag and the mid-drag
  /// hand-off: hop `index` whenever the strip passes a midpoint (the
  /// TabBarView warp) so `offset` stays inside its [-1, 1] contract and
  /// lazy neighbours load in step with the finger.
  void _writeTab(double target) {
    final tc = _tc!;
    if ((target - tc.index).abs() > 0.5) {
      tc.index = target.round().clamp(0, tc.length - 1);
    }
    tc.offset = (target - tc.index).clamp(-1.0, 1.0);
  }

  void _onDragEnd(DragEndDetails details) {
    if (!_active) return;
    _active = false;
    final width = MediaQuery.sizeOf(context).width;
    final vPx = details.primaryVelocity ?? 0;
    final fling = vPx.abs() >= RootSwipeSwitcher.minFlingVelocity;
    // Leftward/upstream motion advances in LTR — velocity wins over raw
    // distance when the finger flicks back across its own drag.
    final forward = ((fling ? vPx : _rawDx) < 0) == _ltr;
    final vPages = (_ltr ? -vPx : vPx) / (width > 0 ? width : 1);

    _settle?.stop();
    if (_owner == _DragOwner.branch) {
      // The outer pager owned this gesture: the strip is already pinned
      // on its edge (reel it onto a clean integer) and the release
      // decision belongs to the branch layer alone.
      _settleTabEdge();
      _releaseBranch(vPages, forward);
      return;
    }

    final tc = _tc;
    if (tc == null || tc.length < 2) {
      // No strip and no branch ownership — still consume the branch
      // drag that beginDrag opened, so it cannot leak into the next
      // gesture's judgement.
      _branch?.endDrag(0);
      return;
    }

    final pos = tc.animation?.value ?? tc.index.toDouble();
    final base = _dragOrigin.round().clamp(0, tc.length - 1);
    final moved = pos - base;
    final committed =
        fling ||
        _rawDx.abs() >= width * RootSwipeSwitcher.distanceFraction ||
        moved.abs() >= RootSwipeSwitcher.distanceFraction;
    // A flick's direction wins over net displacement — ViewPager commits
    // on release velocity the same way.
    final direction = fling ? forward : (moved > 0);

    // _dragging on the branch pager is consumed exactly once per gesture:
    // a release that stays on the strip ends it silently, while a release
    // past the strip's edge hands it the real velocity — the edge fling
    // must reach endDrag while _dragging is still live.
    if (!committed) {
      _settleTo(base);
      _branch?.endDrag(0);
      return;
    }
    if (direction) {
      if (base >= tc.length - 1) {
        _settleTo(base);
        _releaseBranch(vPages, true);
        return;
      }
      _landOn(base + 1);
      _branch?.endDrag(0);
      return;
    }
    if (base <= 0) {
      _settleTo(base);
      _releaseBranch(vPages, false);
      return;
    }
    _landOn(base - 1);
    _branch?.endDrag(0);
  }

  /// After a branch-owned gesture the strip sits on its edge integer —
  /// clear any residual offset/warp so the strip is parked, not half-lit.
  void _settleTabEdge() {
    final tc = _tc;
    if (tc == null || tc.length < 2) return;
    _settleTo(tc.index);
  }

  /// Committed move to an adjacent tab. When the mid-drag warp already
  /// hopped `index` onto the target, `animateTo` would no-op — reel the
  /// value in by hand instead.
  void _landOn(int target) {
    final tc = _tc!;
    if (target == tc.index) {
      _settleTo(target);
      return;
    }
    tc.animateTo(
      target,
      duration: MotionTokens.enabled(context) ? null : Duration.zero,
    );
  }

  void _settleTo(int target) {
    final tc = _tc!;
    _settleTarget = target;
    final from = tc.animation?.value ?? tc.index.toDouble();
    if (!MotionTokens.enabled(context) || (from - target).abs() < 1e-4) {
      tc.index = target;
      tc.offset = 0;
      return;
    }
    final controller = _settle ??= AnimationController(vsync: this)
      ..addListener(_applySettle)
      ..addStatusListener(_finishSettle);
    controller.duration = MotionTokens.fast;
    _settleAnim = Tween<double>(begin: from, end: target.toDouble()).animate(
      CurvedAnimation(parent: controller, curve: MotionTokens.fastCurve),
    );
    controller.forward(from: 0);
  }

  /// `offset` writes `animation.value` outright, so each settle tick moves
  /// the strip and the indicator together.
  void _applySettle() {
    final tc = _tc;
    final anim = _settleAnim;
    if (tc == null || anim == null || tc.indexIsChanging) return;
    tc.offset = (anim.value - tc.index).clamp(-1.0, 1.0);
  }

  void _finishSettle(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    final tc = _tc;
    // A tap mid-settle starts a fresh animateTo — it owns the strip now;
    // pinning here would yank the index back under the new flight.
    if (tc == null || !mounted || tc.indexIsChanging) return;
    // Pin the index last: for a same-index reel-in this is a no-op, for a
    // warp-back it snaps `animation.value` onto the target the strip
    // already shows — either way `offset` lands on zero.
    tc.index = _settleTarget;
    tc.offset = 0;
  }

  void _onDragCancel() {
    // Not every cancel is ours: a rejected recognizer still gets the
    // callback, so only gestures this recognizer actually started unwind
    // here — otherwise a vertical scroll would reel/settle (or even
    // commit, via a stale drag origin) layers it never touched.
    if (!_active) return;
    _active = false;
    _settle?.stop();
    final owner = _owner;
    _owner = _DragOwner.undecided;
    _branch?.endDrag(0);
    if (owner == _DragOwner.branch) {
      // The strip was pinned on its edge during the hand-off — park it on
      // a clean integer like the release path does.
      _settleTabEdge();
      return;
    }
    final tc = _tc;
    if (tc == null) return;
    _settleTo(tc.index);
  }

  /// The drag ran off the tab strip's edge (or the page has no strip at
  /// all): hand release to the branch pager, which commits or reels back
  /// on its own thresholds. Without a [BranchSlideStack] ancestor — a
  /// standalone mount outside the shell — fall back to the old instant
  /// goBranch step so the gesture never dead-ends.
  void _releaseBranch(double vPages, bool forward) {
    final pager = _branch;
    if (pager != null) {
      final width = MediaQuery.sizeOf(context).width;
      pager.endDrag(
        vPages,
        flingPages:
            RootSwipeSwitcher.minFlingVelocity / (width > 0 ? width : 1),
      );
      return;
    }
    _stepBranch(forward);
  }

  void _stepBranch(bool forward) {
    final shell = StatefulNavigationShell.maybeOf(context);
    if (shell == null) return;
    final next = shell.currentIndex + (forward ? 1 : -1);
    if (next < 0 || next >= shell.route.branches.length) return;
    shell.goBranch(next);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: _onDragStart,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      onHorizontalDragCancel: _onDragCancel,
      child: widget.child,
    );
  }
}

/// Tab bodies arranged side by side and slid by the strip's live position —
/// the content half of the ViewPager pairing [RootSwipeSwitcher] provides.
///
/// Every child stays mounted so per-tab scroll offsets and feed state
/// survive a switch (the Offstage stack this replaces kept the same
/// contract); only slots inside the one-page slide window lay out.
class TabSlideStack extends StatelessWidget {
  const TabSlideStack({
    super.key,
    required this.controller,
    required this.children,
  });

  /// The same controller the page's TabBar and [RootSwipeSwitcher] share —
  /// its `animation` carries finger drags, taps and `animateTo` alike.
  final TabController controller;

  /// One child per tab index, in strip order. Slots not yet visited can be
  /// a placeholder; the page's `onPrepareAdjacent` hook loads them before
  /// a drag brings them into view.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final animation = controller.animation;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    Widget stack(double pos) => Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.hardEdge,
      children: [
        for (var i = 0; i < children.length; i++)
          Offstage(
            offstage: (i - pos).abs() > 1.0,
            child: FractionalTranslation(
              translation: Offset(rtl ? pos - i : i - pos, 0),
              child: children[i],
            ),
          ),
      ],
    );
    if (animation == null) {
      return stack(controller.index.toDouble());
    }
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) => stack(animation.value),
    );
  }
}
