import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/format/app_format.dart';
import '../../app/motion/app_overlays.dart';
import '../../app/navigation/routes.dart';
import '../../app/widgets/edge_icon_buttons.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/author_summary.dart';
import '../../app/widgets/bookmark_switch_button.dart';
import '../../app/widgets/caption_rich_text.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/inline_translation.dart';
import '../../app/widgets/meta_fact.dart';
import '../../app/widgets/person_card.dart';
import '../../app/widgets/tag_actions_sheet.dart';
import '../../app/widgets/tag_chips.dart';
import '../../core/auth/account_store.dart';
import '../../core/entity/illust_caption.dart';
import '../../core/errors/no_retry.dart';
import '../../core/history/history_models.dart';
import '../../core/history/history_repository.dart';
import '../../core/history/history_snapshot.dart';
import '../../core/history/history_visibility.dart';
import '../../core/log.dart';
import '../../core/mute/mute_store.dart';
import '../../core/network/api_error.dart';
import '../../core/network/pixiv_http_client.dart';
import '../../core/novel/novel_entity.dart';
import '../../core/novel/novel_repository.dart';
import '../../core/novel/novel_store.dart';
import '../../core/novel/reader_settings.dart';
import '../../core/search/search_models.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/share/share_service.dart';
import '../../l10n/context.dart';
import 'novel_layout.dart';
import 'novel_reader.dart';
import 'novel_reader_stage.dart';
import '../../app/theme/func_semantic_tokens.dart';

final _novelDetailProvider = FutureProvider.autoDispose
    .family<NovelEntity, int>((ref, novelId) async {
      // Account-scoped like the store it fills: a switch refetches, and the
      // previous account's late payload stays out of the reused NovelStore.
      ref.watch(
        accountStoreProvider.select((async) => async.value?.current?.id),
      );
      final claim = AccountClaim(ref);
      final token = CancelToken();
      ref.onDispose(token.cancel);
      final repository = ref.read(novelRepositoryProvider);
      final entity = await repository.fetchDetail(novelId, cancelToken: token);
      if (claim.holds) {
        ref.read(novelStoreProvider.notifier).mergeAll([entity]);
      }
      return entity;
    }, retry: noRetry);

class NovelPage extends ConsumerWidget {
  const NovelPage({super.key, required this.novelId, this.atPixivPage});

  final int novelId;

