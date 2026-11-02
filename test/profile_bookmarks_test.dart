// The profile's bookmarks tab: its tag menu and its kinds.

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/core/bookmark/bookmark_models.dart';
import 'package:parfait/features/profile/profile_novel_feed.dart';
import 'package:parfait/features/profile/user_page.dart';

import 'helpers/bookmark_world.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/localized_app.dart';
import 'helpers/profile_world.dart';
import 'helpers/prompt_host.dart';

void main() {
  testWidgets('a long tag list sends the rest to the tag page', (tester) async {
    final bookmarks = BookmarkApi()
      ..tagPage = UserBookmarkTagPage(
        tags: [
          for (var i = 0; i < 11; i++)
            UserBookmarkTag(name: 'tag $i', count: 1),
        ],
        nextUrl: null,
      );
    final container = await makeProfileWorld(
      users: UserApi(detail: sampleUser(100).copyWith(hasDetail: true)),
      bookmarks: bookmarks,
    );
    await tester.pumpWidget(
      localizedApp(
        container: container,
        builder: promptHostBuilder,
        home: MePage(onEditProfile: () {}),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('profile-filter-tag')));
    await tester.pumpAndSettle();
    Finder menuItem(String label) => find.descendant(
      of: find.byType(MenuItemButton),
      matching: find.text(label),
    );
    expect(menuItem('tag 9'), findsOneWidget);
    expect(menuItem('tag 10'), findsNothing);
    expect(menuItem('更多标签…'), findsOneWidget);
  });

  testWidgets('your bookmarks switch to novels with their own tags', (
    tester,
  ) async {
    final users = UserApi(
      detail: sampleUser(100).copyWith(hasDetail: true),
      novelBookmarks: [novelJson(7, title: 'kept novel')],
    );
    final bookmarks = BookmarkApi()
      ..tagPage = const UserBookmarkTagPage(
        tags: [UserBookmarkTag(name: 'tag 0', count: 1)],
        nextUrl: null,
      );
    final container = await makeProfileWorld(
      users: users,
      bookmarks: bookmarks,
    );
    await tester.pumpWidget(
      localizedApp(
        container: container,
        builder: promptHostBuilder,
        home: MePage(onEditProfile: () {}),
      ),
    );
    await tester.pumpAndSettle();
    await pickFilterMenu(tester, 'profile-filter-tag', 'tag 0');
    expect(users.requests, contains('bookmarks:100:public:tag 0'));

    // Tags are per kind: the novel list starts untagged, with novel tags.
    await pickFilterMenu(tester, 'profile-filter-kind', '小说');
    expect(users.requests.last, 'novel-bookmarks:100:public:');
    expect(bookmarks.tagRequests, contains('novel-tags:100:public'));
    expect(find.text('kept novel'), findsOneWidget);
    await pickFilterMenu(tester, 'profile-filter-restrict', '私密');
    expect(users.requests.last, 'novel-bookmarks:100:private:');
    await pickFilterMenu(tester, 'profile-filter-tag', 'tag 0');
    expect(users.requests.last, 'novel-bookmarks:100:private:tag 0');

    await pickFilterMenu(tester, 'profile-filter-kind', '插画');
    expect(users.requests.last, 'bookmarks:100:private:');
    expect(find.byType(ProfileNovelFeed), findsNothing);
  });
}
