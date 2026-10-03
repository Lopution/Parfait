import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/reverse_image/reverse_image_engine.dart';
import 'package:parfait/core/reverse_image/reverse_image_provider.dart';
import 'package:parfait/core/search/search_models.dart';
import 'package:parfait/core/search/search_repository.dart';
import 'package:parfait/core/user/user_entity.dart';
import 'package:parfait/features/illust/detail/illust_detail_page.dart';
import 'package:parfait/features/illust/detail/widgets/illust_series_section.dart';
import 'package:parfait/features/profile/user_page.dart';
import 'package:parfait/features/search/reverse_image_search_page.dart';
import 'package:parfait/features/search/search_page.dart';
import 'package:parfait/features/search/search_result_page.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../helpers/detail_world.dart';
import '../helpers/illust_fixtures.dart';
import '../helpers/locale_layout.dart';
import '../helpers/profile_world.dart';
import '../helpers/reverse_image_world.dart';
import '../helpers/search_world.dart';
import '../helpers/series_world.dart';
import '../helpers/test_preferences.dart';

/// A profile with every header field filled and counts in the thousands.
const _author = UserEntity(
  id: 42,
  name: 'sample user',
  account: 'sample',
  comment: 'hello',
  webpage: 'https://example.com',
  isFollowed: false,
  totalFollowUsers: 1234,
  totalMyPixivUsers: 567,
  totalIllusts: 890,
  totalManga: 12,
  totalNovels: 3,
  totalIllustSeries: 4,
  hasDetail: true,
);

Future<void> _pumpChecked(
  WidgetTester tester,
  Locale locale,
  LayoutProfile profile,
  Widget app,
) async {
  await mockNetworkImagesFor(() async {
    await tester.pumpWidget(app);
    await settleLayout(tester);
    await expectPageLayoutIntact(tester, locale: locale, profile: profile);
  });
}

void main() {
  installMemoryPreferences();
  // The detail page tracks the visible image through VisibilityDetector;
  // a zero interval keeps its timer from outliving a test.
  VisibilityDetectorController.instance.updateInterval = Duration.zero;

  localeLayoutMatrix('content: illust detail', (tester, locale, profile) async {
    final illust = illustJson(
      42,
      caption: 'caption',
      totalView: 123456,
      totalBookmarks: 12345,
    );
    final (container, _, _) = await makeWorld(detailOverrides: {42: illust});
    container.read(illustStoreProvider).mergeAll([parseIllust(illust)]);
    await _pumpChecked(
      tester,
      locale,
      profile,
      localeLayoutApp(
        locale: locale,
        container: container,
        home: const IllustDetailPage(illustId: 42),
      ),
    );
  });

  localeLayoutMatrix('content: illust series section', (
    tester,
    locale,
    profile,
  ) async {
    final (container, _) = await makeSeriesWorld();
    addTearDown(container.dispose);
    await _pumpChecked(
      tester,
      locale,
      profile,
      localeLayoutApp(
        locale: locale,
        container: container,
        home: const Scaffold(
          body: CustomScrollView(slivers: [IllustSeriesSection(illustId: 910)]),
        ),
      ),
    );
  });

  // The signed-in account is user 100: 42 is someone else, 100 is me.
  for (final (who, userId) in const [('other user', 42), ('own', 100)]) {
    localeLayoutMatrix('content: profile ($who)', (
      tester,
      locale,
      profile,
    ) async {
      final container = await makeProfileWorld(
        users: FakeUserRepository(
          detail: _author,
          works: [for (var id = 1; id <= 6; id++) parseIllust(illustJson(id))],
        ),
      );
      await _pumpChecked(
        tester,
        locale,
        profile,
        localeLayoutApp(
          locale: locale,
          container: container,
          home: UserPage(userId: userId),
        ),
      );
    });
  }

  final searchPages = <String, Widget>{
    'search home': const SearchPage(),
    'search input': const SearchInputPage(),
    'illust results': const SearchResultPage(
      query: IllustSearchQuery(keyword: 'cat'),
    ),
    'novel results': const SearchResultPage(
      query: NovelSearchQuery(keyword: 'cat'),
    ),
    'user results': const SearchResultPage(
      query: UserSearchQuery(keyword: 'cat'),
    ),
  };
  for (final MapEntry(key: name, value: page) in searchPages.entries) {
    localeLayoutMatrix('content: $name', (tester, locale, profile) async {
      final repository = FakeSearchRepository(trendingTagCount: 6)
        ..illustPage = SearchIllustPage(
          illusts: [
            for (var id = 1; id <= 6; id++) parseIllust(illustJson(id)),
          ],
          nextUrl: null,
        );
      await _pumpChecked(
        tester,
        locale,
        profile,
        localeLayoutApp(
          locale: locale,
          overrides: [searchRepositoryProvider.overrideWithValue(repository)],
          home: page,
        ),
      );
    });
  }

  localeLayoutMatrix('content: reverse image search', (
    tester,
    locale,
    profile,
  ) async {
    final directory = Directory.systemTemp.createTempSync('reverse-layout-');
    addTearDown(() => directory.deleteSync(recursive: true));
    InAppWebViewPlatform.instance = FakeInAppWebViewPlatform();
    final l10n = lookupAppLocalizations(locale);
    await _pumpChecked(
      tester,
      locale,
      profile,
      localeLayoutApp(
        locale: locale,
        home: ReverseImageSearchPage(
          platform: FakeReverseImagePlatform(writeTinyPng(directory)),
          providers: const {
            ReverseImageEngine.sauceNao: OutcomeReverseImageProvider(
              ReverseImageSearchFailure(
                code: ReverseImageProviderFailureCode.rateLimited,
                message: 'provider is rate limited',
                retryable: true,
                retryAfter: Duration(seconds: 27),
              ),
            ),
          },
        ),
      ),
    );

    // Ready: the picked image with the engines and the start action.
    await tester.tap(find.text(l10n.searchReversePick));
    await pumpUntilVisible(tester, find.text(l10n.searchReverseUse));
    await expectPageLayoutIntact(tester, locale: locale, profile: profile);

    // Failed: the wait copy and the retry.
    await tester.ensureVisible(find.text(l10n.searchReverseUse));
    await tester.tap(find.text(l10n.searchReverseUse));
    await pumpUntilVisible(tester, find.textContaining('27'));
    await settleLayout(tester);
    await expectPageLayoutIntact(tester, locale: locale, profile: profile);
  });
}
