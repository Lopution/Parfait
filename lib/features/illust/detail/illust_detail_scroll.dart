import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:material_ui/material_ui.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../app/layout/app_breakpoints.dart';
import '../../../app/motion/motion_tokens.dart';
import '../../../app/navigation/home_shell_metrics.dart';
import '../../../core/entity/illust_entity.dart';
import 'widgets/page_image.dart';

/// A short first illustration on a narrow screen, alone or opening a set,
/// sits where centering it in this share of the viewport puts it: a very
/// wide image at the top was hard to see and to tap. Its slot ends with the
/// image, so the title follows right under it. Manga reads page after
/// page, so its first page keeps its natural height.
const _shortFirstImageSlotFactor = 0.7;

/// Where the first image sits in the detail scroll. The narrow layout
/// starts the artwork below the status bar, which the top bar keeps opaque;
/// it may run under the see-through toolbar, so overlays on it start below
/// the toolbar, and the bar draws in as it leaves.
class IllustFirstImageLayout {
  IllustFirstImageLayout._({
    required this.useTwoPane,
    required this.statusInset,
    required this.topChrome,
    required this.collapsible,
    required this.shownPages,
    required this.natural,
    required this.slots,
    required this.alone,
  });

  factory IllustFirstImageLayout.of(
    BuildContext context,
    IllustEntity entity, {
    required bool expanded,
    bool embeddedInspector = false,
  }) {
    final viewport = HomeShellChrome.contentSizeOf(context);
    final useTwoPane =
        !embeddedInspector &&
        AppBreakpoints.useTwoPaneDetailOf(context, viewport);
    // An illustration set opens on its first image; manga reads in full.
    final collapsible =
        entity.type == IllustType.illust && entity.pageCount > 1;
    final aspectRatio = entity.pageAspectRatioAt(0);
    final panoramaHeight = DetailPageImage.panoramaHeight(
      viewport,
      viewport.width,
      aspectRatio,
    );
    final natural = panoramaHeight ?? viewport.width / aspectRatio;
    // A panorama already has its own viewport; the reading slot is for an
    // ordinary short illustration on a phone held upright. On wider
    // single-column screens or inside the desktop inspector pane it only
    // opens a gap above the image.
    final slots =
        !embeddedInspector &&
        !useTwoPane &&
        viewport.width < AppBreakpoints.medium &&
        entity.type == IllustType.illust &&
        !entity.isUgoira &&
        panoramaHeight == null;
    final rawBand = slots
        ? math.max(
                0.0,
                viewport.height * _shortFirstImageSlotFactor - natural,
              ) /
              2
        : 0.0;
    // Keep the reading-slot wrapper (`slots`) unchanged so expanding a
    // multi-page set never remounts page 1, but collapse sub-toolbar bands:
    // a band smaller than `kToolbarHeight` leaves the top edge inside the
    // top chrome and horizontally bisects the back/more icons.
    final band = rawBand >= kToolbarHeight ? rawBand : 0.0;
    return IllustFirstImageLayout._(
      useTwoPane: useTwoPane,
      statusInset: embeddedInspector || useTwoPane
          ? 0
          : MediaQuery.paddingOf(context).top,
      topChrome: embeddedInspector
          ? 0
          : MediaQuery.paddingOf(context).top + kToolbarHeight,
      collapsible: collapsible,
      shownPages: collapsible && !expanded ? 1 : entity.pageCount,
      natural: natural,
      slots: slots,
      alone: band + natural,
    );
  }

  final bool useTwoPane;
  final double statusInset;
  final double topChrome;
  final bool collapsible;
  final int shownPages;
  final double natural;
  final bool slots;
  final double alone;

  double get extent => shownPages == 1 ? alone : natural;

  double get top => statusInset + extent - natural;

  bool get artworkUnderBar => top < topChrome;

  double get artworkUnderBarExtent => math.max(0.0, topChrome - top);

  double get immersionStart => math.max(
    0,
    (artworkUnderBar ? statusInset + extent : top) - topChrome - kToolbarHeight,
  );

