part of 'routes.dart';

class IllustRouteExtra {
  const IllustRouteExtra({
    this.entity,
    this.heroScope = 'feed',
    this.heroImageUrl,
    this.heroImageDecodeWidth,
    this.pagerSource,
  });

  final IllustEntity? entity;
  final String heroScope;
  final String? heroImageUrl;

  /// Decode width of the feed card that produced [heroImageUrl]. The detail
  /// page decodes its hero-phase image at this width so the first frame is
  /// the same cache entry the feed already painted.
  final int? heroImageDecodeWidth;

  /// The feed's ordered work list. Present ⇒ the route mounts the
  /// work-to-work pager instead of a single detail
  /// page. The object is in-memory only — never serialized into the URL.
  final IllustPagerSource? pagerSource;
}

/// How a novel opens. In-memory only: a restored reader opens at the
/// account's own place.
class NovelRouteExtra {
  const NovelRouteExtra({required this.atPixivPage});

  /// The Pixiv page (1-based) to open at, before any saved place: the
  /// account's bookmark, from the bookmark list.
  final int atPixivPage;
}

class ImageViewerRouteExtra {
  const ImageViewerRouteExtra({
    required this.urls,
    this.entity,
    this.heroScope,
    this.entryPage = 0,
  });

  final List<String> urls;
  final IllustEntity? entity;
  final String? heroScope;

  /// The page the viewer opened on. Only that page carries the Hero back:
  /// any other page's image is not where the detail page shows it, so the
  /// viewer slides away instead of shrinking to the wrong place.
  final int entryPage;
}

class _ImageViewerRoute extends ConsumerWidget {
  const _ImageViewerRoute({
    required this.illustId,
    required this.page,
    required this.quality,
    this.extra,
  });

  final int illustId;
  final int page;
  final ViewQuality quality;
  final ImageViewerRouteExtra? extra;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Prefer the store entity over the tap-time snapshot: when the detail
    // payload lands mid-session it carries original-tier URLs the snapshot
    // lacked, and recomputing urls lets PixivImage's gapless URL swap
    // upgrade to the real tier instead of staying on large forever. The
    // store does not notify: the detail the page below loads does.
    final detail = ref.watch(illustDetailControllerProvider(illustId));
    final entity =
        ref.watch(illustStoreProvider).get(illustId) ?? extra?.entity;
    final urls = entity?.viewerUrls(quality) ?? extra?.urls ?? const <String>[];
    return ImageViewerPage(
      entity: entity,
      urls: urls,
      // A restored viewer has no snapshot and no extra: it waits for the
      // detail's pages.
      loading: detail.isLoading,
      failure: switch (detail) {
        AsyncData(value: IllustDetailError(error: final Object error)) ||
        AsyncError(:final error) => FeedError(
          title: context.l10n.illustDetailLoadFailed,
          error: error,
          retryLabel: context.l10n.retry,
          onRetry: () => ref
              .read(illustDetailControllerProvider(illustId).notifier)
              .reload(),
        ),
        _ => null,
      },
      initialPage: page,
      heroTagForPage: switch (extra) {
        ImageViewerRouteExtra(:final heroScope?, :final entryPage) => (page) {
          if (page != entryPage) return null;
          final base = illustHeroTag(heroScope, illustId);
          return page == 0 ? base : '$base-$page';
        },
        _ => null,
      },
      tierKeyForPage: entity == null
          ? null
          : (page) => entity.imageTierKeyAt(page),
      tier: quality.tier,
      prefetchUrlForPage: entity == null
          ? null
          : (page) => entity.mediumUrlAt(page),
      onPageChanged: (page) => replaceImageViewerPage(
        context,
        illustId: illustId,
        page: page,
        quality: quality,
        extra: extra,
      ),
    );
  }
}

/// An image the author uploaded into a novel, alone in the viewer. Its
/// address comes from the body the reader below loaded.
class _NovelImageRoute extends ConsumerWidget {
  const _NovelImageRoute({required this.novelId, required this.imageId});

  final int novelId;
  final String imageId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final urls = ref
        .watch(novelStoreProvider.select((novels) => novels[novelId]))
        ?.uploadedImage(
          NovelImageLoadRequest(
            source: NovelImageSource.uploaded,
            identifier: imageId,
          ),
        );
    return ImageViewerPage(
      urls: [
        ?switch (ref.watch(viewQualityProvider)) {
          ViewQuality.original => urls?.original,
          ViewQuality.medium || ViewQuality.large => urls?.large,
        },
      ],
    );
  }
}

Widget _scoped(RouteObserver<ModalRoute<dynamic>> observer, Widget child) =>
    RouteObserverScope(observer: observer, child: child);

Page<dynamic> _page(
  BuildContext context,
  GoRouterState state,
  RouteObserver<ModalRoute<dynamic>> observer,
  Widget child, {
  bool sharedElement = false,
  bool sharedElementBackdrop = true,
}) {
  // Reduced-motion collapses the transition without dropping the state it
  // communicates: the route still changes on the same frame. The animation
  // speed scales each transition's own duration.
  final isDesktop = switch (Theme.of(context).platform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.fuchsia => false,
  };
  final duration = MotionTokens.resolve(
    context,
    sharedElement
        ? MotionTokens.sharedElement
        : isDesktop
        ? MotionTokens.desktopPageTransition
        : MotionTokens.pageTransition,
  );
  return FuncPage<dynamic>(
    key: state.pageKey,
    restorationId: RestorationScope.maybeOf(context) == null
        ? null
        : state.pageKey.value,
    // The detail route animates at the same time as the Hero overlay.
    // Keeping its static subtree in one repaint layer prevents the route
    // animation from repainting every image card on each tick; Hero still
    // extracts its own child into the navigator overlay and keeps the
    // custom flight clip.
    child: _scoped(observer, child),
    transitionDuration: duration,
    reverseTransitionDuration: duration,
    sharedElement: sharedElement,
    sharedElementBackdrop: sharedElementBackdrop,
  );
}

int _pathId(GoRouterState state, String name) =>
    int.parse(state.pathParameters[name]!);

/// Keeps the work the detail pager last settled on in the route's
/// restoration bucket. The pager source travels in `extra`, which a
/// restored route no longer has, so without this a restore after swiping
/// A→B reopened A.
class _RememberedIllust extends StatefulWidget {
  const _RememberedIllust({required this.builder});

  /// `remembered` is null until the pager settles on another work.
  final Widget Function(int? remembered, ValueChanged<int> remember) builder;

  @override
  State<_RememberedIllust> createState() => _RememberedIllustState();
}

class _RememberedIllustState extends State<_RememberedIllust>
    with RestorationMixin {
  final _shown = RestorableIntN(null);

  @override
  String get restorationId => 'illust-shown';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_shown, 'id');
  }

  void _remember(int id) => _shown.value = id;

  @override
  void dispose() {
    _shown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_shown.value, _remember);
}

/// The docked panel's handed-over session (R10 narrow): the text exactly as
/// typed, the kind and the filter drafts cross the location as its extra.
class _SearchInputDraft {
  const _SearchInputDraft({
    required this.keyword,
    required this.type,
    this.illustFilters,
    this.novelFilters,
  });

  final String keyword;
  final SearchResultType type;
  final IllustSearchFilters? illustFilters;
  final NovelSearchFilters? novelFilters;
}
