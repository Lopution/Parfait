import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/app.dart';
import 'package:parfait/app/navigation/route_search_facade.dart';
import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/app/widgets/bookmark_switch_button.dart';
import 'package:parfait/app/widgets/feed/illust_card.dart';
import 'package:parfait/app/widgets/follow_switch_button.dart';
import 'package:parfait/app/widgets/func_bottom_nav.dart';
import 'package:parfait/app/widgets/prompt_host.dart';
import 'package:parfait/app/widgets/settings/settings_control.dart';
import 'package:parfait/core/download/download_providers.dart';
import 'package:parfait/core/download/download_task.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/navigation/home_destination.dart';
import 'package:parfait/core/search/search_models.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/features/history/history_page.dart';
import 'package:parfait/features/home/recommended/recommended_home_page.dart';
import 'package:parfait/features/illust/detail/illust_detail_page.dart';
import 'package:parfait/features/illust/detail/widgets/detail_action_bar.dart';
import 'package:parfait/features/illust/viewer/image_viewer_page.dart';
import 'package:parfait/features/novel/local_novel_reader_page.dart';
import 'package:parfait/features/novel/novel_reader.dart';
import 'package:parfait/features/profile/user_page.dart';
import 'package:parfait/features/ranking/ranking_page.dart';
import 'package:parfait/features/search/search_result_page.dart';
import 'package:parfait/features/settings/me_dashboard_page.dart';
import 'package:parfait/features/settings/pages/download_tasks_page.dart';
import 'package:parfait/features/settings/settings_catalog.dart';
import 'package:parfait/features/watchlater/watchlater_page.dart';

import '../helpers/leak_tracking.dart';
import '../helpers/prompt_host.dart';
import '../review/review_support.dart';
import 'e2e_harness.dart';

