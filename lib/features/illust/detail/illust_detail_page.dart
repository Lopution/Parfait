import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show
        MatrixUtils,
        RenderBox,
        RenderObject,
        RenderProxyBox,
        RenderSliver,
        RenderViewportBase;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/person_avatar.dart';
import '../../../app/pixiv_image.dart';
import '../../../app/navigation/replica_page_route.dart';

import '../../../core/download/download_providers.dart';
import '../../../core/download/download_task.dart'
    show DownloadEvent, DownloadStatus;
import '../../../core/entity/illust_caption.dart';
import '../../../core/entity/illust_entity.dart';
import '../../../core/entity/illust_store.dart';
import '../../../core/history/history_models.dart';
import '../../../core/history/history_repository.dart';
import '../../../core/history/history_snapshot.dart';
import '../../../core/history/history_visibility.dart';
import '../../../core/platform/android_intent_channel.dart';
import '../../../core/settings/app_settings.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../core/settings/blocked_tags.dart';
import '../../bookmark/bookmark_switch_button.dart';
import '../../comments/comments_page.dart';
import '../../profile/user_page.dart' show showUserPage;
import '../../search/tag_search_page.dart';
import '../../../core/i18n/replica_strings.dart';
import '../viewer/image_viewer_page.dart';
import 'illust_detail_controller.dart';
import 'illust_download_controller.dart';
import '../../../app/navigation/home_shell_metrics.dart';
import 'related_illusts_section.dart';
import 'ugoira_viewer.dart';

/// Detail page replicating beta56 illust.dart: images with download mode,
/// author block, meta row, caption, tag chips (R2/R4/R5).
String illustHeroTag(String scope, int illustId) =>
    'IllustHero:$scope:$illustId';

/// Conservative fallback for the home shell bottom navigation before its
/// first rendered global edge has been published by [HomePage]. The normal
/// path uses [HomeShellMetrics.bottomNavTop], so this is only used in a
/// first-frame or test-only route with no measured shell.
const kHomeBottomNavHeight = 80.0;

/// Shared artwork Hero flight.
///
/// Hero shuttles are painted in the Navigator overlay, above both route
/// entries. The route's AppBar, pinned profile headers and shell navigation
/// therefore cannot occlude the shuttle by themselves. The boundary is
/// sampled from both endpoint viewports and interpolated with the same flight
/// progress as the Hero position. At the beginning of either direction the
/// image is clipped by the page it leaves; at the end it is clipped by the
/// page it enters. This moving boundary is important: a static intersection
/// produces the hard cut seen when returning from a scrolled profile, while
/// no clip lets an opening image paint over the destination chrome.
Widget illustHeroFlightShuttleBuilder(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection direction,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final heroContext = direction == HeroFlightDirection.push
      ? toHeroContext
      : fromHeroContext;
  final hero = heroContext.widget as Hero;
  final child = ClipRRect(
    borderRadius: _illustHeroBorderRadius,
    child: hero.child,
  );
  return AnimatedBuilder(
    animation: animation,
    child: child,
    builder: (context, child) {
      return _GlobalRectClip(
        globalRect: _heroFlightClipRect(
          flightContext,
          fromHeroContext,
          toHeroContext,
          direction,
          animation.value,
        ),
        child: child!,
      );
    },
  );
}

/// Returns the UI occlusion boundary for one frame of a Hero flight.
///
/// [Animation.value] is the route animation value. A push runs 0 -> 1; a pop
/// runs 1 -> 0, while Flutter's Hero overlay uses a reversed proxy for the
/// latter. Normalising here keeps the clip and the shuttle position moving in
/// the same direction for both transitions.
Rect _heroFlightClipRect(
  BuildContext flightContext,
  BuildContext fromContext,
  BuildContext toContext,
  HeroFlightDirection direction,
  double animationValue,
) {
  final size = _heroScreenSize(flightContext, fromContext, toContext);
  if (size.isEmpty) return Rect.zero;
  final screen = Offset.zero & size;
  final from = _heroEndpointViewport(flightContext, fromContext, size);
  final to = _heroEndpointViewport(flightContext, toContext, size);

  final rawProgress = direction == HeroFlightDirection.push
      ? animationValue
      : 1 - animationValue;
  final progress = rawProgress.isFinite
      ? rawProgress.clamp(0.0, 1.0).toDouble()
      : (direction == HeroFlightDirection.push ? 1.0 : 0.0);

  // Horizontal route-slide transforms are intentionally ignored. The Hero
  // rect itself is already in Navigator coordinates, while the chrome spans
  // the navigator width; interpolating endpoint x values would make the clip
  // disappear into the offstage route for the first frames.
  final top = _lerp(
    from.top,
    to.top,
    progress,
  ).clamp(0.0, size.height).toDouble();
  final bottom = _lerp(
    from.bottom,
    to.bottom,
    progress,
  ).clamp(0.0, size.height).toDouble();
  if (bottom <= top) {
    // A route can be offstage for one frame while HeroController measures it.
    // Fall back to conservative chrome bounds rather than returning an empty
    // clip (which makes the artwork disappear for the whole flight).
    return _fallbackHeroFlightClipRect(
      flightContext,
      fromContext,
      toContext,
      size,
      progress,
    );
  }
  return Rect.fromLTRB(0, top, size.width, bottom).intersect(screen);
}