  double get firstPageEnd => math.max(0, statusInset + alone - topChrome);
}

/// Where a freshly built narrow detail page draws [entity]'s first image:
/// its top in the scroll and its height (a panorama's viewport height). The
/// pager's stand-in for a page not built yet draws there, so a swipe lands
/// on the picture the page then builds instead of jumping into place.
({double top, double height}) detailFirstImageFrame(
  BuildContext context,
  IllustEntity entity,
) {
  final layout = IllustFirstImageLayout.of(context, entity, expanded: false);
  return (top: layout.top, height: layout.natural);
}

/// Owns the narrow/two-pane scroll controllers, page visibility state,
/// immersion progress, and lazy-sliver scroll-to-anchor routines for
/// `IllustDetailPage`.
class IllustDetailScrollController {
  IllustDetailScrollController() {
    narrowScroll
      ..addListener(updateImmersion)
      ..addListener(schedulePagesToggleCheck)
      ..addListener(updateNarrowInfoStartOffset);
    metaScroll.addListener(_onMetaScrollChanged);
  }

  /// Passed to the narrow layout's `SmoothWheelScroll` so lazy anchor jumps
  /// can step through unbuilt sliver pages.
  final ScrollController narrowScroll = ScrollController();

  /// Two-pane right column scroll controller — kept explicit so resizing
  /// across the two-pane breakpoint preserves the meta/caption/comments offset.
  final ScrollController metaScroll = ScrollController();

  final Map<int, GlobalKey> pageKeys = {};
  final GlobalKey pagesToggleKey = GlobalKey();
  final GlobalKey infoAnchorKey = GlobalKey();

  final Set<int> _visiblePages = <int>{};
  final ValueNotifier<int?> topVisiblePage = ValueNotifier<int?>(null);
  final ValueNotifier<bool> pagesToggleOnScreen = ValueNotifier<bool>(false);
  final ValueNotifier<double> immersion = ValueNotifier<double>(0);

  /// The image the reader is on, shared by narrow & two-pane layouts (NAV-21).
  int imageIndex = 0;
  bool? lastTwoPane;
  double topChromeExtent = 0;
  double immersionStart = 0;
  double lastMetaOffset = 0;
  double? narrowInfoStartOffset;

  bool _disposed = false;
  bool _pagesToggleCheckScheduled = false;
  bool _metricsSyncScheduled = false;
  bool _revealScheduled = false;
  bool _revealingNarrow = false;

  void cancelNarrowReveal() {
    _revealingNarrow = false;
  }

  GlobalKey keyForPage(int index) =>
      pageKeys.putIfAbsent(index, () => GlobalKey());

  void dispose() {
    _disposed = true;
    _revealingNarrow = false;
    narrowScroll.dispose();
    metaScroll.dispose();
    topVisiblePage.dispose();
    pagesToggleOnScreen.dispose();
    immersion.dispose();
  }

  void _onMetaScrollChanged() {
    if (metaScroll.hasClients) {
      lastMetaOffset = metaScroll.offset;
    }
  }

  void updateImmersion() {
    if (!narrowScroll.hasClients) return;
    final drawn = (narrowScroll.offset - immersionStart) / kToolbarHeight;
    immersion.value = drawn.clamp(0.0, 1.0).toDouble();
  }

