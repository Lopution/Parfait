// One-off diagnostic (not committed): pump each tab page and print the
// global Y of its TabBar so the "third page sits lower" report can be
// attributed to code, not to eyeballing screenshots.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:pixiv_func/core/new/new_feed_models.dart';
import 'package:pixiv_func/core/new/new_feed_repository.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/features/home/recommended/recommended_home_page.dart';
import 'package:pixiv_func/features/new/new_page.dart';
import 'package:pixiv_func/features/ranking/ranking_page.dart';

class _FakeNewFeedRepository implements NewFeedRepository {
  @override
  Future<NewIllustPage> fetchIllust(
    NewFeedKey key, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    return const NewIllustPage(illusts: [], nextUrl: null);
  }

  @override
  Future<NewNovelPage> fetchNovel(
    NewFeedKey key, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    return const NewNovelPage(novels: [], nextUrl: null);
  }

  @override
  bool validateIllustCursor(NewFeedKey key, {required String cursor}) => true;

  @override
  bool validateNovelCursor(NewFeedKey key, {required String cursor}) => true;
}

void main() {
  testWidgets('DIAGNOSTIC: tab bar geometry of the three tab pages', (
    tester,
  ) async {
    // Emulate a real Android status bar so the AppBar height includes it.
    tester.view.viewPadding = const FakeViewPadding(top: 100);
    addTearDown(tester.view.resetViewPadding);
    await mockNetworkImagesFor(() async {
      Widget wrap(Widget child) => ProviderScope(
            overrides: [
              newFeedRepositoryProvider.overrideWithValue(
                _FakeNewFeedRepository(),
              ),
            ],
            child: MaterialApp(
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: child,
            ),
          );

      Future<void> measure(String label, Widget page) async {
        await tester.pumpWidget(wrap(page));
        await tester.pump();
        await tester.pump();
        final tabBar = tester.getTopLeft(find.byType(TabBar));
        final barSize = tester.getSize(find.byType(TabBar));
        final appBar = find.byType(AppBar);
        final appBarRect = tester.getRect(appBar);
        // ignore: avoid_print
        print('$label: TabBar top-left=$tabBar size=$barSize '
            'AppBar rect=$appBarRect');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }

      await measure('RecommendedHomePage', const RecommendedHomePage());
      await measure('RankingPage', const RankingPage());
      await measure('NewPage', const NewPage());
    });
  });
}