double _lerp(double begin, double end, double t) => begin + (end - begin) * t;

Size _heroScreenSize(
  BuildContext flightContext,
  BuildContext fromContext,
  BuildContext toContext,
) {
  for (final context in [flightContext, fromContext, toContext]) {
    final media = MediaQuery.maybeOf(context);
    final size = media?.size;
    if (size != null && size.isFinite && !size.isEmpty) return size;
  }
  final navigator = Navigator.maybeOf(flightContext);
  final renderObject = navigator?.context.findRenderObject();
  if (renderObject is RenderBox && renderObject.hasSize) {
    try {
      final bounds = MatrixUtils.transformRect(
        renderObject.getTransformTo(null),
        Offset.zero & renderObject.size,
      );
      if (bounds.isFinite && !bounds.isEmpty) return bounds.size;
    } on Object {
      // A detached overlay has no usable global transform. Returning an
      // empty size below makes the clip a safe no-op instead of throwing
      // during a route transition.
    }
  }
  return Size.zero;
}

Rect _heroEndpointViewport(
  BuildContext flightContext,
  BuildContext heroContext,
  Size size,
) {
  RenderObject? renderObject = heroContext.findRenderObject();
  RenderSliver? viewportSliver;
  while (renderObject != null) {
    if (renderObject is RenderSliver) {
      // The first sliver above the Hero belongs to the nearest viewport. Its
      // approximate paint clip includes NestedScrollView overlap (for
      // example a pinned profile tab row), which viewport.size alone misses.
      viewportSliver ??= renderObject;
    }
    if (renderObject is RenderViewportBase &&
        renderObject.axis == Axis.vertical &&
        renderObject.hasSize) {
      try {
        final localClip =
            viewportSliver == null || viewportSliver.geometry == null
            ? Offset.zero & renderObject.size
            : renderObject.describeApproximatePaintClip(viewportSliver) ??
                  (Offset.zero & renderObject.size);
        final bounds = MatrixUtils.transformRect(
          renderObject.getTransformTo(null),
          localClip,
        );
        if (bounds.isFinite && bounds.height > 0) {
          final viewportBounds = Rect.fromLTRB(
            0,
            bounds.top.clamp(0.0, size.height).toDouble(),
            size.width,
            bounds.bottom.clamp(0.0, size.height).toDouble(),
          );
          // A viewport can intentionally paint under an edge-to-edge AppBar
          // (and a NestedScrollView can paint under pinned headers). The
          // endpoint's actual chrome is still an occlusion boundary, so
          // combine both measurements instead of trusting viewport.size
          // alone. This also keeps non-scrollable Hero endpoints consistent
          // with scrollable ones.
          final chrome = _fallbackHeroEndpoint(
            flightContext,
            heroContext,
            size,
          );
          final top = math.max(viewportBounds.top, chrome.top);
          final bottom = math.min(viewportBounds.bottom, chrome.bottom);
          if (bottom > top) {
            return Rect.fromLTRB(0, top, size.width, bottom);
          }
          return viewportBounds;
        }
      } on Object {
        // The route may be detached while a diverted flight is being
        // measured. The conservative fallback below keeps the shuttle
        // visible and bounded instead of failing the transition.
      }
    }
    renderObject = renderObject.parent;
  }
  return _fallbackHeroEndpoint(flightContext, heroContext, size);
}

Rect _fallbackHeroFlightClipRect(
  BuildContext flightContext,
  BuildContext fromContext,
  BuildContext toContext,
  Size size,
  double progress,
) {
  final from = _fallbackHeroEndpoint(flightContext, fromContext, size);
  final to = _fallbackHeroEndpoint(flightContext, toContext, size);
  final top = _lerp(
    from.top,
    to.top,
    progress,
  ).clamp(0.0, size.height).toDouble();
  final bottom = _lerp(
    from.bottom,
    to.bottom,
    progress,
  ).clamp(0.0, size.height).toDouble();
  if (bottom <= top) return Offset.zero & size;
  return Rect.fromLTRB(0, top, size.width, bottom);
}

