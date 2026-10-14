import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/widgets/app_top_bar.dart';
import '../../../app/widgets/func_bottom_nav.dart';
import '../../../app/widgets/ranking_category_sheet.dart';
import '../../../app/widgets/settings/settings_choice_tile.dart';
import '../../../app/widgets/settings/settings_group.dart';
import '../../../app/widgets/settings/settings_tile.dart';
import '../../../core/navigation/home_destination.dart';
import '../../../core/ranking/ranking_catalog.dart';
import '../../../core/ranking/ranking_category.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../l10n/context.dart';
import '../settings_catalog.dart';
import '../settings_helpers.dart';

/// Where the app's navigation is arranged: the bottom bar and the page the
/// app opens on, then the ranking categories, each row opening that
/// ranking's category editor.
class NavigationSettingsPage extends ConsumerWidget {
  const NavigationSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(settingsProvider);
    if (state.value == null) {
      return settingsUnavailable(
        context,
        ref,
        state,
        titleKey: 'navigationSettings',
      );
    }
    return Scaffold(
      appBar: AppTopBar(title: Text(context.l10n.navigationSettings)),
      body: settingsNarrowBody(
        ListView(
          padding: const EdgeInsets.only(
            top: FuncSpacing.sm,
            bottom: FuncSpacing.xl,
          ),
          children: [
            const SettingsGroup(children: [_BottomBarTile()]),
            _StartPageGroup(startPage: state.value?.homeStartPage),
            SettingsGroup(
              children: [
                _CategoriesTile(
                  setting: Setting.illustRankingCategories,
                  catalog: illustRankingCatalog,
                ),
                _CategoriesTile(
                  setting: Setting.novelRankingCategories,
                  catalog: novelRankingCatalog,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoriesTile<M extends RankingCategory> extends ConsumerWidget {
  const _CategoriesTile({required this.setting, required this.catalog});

  final Setting setting;
  final RankingCatalog<M> catalog;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final arrangement = ref.watch(catalog.arrangementProvider);
    return SettingsTile(
      setting: setting,
      subtitle: Text(
        context.l10n.shownOfTotal(
          arrangement.shown.length,
          arrangement.shown.length + arrangement.hidden.length,
        ),
      ),
      onTap: () =>
          unawaited(showRankingCategorySheet(context, catalog: catalog)),
    );
  }
}

class _BottomBarTile extends ConsumerWidget {
  const _BottomBarTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final arrangement = ref.watch(homeArrangementProvider);
    return SettingsTile(
      setting: SettingsPageRef.bottomBar,
      subtitle: Text(
        context.l10n.shownOfTotal(
          arrangement.shown.length,
          HomeDestination.values.length,
        ),
      ),
      onTap: () => openSettingsPage(context, SettingsPageRef.bottomBar.path),
    );
  }
}

/// The page the app opens on: the first on the bar, the one used last, or
/// one of those on the bar.
class _StartPageGroup extends ConsumerWidget {
  const _StartPageGroup({required this.startPage});

  /// As saved; one taken off the bar shows as the first on the bar.
  final String? startPage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final arrangement = ref.watch(homeArrangementProvider);
    final effective = effectiveHomeStartPage(arrangement, startPage);
    Widget choice(String? value, String title, {String? subtitle}) =>
        SettingsChoiceTile(
          title: Text(title),
          subtitle: subtitle == null ? null : Text(subtitle),
          selected: effective == value,
          onTap: () => persistSettings(
            context,
            () => ref.read(settingsProvider.notifier).setHomeStartPage(value),
          ),
        );
    return SettingsGroup(
      setting: Setting.homeStartPage,
      title: Text(l10n.homeStartPage),
      children: [
        choice(
          null,
          l10n.homeStartFirstVisible,
          subtitle: homeDestinationLabel(context, arrangement.shown.first),
        ),
        choice(homeStartLastUsed, l10n.homeStartLastUsed),
        for (final destination in arrangement.shown)
          choice(destination.name, homeDestinationLabel(context, destination)),
      ],
    );
  }
}