void main() {
  ignoreOctoImageFades();
  final captionControl = find.byWidgetPredicate(
    (w) => w is SettingsControl && w.setting == Setting.downloadCaption,
  );
  ReviewResponder countHit(VoidCallback hit) => (u) {
    hit();
    return reviewJson(const {})(u);
  };

  group('In-app real-shell E2E core journeys', () {
    testE2e(
      'Journey 1: recommended feed tabs, branch state preservation, and update prompt',
      (tester, world, router) async {
        expect(find.byType(IllustCard), findsWidgets);
        final firstRec = tester.state<State<RecommendedHomePage>>(
          find.byType(RecommendedHomePage),
        );
        await tapAndSettle(tester, find.text('漫画'));
        expect(find.byType(IllustCard), findsWidgets);

        await tapAndSettle(tester, find.text('小说'));
        expect(find.text('novel 2000'), findsOneWidget);

        final navCtx = tester.element(find.byType(FuncBottomNav));
        for (final d in const [
          HomeDestination.ranking,
          HomeDestination.newWorks,
          HomeDestination.search,
          HomeDestination.me,
          HomeDestination.recommended,
        ]) {
          await tapAndSettle(
            tester,
            find.descendant(
              of: find.byType(FuncBottomNav),
              matching: find.text(homeDestinationLabel(navCtx, d)),
            ),
          );
        }
        expect(find.text('novel 2000'), findsOneWidget);
        expect(
          identical(
            tester.state<State<RecommendedHomePage>>(
              find.byType(RecommendedHomePage),
            ),
            firstRec,
          ),
          isTrue,
        );
        expect(find.byType(RankingPage, skipOffstage: false), findsOneWidget);

        final shell = tester.element(find.byType(FuncShellBottomNav));
        showUpdatePrompt(PromptHost.of(shell), version: '9.9.9', onOpen: () {});
        await tester.pump();
        await tester.pumpAndSettle();
        const msg = '发现新版本：9.9.9';
        expect(find.text(msg), findsOneWidget);
        final card = tester.getRect(promptCard(msg));
        final bar = tester.getRect(find.byType(FuncBottomNav));
        expect(card.overlaps(bar), isFalse);
        expect(card.bottom, closeTo(bar.top - 16, 0.5));
        await tester.pump(const Duration(seconds: 7));
        expect(find.text(msg), findsOneWidget);
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(find.text(msg), findsNothing);
      },
    );

    var bookmarkAdds = 0;
    var followAdds = 0;
    testE2e(
      'Journey 2: work detail optimistic bookmark and author follow sync back to feed',
      api: {
        '/v2/illust/bookmark/add': countHit(() => bookmarkAdds++),
        '/v1/user/follow/add': countHit(() => followAdds++),
      },
      (tester, world, router) async {
        bookmarkAdds = 0;
        followAdds = 0;
        await tapAndSettle(
          tester,
          find.byWidgetPredicate((w) => w is IllustCard && w.entity.id == 1000),
          3,
        );
        expect(find.byType(IllustDetailPage), findsOneWidget);

        await tapAndSettle(
          tester,
          find.descendant(
            of: find.byType(DetailActionBar),
            matching: find.byType(BookmarkSwitchButton),
          ),
        );
        expect(bookmarkAdds, 1);
        expect(
          world.container.read(illustStoreProvider).get(1000)?.isBookmarked,
          isTrue,
        );

        await revealForReview(tester, find.byType(FollowSwitchButton));
        await tapAndSettle(tester, find.byType(FollowSwitchButton).first);
        expect(followAdds, 1);

        router.pop();
        await settle(tester);
        expect(
          world.container.read(illustStoreProvider).get(1000)?.isBookmarked,
          isTrue,
        );
      },
    );

    testE2e(
      'Journey 3: multi-page viewer open/close and real download submission flow',
      location: '/recommended/illust/1000',
      (tester, world, router) async {
        expect(find.byType(IllustDetailPage), findsOneWidget);
        await tapAndSettle(tester, find.byType(PixivImage).hitTestable().first);
        expect(find.byType(ImageViewerPage), findsOneWidget);

        router.pop();
        await settle(tester);
        expect(find.byType(IllustDetailPage), findsOneWidget);

        await tapAndSettle(tester, find.byType(DetailDownloadButton), 3);
        final tasks = world.container.read(downloadManagerProvider).tasks;
        expect(tasks, isNotEmpty);
        expect(
          tasks.every((t) => t.status == DownloadStatus.succeeded),
          isTrue,
        );

        unawaited(router.push('/downloads'));
        await settle(tester);
        expect(find.byType(DownloadTasksPage), findsOneWidget);
      },
    );

    Uri? captured;
    testE2e(
      'Journey 4: novel search forwards is_original_only and text_length filters end-to-end',
      location: '/search',
      api: {
        '/v1/search/novel': (u) {
          captured = u;
          return reviewJson({
            'novels': [reviewNovelJson(2000), reviewNovelJson(2001)],
            'next_url': null,
          })(u);
        },
      },
      (tester, world, router) async {
        captured = null;
        unawaited(
          openSearchResults(
            tester.element(find.byType(Scaffold).first),
            const NovelSearchQuery(
              keyword: 'fantasy',
              filters: NovelSearchFilters(
                originalOnly: true,
                textLengthMin: 5000,
                textLengthMax: 20000,
              ),
            ),
          ),
        );
        await settle(tester, 3);
        expect(find.byType(SearchResultPage), findsOneWidget);
        expect(find.text('novel 2000'), findsOneWidget);
        expect(
          captured?.queryParameters,
          allOf(
            containsPair('word', 'fantasy'),
            containsPair('is_original_only', 'true'),
            containsPair('text_length_min', '5000'),
            containsPair('text_length_max', '20000'),
          ),
        );
      },
    );

    var profileFollowAdds = 0;
    testE2e(
      'Journey 5: author profile loads works, switches to novels/bookmarks, and toggles follow',
      location: '/recommended/user/99',
      api: {'/v1/user/follow/add': countHit(() => profileFollowAdds++)},
      (tester, world, router) async {
        profileFollowAdds = 0;
        expect(find.byType(UserPage), findsOneWidget);
        expect(find.text('user 99'), findsWidgets);
        await tapAndSettle(tester, find.byType(FollowSwitchButton).first);
        expect(profileFollowAdds, 1);

        await tapAndSettle(tester, find.text('小说'));
        expect(find.text('novel 2000'), findsOneWidget);

        await tapAndSettle(tester, find.text('收藏'));
        expect(find.byType(IllustCard), findsWidgets);
      },
    );

    testE2e(
      'Journey 6: online novel reader and offline local novel reader render parsed text',
      location: '/recommended/novel/2000',
      localNovels: 2,
      (tester, world, router) async {
        expect(find.byType(NovelReader), findsOneWidget);
        expect(find.textContaining('第一章'), findsWidgets);

        router.go('/recommended/local-novels');
        await settle(tester);
        await tapAndSettle(tester, find.textContaining('local novel 0').first);
        expect(find.byType(LocalNovelReaderPage), findsOneWidget);
      },
    );

    testE2e(
      'Journey 7: Me dashboard, history list, and watch-later list render seeded items',
      location: '/settings',
      history: reviewHistory(),
      watchlater: 2,
      (tester, world, router) async {
        expect(find.byType(MeDashboardPage), findsOneWidget);
        unawaited(router.push('/settings/history'));
        await settle(tester);
        expect(find.byType(HistoryPage), findsOneWidget);
        expect(find.text('illust 1000'), findsWidgets);

        router.pop();
        await settle(tester, 1);
        unawaited(router.push('/settings/watchlater'));
        await settle(tester);
        expect(find.byType(WatchLaterPage), findsOneWidget);
        expect(find.text('illust 4000'), findsWidgets);
      },
    );

    testE2e(
      'Journey 8a: desktop download settings enable and persist caption export',
      device: reviewDevices['desktop']!,
      location: '/settings/download',
      (tester, world, router) async {
        expect(
          tester.widget<SettingsControl>(captionControl).onChanged,
          isNotNull,
        );
        await tapAndSettle(tester, captionControl);
        expect(
          world.container.read(settingsProvider).value?.downloadCaption,
          isTrue,
        );
      },
    );

    testE2e(
      'Journey 8b: iOS download settings disable caption export on photo library',
      device: reviewDevices['iphone']!,
      location: '/settings/download',
      (tester, world, router) async {
        final c = tester.widget<SettingsControl>(captionControl);
        expect((c.onChanged, c.value), (null, false));
      },
    );
  });
}