Rect _fallbackHeroEndpoint(
  BuildContext flightContext,
  BuildContext heroContext,
  Size size,
) {
  final top = _heroTopChrome(flightContext, heroContext);
  final bottom = _heroBottomEdge(heroContext, size);
  return Rect.fromLTRB(0, top, size.width, bottom);
}

/// Status bar + app bar + pinned header of one flight end.
double _heroTopChrome(BuildContext context, BuildContext heroContext) {
  final media = MediaQuery.maybeOf(heroContext) ?? MediaQuery.maybeOf(context);
  final statusTop = media?.viewPadding.top ?? media?.padding.top ?? 0;
  final scaffold = heroContext.findAncestorWidgetOfExactType<Scaffold>();
  final appBar = scaffold?.appBar;
  final appBarChrome = appBar is PreferredSizeWidget
      ? appBar.preferredSize.height
      : 0;
  return statusTop + appBarChrome + _pinnedHeaderChrome(heroContext, statusTop);
}

double _heroBottomEdge(BuildContext heroContext, Size size) {
  final isHomeRoute = ModalRoute.of(heroContext)?.isFirst ?? false;
  if (!isHomeRoute) return size.height;

  // HomePage publishes the actual global edge of its BottomAppBar. Unlike a
  // height-plus-safe-area calculation this cannot double-count the gesture or
  // three-button navigation inset.
  final measuredTop = HomeShellMetrics.bottomNavTop;
  if (measuredTop != null && measuredTop > 0 && measuredTop < size.height) {
    return measuredTop;
  }
  final measuredHeight =
      HomeShellMetrics.bottomNavHeight ?? kHomeBottomNavHeight;
  return (size.height - measuredHeight).clamp(0.0, size.height).toDouble();
}

/// Collapsed height of pinned persistent headers in the landing page's scroll
/// containers, minus the status inset. A profile Hero lives in the inner
/// [CustomScrollView] of a [NestedScrollView], so looking at only one of
/// those ancestors misses the profile header (the profile-specific hard-cut
/// regression). Include both layers; the render viewport remains the source
/// of truth when it can provide an overlap-aware paint clip.
double _pinnedHeaderChrome(BuildContext context, double statusInset) {
  double fromSliver(SliverPersistentHeader header) {
    final h = header.delegate.minExtent;
    return h > 0 ? h : 0;
  }

  double total = 0;
  final scroll = context.findAncestorWidgetOfExactType<CustomScrollView>();
  if (scroll != null) {
    for (final sliver in scroll.slivers) {
      if (sliver is SliverPersistentHeader && sliver.pinned) {
        total += fromSliver(sliver);
      }
    }
  }
  final nested = context.findAncestorWidgetOfExactType<NestedScrollView>();
  if (nested != null) {
    for (final sliver in nested.headerSliverBuilder(context, false)) {
      if (sliver is SliverPersistentHeader && sliver.pinned) {
        total += fromSliver(sliver);
      }
    }
  }
  return total > 0 ? math.max(0, total - statusInset) : 0;
}

const _illustHeroBorderRadius = BorderRadius.all(Radius.circular(12));

class _GlobalRectClip extends SingleChildRenderObjectWidget {
  const _GlobalRectClip({required this.globalRect, required super.child});

  final Rect globalRect;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderGlobalRectClip(globalRect);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderGlobalRectClip renderObject,
  ) {
    renderObject.globalRect = globalRect;
  }
}

class _RenderGlobalRectClip extends RenderProxyBox {
  _RenderGlobalRectClip(this._globalRect);

  Rect _globalRect;
  Rect? _lastPaintClipRect;

  Rect get globalRect => _globalRect;

  /// Actual global clip used by the last paint pass. Tests use this to catch
  /// render-time changes that are invisible if they only inspect the widget's
  /// input rectangle.
  Rect? get debugLastPaintClipRect => _lastPaintClipRect;

  set globalRect(Rect value) {
    if (value == _globalRect) return;
    _globalRect = value;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null || size.isEmpty) {
      _lastPaintClipRect = Rect.zero;
      return;
    }
    final globalOrigin = localToGlobal(Offset.zero);
    final clipRect = _globalRect;
    // Keep the boundary itself rather than intersecting it with the current
    // shuttle bounds. The latter changes every frame by design; the former
    // is the UI occlusion contract we need to keep stable in both directions.
    _lastPaintClipRect = clipRect;
    final localClip = clipRect
        .shift(-globalOrigin)
        .intersect(Offset.zero & size);
    if (localClip.isEmpty) return;
    context.pushClipRect(
      needsCompositing,
      offset,
      localClip,
      super.paint,
      clipBehavior: Clip.hardEdge,
    );
  }
}

