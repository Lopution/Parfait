import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/widgets/feed/feed_states.dart';
import '../../core/auth/account_store.dart';
import '../../core/bookmark/bookmark_models.dart';
import '../../core/profile/profile_models.dart';
import '../../core/user/user_repository.dart';
import '../../l10n/context.dart';
import 'profile_illust_feed.dart';

/// The signed-in user's bookmarks filtered to one tag — the same
/// `ProfileIllustFeed` pipeline with `ProfileFeedKey.bookmarkTag`.
class BookmarkTagFeedPage extends ConsumerStatefulWidget {
  const BookmarkTagFeedPage({
    super.key,
    required this.tag,
    required this.restrict,
  });

  final String tag;
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
      appBar: AppBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.tag, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              widget.restrict == BookmarkRestrict.private
                  ? l10n.restrictPrivate
                  : l10n.restrictPublic,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _filterController,
              onChanged: (value) => setState(() => _filter = value),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: l10n.bookmarkTagFilterHint,
                prefixIcon: const Icon(Icons.search),
              ),
            ),
          ),
        ),
      ),
      body: userId == null
          ? FeedEmpty(icon: Icons.label_outline, title: l10n.bookmarkTagsEmpty)
          : ProfileIllustFeed(
              feedKey: ProfileFeedKey(
                userId: userId,
                kind: ProfileFeedKind.bookmarks,
                restrict: widget.restrict == BookmarkRestrict.private
                    ? UserRestrict.private
                    : UserRestrict.public,
                bookmarkTag: widget.tag,
              ),
              localFilter: _filter,
            ),
    );
  }
}
