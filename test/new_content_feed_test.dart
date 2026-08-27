import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/new/new_feed_models.dart';
import 'package:pixiv_func/core/new/new_feed_repository.dart';
import 'package:pixiv_func/features/new/new_page.dart';

class _FakeNewFeedRepository implements NewFeedRepository {
  final requests = <NewFeedKey>[];

  @override
  Future<NewIllustPage> fetchIllust(
    NewFeedKey key, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    requests.add(key);
    return const NewIllustPage(illusts: [], nextUrl: null);
  }

  @override
  Future<NewNovelPage> fetchNovel(
    NewFeedKey key, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    requests.add(key);
    return const NewNovelPage(novels: [], nextUrl: null);
  }

  @override
  bool validateIllustCursor(NewFeedKey key, {required String cursor}) => true;

  @override
  bool validateNovelCursor(NewFeedKey key, {required String cursor}) => true;
}

void main() {
  test('NewFeedKey keeps scope and content type independent', () {
    const followingIllust = NewFeedKey(
      scope: NewFeedScope.following,
      type: NewFeedType.illust,
    );
    const followingNovel = NewFeedKey(
      scope: NewFeedScope.following,
      type: NewFeedType.novel,
    );
    const everyoneIllust = NewFeedKey(
      scope: NewFeedScope.everyone,
      type: NewFeedType.illust,
    );

    expect(followingIllust, isNot(followingNovel));
    expect(followingIllust, isNot(everyoneIllust));
    expect({followingIllust, followingNovel}, hasLength(2));
  });

  testWidgets('New tabs are lazy and re-tap opens the type selector', (
    tester,
  ) async {
    final repository = _FakeNewFeedRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [newFeedRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: const NewPage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(TabBar), findsOneWidget);
    expect(find.text('关注'), findsOneWidget);
    expect(find.text('大家'), findsOneWidget);
    expect(find.text('好P友'), findsOneWidget);
    expect(repository.requests, [
      const NewFeedKey(scope: NewFeedScope.following, type: NewFeedType.illust),
    ]);

    await tester.tap(find.text('大家'));
    await tester.pumpAndSettle();
    expect(
      repository.requests,
      contains(
        const NewFeedKey(
          scope: NewFeedScope.everyone,
          type: NewFeedType.illust,
        ),
      ),
    );

    await tester.tap(find.text('大家'));
    await tester.pumpAndSettle();
    expect(find.text('小说'), findsOneWidget);

    await tester.tap(find.text('小说'));
    await tester.pump();
    await tester.pump();
    expect(
      repository.requests,
      contains(
        const NewFeedKey(scope: NewFeedScope.everyone, type: NewFeedType.novel),
      ),
    );
  });
}