class IllustDetailPage extends ConsumerStatefulWidget {
  const IllustDetailPage({
    super.key,
    required this.illustId,
    this.initialEntity,
    this.heroScope = 'feed',
    this.heroImageUrl,
  });

  final int illustId;
  final IllustEntity? initialEntity;
  final String heroScope;
  final String? heroImageUrl;

  @override
  ConsumerState<IllustDetailPage> createState() => _IllustDetailPageState();
}

class _IllustDetailPageState extends ConsumerState<IllustDetailPage> {
  bool _downloadMode = false;
  bool _blockMode = false;
  StreamSubscription<DownloadEvent>? _downloadEvents;

  @override
  void initState() {
    super.initState();
    // Start fetching related works as soon as the detail page opens (the
    // official client does too). The section further down is a lazy sliver:
    // without this prefetch the request only began once the user scrolled
    // to the bottom, which read as an endless spinner.
    unawaited(
      ref
          .read(relatedIllustControllerProvider(widget.illustId).future)
          .then((_) {}, onError: (Object _) {}),
    );
  }

  @override
  void dispose() {
    _downloadEvents?.cancel();
    super.dispose();
  }

  /// Download badge states derive from live manager tasks; without this
  /// subscription the Provider-backed snapshot would never notify the UI.
  void _ensureDownloadListener() {
    _downloadEvents ??= ref.read(downloadManagerProvider).events.listen((_) {
      if (mounted) setState(() {});
    });
  }

  void _toggleDownloadMode() => setState(() => _downloadMode = !_downloadMode);

  @override
  Widget build(BuildContext context) {
    _ensureDownloadListener();
    final async = ref.watch(illustDetailControllerProvider(widget.illustId));
    return Scaffold(
      appBar: _buildAppBar(context, ref, async),
      body: async.when(
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
          return const Center(child: CupertinoActivityIndicator());
        },
        error: (Object error, StackTrace _) => _ErrorView(
          error: error,
          onRetry: () => ref
              .read(illustDetailControllerProvider(widget.illustId).notifier)
              .reload(),
        ),
        data: (state) {
          // Snapshot-first (R1): the shared store renders stale data behind
          // any in-flight refresh; the controller state drives the terminal
          // surfaces (the loading branch above reads the store directly).
          return switch (state) {
            IllustDetailRestricted(:final entity) => _RestrictedView(entity),
            IllustDetailNotFound() => const _NotFoundView(),
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
    );
  }

  PreferredSizeWidget _buildAppBar(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<IllustDetailState> async,
  ) {
    final entity = _entityOf(async);
    final download = ref.watch(illustDownloadControllerProvider);
    return AppBar(
      title: Text(
        entity?.title ?? _detailText(context, 'illustDetailTitle'),
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      actions: [
        if (_downloadMode && entity != null)
          IconButton(
            tooltip: _detailText(context, 'downloadAll'),
            onPressed: () {
              try {
                download.downloadAll(entity);
              } catch (error) {
                // Any submission failure must be visible on device: the
                // manager/ownership/channel errors that are not
                // FormatException otherwise vanish with no UI feedback.
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      _detailText(context, 'downloadSubmissionFailed', {
                        'error': error,
                      }),
                    ),
                  ),
                );
              }
            },
            icon: const Icon(Icons.file_download_outlined),
          ),
        // Beta56 keeps the bookmark heart in the app bar actions at all
        // times (isButton: false variant, tap toggles / long-press sheet
        // only while unbookmarked).
        if (entity != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(
              child: BookmarkSwitchButton(
                illustId: entity.id,
                title: entity.title,
                isButton: false,
              ),
            ),
          ),
      ],
    );
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
    return _ErrorView(
      error: error,
      onRetry: () => ref
          .read(illustDetailControllerProvider(widget.illustId).notifier)
          .reload(),
    );
  }

