import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/navigation/routes.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/author_summary.dart';
import '../../app/widgets/bookmark_switch_button.dart';
import '../../app/widgets/caption_rich_text.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/tag_chips.dart';
import '../../core/auth/account_store.dart';
import '../../core/history/history_models.dart';
import '../../core/history/history_repository.dart';
import '../../core/history/history_snapshot.dart';
import '../../core/history/history_visibility.dart';
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
import 'novel_reader_stage.dart';

final _novelDetailProvider = FutureProvider.autoDispose
    .family<NovelEntity, int>((ref, novelId) async {
      final token = CancelToken();
      ref.onDispose(token.cancel);
      final repository = ref.read(novelRepositoryProvider);
      final entity = await repository.fetchDetail(novelId, cancelToken: token);
      ref.read(novelStoreProvider.notifier).mergeAll([entity]);
      return entity;
    });

class NovelPage extends ConsumerWidget {
  const NovelPage({super.key, required this.novelId});

  final int novelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_novelDetailProvider(novelId));
    return Scaffold(
      body: async.when(
        loading: () => NovelStatusScaffold(
          child: FeedEmpty(
            icon: Icons.menu_book_outlined,
            title: context.l10n.novelLoading,
          ),
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
          return NovelReaderStage(spec: _onlineSpec(context, novel));
        },
      ),
    );
  }

  /// Online spec: share/bookmark actions, the work-info sheet, history
  /// tracking around the body and the account-scoped progress store.
  NovelReaderStageSpec _onlineSpec(BuildContext context, NovelEntity novel) {
    return NovelReaderStageSpec(
      novel: novel,
      topActions: [
        IconButton(
          tooltip: context.l10n.cardActionShare,
          onPressed: () => _shareNovel(context, novel),
          icon: const Icon(Icons.share_outlined),
        ),
        BookmarkSwitchButton(
          illustId: novel.id,
          title: novel.title,
          isNovel: true,
        ),
      ],
      infoTooltip: context.l10n.novelInfoTitle,
      infoSheet: (sheetContext) => _novelInfoSheet(sheetContext, novel),
      progress: _NovelProgressBinding(
        ProviderScope.containerOf(context, listen: false),
        novel.id,
      ),
      bodyWrapper: (context, anchor, child) =>
          _NovelHistoryVisibility(novel: novel, anchor: anchor, child: child),
    );
  }

  Future<void> _shareNovel(BuildContext context, NovelEntity novel) async {
    final outcome = await ProviderScope.containerOf(context, listen: false)
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

  Widget _novelInfoSheet(BuildContext sheetContext, NovelEntity novel) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.5,
      maxChildSize: 0.9,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Text(novel.title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          AuthorSummary(
            name: novel.user.name,
            imageUrl: novel.user.profileImageUrl,
            avatarRadius: 16,
            compact: true,
            onTap: () {
              Navigator.of(sheetContext).pop();
              openUser(context, novel.user.id);
            },
          ),
          if (novel.caption.isNotEmpty) ...[
            const SizedBox(height: 12),
            // Caption HTML renders through the shared parser — <br> tags
            // become real line breaks and links stay clickable.
            CaptionRichText(caption: novel.caption),
          ],
          if (novel.tags.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              children: [
                for (final tag in novel.tags)
                  TagChip(
                    label: tag.name,
                    translated: tag.translatedName,
                    onTap: () {
                      // Same close-then-navigate sequence as the author
                      // chip above.
                      Navigator.of(sheetContext).pop();
                      openSearchResults(
                        context,
                        NovelSearchQuery(keyword: tag.name),
                      );
                    },
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () {
                Navigator.of(sheetContext).pop();
                openNovelComments(context, novel.id);
              },
              icon: const Icon(Icons.comment_outlined),
              label: Text(
                novel.totalComments > 0
                    ? '${context.l10n.commentTitle} (${novel.totalComments})'
                    : context.l10n.commentTitle,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Account-scoped progress persistence: `NovelProgressStore` keyed by
/// `<accountId>:<novelId>`. The account is resolved per call so a switch
/// mid-session never writes into the previous account's map.
class _NovelProgressBinding implements ReaderProgressBinding {
  const _NovelProgressBinding(this._container, this._novelId);

  final ProviderContainer _container;
  final int _novelId;

  String? get _accountId => _container.read(
    accountStoreProvider.select((a) => a.value?.usableCurrent?.id),
  );

  @override
  Future<NovelAnchor?> load() async {
    final accountId = _accountId;
    if (accountId == null) return null;
    final saved = await _container
        .read(novelProgressStoreProvider)
        .read(accountId, _novelId);
    if (saved == null) return null;
    return NovelAnchor(paragraphId: saved.paragraphId, offset: saved.offset);
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
      isAccountCurrent: () => ref.read(historyAccountIdProvider) == accountId,
      child: child,
    );
  }
}