  /// Opens at this Pixiv page (1-based) before the saved place: the
  /// account's bookmark, from the bookmark list.
  final int? atPixivPage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_novelDetailProvider(novelId));
    return Scaffold(
      body: async.when(
        loading: () => NovelStatusScaffold(
          child: NovelPageSkeleton(label: context.l10n.novelLoading),
        ),
        error: (error, _) {
          final isNotFound = error is ApiHttpError && error.statusCode == 404;
          return NovelStatusScaffold(
            child: FeedError(
              title: isNotFound
                  ? context.l10n.novelNotFound
                  : context.l10n.novelLoadFailed,
              error: error,
              retryLabel: context.l10n.novelRetry,
              onRetry: () => ref.invalidate(_novelDetailProvider(novelId)),
            ),
          );
        },
        data: (novel) {
          if (novel.isRestricted) {
            return NovelStatusScaffold(
              child: FeedEmpty(
                icon: Icons.lock_outline,
                title: context.l10n.novelRestricted,
              ),
            );
          }
          if (!novel.contentAvailable) {
            return NovelStatusScaffold(
              child: FeedEmpty(
                icon: Icons.text_snippet_outlined,
                title: context.l10n.novelContentUnavailable,
              ),
            );
          }
          return NovelReaderStage(spec: _onlineSpec(context, ref, novel));
        },
      ),
    );
  }

  /// Online spec: share/bookmark actions, the work-info sheet, history
  /// tracking around the body and the account-scoped progress store.
  NovelReaderStageSpec _onlineSpec(
    BuildContext context,
    WidgetRef ref,
    NovelEntity novel,
  ) {
    return NovelReaderStageSpec(
      novel: novel,
      titleBlock: NovelTitleBlock(
        title: novel.title,
        byline: [novel.user.name, ?novel.seriesTitle].join(' · '),
      ),
      topActions: [
        IconButton(
          tooltip: context.l10n.cardActionShare,
          onPressed: () => _shareNovel(context, ref, novel),
          icon: const Icon(Icons.share_outlined),
        ),
        BookmarkSwitchButton(
          illustId: novel.id,
          title: novel.title,
          isNovel: true,
        ),
      ],
      onImageTap: (context, image) => _openIllustration(context, ref, image),
      onLinkTap: (context, uri) => openPixivLink(context, ref, '$uri'),
      infoTooltip: context.l10n.novelInfoTitle,
      infoSheet: (sheetContext) => _novelInfoSheet(sheetContext, ref, novel),
      progress: _NovelProgressBinding(
        ProviderScope.containerOf(context, listen: false),
        novel.id,
        atPixivPage: atPixivPage,
      ),
      marker: _markerBinding(ref, novel.id),
      bodyWrapper: (context, anchor, child) =>
          _NovelHistoryVisibility(novel: novel, anchor: anchor, child: child),
    );
  }

  /// The account's bookmark of the novel; a guest has none.
  NovelMarkerBinding? _markerBinding(WidgetRef ref, int novelId) {
    final hasAccount = ref.read(
      accountStoreProvider.select((a) => a.value?.usableCurrent != null),
    );
    if (!hasAccount) return null;
    final writes = ref.read(novelMarkerWritesProvider.notifier);
    return NovelMarkerBinding(
      page: novelStoreProvider.select((novels) => novels[novelId]?.markerPage),
      pending: novelMarkerWritesProvider.select(
        (pending) => pending.contains(novelId),
      ),
      write: (page) => writes.write(novelId, page),
    );
  }

  /// A Pixiv work opens in its own viewer at the marker's page; an image
  /// the author uploaded opens alone.
  void _openIllustration(
    BuildContext context,
    WidgetRef ref,
    NovelImageLoadRequest image,
  ) {
    switch (image.source) {
      case NovelImageSource.pixiv:
        unawaited(
          openIllustViewer(
            context,
            illustId: image.illustId!,
            page: (image.page ?? 1) - 1,
            quality: ref.read(viewQualityProvider),
          ),
        );
      case NovelImageSource.uploaded:
        unawaited(openNovelImage(context, novelId, image.identifier));
    }
  }

  Future<void> _shareNovel(
    BuildContext context,
    WidgetRef ref,
    NovelEntity novel,
  ) async {
    final outcome = await ref
        .read(shareServiceProvider)
        .share(
          SharePayload.novel(
            id: novel.id,
            title: novel.title,
            author: novel.user.name,
          ),
          sharePositionOrigin: shareOriginOf(context),
        );
    if (outcome == ShareOutcome.copiedToClipboard && context.mounted) {
      showAppSnackBar(context, context.l10n.linkCopied);
    }
  }

  Widget _novelInfoSheet(
    BuildContext sheetContext,
    WidgetRef ref,
    NovelEntity novel,
  ) {
    // Same close-then-navigate sequence as the author chip. Tag searches
    // start from the persisted novel defaults like every other entry.
    void searchTag(String tag) {
      Navigator.of(sheetContext).pop();
      unawaited(
        openSearchResults(
          sheetContext,
          NovelSearchQuery(
            keyword: tag,
            filters: ref.read(searchNovelFiltersProvider),
          ),
        ),
      );
    }

    // The same entries as the long-press panel, beside the pointer on a
    // PC (R11).
    void showTagActions(NovelTag tag, {Offset? position}) {
      final muted = ref.read(muteStoreProvider).tags.contains(tag.name);
      unawaited(
        showTagActionsSheet(
          sheetContext,
          tag: tag.name,
          muted: muted,
          position: position,
          onSearch: () => searchTag(tag.name),
          onToggleMute: () => unawaited(
            toggleTagMute(
              sheetContext,
              ref.read(muteStoreProvider.notifier),
              tag.name,
              muted: muted,
            ),
          ),
        ),
      );
    }

    Widget buildInfoList(
      BuildContext listContext, {
      ScrollController? controller,
      required EdgeInsetsGeometry padding,
    }) => ListView(
      controller: controller,
      padding: padding,
      children: [
        _NovelIntro(
          novel: novel,
          // The sheet closes before the profile opens. The sheet is the
          // card tier already, so the card takes the next one up.
          author: PersonCard(
            color: Theme.of(listContext).colorScheme.surfaceContainerHigh,
            tapHint: listContext.l10n.openAuthorProfile,
            onTap: () {
              Navigator.of(sheetContext).pop();
              unawaited(openUser(listContext, novel.user.id));
            },
            child: AuthorSummary(
              name: novel.user.name,
              account: novel.user.account.isEmpty
                  ? null
                  : '@${novel.user.account}',
              imageUrl: novel.user.profileImageUrl,
              avatarRadius: 20,
            ),
          ),
          series: switch ((novel.seriesId, novel.seriesTitle)) {
            (final seriesId?, final title?) when title.isNotEmpty =>
              _SeriesLink(
                title: title,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(openNovelSeries(listContext, seriesId));
                },
              ),
            _ => null,
          },
        ),
        if (novel.tags.isNotEmpty) ...[
          const SizedBox(height: FuncSpacing.md),
          TagChips(
            children: [
              for (final tag in novel.tags)
                TagChip(
                  label: tag.name,
                  translated: tag.translatedName,
                  onTap: () => searchTag(tag.name),
                  onLongPress: () => showTagActions(tag),
                  onSecondaryTapAt: (position) =>
                      showTagActions(tag, position: position),
                ),
            ],
          ),
        ],
        const SizedBox(height: FuncSpacing.sm),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            style: startEdgeTextButtonStyle(),
            onPressed: () {
              Navigator.of(sheetContext).pop();
              unawaited(openNovelComments(listContext, novel.id));
            },
            icon: const Icon(Icons.comment_outlined),
            label: Text(
              novel.totalComments > 0
                  ? listContext.l10n.commentTitleCount(
                      AppFormat.count(listContext, novel.totalComments),
                    )
                  : listContext.l10n.commentTitle,
            ),
          ),
        ),
      ],
    );

    if (useWideOverlay(sheetContext)) {
      return SafeArea(
        child: buildInfoList(
          sheetContext,
          padding: const EdgeInsets.all(FuncSpacing.xl),
        ),
      );
    }
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.5,
      maxChildSize: 0.9,
      builder: (context, controller) => buildInfoList(
        context,
        controller: controller,
        padding: const EdgeInsets.fromLTRB(
          FuncSpacing.xl,
          0,
          FuncSpacing.xl,
          FuncSpacing.xl,
        ),
      ),
    );
  }
}

