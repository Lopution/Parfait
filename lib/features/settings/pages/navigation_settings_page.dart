import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/widgets/app_top_bar.dart';
import '../../../app/widgets/ranking_category_sheet.dart';
import '../../../app/widgets/settings/settings_group.dart';
import '../../../app/widgets/settings/settings_tile.dart';
import '../../../core/ranking/ranking_catalog.dart';
import '../../../core/ranking/ranking_category.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../l10n/context.dart';
import '../settings_catalog.dart';
import '../settings_helpers.dart';

/// Where the app's navigation is arranged: for now the ranking categories,
/// each row opening that ranking's category editor.
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
        context.l10n.rankingCategoriesShown(
          arrangement.shown.length,
          arrangement.shown.length + arrangement.hidden.length,
        ),
      ),
      onTap: () =>
          unawaited(showRankingCategorySheet(context, catalog: catalog)),
    );
  }
}
