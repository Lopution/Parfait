import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/app/widgets/app_top_bar.dart';
import 'package:parfait/app/widgets/settings/settings_action_tile.dart';
import 'package:parfait/app/widgets/settings/settings_anchor.dart';
import 'package:parfait/app/widgets/settings/settings_choice_tile.dart';
import 'package:parfait/app/widgets/settings/settings_control.dart';
import 'package:parfait/app/widgets/settings/settings_group_content.dart';
import 'package:parfait/app/widgets/settings/settings_menu_tile.dart';
import 'package:parfait/app/widgets/settings/settings_tile.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/comments/comment_translation.dart'
    show translationCredentialStoreProvider;
import 'package:parfait/core/network/compat/network_providers.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/features/settings/network_settings_page.dart';
import 'package:parfait/features/settings/settings_catalog.dart';
import 'package:parfait/features/settings/settings_page.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';

import 'helpers/fake_account.dart';
import 'helpers/prompt_host.dart';
import 'helpers/settings_world.dart';
import 'helpers/test_preferences.dart';

/// Each settings page that holds catalog entries. The settings index holds
/// the top-level page entries.
final _pages = <SettingsPageRef?, Widget>{
  null: const SettingsPage(),
  SettingsPageRef.account: const AccountSettingsPage(),
  SettingsPageRef.theme: const ThemeSettingsPage(),
  SettingsPageRef.language: const LanguageSettingsPage(),
  SettingsPageRef.translate: const TranslateSettingsPage(),
  SettingsPageRef.motion: const MotionSettingsPage(),
  SettingsPageRef.browse: const BrowseSettingsPage(),
  SettingsPageRef.muted: const MutedItemsPage(),
  SettingsPageRef.network: const NetworkSettingsPage(),
  SettingsPageRef.networkAdvanced: const NetworkAdvancedSettingsPage(),
  SettingsPageRef.download: const DownloadSettingsPage(),
  SettingsPageRef.downloadDestination: const DownloadDestinationPage(),
  SettingsPageRef.backup: const BackupSettingsPage(),
  SettingsPageRef.about: const AboutSettingsPage(),
};

List<Override> _overrides() => [
  settingsRepositoryProvider.overrideWithValue(
    FakeSettingsRepository(baseTestSettings(languageTag: 'zh-CN')),
  ),
  translationCredentialStoreProvider.overrideWithValue(FakeTranslationStore()),
  networkAccessPolicyProvider.overrideWithValue(stubNetworkPolicy()),
  ...accountProviderOverrides(
    credentialStore: FakeCredentialStore(
      values: const {'100': Credential(accessToken: 'a', refreshToken: 'r')},
    ),
    metadataRepository: FakeAccountMetadataRepository(
      accounts: const [Account(id: '100', userId: 100, name: 'tester')],
      currentId: '100',
    ),
  ),
];

/// The entries a page must anchor: its settings, and the pages its rows
/// open.
Set<SettingsEntry> _expectedOn(SettingsPageRef? page) => {
  for (final setting in Setting.values)
    if (setting.page == page && setting.available) setting,
  for (final child in SettingsPageRef.values)
    if (child.parent == page) child,
};

/// The texts [anchor] shows, with the options of the menu row it anchors.
List<String> _shownTexts(Element anchor) {
  final texts = <String>[];
  void collect(Element element) {
    switch (element.widget) {
      case final Text text:
        texts.add(text.data ?? text.textSpan?.toPlainText() ?? '');
      case final SettingsMenuTile<Object?> menu:
        texts.addAll([for (final option in menu.options) option.label]);
    }
    element.visitChildren(collect);
  }

  collect(anchor);
  // A row anchors itself inside its own build, so its menu is above.
  anchor.visitAncestorElements((element) {
    final widget = element.widget;
    if (widget is SettingsMenuTile<Object?>) {
      texts.addAll([for (final option in widget.options) option.label]);
    }
    return widget is! SettingsMenuTile && widget is! SettingAnchor;
  });
  return texts;
}

/// Whether [row] sits under an anchor or anchors itself.
bool _isAnchored(Element row) {
  var anchored = false;
  row.visitAncestorElements((element) {
    anchored = element.widget is SettingAnchor;
    return !anchored;
  });
  if (anchored) return true;
  void find(Element element) {
    if (anchored) return;
    if (element.widget is SettingAnchor) {
      anchored = true;
      return;
    }
    element.visitChildren(find);
  }

  row.visitChildren(find);
  return anchored;
}

