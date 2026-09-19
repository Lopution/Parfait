import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/bookmark/bookmark_actions.dart';
import '../../../core/bookmark/bookmark_models.dart';
import '../../../core/bookmark/bookmark_store.dart';
import '../../../core/entity/illust_entity.dart';
import '../../../core/illust/illust_download_controller.dart';
import '../../../core/mute/mute_models.dart';
import '../../../core/mute/mute_store.dart';
import '../../../core/share/share_service.dart';
import '../../../core/watchlater/watch_later_store.dart';
import '../../../l10n/app_localizations.dart';
import '../../../l10n/context.dart';
import '../app_snack_bar.dart';
import 'card_action.dart';

/// Ordered card long-press actions. Each domain contributes a thin adapter;
/// the mute-system child appends its block entries here without touching
/// the card or sheet code (registered slot per parent design §2).
final illustCardActionsProvider = Provider<List<CardAction>>((ref) {
  return const [
    _BookmarkAction(),
    _DownloadAction(),
    _WatchLaterAction(),
    _MuteWorkAction(),
    _MuteUserAction(),
    _ShareAction(),
  ];
});

BookmarkKey _illustKey(IllustEntity entity) =>
    BookmarkKey(BookmarkEntityType.illust, entity.id);

class _BookmarkAction extends CardAction {
  const _BookmarkAction();

  @override
  String get id => 'bookmark';

  @override
  IconData iconFor(WidgetRef ref, IllustEntity entity) {
    final bookmarked = ref.watch(
      bookmarkStoreProvider.select(
        (s) => s[_illustKey(entity)]?.bookmarked ?? false,
      ),
    );
    return bookmarked ? Icons.favorite : Icons.favorite_border;
  }

  @override
  String labelFor(WidgetRef ref, IllustEntity entity, AppLocalizations l10n) {
    final bookmarked = ref.watch(
      bookmarkStoreProvider.select(
        (s) => s[_illustKey(entity)]?.bookmarked ?? false,
      ),
    );
    return bookmarked ? l10n.cardActionUnbookmark : l10n.cardActionBookmark;
  }

  @override
  Future<void> run(BuildContext context, WidgetRef ref, IllustEntity entity) {
    return ref.read(bookmarkActionsProvider).toggle(_illustKey(entity));
  }
}

class _DownloadAction extends CardAction {
  const _DownloadAction();

  @override
  String get id => 'download';

  @override
  IconData iconFor(WidgetRef ref, IllustEntity entity) =>
      Icons.file_download_outlined;

  @override
  String labelFor(WidgetRef ref, IllustEntity entity, AppLocalizations l10n) =>
      l10n.cardActionDownload;

  @override
  Future<void> run(
    BuildContext context,
    WidgetRef ref,
    IllustEntity entity,
  ) async {
    try {
      await ref.read(illustDownloadControllerProvider).downloadAll(entity);
      if (context.mounted) {
        showAppSnackBar(context, context.l10n.downloadQueuedMessage);
      }
    } catch (error) {
      if (context.mounted) {
        showAppSnackBar(
          context,
          context.l10n.downloadSubmissionFailed(error.toString()),
        );
      }
    }
  }
}

class _WatchLaterAction extends CardAction {
  const _WatchLaterAction();

  @override
  String get id => 'watch-later';

  @override
  IconData iconFor(WidgetRef ref, IllustEntity entity) {
    final saved = _saved(ref, entity);
    return saved ? Icons.bookmark : Icons.bookmark_border;
  }

  @override
  String labelFor(WidgetRef ref, IllustEntity entity, AppLocalizations l10n) {
    return _saved(ref, entity)
        ? l10n.cardActionRemoveWatchLater
        : l10n.cardActionWatchLater;
  }

  @override
  Future<void> run(
    BuildContext context,
    WidgetRef ref,
    IllustEntity entity,
  ) async {
    final store = ref.read(watchLaterStoreProvider.notifier);
    if (_saved(ref, entity)) {
      await store.remove(entity.id);
    } else {
      final added = await store.add(entity);
      if (added && context.mounted) {
        showAppSnackBar(context, context.l10n.watchLaterAdded);
      }
    }
  }

  bool _saved(WidgetRef ref, IllustEntity entity) {
    return ref.watch(
      watchLaterStoreProvider.select(
        (async) => (async.value ?? const []).any(
          (entry) => entry.entity.id == entity.id,
        ),
      ),
    );
  }
}

/// Single-work mute stays local (no official endpoint); failures from the
/// server-backed user/tag edits roll back in the store and surface here.
class _MuteWorkAction extends CardAction {
  const _MuteWorkAction();

  @override
  String get id => 'mute-work';

  bool _muted(WidgetRef ref, IllustEntity entity) =>
      ref.watch(muteStoreProvider.select((s) => s.isWorkMuted(entity.id)));

  @override
  IconData iconFor(WidgetRef ref, IllustEntity entity) => _muted(ref, entity)
      ? Icons.visibility_off
      : Icons.visibility_off_outlined;

  @override
  String labelFor(WidgetRef ref, IllustEntity entity, AppLocalizations l10n) =>
      _muted(ref, entity) ? l10n.unmuteWork : l10n.muteWork;

  @override
  Future<void> run(
    BuildContext context,
    WidgetRef ref,
    IllustEntity entity,
  ) async {
    try {
      await ref.read(muteStoreProvider.notifier).toggleWork(entity.id);
    } catch (error) {
      if (context.mounted) {
        showAppSnackBar(context, context.l10n.muteFailed('$error'));
      }
    }
  }
}

class _MuteUserAction extends CardAction {
  const _MuteUserAction();

  @override
  String get id => 'mute-user';

  bool _muted(WidgetRef ref, IllustEntity entity) =>
      ref.watch(muteStoreProvider.select((s) => s.isUserMuted(entity.user.id)));

  @override
  IconData iconFor(WidgetRef ref, IllustEntity entity) =>
      _muted(ref, entity) ? Icons.person_off : Icons.person_off_outlined;

  @override
  String labelFor(WidgetRef ref, IllustEntity entity, AppLocalizations l10n) =>
      _muted(ref, entity) ? l10n.unmuteAuthor : l10n.muteAuthor;

  @override
  Future<void> run(
    BuildContext context,
    WidgetRef ref,
    IllustEntity entity,
  ) async {
    try {
      await ref
          .read(muteStoreProvider.notifier)
          .toggleUser(
            MutedUser(
              userId: entity.user.id,
              name: entity.user.name,
              account: entity.user.account,
              profileImageUrl: entity.user.profileImageUrl,
            ),
          );
    } catch (error) {
      if (context.mounted) {
        showAppSnackBar(context, context.l10n.muteFailed('$error'));
      }
    }
  }
}

class _ShareAction extends CardAction {
  const _ShareAction();

  @override
  String get id => 'share';

  @override
  IconData iconFor(WidgetRef ref, IllustEntity entity) => Icons.share_outlined;

  @override
  String labelFor(WidgetRef ref, IllustEntity entity, AppLocalizations l10n) =>
      l10n.cardActionShare;

  /// Opens the platform share sheet (Shaft-parity payload); on platforms
  /// without one the service falls back to the clipboard and we confirm the
  /// copy with a snackbar so the action is never silent.
  @override
  Future<void> run(
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
}