  /// Coalesced post-frame check for both immersion and pages-toggle visibility
  /// after a layout change (e.g. expanding pages or resolving aspect ratios).
  void schedulePostLayoutSync() {
    if (_metricsSyncScheduled || _disposed) return;
    _metricsSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _metricsSyncScheduled = false;
      if (_disposed) return;
      updateImmersion();
      updatePagesToggleOnScreen();
    });
  }

  void schedulePagesToggleCheck() {
    if (_pagesToggleCheckScheduled || _disposed) return;
    _pagesToggleCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pagesToggleCheckScheduled = false;
      if (!_disposed) updatePagesToggleOnScreen();
    });
  }

  /// At least half of the toggle button inside the scroll view counts as on
  /// screen.
  void updatePagesToggleOnScreen() {
    final box = pagesToggleKey.currentContext?.findRenderObject();
    final Object? viewport = box == null
        ? null
        : RenderAbstractViewport.maybeOf(box);
    if (box is! RenderBox ||
        !box.attached ||
        !box.hasSize ||
        viewport is! RenderBox ||
        !viewport.attached ||
        !viewport.hasSize) {
      pagesToggleOnScreen.value = false;
      return;
    }
    final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
    final height = box.size.height;
    final shown =
        math.min(top + height, viewport.size.height) - math.max(top, 0.0);
    pagesToggleOnScreen.value = shown >= height / 2;
  }

  void onPageVisibility(int index, VisibilityInfo info) {
    if (_disposed) return;
    final bounds = info.visibleBounds;
    final behindTopChrome = bounds.top > 0 && bounds.height <= topChromeExtent;
    if (info.visibleFraction > 0 && !behindTopChrome) {
      _visiblePages.add(index);
    } else {
      _visiblePages.remove(index);
    }
    topVisiblePage.value = _visiblePages.isEmpty
        ? null
        : _visiblePages.reduce(math.min);
    final top = topVisiblePage.value;
    if (top != null && !_revealingNarrow) imageIndex = top;
  }

  void updateNarrowInfoStartOffset([double? topChromeOverride]) {
    final infoCtx = infoAnchorKey.currentContext;
    if (infoCtx == null || !infoCtx.mounted || !narrowScroll.hasClients) {
      return;
    }
    final infoRo = infoCtx.findRenderObject();
    final scrollRo = narrowScroll.position.context.notificationContext
        ?.findRenderObject();
    if (infoRo is! RenderBox ||
        !infoRo.attached ||
        !infoRo.hasSize ||
        scrollRo is! RenderBox ||
        !scrollRo.attached ||
        !scrollRo.hasSize) {
      return;
    }
    final topEdge =
        scrollRo.localToGlobal(Offset.zero).dy +
        (topChromeOverride ?? topChromeExtent);
    narrowInfoStartOffset =
        narrowScroll.offset + (infoRo.localToGlobal(Offset.zero).dy - topEdge);
  }

  double captureNarrowMetaOffset(double previousTopChromeExtent) {
    updateNarrowInfoStartOffset(previousTopChromeExtent);
    final infoStart = narrowInfoStartOffset;
    if (!narrowScroll.hasClients || infoStart == null) return 0;
    return math.max(0.0, narrowScroll.offset - infoStart);
  }

  /// Steps [narrowScroll] forward one viewport per frame until [ready] holds
  /// or the scroll reaches its end — shared by info-jump, narrow meta-offset
  /// restore, and two-pane-to-narrow image reveal.
  Future<void> _walkLazyNarrowScrollUntil(
    bool Function() isMounted,
    bool Function() ready,
  ) async {
    while (!_disposed && isMounted() && !ready() && narrowScroll.hasClients) {
      final position = narrowScroll.position;
      if (position.pixels >= position.maxScrollExtent) break;
      position.jumpTo(
        math.min(
          position.pixels + position.viewportDimension,
          position.maxScrollExtent,
        ),
      );
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  void scheduleMetaSync(double target, {required bool Function() isMounted}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !isMounted() || !metaScroll.hasClients) return;
      metaScroll.jumpTo(target.clamp(0.0, metaScroll.position.maxScrollExtent));
    });
  }

  void scheduleNarrowMetaSync(
    double targetMetaOffset, {
    required bool Function() isMounted,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_runNarrowMetaSync(targetMetaOffset, isMounted: isMounted));
    });
  }

  Future<void> _runNarrowMetaSync(
    double targetMetaOffset, {
    required bool Function() isMounted,
  }) async {
    await _walkLazyNarrowScrollUntil(
      isMounted,
      () => infoAnchorKey.currentContext != null,
    );
    if (_disposed || !isMounted() || !narrowScroll.hasClients) return;
    updateNarrowInfoStartOffset();
    final infoStart = narrowInfoStartOffset;
    if (infoStart == null) return;
    final target = (infoStart + targetMetaOffset).clamp(
      0.0,
      narrowScroll.position.maxScrollExtent,
    );
    narrowScroll.jumpTo(target);
  }

  Future<void> scrollToInfo({required bool Function() isMounted}) async {
    await _walkLazyNarrowScrollUntil(
      isMounted,
      () => infoAnchorKey.currentContext != null,
    );
    if (_disposed || !isMounted()) return;
    final anchor = infoAnchorKey.currentContext;
    if (anchor == null || !anchor.mounted) return;
    await Scrollable.ensureVisible(
      anchor,
      duration: MotionTokens.resolve(anchor, MotionTokens.spatial),
    );
  }

  void scheduleNarrowReveal({
    required BuildContext Function() getContext,
    required bool Function() isMounted,
    required IllustEntity entity,
    required bool Function() isPagesExpanded,
    required VoidCallback onExpandPages,
  }) {
    if (_revealScheduled || _disposed) return;
    _revealScheduled = true;
    if (imageIndex > 0) _revealingNarrow = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      unawaited(
        _runNarrowReveal(
          getContext: getContext,
          isMounted: isMounted,
          entity: entity,
          isPagesExpanded: isPagesExpanded,
          onExpandPages: onExpandPages,
        ),
      );
    });
  }

  Future<void> _runNarrowReveal({
    required BuildContext Function() getContext,
    required bool Function() isMounted,
    required IllustEntity entity,
    required bool Function() isPagesExpanded,
    required VoidCallback onExpandPages,
  }) async {
    try {
      if (_disposed || !isMounted()) return;
      final index = imageIndex;
      if (index <= 0) return;
      final layout = IllustFirstImageLayout.of(
        getContext(),
        entity,
        expanded: isPagesExpanded(),
      );
      if (index >= layout.shownPages) {
        onExpandPages();
        await WidgetsBinding.instance.endOfFrame;
        if (_disposed || !isMounted()) return;
      }
      await _walkLazyNarrowScrollUntil(isMounted, () {
        final page = pageKeys[index]?.currentContext;
        return page != null && page.mounted;
      });
      if (_disposed || !isMounted()) return;
      final page = pageKeys[index]?.currentContext;
      if (page == null || !page.mounted) return;
      await Scrollable.ensureVisible(
        page,
        duration: MotionTokens.resolve(page, MotionTokens.spatial),
      );
    } finally {
      _revealingNarrow = false;
    }
  }

  /// The image at the top of the single column right now, read directly from
  /// laid-out page boxes without waiting for VisibilityDetector timers (NAV-21).
  int? narrowTopImage(BuildContext context, IllustFirstImageLayout layout) {
    final bottom = _narrowBottom(context);
    int? top;
    for (final entry in pageKeys.entries) {
      final box = entry.value.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.bottom <= layout.topChrome || rect.top >= bottom) continue;
      if (top == null || entry.key < top) top = entry.key;
    }
    return top;
  }

  double _narrowBottom(BuildContext context) {
    if (!narrowScroll.hasClients) return MediaQuery.sizeOf(context).height;
    final viewport = narrowScroll.position.context.notificationContext
        ?.findRenderObject();
    if (viewport is! RenderBox || !viewport.attached || !viewport.hasSize) {
      return MediaQuery.sizeOf(context).height;
    }
    return viewport.localToGlobal(Offset.zero).dy + viewport.size.height;
  }

  void clampForCollapse(double firstPageEnd) {
    if (narrowScroll.hasClients && narrowScroll.offset > firstPageEnd) {
      narrowScroll.jumpTo(firstPageEnd);
    }
  }

  void compensateExpandedSlot(double removedBand) {
    if (removedBand > 0 && narrowScroll.hasClients && narrowScroll.offset > 0) {
      narrowScroll.jumpTo(math.max(0.0, narrowScroll.offset - removedBand));
    }
  }
}