  Widget _buildContent(
    BuildContext context,
    WidgetRef ref,
    IllustEntity entity, {
    bool detailReady = false,
  }) {
    // 三档质量之详情档: the detail-page hero follows the user's detail
    // quality once the detail payload is merged; before that it shows the
    // feed-provided hero URL so the Hero flight stays on one cache key.
    final detailQuality = ref.watch(detailQualityProvider);
    String? detailUrlFor(int index) =>
        detailReady ? entity.detailUrlAt(index, detailQuality) : null;
    final content = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (_downloadMode) _toggleDownloadMode();
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          // Related works paginate as the user reaches the bottom of the
          // page (official client behaviour). loadMore is internally
          // guarded against re-entry / exhausted state.
          final metrics = notification.metrics;
          if (metrics.maxScrollExtent > 0 &&
              metrics.pixels >= metrics.maxScrollExtent - 500) {
            // loadMore asserts an AsyncData state (it calls requireValue),
            // so only hand the scroll event over once the first page
            // actually loaded.
            final relatedState = ref.read(
              relatedIllustControllerProvider(widget.illustId),
            );
            if (relatedState.hasValue) {
              ref
                  .read(
                    relatedIllustControllerProvider(widget.illustId).notifier,
                  )
                  .loadMore();
            }
          }
          return false;
        },
        child: CustomScrollView(
          slivers: [
            if (entity.isUgoira)
              SliverToBoxAdapter(
                child: UgoiraViewer(
                  illustId: entity.id,
                  // Keep the first frame on the exact feed URL during the
                  // initial Hero hand-off, then follow the same detail
                  // quality selection as still and multi-page works. The
                  // shared PixivImage inside UgoiraViewer keeps this URL
                  // change gapless while a decoded frame (if any) remains
                  // above it.
                  previewUrl:
                      detailUrlFor(0) ??
                      widget.heroImageUrl ??
                      entity.imageUrls.large,
                  width: entity.width,
                  height: entity.height,
                  downloadMode: _downloadMode,
                  onLongPress: _toggleDownloadMode,
                  heroTag: illustHeroTag(widget.heroScope, entity.id),
                  flightShuttleBuilder: illustHeroFlightShuttleBuilder,
                ),
              )
            else if (entity.pageCount == 1)
              SliverToBoxAdapter(
                child: _PageImage(
                  key: ValueKey<Object?>('illust-page-${entity.id}-0'),
                  entity: entity,
                  index: 0,
                  heroTag: illustHeroTag(widget.heroScope, entity.id),
                  heroImageUrl: widget.heroImageUrl,
                  detailUrl: detailUrlFor(0),
                  downloadMode: _downloadMode,
                  onLongPress: _toggleDownloadMode,
                ),
              )
            else
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => Padding(
                    padding: EdgeInsets.only(
                      bottom: index == entity.pageCount - 1 ? 0 : 10,
                    ),
                    child: _PageImage(
                      key: ValueKey<Object?>('illust-page-${entity.id}-$index'),
                      entity: entity,
                      index: index,
                      heroTag: index == 0
                          ? illustHeroTag(widget.heroScope, entity.id)
                          : '${illustHeroTag(widget.heroScope, entity.id)}-$index',
                      heroImageUrl: index == 0 ? widget.heroImageUrl : null,
                      detailUrl: detailUrlFor(index),
                      downloadMode: _downloadMode,
                      onLongPress: _toggleDownloadMode,
                      placeholderOnly: !detailReady && index > 0,
                    ),
                  ),
                  // All pages appear immediately: before the detail payload the
                  // non-first pages render as neutral placeholders (uniform
                  // ratio), and the real images/proportions replace them when
                  // the detail API payload is merged.
                  childCount: entity.pageCount,
                ),
              ),
            SliverToBoxAdapter(
              child: _InfoBlock(
                entity: entity,
                blockMode: _blockMode,
                onToggleBlockMode: () =>
                    setState(() => _blockMode = !_blockMode),
              ),
            ),
            // Official client behaviour: "関連作品" below the caption/tags,
            // paginated as the user scrolls to the bottom of the page.
            RelatedIllustsSlivers(illustId: widget.illustId),
          ],
        ),
      ),
    );
    final accountId = ref.watch(historyAccountIdProvider);
    if (accountId == null) return content;
    final pixivEnabled = ref.watch(pixivHistoryEnabledProvider);
    return HistoryVisibility(
      accountId: accountId,
      contentType: HistoryContentType.illust,
      contentId: entity.id,
      snapshot: snapshotFromIllust(entity),
      localHistoryEnabled: ref.watch(localHistoryEnabledProvider),
      pixivHistoryEnabled: pixivEnabled,
      repository: ref.watch(historyRepositoryProvider),
      remote: pixivEnabled ? ref.watch(pixivHistoryRemoteProvider) : null,
      isAccountCurrent: () => ref.read(historyAccountIdProvider) == accountId,
      child: content,
    );
  }
}

class _PageImage extends ConsumerStatefulWidget {
  const _PageImage({
    super.key,
    required this.entity,
    required this.index,
    required this.heroTag,
    this.heroImageUrl,
    this.detailUrl,
    required this.downloadMode,
    required this.onLongPress,
    this.placeholderOnly = false,
  });

  final IllustEntity entity;
  final int index;
  final String heroTag;
  final String? heroImageUrl;

  /// True while the detail payload is still loading for a multi-page work:
  /// the page renders a neutral placeholder instead of an image whose URL
  /// does not exist in the feed snapshot yet.
  final bool placeholderOnly;

