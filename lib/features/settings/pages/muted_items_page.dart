import 'dart:async';
import 'dart:ui';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/motion/removal.dart';
import '../../../app/navigation/routes.dart';
import '../../../app/person_avatar.dart';
import '../../../app/pixiv_image.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/widgets/app_top_bar.dart';
import '../../../app/widgets/errors/error_details.dart';
import '../../../app/widgets/settings/settings_group.dart';
import '../../../app/widgets/settings/settings_group_content.dart';
import '../../../app/widgets/unmute_undo.dart';
import '../../../core/entity/illust_store.dart';
import '../../../core/mute/mute_models.dart';
import '../../../core/mute/mute_store.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';

/// Muted items management: tags and users mirror the official client's
/// `/v1/mute` list; works are local-only (no official endpoint). Removing
/// an entry sends the matching `mute/edit` delete and rolls back on
/// failure — the row reappears and the error is surfaced. An empty author
/// or work group says where those mutes are made.
class MutedItemsPage extends ConsumerStatefulWidget {
  const MutedItemsPage({super.key});

  @override
  ConsumerState<MutedItemsPage> createState() => _MutedItemsPageState();
}

class _MutedItemsPageState extends ConsumerState<MutedItemsPage> {
  late final TextEditingController _controller;
  final _removals = RemovalController();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The row leaves first, then the unmute is sent; a failed write brings
  /// the row back with the error, a landed one offers Undo. User and work
  /// unmutes pass the removed [user] or [work] so Undo can mute it again.
  Future<void> _unmute(
    MuteKey key,
    Future<void> Function() action, {
    MutedUser? user,
    MutedWork? work,
  }) async {
    await _removals.playExit([key]);
    try {
      await action();
      if (mounted) showUnmuteUndo(context, key, user: user, work: work);
    } on Object catch (error) {
      _removals.restore([key]);
      if (mounted) {
        showErrorSnackBar(
          context,
          action: context.l10n.muteFailed,
          error: error,
        );
      }
    }
  }

  Future<void> _addTag(String value) async {
    final tag = value.trim();
    if (tag.isEmpty) return;
    final store = ref.read(muteStoreProvider.notifier);
    if (ref.read(muteStoreProvider).isTagMuted(tag)) return;
    try {
      await store.toggleTag(tag);
      if (mounted) _controller.clear();
    } on Object catch (error) {
      if (mounted) {
        showErrorSnackBar(
          context,
          action: context.l10n.muteFailed,
          error: error,
        );
      }
    }
  }

  /// Unmute affordance (D6): the visibility icon reads as "show again";
  /// while the write is in flight the slot shows a spinner instead of a
  /// dead disabled button so the pending state is visible.
  Widget _unmuteTrailing({
    required bool pending,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    if (pending) {
      return const SizedBox(
        width: 24,
        height: 24,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return IconButton(
      icon: const Icon(Icons.visibility_outlined),
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = ref.watch(muteStoreProvider);
    final store = ref.read(muteStoreProvider.notifier);
    final tags = state.tags.toList()..sort();
    final users = state.users.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final works = state.works.values.toList()
      ..sort((a, b) => a.illustId.compareTo(b.illustId));
    // Works muted before titles were kept fall back to a loaded copy.
    final illusts = ref.watch(illustStoreProvider);
    return Scaffold(
      appBar: AppTopBar(title: Text(l10n.mutedItemsSettings)),
      body: RemovalScope(
        controller: _removals,
        child: settingsNarrowBody(
          ListView(
            padding: const EdgeInsets.only(
              top: FuncSpacing.sm,
              bottom: FuncSpacing.xl,
            ),
            children: [
              SettingsGroup(
                title: Text(l10n.mutedTagsSection),
                children: [
                  SettingsGroupContent(
                    child: TextField(
                      controller: _controller,
                      decoration: InputDecoration(
                        labelText: l10n.muteTagInputHint,
                        suffixIcon: IconButton(
                          tooltip: l10n.add,
                          icon: const Icon(Icons.add),
                          onPressed: () => _addTag(_controller.text),
                        ),
                      ),
                      onSubmitted: _addTag,
                    ),
                  ),
                  for (final tag in tags)
                    Removable(
                      id: MuteKey.tag(tag),
                      child: ListTile(
                        dense: true,
                        title: Text(tag),
                        onTap: () => openTagSearch(context, tag),
                        trailing: _unmuteTrailing(
                          pending: state.pending.contains(MuteKey.tag(tag)),
                          tooltip: l10n.unmuteTag,
                          onPressed: () => unawaited(
                            _unmute(
                              MuteKey.tag(tag),
                              () => store.toggleTag(tag),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              SettingsGroup(
                title: Text(l10n.mutedUsersSection),
                children: [
                  if (users.isEmpty)
                    _EmptyHint(l10n.muteEmptyHint(l10n.muteAuthor)),
                  for (final user in users)
                    Removable(
                      id: MuteKey.user(user.userId),
                      child: ListTile(
                        leading: PersonAvatar(
                          imageUrl: user.profileImageUrl,
                          radius: 20,
                        ),
                        title: Text(user.name),
                        subtitle: user.account == null
                            ? null
                            : Text('@${user.account}'),
                        onTap: () => openUser(context, user.userId),
                        trailing: _unmuteTrailing(
                          pending: state.pending.contains(
                            MuteKey.user(user.userId),
                          ),
                          tooltip: l10n.unmuteAuthor,
                          onPressed: () => unawaited(
                            _unmute(
                              MuteKey.user(user.userId),
                              () => store.toggleUser(user),
                              user: user,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              SettingsGroup(
                title: Text(l10n.mutedWorksSection),
                children: [
                  if (works.isEmpty)
                    _EmptyHint(l10n.muteEmptyHint(l10n.muteWork)),
                  for (final work in works)
                    Removable(
                      id: MuteKey.work(work.illustId),
                      child: ListTile(
                        leading: _MutedThumbnail(
                          url:
                              work.thumbnailUrl ??
                              illusts
                                  .get(work.illustId)
                                  ?.imageUrls
                                  .squareMedium,
                        ),
                        title: Text(
                          work.title ??
                              illusts.get(work.illustId)?.title ??
                              '#${work.illustId}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => openIllust(context, work.illustId),
                        trailing: _unmuteTrailing(
                          pending: state.pending.contains(
                            MuteKey.work(work.illustId),
                          ),
                          tooltip: l10n.unmuteWork,
                          onPressed: () => unawaited(
                            _unmute(
                              MuteKey.work(work.illustId),
                              () => store.unmuteWork(work.illustId),
                              work: work,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The one row of an empty group: where its mutes come from. Not a
/// button — the action lives on the cards.
class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SettingsGroupContent(
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A muted work's square thumbnail, blurred like its card ([MutedCover]):
/// the user muted it, so the list does not show it plainly either. Works
/// muted before thumbnails were kept get a placeholder.
class _MutedThumbnail extends StatelessWidget {
  const _MutedThumbnail({required this.url});

  final String? url;

  static const double _size = 48;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = this.url;
    return ClipRRect(
      borderRadius: FuncShape.control,
      child: SizedBox.square(
        dimension: _size,
        child: url == null
            ? ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: Icon(
                  Icons.image_outlined,
                  color: scheme.onSurfaceVariant,
                ),
              )
            : ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: PixivImage(
                  url: url,
                  width: _size,
                  height: _size,
                  memCacheWidth: PixivImage.decodeWidthFor(_size),
                ),
              ),
      ),
    );
  }
}
