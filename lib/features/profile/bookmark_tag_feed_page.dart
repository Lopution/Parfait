import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/widgets/feed/desktop_inspectable_gallery.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../core/auth/account_store.dart';
import '../../core/bookmark/bookmark_models.dart';
import '../../core/profile/profile_models.dart';
import '../../core/user/user_repository.dart';
import '../../l10n/context.dart';
import 'profile_illust_feed.dart';
import 'profile_novel_feed.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/icons/app_icons.dart';
import '../../app/icons/ui_icons.dart';

/// The signed-in user's bookmarks of one [kind] filtered to one tag — the
/// profile's own list (`ProfileIllustFeed` or `ProfileNovelFeed`) with
/// `ProfileFeedKey.bookmarkTag`.
class BookmarkTagFeedPage extends ConsumerStatefulWidget {
  const BookmarkTagFeedPage({
    super.key,
    required this.tag,
    this.kind = BookmarkEntityType.illust,
    required this.restrict,
  });

  final String tag;
  final BookmarkEntityType kind;
  final BookmarkRestrict restrict;

  @override
  ConsumerState<BookmarkTagFeedPage> createState() =>
      _BookmarkTagFeedPageState();
}

class _BookmarkTagFeedPageState extends ConsumerState<BookmarkTagFeedPage> {
  final _filterController = TextEditingController();
  String _filter = '';

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final userId = ref.watch(
      accountStoreProvider.select(
        (async) => async.value?.usableCurrent?.userId,
      ),
    );
    return Scaffold(
      appBar: AppTopBar(
        title: Builder(
          builder: (titleContext) {
            final titleColor = DefaultTextStyle.of(titleContext).style.color;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.tag, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  // The kind is named for novels only: illustrations are what
                  // this page always showed.
                  [
                    if (widget.kind == BookmarkEntityType.novel)
                      l10n.profileNovel,
                    widget.restrict == BookmarkRestrict.private
                        ? l10n.restrictPrivate
                        : l10n.restrictPublic,
                  ].join(' · '),
                  style: Theme.of(titleContext).textTheme.bodySmall?.copyWith(
                    color: titleColor?.withValues(alpha: 0.82),
                  ),
                ),
              ],
            );
          },
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              FuncSpacing.lg,
              0,
              FuncSpacing.lg,
              FuncSpacing.sm,
            ),
            // The search page's field (L3): a filter is a search too.
            child: SearchBar(
              controller: _filterController,
              constraints: const BoxConstraints(minHeight: 48),
              hintText: l10n.bookmarkTagFilterHint,
              leading: Icon(
                AppIcons.search,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              trailing: _filter.isEmpty
                  ? null
                  : [
                      IconButton(
                        tooltip: l10n.searchClear,
                        onPressed: () {
                          _filterController.clear();
                          setState(() => _filter = '');
                        },
                        icon: const Icon(UiIcons.close),
                      ),
                    ],
              onChanged: (value) => setState(() => _filter = value),
              textInputAction: TextInputAction.search,
            ),
          ),
        ),
      ),
      body: DesktopInspectableGallery(
        active: widget.kind == BookmarkEntityType.illust,
        child: userId == null
            ? FeedEmpty(icon: AppIcons.tag, title: l10n.bookmarkTagsEmpty)
            : _feed(userId),
      ),
    );
  }

  Widget _feed(int userId) {
    final key = ProfileFeedKey(
      userId: userId,
      kind: ProfileFeedKind.bookmarks,
      workType: widget.kind == BookmarkEntityType.novel
          ? UserWorkType.novel
          : UserWorkType.illust,
      restrict: widget.restrict == BookmarkRestrict.private
          ? UserRestrict.private
          : UserRestrict.public,
      bookmarkTag: widget.tag,
    );
    return widget.kind == BookmarkEntityType.novel
        ? ProfileNovelFeed(feedKey: key, localFilter: _filter, isNested: false)
        : ProfileIllustFeed(
            feedKey: key,
            localFilter: _filter,
            isNested: false,
          );
  }
}