  /// Detail-quality URL once the detail payload is merged. Preferring it
  /// over [heroImageUrl] means the detail hero upgrades from the feed
  /// preview to the user's chosen detail quality as soon as data arrives.
  final String? detailUrl;
  final bool downloadMode;
  final VoidCallback onLongPress;

  @override
  ConsumerState<_PageImage> createState() => _PageImageState();
}

class _PageImageState extends ConsumerState<_PageImage> {
  /// Optimistic in-flight flag: the badge switches to the loading spinner
  /// the moment the user taps, before the coordinator notification arrives.
  bool _optimisticDownloading = false;

  IllustEntity get entity => widget.entity;
  bool get downloadMode => widget.downloadMode;

  @override
  Widget build(BuildContext context) {
    final download = ref.watch(illustDownloadControllerProvider);
    final manager = ref.watch(downloadManagerProvider);
    final viewQuality = ref.watch(viewQualityProvider);
    final state = download.stateFor(entity.id, widget.index);
    final isPagePlaceholder = widget.placeholderOnly && widget.index > 0;
    final hasActiveTask = manager.tasks.any(
      (task) =>
          task.illustId == entity.id &&
          task.pageIndex == widget.index &&
          switch (task.status) {
            DownloadStatus.queued ||
            DownloadStatus.running ||
            DownloadStatus.finalizing ||
            DownloadStatus.canceling => true,
            DownloadStatus.failed ||
            DownloadStatus.canceled ||
            DownloadStatus.retryable ||
            DownloadStatus.succeeded ||
            DownloadStatus.orphaned => false,
          },
    );
    // PixivImage keeps its last decoded frame when this URL changes. That
    // gives every quality hand-off (preview -> detail and medium -> large ->
    // original) the same gapless behavior without a second preload state in
    // each page widget.
    final previewUrl =
        widget.detailUrl ??
        (widget.index == 0 && widget.heroImageUrl != null
            ? widget.heroImageUrl!
            : entity.pageCount > 1 && widget.index < entity.metaPages.length
            ? entity.metaPages[widget.index].large
            : entity.imageUrls.large);
    final image = GestureDetector(
      onTap: isPagePlaceholder
          ? null
          : () => _openViewer(context, quality: viewQuality),
      onLongPress: isPagePlaceholder ? null : widget.onLongPress,
      child: AspectRatio(
        // Per-page ratio (R7): meta_pages carry their own width/height and
        // multi-page works legitimately differ page to page. Using the
        // work-level ratio + BoxFit.cover cropped every non-first page
        // (visible on the 31-page strip work).
        aspectRatio: entity.pageAspectRatioAt(widget.index),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Keep download controls out of the Hero flight. The matching
            // feed Hero contains only this image, so a page-count badge can
            // never be scaled or retained by a detail pop transition.
            // Both directions use the same progress-aware endpoint boundary
            // (see illustHeroFlightShuttleBuilder), so occlusion follows the
            // route chrome continuously instead of hard-cutting at landing.
            if (isPagePlaceholder)
              _PagePlaceholder()
            else
              Hero(
                tag: widget.heroTag,
                flightShuttleBuilder: illustHeroFlightShuttleBuilder,
                child: PixivImage(
                  url: previewUrl,
                  fit: BoxFit.contain,
                  width: double.infinity,
                  transitionKey: widget.heroTag,
                  // Keep the loading transition for cold detail images. A
                  // cached Hero hand-off is still instantaneous because
                  // PixivImage disables its fade for completed cache entries.
                  filterColor: downloadMode ? Colors.white24 : null,
                  filterBlendMode: downloadMode ? BlendMode.srcOver : null,
                ),
              ),
            if (downloadMode && !isPagePlaceholder)
              Positioned(
                top: 20,
                right: 20,
                child: _DownloadBadge(
                  state:
                      _optimisticDownloading &&
                          state == IllustPageSaveState.none &&
                          hasActiveTask
                      ? IllustPageSaveState.downloading
                      : state,
                  onTap: () {
                    try {
                      download.download(entity, widget.index);
                      // Immediate visual feedback: the spinner shows before
                      // the coordinator/task notification round trip.
                      setState(() => _optimisticDownloading = true);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            _detailText(context, 'downloadQueuedMessage'),
                          ),
                        ),
                      );
                    } catch (error) {
                      // Any submission failure must be visible on device: the
                      // manager/ownership/channel errors that are not
                      // FormatException otherwise vanish with no UI feedback.
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            _detailText(context, 'downloadSubmissionFailed', {
                              'error': error,
                            }),
                          ),
                        ),
                      );
                    }
                  },
                ),
              ),
          ],
        ),
      ),
    );
    return image;
  }

  void _openViewer(BuildContext context, {required ViewQuality quality}) {
    Navigator.of(context).push(
      ReplicaPageRoute<void>(
        builder: (_) => ImageViewerPage(
          urls: [
            for (var i = 0; i < entity.pageCount; i++)
              entity.viewerUrlAt(i, quality),
          ],
          initialPage: widget.index,
        ),
      ),
    );
  }
}

