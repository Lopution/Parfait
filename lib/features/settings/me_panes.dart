import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/icons/app_icons.dart';
import '../../app/navigation/route_facade.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/feed/desktop_inspectable_gallery.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../core/auth/account_store.dart';
import '../../core/bookmark/bookmark_models.dart';
import '../../core/profile/profile_models.dart';
import '../../core/user/user_repository.dart';
import '../../l10n/context.dart';

/// Signals whether the Me dashboard has ever been visible so inline workspace
/// panes defer network fetches until the user visits Me.
class MeNetworkScope extends InheritedWidget {
  const MeNetworkScope({
    super.key,
    required this.activated,
    required super.child,
  });

  final bool activated;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MeNetworkScope>()?.activated ??
      true;

  @override
  bool updateShouldNotify(MeNetworkScope oldWidget) =>
      activated != oldWidget.activated;
}

typedef MeProfileFilterBarBuilder =
    Widget Function({
      BookmarkEntityType? kind,
      ValueChanged<BookmarkEntityType>? onKindChanged,
      required UserRestrict restrict,
      required ValueChanged<UserRestrict> onRestrictChanged,
      String? tag,
      ValueChanged<String?>? onTagChanged,
    });

typedef MeProfileFeedBuilder = Widget Function(ProfileFeedKey key);

/// Dedicated inline bookmarks feed for the wide Me workspace, avoiding nested
/// `UserPage` profile sidebars inside the detail pane.
class MeBookmarksPane extends ConsumerStatefulWidget {
  const MeBookmarksPane({
    super.key,
    required this.filterBarBuilder,
    required this.illustFeedBuilder,
    required this.novelFeedBuilder,
  });

  final MeProfileFilterBarBuilder filterBarBuilder;
  final MeProfileFeedBuilder illustFeedBuilder;
  final MeProfileFeedBuilder novelFeedBuilder;

  @override
  ConsumerState<MeBookmarksPane> createState() => _MeBookmarksPaneState();
}

class _MeBookmarksPaneState extends ConsumerState<MeBookmarksPane> {
  BookmarkEntityType _kind = BookmarkEntityType.illust;
  UserRestrict _restrict = UserRestrict.public;
  String? _tag;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final userId = ref.watch(
      accountStoreProvider.select(
        (async) => async.value?.usableCurrent?.userId,
      ),
    );
    if (userId == null) {
      return Scaffold(
        appBar: AppTopBar(title: Text(l10n.profileBookmarked)),
        body: FeedEmpty(
          icon: AppIcons.heart,
          title: l10n.signedOut,
          actionLabel: l10n.login,
          onAction: () => openLogin(context),
        ),
      );
    }
    if (!MeNetworkScope.of(context)) {
      return Scaffold(
        appBar: AppTopBar(title: Text(l10n.profileBookmarked)),
        body: const SizedBox.shrink(),
      );
    }
    final feedKey = ProfileFeedKey(
      userId: userId,
      kind: ProfileFeedKind.bookmarks,
      workType: _kind == BookmarkEntityType.novel
          ? UserWorkType.novel
          : UserWorkType.illust,
      restrict: _restrict,
      bookmarkTag: _tag,
    );
    return Scaffold(
      appBar: AppTopBar(
        title: Text(l10n.profileBookmarked),
        actions: [
          TextButton(
            onPressed: () => unawaited(
              openBookmarkTags(context, kind: _kind, restrict: _restrict),
            ),
            child: Text(l10n.bookmarkTags),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          widget.filterBarBuilder(
            kind: _kind,
            onKindChanged: (value) => setState(() {
              _kind = value;
              _tag = null;
            }),
            restrict: _restrict,
            onRestrictChanged: (value) => setState(() {
              _restrict = value;
              _tag = null;
            }),
            tag: _tag,
            onTagChanged: (value) => setState(() => _tag = value),
          ),
          Expanded(
            child: DesktopInspectableGallery(
              active: _kind == BookmarkEntityType.illust,
              scopeKey: feedKey,
              child: _kind == BookmarkEntityType.novel
                  ? widget.novelFeedBuilder(feedKey)
                  : widget.illustFeedBuilder(feedKey),
            ),
          ),
        ],
      ),
    );
  }
}

/// Dedicated inline following-creators list for the wide Me workspace.
class MeFollowingPane extends ConsumerStatefulWidget {
  const MeFollowingPane({
    super.key,
    required this.filterBarBuilder,
    required this.userFeedBuilder,
  });

  final MeProfileFilterBarBuilder filterBarBuilder;
  final MeProfileFeedBuilder userFeedBuilder;

  @override
  ConsumerState<MeFollowingPane> createState() => _MeFollowingPaneState();
}

class _MeFollowingPaneState extends ConsumerState<MeFollowingPane> {
  UserRestrict _restrict = UserRestrict.public;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final userId = ref.watch(
      accountStoreProvider.select(
        (async) => async.value?.usableCurrent?.userId,
      ),
    );
    if (userId == null) {
      return Scaffold(
        appBar: AppTopBar(title: Text(l10n.profileFollowing)),
        body: FeedEmpty(
          icon: AppIcons.users,
          title: l10n.signedOut,
          actionLabel: l10n.login,
          onAction: () => openLogin(context),
        ),
      );
    }
    if (!MeNetworkScope.of(context)) {
      return Scaffold(
        appBar: AppTopBar(title: Text(l10n.profileFollowing)),
        body: const SizedBox.shrink(),
      );
    }
    return Scaffold(
      appBar: AppTopBar(title: Text(l10n.profileFollowing)),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          widget.filterBarBuilder(
            restrict: _restrict,
            onRestrictChanged: (value) => setState(() => _restrict = value),
          ),
          Expanded(
            child: widget.userFeedBuilder(
              ProfileFeedKey(
                userId: userId,
                kind: ProfileFeedKind.following,
                restrict: _restrict,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
