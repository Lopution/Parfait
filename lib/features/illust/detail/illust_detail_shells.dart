import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../app/icons/app_icons.dart';
import '../../../app/icons/ui_icons.dart';
import '../../../app/layout/deferred_cache_scroll_view.dart';
import '../../../app/layout/two_pane.dart';
import '../../../app/layout/window_layout_spec.dart';
import '../../../app/motion/hero_transition.dart';
import '../../../app/motion/motion_tokens.dart';
import '../../../app/pixiv_image.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/theme/func_tokens.dart';
import '../../../app/widgets/ambient_wash.dart';
import '../../../app/widgets/app_top_bar.dart';
import '../../../app/widgets/artwork_controls.dart';
import '../../../app/widgets/comment_composer.dart';
import '../../../app/widgets/selection_app_bar.dart';
import '../../../app/widgets/smooth_wheel_scroll.dart';
import '../../../core/entity/illust_entity.dart';
import '../../../core/history/history_models.dart';
import '../../../core/history/history_repository.dart';
import '../../../core/history/history_snapshot.dart';
import '../../../core/history/history_visibility.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../l10n/context.dart';
import 'author_works_section.dart';
import 'comments_preview_section.dart';
import 'detail_page_activity.dart';
import 'illust_detail_menu.dart';
import 'illust_detail_scroll.dart';
import 'related_illusts_section.dart';
import 'ugoira_viewer.dart';
import 'widgets/detail_action_bar.dart';
import 'widgets/detail_image_pager.dart';
import 'widgets/detail_overlay_frame.dart';
import 'widgets/detail_page_counter.dart';
import 'widgets/illust_series_section.dart';
import 'widgets/info_block.dart';
import 'widgets/page_image.dart';

/// Two-pane layout shell: ambient artwork stage on the primary pane and
/// docked metadata/comments inspector beside it.
class IllustDetailTwoPaneShell extends StatelessWidget {
  const IllustDetailTwoPaneShell({
    super.key,
    required this.entity,
    required this.detailUrlFor,
    required this.downloadMode,
    required this.selectedPages,
    required this.onToggleSelect,
    required this.onLongPress,
    required this.onExitDownloadMode,
    required this.heroScope,
    required this.initialPage,
    required this.onPageChanged,
    required this.heroImageUrl,
    required this.heroImageDecodeWidth,
    required this.inspectorHeader,
    required this.metaScrollController,
    required this.metaSlivers,
    required this.onScrollNotification,
    required this.composerLayer,
  });

  final IllustEntity entity;
  final String? Function(int index) detailUrlFor;
  final bool downloadMode;
  final Set<int> selectedPages;
  final ValueChanged<int> onToggleSelect;
  final VoidCallback onLongPress;
  final VoidCallback onExitDownloadMode;
  final String heroScope;
  final int initialPage;
  final ValueChanged<int> onPageChanged;
  final String? heroImageUrl;
  final int? heroImageDecodeWidth;
  final Widget inspectorHeader;
  final ScrollController metaScrollController;
  final List<Widget> metaSlivers;
  final bool Function(ScrollNotification) onScrollNotification;
  final Widget? composerLayer;