/// Stable multi-page placeholder used while the detail payload is pending.
/// Rendering the feed snapshot's first-page URL in every slot made a strip
/// appear as duplicated artwork and allowed tapping a page that had no viewer
/// URL yet.
class _PagePlaceholder extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.image_outlined,
          size: 36,
          color: colors.onSurfaceVariant.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

class _DownloadBadge extends StatelessWidget {
  const _DownloadBadge({required this.state, required this.onTap});

  final IllustPageSaveState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final child = switch (state) {
      IllustPageSaveState.none => const Icon(
        Icons.file_download_outlined,
        size: 30,
      ),
      IllustPageSaveState.downloading => const SizedBox(
        width: 30,
        height: 30,
        child: CircularProgressIndicator(),
      ),
      IllustPageSaveState.error => Icon(
        Icons.error_outline,
        color: theme.colorScheme.error,
        size: 30,
      ),
      IllustPageSaveState.exist => Icon(
        Icons.check,
        color: theme.colorScheme.primary,
        size: 30,
      ),
    };
    return GestureDetector(
      onTap: state == IllustPageSaveState.downloading ? null : onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(30),
        ),
        child: child,
      ),
    );
  }
}

class _InfoBlock extends ConsumerWidget {
  const _InfoBlock({
    required this.entity,
    required this.blockMode,
    required this.onToggleBlockMode,
  });

  final IllustEntity entity;
  final bool blockMode;
  final VoidCallback onToggleBlockMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final blockedTags = ref.watch(blockedTagsProvider);
    final blockedController = ref.read(blockedTagsProvider.notifier);
    final createDate = DateTime.tryParse(entity.createDate ?? '');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 25, vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The whole author block (avatar + name + account) opens the user
          // page. Wrapping happens outside the Row so the avatar keeps its
          // 48px slot and the existing key/spacing stay untouched.
          InkWell(
            onTap: () => showUserPage(context, entity.user.id),
            borderRadius: BorderRadius.circular(8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox.square(
                  key: const Key('illust-author-avatar'),
                  dimension: 48,
                  child: PersonAvatar(
                    imageUrl: entity.user.profileImageUrl,
                    radius: 24,
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entity.user.name,
                        style: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        entity.user.account,
                        style: textTheme.bodyMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          // 日期行与统计行的排版（U2 一并整理）：日期占左侧，视线/收藏
          // 统计右侧成组，避免数字被日期挤压后换行错位。
          Row(
            children: [
              Expanded(
                child: Text(
                  createDate == null
                      ? _detailText(context, 'illustDetailCreateDateUnknown')
                      : _detailText(context, 'illustDetailCreateDate', {
                          'date':
                              '${createDate.year}/${createDate.month}/${createDate.day}',
                        }),
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: 12),
              _StatItem(
                icon: Icons.remove_red_eye_outlined,
                label: '${entity.totalView}',
              ),
              const SizedBox(width: 10),
              _StatItem(
                icon: Icons.favorite_border,
                label: '${entity.totalBookmarks}',
              ),
            ],
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              Text(
                _detailText(context, 'illustDetailSize', {
                  'width': entity.width,
                  'height': entity.height,
                }),
                style: textTheme.bodyMedium,
              ),
              const SizedBox(width: 5),
              Text('ID: ${entity.id}', style: textTheme.bodyMedium),
            ],
          ),
          if (entity.caption.isNotEmpty) ...[
            const SizedBox(height: 12),
            // Pixiv captions are HTML; render them immediately so the detail
            // content is complete on the same frame as the artwork.
            Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: _CaptionRichText(caption: entity.caption),
            ),
          ],
          const SizedBox(height: 20),
          Wrap(
            children: [
              for (final tag in entity.tags)
                _TagChip(
                  tag: tag,
                  blockMode: blockMode,
                  blocked: blockedTags.contains(tag.name),
                  onTap: () {
                    if (blockMode) {
                      blockedController.toggle(tag.name);
                    } else {
                      showTagSearch(context, tag.name);
                    }
                  },
                  onLongPress: onToggleBlockMode,
                ),
            ],
          ),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: () => showIllustComments(context, entity.id),
            icon: const Icon(Icons.comment_outlined),
            label: Text(_detailText(context, 'commentTitle')),
          ),
        ],
      ),
    );
  }
}