void main() {
  setUp(() {
    installMemoryPreferences();
    PackageInfo.setMockInitialValues(
      appName: 'Parfait',
      packageName: 'io.github.lopution.parfait',
      version: '9.9.9',
      buildNumber: '99',
      buildSignature: '',
    );
  });

  final zh = lookupAppLocalizations(const Locale('zh'));

  group('every catalog entry is on its page', () {
    for (final MapEntry(key: ref, value: page) in _pages.entries) {
      testWidgets(ref?.name ?? 'settings index', (tester) async {
        // Tall enough that the lazy lists build every row.
        tester.view.physicalSize = const Size(800, 8000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            overrides: _overrides(),
            child: MaterialApp(
              builder: promptHostBuilder,
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh', 'CN'),
              home: page,
            ),
          ),
        );
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }

        if (ref != null) {
          expect(
            find.descendant(
              of: find.byType(AppTopBar),
              matching: find.text(ref.title(zh)),
            ),
            findsOneWidget,
            reason: 'the catalog names the page as its title bar does',
          );
        }

        final anchors = tester.widgetList<SettingAnchor>(
          find.byType(SettingAnchor),
        );
        expect({for (final anchor in anchors) anchor.entry}, _expectedOn(ref));
        expect(
          anchors.length,
          anchors.map((anchor) => anchor.entry).toSet().length,
          reason: 'each entry is anchored once',
        );

        // The anchor shows what the index finds it by.
        for (final anchor in find.byType(SettingAnchor).evaluate()) {
          final entry = (anchor.widget as SettingAnchor).entry;
          final shown = _shownTexts(anchor);
          final title = entry.title(zh);
          if (title != null) {
            expect(
              shown.any((text) => text.contains(title)),
              isTrue,
              reason: '${entry.id} shows its title',
            );
          }
          if (entry is! Setting) continue;
          for (final option in entry.options(zh)) {
            expect(
              shown.any((text) => text.contains(option)),
              isTrue,
              reason: '${entry.id} shows $option',
            );
          }
        }

        // No settings row escapes the index.
        final rows = find.byWidgetPredicate(
          (w) =>
              w is SettingsTile ||
              w is SettingsControl ||
              w is SettingsMenuTile ||
              w is SettingsActionTile ||
              w is SettingsGroupContent ||
              w is SettingsChoiceTile,
        );
        for (final row in rows.evaluate()) {
          expect(
            _isAnchored(row),
            isTrue,
            reason: '${row.widget} is not anchored to a catalog entry',
          );
        }
      });
    }
  });

  group('the search finds every entry', () {
    for (final locale in AppLocalizations.supportedLocales) {
      test('in ${locale.languageCode}', () {
        final l10n = lookupAppLocalizations(locale);
        for (final page in SettingsPageRef.values.where((p) => p.indexed)) {
          final title = page.title(l10n);
          expect(title, isNot(page.titleKey), reason: 'key resolves');
          expect(
            searchSettings(l10n, title).map((r) => r.entry),
            contains(page),
            reason: title,
          );
        }
        for (final setting in Setting.values.where((s) => s.available)) {
          final terms = [
            ?setting.title(l10n),
            ...setting.options(l10n),
            ...setting.extras(l10n),
          ];
          expect(terms, isNotEmpty, reason: setting.id);
          for (final term in terms) {
            expect(term, isNot(contains(RegExp(r'^[a-z]+[A-Z]'))));
            expect(
              searchSettings(l10n, term).map((r) => r.entry),
              contains(setting),
              reason: '${setting.id} by "$term"',
            );
          }
        }
      });
    }

    test('title hits come before option hits, case and spaces ignored', () {
      final results = searchSettings(zh, ' ai ');
      // 屏蔽 AI 作品 (a title) and AI-related options both match.
      expect(results.first.entry, Setting.blockAI);
      final option = searchSettings(zh, '深色');
      expect(option.single.entry, Setting.themeMode);
      expect(option.single.path, ['主题']);
      expect(searchSettings(zh, '   '), isEmpty);
      expect(searchSettings(zh, '不存在的设置项'), isEmpty);
    });
  });

  testWidgets('a result opens its page with the setting revealed and marked', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = createPixivRouter(initialLocation: settingsIndexPath);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(),
        child: MaterialApp.router(
          builder: promptHostBuilder,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final title = Setting.networkEffectiveRoutes.title(zh)!;
    await tester.enterText(find.byType(SearchBar), title);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(SettingsTile),
        matching: find.text(title),
      ),
    );
    // Push, reveal, then the mark at full strength.
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(
      router.state.uri.toString(),
      Setting.networkEffectiveRoutes.location,
    );
    final anchor = find.byWidgetPredicate(
      (w) => w is SettingAnchor && w.entry == Setting.networkEffectiveRoutes,
    );
    final rect = tester.getRect(anchor);
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.top, lessThan(844), reason: 'scrolled into view');
    double markOf(Finder overlays) => tester
        .widgetList<SettingMarkOverlay>(overlays)
        .map((overlay) => overlay.mark.value)
        .reduce((a, b) => a > b ? a : b);
    final overlays = find.descendant(
      of: anchor,
      matching: find.byType(SettingMarkOverlay),
    );
    expect(markOf(overlays), 1);

    await tester.pumpAndSettle();
    expect(markOf(overlays), 0, reason: 'the mark fades after its dwell');
  });

  testWidgets('back from a result returns to the search', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = createPixivRouter(initialLocation: settingsIndexPath);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(),
        child: MaterialApp.router(
          builder: promptHostBuilder,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(SearchBar), '深色');
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(SettingsTile), matching: find.text('深色')),
    );
    await tester.pumpAndSettle();
    expect(router.state.uri.path, SettingsPageRef.theme.path);

    unawaited(router.maybePop());
    await tester.pumpAndSettle();
    expect(router.state.uri.path, settingsIndexPath);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      '深色',
      reason: 'the query survives',
    );
    expect(
      find.descendant(of: find.byType(SettingsTile), matching: find.text('深色')),
      findsOneWidget,
    );
  });
}

extension on GoRouter {
  Future<bool> maybePop() async {
    if (!canPop()) return false;
    pop();
    return true;
  }
}