/// Account-scoped progress persistence: `NovelProgressStore` keyed by
/// `<accountId>:<novelId>`. The account is resolved per call so a switch
/// mid-session never writes into the previous account's map.
class _NovelProgressBinding implements ReaderProgressBinding {
  const _NovelProgressBinding(
    this._container,
    this._novelId, {
    this.atPixivPage,
  });

  final ProviderContainer _container;
  final int _novelId;

  /// Opened from the bookmark list: this page comes before the saved place.
  final int? atPixivPage;

  String? get _accountId => _container.read(
    accountStoreProvider.select((a) => a.value?.usableCurrent?.id),
  );

  @override
  Future<NovelAnchor?> load() async {
    final accountId = _accountId;
    if (accountId != null) _recordSeries(accountId);
    final asked = _pageStart(atPixivPage);
    if (asked != null) return asked;
    if (accountId == null) return null;
    final saved = await _container
        .read(novelProgressStoreProvider)
        .read(accountId, _novelId);
    if (saved != null) {
      return NovelAnchor(paragraphId: saved.paragraphId, offset: saved.offset);
    }
    // No place of this account's own: the account's bookmark.
    return _pageStart(
      _container.read(novelStoreProvider)[_novelId]?.markerPage,
    );
  }

  /// Opening a novel of a series makes it the series' last read, for the
  /// series page's 「继续」. Fire-and-forget: a lost record only hides the
  /// button, but a broken store is logged.
  void _recordSeries(String accountId) {
    final seriesId = _container.read(novelStoreProvider)[_novelId]?.seriesId;
    if (seriesId == null) return;
    unawaited(
      _container
          .read(novelSeriesLastReadStoreProvider)
          .write(accountId, seriesId, _novelId)
          .then(
            (_) => _container.invalidate(novelSeriesLastReadProvider(seriesId)),
          )
          .catchError((Object error, _) {
            log('novel series last read not remembered: $error');
          }),
    );
  }

  /// The first line of Pixiv [page], if the novel still has that page.
  NovelAnchor? _pageStart(int? page) {
    if (page == null || page < 1) return null;
    final starts =
        _container
            .read(novelStoreProvider)[_novelId]
            ?.markup
            ?.pixivPageStarts ??
        const <String>[];
    if (page > starts.length) return null;
    return NovelAnchor(paragraphId: starts[page - 1], offset: 0);
  }

  @override
  Future<void> save(NovelAnchor anchor) {
    final accountId = _accountId;
    if (accountId == null) return Future.value();
    return _container
        .read(novelProgressStoreProvider)
        .write(
          accountId,
          _novelId,
          paragraphId: anchor.paragraphId,
          offset: anchor.offset,
        );
  }
}

/// Wraps the reader body in `HistoryVisibility` when an account is active;
/// the live anchor feeds the snapshot so resuming from history lands on
/// the last page. Lives in a real widget because the provider watches must
/// hang on a building element.
class _NovelHistoryVisibility extends ConsumerWidget {
  const _NovelHistoryVisibility({
    required this.novel,
    required this.anchor,
    required this.child,
  });