/// One icon + numeric-stat pair in the detail meta row (U2 排版整理).
class _StatItem extends StatelessWidget {
  const _StatItem({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.bodyMedium;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12),
        const SizedBox(width: 4),
        Text(label, style: textStyle),
      ],
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({
    required this.tag,
    required this.blockMode,
    required this.blocked,
    required this.onTap,
    required this.onLongPress,
  });

  final IllustTag tag;
  final bool blockMode;
  final bool blocked;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: theme.colorScheme.surface,
              ),
              child: Text(
                '#${tag.name}${tag.translatedName != null ? ' ${tag.translatedName}' : ''}',
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ),
          if (blockMode)
            Positioned(
              top: 0,
              right: 0,
              child: Icon(
                Icons.block,
                size: 15,
                color: blocked ? theme.colorScheme.primary : null,
              ),
            ),
        ],
      ),
    );
  }
}

/// Renders a parsed HTML caption with clickable links (U6).
///
/// pixiv-internal links (www.pixiv.net users/artworks) navigate inside the
/// app with the same right-in rhythm as feed cards; anything else opens via
/// the outbound Android intent.
class _CaptionRichText extends ConsumerWidget {
  const _CaptionRichText({required this.caption});

  final String caption;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final linkColor = theme.colorScheme.primary;
    final parsed = parseIllustCaption(caption);

    final spans = <InlineSpan>[];
    for (final span in parsed.spans) {
      switch (span) {
        case CaptionText(:final text):
          spans.add(TextSpan(text: text));
        case CaptionBreak():
          spans.add(const TextSpan(text: '\n'));
        case CaptionLink(:final href, :final text):
          final target = _resolvePixivRoute(href);
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.top,
              child: GestureDetector(
                onTap: () {
                  if (target != null) {
                    _openPixivRoute(context, target);
                    return;
                  }
                  final opener = ref.read(outboundUrlOpenerProvider);
                  unawaited(
                    opener.openExternal(href).catchError((Object error) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              _detailText(
                                context,
                                'illustDetailOpenLinkFailed',
                                {'error': error},
                              ),
                            ),
                          ),
                        );
                      }
                    }),
                  );
                },
                child: Text(
                  text.isEmpty ? href : text,
                  style: TextStyle(
                    color: linkColor,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ),
          );
      }
    }

    return Text.rich(
      TextSpan(children: spans),
      style: theme.textTheme.bodyMedium,
    );
  }
}

/// Resolves a pixiv web URL to an internal route, or null for external.
({String kind, String id})? _resolvePixivRoute(String href) {
  final uri = Uri.tryParse(href);
  if (uri == null) return null;
  final host = uri.host.toLowerCase();
  if (host != 'www.pixiv.net' && host != 'pixiv.net') return null;
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return null;
  // Strip a leading language segment (en/, ja/, ...).
  final start =
      segments.length >= 2 &&
          segments[0].length == 2 &&
          !RegExp(r'^\d+$').hasMatch(segments[0])
      ? 1
      : 0;
  if (segments.length <= start) return null;
  return switch (segments[start]) {
    'users' when segments.length > start + 1 => (
      kind: 'user',
      id: segments[start + 1],
    ),
    'artworks' || 'illusts' when segments.length > start + 1 => (
      kind: 'illust',
      id: segments[start + 1],
    ),
    _ => null,
  };
}

void _openPixivRoute(BuildContext context, ({String kind, String id}) target) {
  final id = int.tryParse(target.id);
  if (id == null || id <= 0) return;
  switch (target.kind) {
    case 'user':
      // showUserPage pushes its own route with the right-in rhythm.
      showUserPage(context, id);
    case 'illust':
      Navigator.of(context).push<void>(
        ReplicaPageRoute<void>(builder: (_) => IllustDetailPage(illustId: id)),
      );
  }
}

class _RestrictedView extends StatelessWidget {
  const _RestrictedView(this.entity);

  final IllustEntity entity;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.visibility_off_outlined, size: 48),
          const SizedBox(height: 12),
          Text(
            _detailText(context, 'illustDetailRestricted', {'id': entity.id}),
          ),
        ],
      ),
    );
  }
}

class _NotFoundView extends StatelessWidget {
  const _NotFoundView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.search_off, size: 48),
          const SizedBox(height: 12),
          Text(_detailText(context, 'illustDetailNotFound')),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48),
            const SizedBox(height: 12),
            Text(_detailText(context, 'illustDetailLoadFailed')),
            const SizedBox(height: 8),
            Text('$error', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: onRetry,
              child: Text(_detailText(context, 'retry')),
            ),
          ],
        ),
      ),
    );
  }
}

String _detailText(
  BuildContext context,
  String key, [
  Map<String, Object?> args = const {},
]) => ReplicaStrings.fromTag(
  Localizations.localeOf(context).toLanguageTag(),
  key,
  args,
);
