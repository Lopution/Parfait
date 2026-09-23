import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/bookmark/bookmark_models.dart';
import 'package:pixiv_func/core/entity/illust_entity.dart';
import 'package:pixiv_func/core/entity/illust_store.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/profile/profile_models.dart';
import 'package:pixiv_func/core/user/user_repository.dart';
import 'package:pixiv_func/features/profile/bookmark_tag_feed_page.dart';
import 'package:pixiv_func/features/profile/profile_illust_feed.dart';
import 'package:pixiv_func/app/widgets/feed/illust_card.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/test_preferences.dart';

class _StubAccountStore extends AccountStore {
  @override
  Future<AccountState> build() async => const AccountState(
    status: AccountStatus.ready,
    accounts: [Account(id: '100', userId: 100, name: 'tester')],
    currentId: '100',
  );
}

class _RecordingUserRepository implements UserRepository {
  final requests = <({int userId, UserRestrict restrict, String? tag})>[];

  final works = [
    _illust(1, 'Blue Sky', [
      const IllustTag(name: '空', translatedName: 'blue'),
    ]),
    _illust(2, 'Sakura', [const IllustTag(name: '花')]),
  ];

  @override
  Future<UserIllustPage> fetchBookmarks(
    int userId, {
    required UserRestrict restrict,
    String? tag,
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    requests.add((userId: userId, restrict: restrict, tag: tag));
    return UserIllustPage(illusts: works, nextUrl: null);
  }

  @override
  bool validateBookmarksCursor(
    int userId, {
    required UserRestrict restrict,
    String? tag,
    required String cursor,
  }) => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

IllustEntity _illust(int id, String title, List<IllustTag> tags) =>
    IllustEntity(
      id: id,
      title: title,
      type: IllustType.illust,
      imageUrls: IllustImageUrls(
        squareMedium: 'https://example.test/$id-square.png',
        medium: 'https://example.test/$id-medium.png',
        large: 'https://example.test/$id-large.png',
      ),
      caption: '',
      user: const IllustUser(
        id: 200,
        name: 'artist',
        account: 'artist',
        profileImageUrl: null,
      ),
      tags: tags,
      pageCount: 1,
      width: 400,
      height: 400,
      xRestrict: 0,
      aiType: 0,
      isBookmarked: true,
      totalView: 1,
      totalBookmarks: 1,
    );

ProviderContainer _makeContainer(_RecordingUserRepository repository) =>
    ProviderContainer(
      overrides: [
        accountStoreProvider.overrideWith(_StubAccountStore.new),
        userRepositoryProvider.overrideWithValue(repository),
        illustStoreProvider.overrideWithValue(IllustStore()),
      ],
    );

Widget _testApp(ProviderContainer container, Widget home) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
        home: home,
      ),
    );

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  testWidgets('bookmark tag feed labels range and isolates hero scope', (
    tester,
  ) async {
    final repository = _RecordingUserRepository();
    final container = _makeContainer(repository);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _testApp(
        container,
        const BookmarkTagFeedPage(
          tag: 'draw',
          restrict: BookmarkRestrict.private,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('draw'), findsOneWidget);
    expect(find.text('私密'), findsOneWidget);
    expect(repository.requests, [
      (userId: 100, restrict: UserRestrict.private, tag: 'draw'),
    ]);
    final taggedScope = tester
        .widget<IllustCard>(find.byType(IllustCard).first)
        .heroScope;
    expect(taggedScope, endsWith(':draw'));

    await tester.pumpWidget(
      _testApp(
        container,
        const ProfileIllustFeed(
          feedKey: ProfileFeedKey(
            userId: 100,
            kind: ProfileFeedKind.bookmarks,
            restrict: UserRestrict.private,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final untaggedScope = tester
        .widget<IllustCard>(find.byType(IllustCard).first)
        .heroScope;
    expect(untaggedScope, endsWith(':'));
    expect(untaggedScope, isNot(taggedScope));
  });

  testWidgets('bookmark tag filter only changes loaded works locally', (
    tester,
  ) async {
    final repository = _RecordingUserRepository();
    final container = _makeContainer(repository);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _testApp(
        container,
        const BookmarkTagFeedPage(
          tag: 'draw',
          restrict: BookmarkRestrict.private,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final filter = find.byType(TextField);
    await tester.enterText(filter, 'BLUE');
    await tester.pump();
    expect(find.text('Blue Sky'), findsOneWidget);
    expect(find.text('Sakura'), findsNothing);
    expect(repository.requests, hasLength(1));

    await tester.enterText(filter, 'no matching work');
    await tester.pump();
    expect(find.text('已加载内容中无匹配'), findsOneWidget);
    expect(repository.requests, hasLength(1));

    await tester.enterText(filter, '');
    await tester.pump();
    expect(find.text('Blue Sky'), findsOneWidget);
    expect(find.text('Sakura'), findsOneWidget);
    expect(repository.requests, hasLength(1));
  });
}