  @override
  Widget build(BuildContext context) {
    final tokens = FuncSemanticTokens.of(context);
    final wideDesktopModal = MediaQuery.sizeOf(context).width >= 960;
    final isModalOverlay = DetailOverlayFrame.isActiveOf(context);
    final safePadding = isModalOverlay
        ? EdgeInsets.zero
        : MediaQuery.paddingOf(context);
    final isTabletop =
        WindowLayoutSpec.postureOf(context) == FoldPosture.tabletop;
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    final startSafe = isRtl ? safePadding.right : safePadding.left;
    final endSafe = isRtl ? safePadding.left : safePadding.right;
    final metaScroll = NotificationListener<ScrollNotification>(
      onNotification: onScrollNotification,
      child: SmoothWheelScroll(
        controller: metaScrollController,
        builder: (context, controller, physics) => DeferredCacheScrollView(
          controller: controller,
          physics: physics,
          slivers: [
            ...metaSlivers,
            if (safePadding.bottom > 0)
              SliverToBoxAdapter(child: SizedBox(height: safePadding.bottom)),
          ],
        ),
      ),
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (downloadMode) onExitDownloadMode();
      },
      child: AdaptiveTwoPane(
        secondaryFraction: wideDesktopModal ? 0.30 : 0.38,
        secondaryMaxWidth: wideDesktopModal ? 420 : 460,
        primary: SelectionContainer.disabled(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (!downloadMode) ...[
                AmbientWash(
                  blur: 52,
                  image: PixivImage.providerFor(
                    context,
                    heroImageUrl ?? entity.imageUrls.medium,
                    decodeWidth: 96,
                  ),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment.center,
                      radius: 1.05,
                      colors: [FuncTokens.transparent, Color(0x470C0914)],
                    ),
                  ),
                ),
              ] else
                ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                ),
              Padding(
                padding: EdgeInsetsDirectional.fromSTEB(
                  FuncSpacing.lg + startSafe,
                  FuncSpacing.lg + safePadding.top,
                  FuncSpacing.lg + (isTabletop ? endSafe : 0),
                  FuncSpacing.lg + (isTabletop ? 0 : safePadding.bottom),
                ),
                child: DetailImagePager(
                  entity: entity,
                  detailUrlFor: detailUrlFor,
                  downloadMode: downloadMode,
                  selectedPages: selectedPages,
                  onToggleSelect: onToggleSelect,
                  onLongPress: onLongPress,
                  heroTag: illustHeroTag(heroScope, entity.id),
                  heroScope: heroScope,
                  initialPage: initialPage,
                  onPageChanged: onPageChanged,
                  heroImageUrl: heroImageUrl,
                  heroImageDecodeWidth: heroImageDecodeWidth,
                ),
              ),
              if (!downloadMode)
                PositionedDirectional(
                  top: FuncSpacing.md + safePadding.top,
                  start: FuncSpacing.md + startSafe,
                  child: HeroChrome(
                    child: ArtworkControls(
                      glyph: FuncTokens.white,
                      halo: const Color(0xCC0C0914),
                      child: Builder(
                        builder: (context) {
                          final localizations = MaterialLocalizations.of(
                            context,
                          );
                          return IconButton(
                            key: const ValueKey('two-pane-primary-back'),
                            tooltip: isModalOverlay
                                ? localizations.closeButtonTooltip
                                : localizations.backButtonTooltip,
                            onPressed: () =>
                                unawaited(Navigator.maybePop(context)),
                            icon: isModalOverlay
                                ? const Icon(UiIcons.close, size: 20)
                                : IconTheme.merge(
                                    data: const IconThemeData(size: 20),
                                    child: const BackButtonIcon(),
                                  ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        secondary: DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.surface,
            border: isTabletop
                ? Border(top: BorderSide(color: tokens.brandHairline))
                : BorderDirectional(
                    start: BorderSide(color: tokens.brandHairline),
                  ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: EdgeInsetsDirectional.only(
                      top: isTabletop ? 0 : safePadding.top,
                      start: isTabletop ? startSafe : 0,
                      end: endSafe,
                    ),
                    child: SelectionContainer.disabled(child: inspectorHeader),
                  ),
                  Divider(height: 1, color: tokens.brandHairline),
                  Expanded(
                    child: MediaQuery.removePadding(
                      context: context,
                      removeTop: true,
                      child: Padding(
                        padding: EdgeInsetsDirectional.only(
                          start: isTabletop ? startSafe : 0,
                          end: endSafe,
                        ),
                        child: Scrollbar(
                          controller: metaScrollController,
                          child: ScrollConfiguration(
                            behavior: ScrollConfiguration.of(
                              context,
                            ).copyWith(scrollbars: false),
                            child: DetailSelectionScope(child: metaScroll),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              ?composerLayer,
            ],
          ),
        ),
      ),
    );
  }
}

/// Single-column scroll stack shared by both mobile narrow detail and the
/// desktop embedded inspector.
class IllustDetailSingleColumnScroll extends StatelessWidget {
  const IllustDetailSingleColumnScroll({
    super.key,
    required this.entity,
    required this.scrollController,
    required this.slivers,
    required this.onScrollNotification,
    required this.downloadMode,
    required this.onExitDownloadMode,
    required this.forceSelectionArea,
    required this.topChrome,
    required this.topVisiblePage,
    required this.pagesToggleOnScreen,
    required this.canCollapseFromPill,
    required this.onCollapsePages,
  });

  final IllustEntity entity;
  final ScrollController scrollController;
  final List<Widget> slivers;
  final bool Function(ScrollNotification) onScrollNotification;
  final bool downloadMode;
  final VoidCallback onExitDownloadMode;
  final bool forceSelectionArea;
  final double topChrome;
  final ValueListenable<int?> topVisiblePage;
  final ValueListenable<bool> pagesToggleOnScreen;
  final bool canCollapseFromPill;
  final VoidCallback onCollapsePages;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (downloadMode) onExitDownloadMode();
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          NotificationListener<ScrollNotification>(
            onNotification: onScrollNotification,
            child: DetailSelectionScope(
              forceSelectionArea: forceSelectionArea,
              child: SmoothWheelScroll(
                controller: scrollController,
                builder: (context, controller, physics) =>
                    DeferredCacheScrollView(
                      controller: controller,
                      physics: physics,
                      slivers: slivers,
                    ),
              ),
            ),
          ),
          if (!entity.isUgoira && entity.pageCount > 1 && !downloadMode)
            Positioned.fill(
              top: topChrome,
              child: HeroChrome(
                child: ListenableBuilder(
                  listenable: Listenable.merge([
                    topVisiblePage,
                    pagesToggleOnScreen,
                  ]),
                  builder: (context, _) => DetailPageCounter(
                    page: topVisiblePage.value,
                    count: entity.pageCount,
                    onCollapse:
                        canCollapseFromPill && !pagesToggleOnScreen.value
                        ? onCollapsePages
                        : null,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Narrow mobile shell: single-column artwork + metadata scroll with the
/// floating [DetailActionBar] and optional in-place comment composer.
class IllustDetailNarrowShell extends StatelessWidget {
  const IllustDetailNarrowShell({
    super.key,
    required this.entity,
    required this.body,
    required this.barVisibility,
    required this.onDownloadAll,
    required this.composerLayer,
  });

  final IllustEntity entity;
  final Widget body;
  final Animation<double> barVisibility;
  final VoidCallback onDownloadAll;
  final Widget? composerLayer;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        body,
        PositionedDirectional(
          start: 0,
          end: 0,
          bottom: 0,
          child: HeroChrome(
            child: DetailActionBar(
              entity: entity,
              visibility: barVisibility,
              onDownload: onDownloadAll,
            ),
          ),
        ),
        ?composerLayer,
      ],
    );
  }
}

/// Desktop side-inspector shell: pinned inspector header above the
/// single-column artwork + metadata scroll.
class IllustDetailEmbeddedInspectorShell extends StatelessWidget {
  const IllustDetailEmbeddedInspectorShell({
    super.key,
    required this.downloadMode,
    required this.header,
    required this.body,
    required this.composerLayer,
  });

  final bool downloadMode;
  final Widget header;
  final Widget body;
  final Widget? composerLayer;

  @override
  Widget build(BuildContext context) {
    final tokens = FuncSemanticTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(color: tokens.surface),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!downloadMode) ...[
                SelectionContainer.disabled(child: header),
                Divider(height: 1, color: tokens.brandHairline),
              ],
              Expanded(child: body),
            ],
          ),
          ?composerLayer,
        ],
      ),
    );
  }
}

/// Page-selection mode top bar: count, select-all, and download actions.
PreferredSizeWidget buildIllustDetailSelectionAppBar(
  BuildContext context, {
  required int selectedCount,
  required VoidCallback onClose,
  required VoidCallback onSelectAll,
  required VoidCallback? onSubmit,
}) {
  final l10n = context.l10n;
  return selectionAppBar(
    context,
    count: selectedCount,
    onClose: onClose,
    actions: [
      IconButton(
        tooltip: l10n.selectAll,
        onPressed: onSelectAll,
        icon: const Icon(UiIcons.selectAll),
      ),
      IconButton(
        tooltip: l10n.downloadSelectedPages,
        onPressed: onSubmit,
        icon: const Icon(AppIcons.download),
      ),
    ],
  );
}

/// Top bar for the embedded desktop inspector while loading or showing an
/// empty/error state without full detail content.
PreferredSizeWidget buildIllustDetailInspectorAppBar(
  BuildContext context, {
  required IllustEntity? entity,
  required Widget? moreMenu,
  required ValueChanged<IllustEntity>? onOpenFullStage,
  required VoidCallback? onCloseInspector,
}) {
  final l10n = context.l10n;
  final tokens = FuncSemanticTokens.of(context);
  return AppTopBar(
    automaticallyImplyLeading: false,
    titleSpacing: FuncSpacing.lg,
    backgroundColor: tokens.surface,
    title: SelectionContainer.disabled(
      child: Text(
        l10n.illustDetailTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    actions: [
      if (entity != null && onOpenFullStage != null)
        IconButton(
          key: const ValueKey('desktop-inspector-expand'),
          tooltip: l10n.viewerOpenDetail,
          icon: const Icon(AppIcons.expand, size: 18),
          onPressed: () => onOpenFullStage(entity),
        ),
      ?moreMenu,
      if (onCloseInspector != null)
        IconButton(
          key: const ValueKey('desktop-inspector-close'),
          tooltip: l10n.profileShareClose,
          icon: const Icon(UiIcons.close, size: 19),
          onPressed: onCloseInspector,
        ),
    ],
  );
}

/// Builds the artwork page slivers (Ugoira player or lazy multi-page list +
/// expand/collapse toggle) for the single-column detail layout.
List<Widget> buildIllustDetailImageSlivers({
  required IllustEntity entity,
  required IllustFirstImageLayout layout,
  required IllustDetailScrollController scroll,
  required String heroScope,
  required String? heroImageUrl,
  required int? heroImageDecodeWidth,
  required bool detailReady,
  required String? Function(int index) detailUrlFor,
  required bool downloadMode,
  required Set<int>? selectedPages,
  required bool pagesExpanded,
  required ValueChanged<int> onTogglePageSelected,
  required VoidCallback onEnterDownloadMode,
  required VoidCallback onCollapsePages,
  required VoidCallback onExpandPages,
}) {
  final shownPages = layout.shownPages;
  return <Widget>[
    if (layout.statusInset > 0)
      SliverToBoxAdapter(child: SizedBox(height: layout.statusInset)),
    if (entity.isUgoira)
      SliverToBoxAdapter(
        child: TickerPartition(
          child: SelectionContainer.disabled(
            child: UgoiraViewer(
              illustId: entity.id,
              previewUrl: entity.imageUrls.large,
              detailUrl: detailUrlFor(0),
              heroImageUrl: heroImageUrl,
              heroTier: heroImageUrl == null
                  ? null
                  : entity.imageTierOf(heroImageUrl),
              width: entity.width,
              height: entity.height,
              heroTag: illustHeroTag(heroScope, entity.id),
              flightShuttleBuilder: illustHeroFlightShuttleBuilder,
              heroDecodeWidth: heroImageDecodeWidth,
              heroPopUrl: heroImageUrl,
              heroPopDecodeWidth: heroImageDecodeWidth,
              tier: entity.imageTierOf(
                detailUrlFor(0) ?? entity.imageUrls.large,
              ),
            ),
          ),
        ),
      )
    else
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => TickerPartition(
            child: KeyedSubtree(
              key: scroll.keyForPage(index),
              child: Padding(
                padding: index == shownPages - 1
                    ? EdgeInsets.zero
                    : const EdgeInsets.only(bottom: FuncSpacing.sm),
                child: VisibilityDetector(
                  key: ValueKey('illust-visibility-${entity.id}-$index'),
                  onVisibilityChanged: (info) =>
                      scroll.onPageVisibility(index, info),
                  child: SelectionContainer.disabled(
                    child: DetailPageImage(
                      key: ValueKey<Object?>('illust-page-${entity.id}-$index'),
                      entity: entity,
                      index: index,
                      heroTag: index == 0
                          ? illustHeroTag(heroScope, entity.id)
                          : '${illustHeroTag(heroScope, entity.id)}-$index',
                      heroScope: heroScope,
                      heroImageUrl: index == 0 ? heroImageUrl : null,
                      heroImageDecodeWidth: index == 0
                          ? heroImageDecodeWidth
                          : null,
                      detailUrl: detailUrlFor(index),
                      downloadMode: downloadMode,
                      selected: selectedPages?.contains(index) ?? false,
                      onToggleSelect: () => onTogglePageSelected(index),
                      onLongPress: onEnterDownloadMode,
                      placeholderOnly: !detailReady && index > 0,
                      overlayTopInset: index == 0
                          ? layout.artworkUnderBarExtent
                          : 0,
                      imageSlotHeight: index == 0 && layout.slots
                          ? layout.extent
                          : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
          childCount: shownPages,
        ),
      ),
    if (layout.collapsible && !(pagesExpanded && downloadMode))
      SliverToBoxAdapter(
        child: KeyedSubtree(
          key: scroll.pagesToggleKey,
          child: SelectionContainer.disabled(
            child: DetailPagesToggleButton(
              count: entity.pageCount,
              expanded: pagesExpanded,
              onPressed: pagesExpanded ? onCollapsePages : onExpandPages,
            ),
          ),
        ),
      ),
  ];
}

/// Builds the metadata, comments preview, author works, and related works
/// slivers shared by both narrow and two-pane detail layouts.
List<Widget> buildIllustDetailMetaSlivers(
  BuildContext context, {
  required int illustId,
  required IllustEntity entity,
  required GlobalKey infoAnchorKey,
  required bool blockMode,
  required VoidCallback onToggleBlockMode,
  required ValueChanged<CommentComposerInputState> onCompose,
  required bool twoPane,
  required bool embeddedInspector,
}) => [
  for (final (section, readable) in <(Widget, bool)>[
    (
      IllustSeriesSection(
        illustId: illustId,
        outsideSeries: entity.outsideSeries,
      ),
      false,
    ),
    (
      InfoBlock(
        anchorKey: infoAnchorKey,
        entity: entity,
        blockMode: blockMode,
        onToggleBlockMode: onToggleBlockMode,
        showAuthor: !twoPane && !embeddedInspector,
      ),
      true,
    ),
    (CommentsPreviewSlivers(illustId: illustId, onCompose: onCompose), true),
    (AuthorWorksSlivers(entity: entity), false),
    (RelatedIllustsSlivers(illustId: illustId), false),
  ])
    TickerPartition(
      child: readable ? DetailArticleTextWidth(child: section) : section,
    ),
  SliverToBoxAdapter(
    child: SizedBox(
      height: twoPane || embeddedInspector
          ? FuncSpacing.xl
          : DetailActionBar.restingExtent(context) + FuncSpacing.md,
    ),
  ),
];

/// Wraps [child] in [HistoryVisibility] when an account is signed in, scoped
/// to `DetailPageActivity` so prebuilt pager neighbours never record a view.
class IllustDetailHistoryScope extends ConsumerWidget {
  const IllustDetailHistoryScope({
    super.key,
    required this.entity,
    required this.child,
  });

  final IllustEntity entity;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountId = ref.watch(historyAccountIdProvider);
    if (accountId == null) return child;
    final container = ProviderScope.containerOf(context, listen: false);
    final pixivEnabled = ref.watch(pixivHistoryEnabledProvider);
    return Builder(
      builder: (context) => HistoryVisibility(
        active: DetailPageActivity.of(context),
        accountId: accountId,
        contentType: HistoryContentType.illust,
        contentId: entity.id,
        snapshot: snapshotFromIllust(entity),
        localHistoryEnabled: ref.watch(localHistoryEnabledProvider),
        pixivHistoryEnabled: pixivEnabled,
        repository: ref.watch(historyRepositoryProvider),
        remote: pixivEnabled ? ref.watch(pixivHistoryRemoteProvider) : null,
        isAccountCurrent: () =>
            container.read(historyAccountIdProvider) == accountId,
        child: child,
      ),
    );
  }
}
