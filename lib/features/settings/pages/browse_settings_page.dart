import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/widgets/app_menu_button.dart';
import '../../../app/widgets/settings/settings_control.dart';
import '../../../app/widgets/settings/settings_group.dart';
import '../../../app/widgets/settings/settings_menu_tile.dart';
import '../../../core/settings/app_settings.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';

class BrowseSettingsPage extends ConsumerWidget {
  const BrowseSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(settingsProvider);
    final settings = state.value;
    if (settings == null) {
      return settingsUnavailable(
        context,
        ref,
        state,
        titleKey: 'browseSettings',
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.browseSettings)),
      body: settingsNarrowBody(
        ListView(
          padding: const EdgeInsets.only(
            top: FuncSpacing.sm,
            bottom: FuncSpacing.xl,
          ),
          children: [
            SettingsGroup(
              children: [
                SettingsControl(
                  title: Text(context.l10n.blockR18),
                  value: settings.enableLocalBlockR18,
                  onChanged: (value) => persistSettings(
                    context,
                    () => ref
                        .read(settingsProvider.notifier)
                        .setLocalBlockR18(value),
                  ),
                ),
                SettingsControl(
                  title: Text(context.l10n.blockAI),
                  value: settings.enableLocalBlockAI,
                  onChanged: (value) => persistSettings(
                    context,
                    () => ref
                        .read(settingsProvider.notifier)
                        .setLocalBlockAI(value),
                  ),
                ),
                SettingsControl(
                  title: Text(context.l10n.hideMuted),
                  subtitle: Text(context.l10n.hideMutedHint),
                  value: settings.hideMuted,
                  onChanged: (value) => persistSettings(
                    context,
                    () =>
                        ref.read(settingsProvider.notifier).setHideMuted(value),
                  ),
                ),
              ],
            ),
            SettingsGroup(
              children: [
                SettingsMenuTile<PreviewQuality>(
                  title: context.l10n.previewQuality,
                  value: settings.previewQuality,
                  options: _qualityOptions(context, PreviewQuality.values),
                  onChanged: (quality) => persistSettings(
                    context,
                    () => ref
                        .read(settingsProvider.notifier)
                        .setPreviewQuality(quality),
                  ),
                ),
                SettingsMenuTile<DetailQuality>(
                  title: context.l10n.detailQuality,
                  value: settings.detailQuality,
                  options: _qualityOptions(context, const [
                    DetailQuality.large,
                    DetailQuality.original,
                  ]),
                  onChanged: (quality) => persistSettings(
                    context,
                    () => ref
                        .read(settingsProvider.notifier)
                        .setDetailQuality(quality),
                  ),
                ),
                SettingsMenuTile<ViewQuality>(
                  title: context.l10n.viewQuality,
                  value: settings.viewQuality,
                  options: _qualityOptions(context, const [
                    ViewQuality.large,
                    ViewQuality.original,
                  ]),
                  onChanged: (quality) => persistSettings(
                    context,
                    () => ref
                        .read(settingsProvider.notifier)
                        .setViewQuality(quality),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

List<AppMenuEntry<T>> _qualityOptions<T extends Object>(
  BuildContext context,
  List<T> qualities,
) => [
  for (final quality in qualities)
    AppMenuEntry<T>(value: quality, label: _qualityText(context, quality)),
];

String _qualityText(BuildContext context, Object quality) {
  return switch (quality) {
    PreviewQuality.medium ||
    ViewQuality.medium ||
    DetailQuality.medium => context.l10n.qualityMedium,
    PreviewQuality.large ||
    ViewQuality.large ||
    DetailQuality.large => context.l10n.qualityLarge,
    ViewQuality.original ||
    DetailQuality.original => context.l10n.qualityOriginal,
    _ => context.l10n.qualityLarge,
  };
}