  final NovelEntity novel;
  final NovelAnchor? anchor;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final container = ProviderScope.containerOf(context, listen: false);
    final accountId = ref.watch(historyAccountIdProvider);
    if (accountId == null) return child;
    final pixivEnabled = ref.watch(pixivHistoryEnabledProvider);
    return HistoryVisibility(
      accountId: accountId,
      contentType: HistoryContentType.novel,
      contentId: novel.id,
      snapshot: snapshotFromNovel(
        novel,
        anchorParagraphId: anchor?.paragraphId,
        anchorOffset: anchor?.offset,
      ),
      localHistoryEnabled: ref.watch(localHistoryEnabledProvider),
      pixivHistoryEnabled: pixivEnabled,
      repository: ref.watch(historyRepositoryProvider),
      remote: pixivEnabled ? ref.watch(pixivHistoryRemoteProvider) : null,
      isAccountCurrent: () =>
          container.read(historyAccountIdProvider) == accountId,
      child: child,
    );
  }
}

/// The head of the novel info sheet: title with the translate button,
/// author, the facts line, caption, then the translation of title and
/// caption.
class _NovelIntro extends ConsumerStatefulWidget {
  const _NovelIntro({required this.novel, required this.author, this.series});

  final NovelEntity novel;
  final Widget author;

  /// The link to the novel's series, when it has one.
  final Widget? series;

  @override
  ConsumerState<_NovelIntro> createState() => _NovelIntroState();
}

class _NovelIntroState extends ConsumerState<_NovelIntro>
    with InlineTranslation {
  @override
  Widget build(BuildContext context) {
    final novel = widget.novel;
    final caption = captionPlainText(novel.caption);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                novel.title,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            TranslateIconButton(
              translating: translating,
              shown: translationShown,
              onPressed: () => unawaited(
                toggleTranslation([
                  novel.title,
                  if (caption.isNotEmpty) caption,
                ]),
              ),
            ),
          ],
        ),
        const SizedBox(height: FuncSpacing.sm),
        widget.author,
        if (widget.series case final series?) ...[
          const SizedBox(height: FuncSpacing.xs),
          series,
          const SizedBox(height: FuncSpacing.xs),
        ] else
          const SizedBox(height: FuncSpacing.md),
        _NovelFacts(novel: novel),
        if (novel.caption.isNotEmpty) ...[
          const SizedBox(height: FuncSpacing.md),
          // Caption HTML renders through the shared parser — <br> tags
          // become real line breaks and links stay clickable.
          CaptionRichText(caption: novel.caption),
        ],
        TranslationPanel(
          translating: translating,
          translations: translations,
          failure: translationFailure,
          emphasizeFirst: true,
        ),
      ],
    );
  }
}

/// The novel's series under its author, as the author is: one button with
/// a chevron, opening the series' page.
class _SeriesLink extends StatelessWidget {
  const _SeriesLink({required this.title, required this.onTap});

  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final variant = theme.colorScheme.onSurfaceVariant;
    return Semantics(
      container: true,
      button: true,
      label: l10n.labelValue(l10n.novelSeries, title),
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        key: const Key('novel-info-series'),
        onTap: onTap,
        borderRadius: FuncShape.control,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: kMinInteractiveDimension,
          ),
          child: Row(
            children: [
              Icon(Icons.library_books_outlined, size: 20, color: variant),
              const SizedBox(width: FuncSpacing.sm),
              Flexible(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(Icons.chevron_right, size: 20, color: variant),
            ],
          ),
        ),
      ),
    );
  }
}

/// The novel's facts, each behind its glyph, wrapping as whole facts: its
/// length, views, bookmarks and the full posting time. Screen readers hear
/// one node. Its series is a link above them ([_SeriesLink]).
class _NovelFacts extends StatelessWidget {
  const _NovelFacts({required this.novel});

  final NovelEntity novel;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final style = MetaFact.styleOf(context);
    final views = AppFormat.count(context, novel.totalView);
    final bookmarks = AppFormat.count(context, novel.totalBookmarks);
    final created = DateTime.tryParse(novel.createDate ?? '');
    final date = created == null
        ? null
        : AppFormat.date(context, created, withTime: true);
    return MergeSemantics(
      key: const Key('novel-info-facts'),
      child: Wrap(
        spacing: FuncSpacing.md,
        runSpacing: FuncSpacing.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          MetaFact(
            icon: Icons.notes,
            text:
                '${AppFormat.count(context, novel.textLength)} '
                '${l10n.novelWords}',
            style: style,
          ),
          Semantics(
            label: date == null
                ? l10n.detailMetaCountsSemantics(views, bookmarks)
                : l10n.detailStatsSemantics(views, bookmarks, date),
            child: ExcludeSemantics(
              child: MetaFact(
                icon: Icons.visibility_outlined,
                text: views,
                style: style,
              ),
            ),
          ),
          ExcludeSemantics(
            child: MetaFact(
              icon: Icons.favorite_outline,
              text: bookmarks,
              style: style,
            ),
          ),
          if (date != null) ExcludeSemantics(child: Text(date, style: style)),
        ],
      ),
    );
  }
}
