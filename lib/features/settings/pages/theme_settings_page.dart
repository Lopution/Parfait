import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/theme/system_colors.dart';
import '../../../app/widgets/settings/settings_choice_tile.dart';
import '../../../app/widgets/settings/settings_control.dart';
import '../../../app/widgets/settings/settings_group.dart';
import '../../../core/settings/app_settings.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';

class ThemeSettingsPage extends ConsumerWidget {
  const ThemeSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(settingsProvider);
    final settings = state.value;
    if (settings == null) {
      return settingsUnavailable(
        context,
        ref,
        state,
        titleKey: 'themeSettings',
      );
    }
    // The default comes first.
    final items = [
      (AppSettings.systemTheme, context.l10n.system),
      (AppSettings.lightTheme, context.l10n.light),
      (AppSettings.darkTheme, context.l10n.dark),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.themeSettings)),
      body: settingsNarrowBody(
        ListView(
          padding: const EdgeInsets.only(
            top: FuncSpacing.sm,
            bottom: FuncSpacing.xl,
          ),
          children: [
            SettingsGroup(
              children: [
                for (final item in items)
                  SettingsChoiceTile(
                    selected: settings.themeCode == item.$1,
                    title: Text(item.$2),
                    onTap: () => persistSettings(
                      context,
                      () => ref
                          .read(settingsProvider.notifier)
                          .selectTheme(item.$1),
                    ),
                  ),
              ],
            ),
            SettingsGroup(
              children: [
                _FollowSystemColorsTile(enabled: settings.followSystemColors),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Only the platform palette's availability gates the switch: while it is
/// still being read the row stays disabled without a reason, and a platform
/// without one (Android below 12, desktops without an accent) says so.
class _FollowSystemColorsTile extends ConsumerWidget {
  const _FollowSystemColorsTile({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final palette = ref.watch(systemColorSchemesProvider);
    final available = palette.hasValue && palette.value != null;
    final String? subtitle = switch (palette) {
      AsyncLoading() => null,
      _ when available => l10n.followSystemColorsHint,
      _ => l10n.followSystemColorsUnavailable,
    };
    return SettingsControl(
      title: Text(l10n.followSystemColors),
      subtitle: subtitle == null ? null : Text(subtitle),
      value: enabled,
      onChanged: available
          ? (value) => persistSettings(
              context,
              () => ref
                  .read(settingsProvider.notifier)
                  .setFollowSystemColors(value),
            )
          : null,
    );
  }
}
