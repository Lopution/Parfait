import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/widgets/app_tab_bar.dart';
import 'package:parfait/app/widgets/app_type_switch.dart';
import 'package:parfait/app/widgets/follow_switch_button.dart';
import 'package:parfait/app/widgets/func_bottom_nav.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/illust/ranking_repository.dart';
import 'package:parfait/core/novel/novel_repository.dart';
import 'package:parfait/core/search/search_models.dart';
import 'package:parfait/core/spotlight/spotlight_models.dart';
import 'package:parfait/core/user/follow_store.dart';
import 'package:parfait/l10n/lookup.dart';

import '../helpers/fake_account.dart';
import '../helpers/locale_layout.dart';
import '../helpers/test_preferences.dart';

/// Every top tab row's real labels.
final _tabGroups = <String, List<String>>{
  'ranking': [for (final mode in RankingMode.values) mode.labelKey],
  'novel ranking': [for (final mode in NovelRankingMode.values) mode.labelKey],
  'new': ['newFollowing', 'newEveryone', 'newMyPixiv'],
  'search results': [for (final type in SearchResultType.values) type.labelKey],
  'search home': [
    for (final type in const [SearchResultType.illust, SearchResultType.novel])
      type.labelKey,
  ],
  'spotlight': [
    for (final category in SpotlightCategory.values) category.labelKey,
  ],
  'bookmark tags': ['restrictPublic', 'restrictPrivate'],
  'watchlist': ['watchlistManga', 'watchlistNovel'],
  'recommended': [
    'recommendedIllust',
    'recommendedManga',
    'recommendedNovel',
    'recommendedUser',
  ],
  'profile (mine)': [
    'profileBookmarked',
    'profileFollowing',
    'profileFans',
    'profileMyPixiv',
    'profileWork',
  ],
  'profile (others)': [
    'profileWork',
    'profileBookmarked',
    'profileFollowing',
    'profileAbout',
  ],
};

const _bottomBar = [
  'homeRecommended',
  'homeRanking',
  'newTitle',
  'searchTitle',
  'homeMe',
];

const _profileWorkTypes = [
  'profileIllust',
  'profileManga',
  'profileNovel',
  'profileSeries',
];

Future<void> _pumpControl(
  WidgetTester tester,
  Locale locale,
  Widget Function(String Function(String key) text) build, {
  ProviderContainer? container,
}) async {
  await tester.pumpWidget(
    localeLayoutApp(
      locale: locale,
      container: container,
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Align(
              alignment: Alignment.topCenter,
              child: Builder(
                builder: (context) =>
                    build((key) => l10nLookupFor(locale, key)),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await settleLayout(tester);
}

void main() {
  for (final MapEntry(key: name, value: keys) in _tabGroups.entries) {
    localeLayoutMatrix('tab bar: $name', (tester, locale, profile) async {
      await _pumpControl(
        tester,
        locale,
        (text) => DefaultTabController(
          length: keys.length,
          child: AppTabBar(labels: [for (final key in keys) text(key)]),
        ),
      );
      expectLocaleLayoutIntact(tester, locale: locale, profile: profile);
    });
  }

  localeLayoutMatrix('type switch: profile works', (
    tester,
    locale,
    profile,
  ) async {
    await _pumpControl(
      tester,
      locale,
      (text) => AppTypeSwitch<int>(
        options: [
          for (var i = 0; i < _profileWorkTypes.length; i++)
            (value: i, label: text(_profileWorkTypes[i])),
        ],
        selected: 0,
        onSelected: (_) {},
      ),
    );
    expectLocaleLayoutIntact(tester, locale: locale, profile: profile);
  });

  localeLayoutMatrix('bottom bar', (tester, locale, profile) async {
    await tester.pumpWidget(
      localeLayoutApp(
        locale: locale,
        home: Scaffold(
          bottomNavigationBar: FuncBottomNav(
            destinations: [
              for (final key in _bottomBar)
                FuncBottomNavDestination(
                  icon: Icons.circle_outlined,
                  label: l10nLookupFor(locale, key),
                ),
            ],
            selectedIndex: 0,
            onSelected: (_) {},
          ),
        ),
      ),
    );
    await settleLayout(tester);
    expectLocaleLayoutIntact(tester, locale: locale, profile: profile);
  });

  for (final followed in [false, true]) {
    localeLayoutMatrix(
      'follow button (${followed ? 'followed' : 'not followed'})',
      (tester, locale, profile) async {
        installMemoryPreferences();
        final container = ProviderContainer(
          overrides: accountProviderOverrides(
            credentialStore: FakeCredentialStore(
              values: const {
                '100': Credential(accessToken: 'a', refreshToken: 'r'),
              },
            ),
            metadataRepository: FakeAccountMetadataRepository(
              accounts: const [Account(id: '100', userId: 100, name: 'me')],
              currentId: '100',
            ),
          ),
        );
        addTearDown(container.dispose);
        await container.read(accountStoreProvider.future);
        if (followed) {
          final follows = container.read(followStoreProvider.notifier);
          follows.commit(follows.beginAdd(42)!);
        }
        // Standalone (detail author row, profile header) and in a list
        // tile's trailing slot capped at half the row (user lists).
        await _pumpControl(
          tester,
          locale,
          container: container,
          (text) => Column(
            children: [
              const FollowSwitchButton(userId: 42, userName: 'u'),
              ListTile(
                title: const Text('sample user'),
                trailing: LayoutBuilder(
                  builder: (context, constraints) => ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: constraints.maxWidth * 0.5,
                    ),
                    child: const FollowSwitchButton(
                      userId: 42,
                      userName: 'u',
                      compact: true,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
        expectLocaleLayoutIntact(tester, locale: locale, profile: profile);
      },
    );
  }
}
