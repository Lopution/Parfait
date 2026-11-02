import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/navigation/routes.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/app_menu_button.dart';
import '../../app/widgets/filter_menu_button.dart';
import '../../core/bookmark/bookmark_models.dart';
import '../../core/bookmark/bookmark_tags_controller.dart';
import '../../core/user/user_repository.dart';
import '../../l10n/context.dart';

/// The filters above a bookmarks or follows list, visible (D3 list filter)
/// rather than checked items in the overflow menu: on bookmarks the kind
/// (illustrations or novels), then on your own lists the visibility and,
/// for bookmarks, the tag.
class ProfileFilterBar extends StatelessWidget {
  const ProfileFilterBar({
    super.key,
    this.kind,
    this.onKindChanged,
    this.restrict = UserRestrict.public,
    this.onRestrictChanged,
    this.tag,
    this.onTagChanged,
  });

  /// Bookmarks only: illustrations or novels. A null [onKindChanged]
  /// leaves the kind filter out.
  final BookmarkEntityType? kind;
  final ValueChanged<BookmarkEntityType>? onKindChanged;

  /// Your own lists only. A null [onRestrictChanged] leaves the
  /// visibility filter out.
  final UserRestrict restrict;
  final ValueChanged<UserRestrict>? onRestrictChanged;

  /// Your own bookmarks only: the picked tag, null for every bookmark. A
  /// null [onTagChanged] leaves the tag filter out.
  final String? tag;
  final ValueChanged<String?>? onTagChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final kind = this.kind ?? BookmarkEntityType.illust;
    final onKindChanged = this.onKindChanged;
    final onRestrictChanged = this.onRestrictChanged;
    final onTagChanged = this.onTagChanged;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FuncSpacing.lg,
        FuncSpacing.sm,
        FuncSpacing.lg,
        0,
      ),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Wrap(
          spacing: FuncSpacing.sm,
          runSpacing: FuncSpacing.sm,
          children: [
            if (onKindChanged != null)
              FilterMenuButton<BookmarkEntityType>(
                key: const ValueKey('profile-filter-kind'),
                label: kind == BookmarkEntityType.novel
                    ? l10n.profileNovel
                    : l10n.profileIllust,
                value: kind,
                options: [
                  AppMenuEntry(
                    value: BookmarkEntityType.illust,
                    label: l10n.profileIllust,
                    icon: Icons.image_outlined,
                  ),
                  AppMenuEntry(
                    value: BookmarkEntityType.novel,
                    label: l10n.profileNovel,
                    icon: Icons.menu_book_outlined,
                  ),
                ],
                onChanged: onKindChanged,
              ),
            if (onRestrictChanged != null)
              FilterMenuButton<UserRestrict>(
                key: const ValueKey('profile-filter-restrict'),
                label: restrict == UserRestrict.private
                    ? l10n.restrictPrivate
                    : l10n.restrictPublic,
                value: restrict,
                options: [
                  AppMenuEntry(
                    value: UserRestrict.public,
                    label: l10n.restrictPublic,
                    icon: Icons.public,
                  ),
                  AppMenuEntry(
                    value: UserRestrict.private,
                    label: l10n.restrictPrivate,
                    icon: Icons.lock_outline,
                  ),
                ],
                onChanged: onRestrictChanged,
              ),
            if (onTagChanged != null)
              _TagFilter(
                kind: kind,
                restrict: restrict,
                tag: tag,
                onChanged: onTagChanged,
              ),
          ],
        ),
      ),
    );
  }
}

class _TagFilter extends ConsumerWidget {
  const _TagFilter({
    required this.kind,
    required this.restrict,
    required this.tag,
    required this.onChanged,
  });

  /// Tags beyond this many go to the full tag page instead of the menu.
  static const menuLimit = 10;

  final BookmarkEntityType kind;
  final UserRestrict restrict;
  final String? tag;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final tag = this.tag;
    final loaded = ref
        .watch(
          userBookmarkTagsProvider((
            kind,
            restrict == UserRestrict.private
                ? BookmarkRestrict.private
                : BookmarkRestrict.public,
          )),
        )
        .value;
    final names = [
      for (final entry in loaded?.tags.take(menuLimit) ?? <UserBookmarkTag>[])
        entry.name,
    ];
    // Until the list is known to fit, the full tag page stays reachable.
    final more =
        loaded == null || loaded.hasMore || loaded.tags.length > menuLimit;
    return FilterMenuButton<String?>(
      key: const ValueKey('profile-filter-tag'),
      label: tag == null
          ? l10n.profileTagFilterAll
          : l10n.profileTagFilter(tag),
      value: tag,
      options: [
        AppMenuEntry(value: null, label: l10n.profileTagAny),
        for (final name in names) AppMenuEntry(value: name, label: name),
        if (tag != null && !names.contains(tag))
          AppMenuEntry(value: tag, label: tag),
      ],
      onChanged: onChanged,
      moreLabel: more ? l10n.profileTagMore : null,
      onMore: more
          ? () => openBookmarkTags(context, kind: kind, restrict: restrict)
          : null,
    );
  }
}
