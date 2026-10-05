import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/haptics/app_haptics.dart';
import '../../../app/haptics/haptics_driver.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/widgets/app_menu_button.dart';
import '../../../app/widgets/settings/settings_choice_tile.dart';
import '../../../app/widgets/settings/settings_control.dart';
import '../../../app/widgets/settings/settings_group.dart';
import '../../../app/widgets/settings/settings_menu_tile.dart';
import '../../../core/settings/app_settings.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';

/// Motion and haptics: page transition style, animation speed, reduce
/// motion, press feedback and the Android haptic strength picker.
class MotionSettingsPage extends ConsumerWidget {
  const MotionSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(settingsProvider);
    final settings = state.value;
    if (settings == null) {
      return settingsUnavailable(
        context,
        ref,
        state,
        titleKey: 'motionSettings',
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.motionSettings)),
      body: settingsNarrowBody(
        ListView(
          padding: const EdgeInsets.only(
            top: FuncSpacing.sm,
            bottom: FuncSpacing.xl,
          ),
          children: [
            SettingsGroup(
              title: Text(context.l10n.motionPageTransition),
              children: [
                for (final style in PageTransitionStyle.values)
                  SettingsChoiceTile(
                    title: Text(_transitionStyleText(context, style)),
                    subtitle: Text(_transitionStyleHint(context, style)),
                    selected: settings.pageTransitionStyle == style,
                    onTap: () => persistSettings(
                      context,
                      () => ref
                          .read(settingsProvider.notifier)
                          .setPageTransitionStyle(style),
                    ),
                  ),
              ],
            ),
            SettingsGroup(
              footer: Text(
                settings.reduceMotion
                    ? context.l10n.animationSpeedReduceHint
                    : context.l10n.animationSpeedHint,
              ),
              children: [
                SettingsMenuTile<AnimationSpeed>(
                  title: context.l10n.animationSpeed,
                  value: settings.animationSpeed,
                  options: [
                    for (final speed in AnimationSpeed.values)
                      AppMenuEntry<AnimationSpeed>(
                        value: speed,
                        label: animationSpeedLabel(context, speed),
                      ),
                  ],
                  // Greyed out while reduce motion is on: the gate
                  // collapses every animation to zero, so the speed
                  // has nothing to drive (footnote explains why).
                  onChanged: settings.reduceMotion
                      ? null
                      : (speed) => persistSettings(
                          context,
                          () => ref
                              .read(settingsProvider.notifier)
                              .setAnimationSpeed(speed),
                        ),
                ),
              ],
            ),
            SettingsGroup(
              children: [
                SettingsControl(
                  title: Text(context.l10n.reduceMotion),
                  subtitle: Text(context.l10n.reduceMotionHint),
                  value: settings.reduceMotion,
                  onChanged: (value) => persistSettings(
                    context,
                    () => ref
                        .read(settingsProvider.notifier)
                        .setReduceMotion(value),
                  ),
                ),
                SettingsControl(
                  title: Text(context.l10n.pressFeedback),
                  subtitle: Text(context.l10n.pressFeedbackHint),
                  value: settings.pressFeedback,
                  onChanged: (value) => persistSettings(
                    context,
                    () => ref
                        .read(settingsProvider.notifier)
                        .setPressFeedback(value),
                  ),
                ),
              ],
            ),
            // Android-only: the haptics driver is a no-op elsewhere.
            if (defaultTargetPlatform == TargetPlatform.android)
              _HapticStrengthGroup(selected: settings.hapticStrength),
          ],
        ),
      ),
    );
  }
}

/// Strength picker with a device-capability footer. Picking a level plays
/// it at once, so the user feels the choice before leaving the page.
class _HapticStrengthGroup extends ConsumerWidget {
  const _HapticStrengthGroup({required this.selected});

  final HapticStrength selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final capability = ref.watch(hapticsCapabilityProvider);
    return SettingsGroup(
      footer: switch (capability) {
        AsyncData(:final value) => Text(
          [
            _hapticTierText(context, value.tier),
            if (value.systemOff) l10n.hapticSystemOff,
          ].join('\n'),
        ),
        AsyncError() => Text(l10n.hapticTierUnknown),
        _ => null,
      },
      children: [
        SettingsMenuTile<HapticStrength>(
          title: l10n.hapticStrength,
          value: selected,
          options: [
            for (final strength in HapticStrength.values)
              AppMenuEntry<HapticStrength>(
                value: strength,
                label: _hapticStrengthText(context, strength),
              ),
          ],
          // The preview below is this picker's haptic.
          haptics: false,
          onChanged: (strength) {
            AppHaptics.preview(strength);
            persistSettings(
              context,
              () => ref
                  .read(settingsProvider.notifier)
                  .setHapticStrength(strength),
            );
          },
        ),
      ],
    );
  }
}

String _hapticStrengthText(BuildContext context, HapticStrength strength) {
  return switch (strength) {
    HapticStrength.off => context.l10n.hapticStrengthOff,
    HapticStrength.light => context.l10n.hapticStrengthLight,
    HapticStrength.standard => context.l10n.hapticStrengthStandard,
    HapticStrength.strong => context.l10n.hapticStrengthStrong,
  };
}

String _hapticTierText(BuildContext context, HapticsTier tier) {
  return switch (tier) {
    HapticsTier.composition => context.l10n.hapticTierComposition,
    HapticsTier.predefined => context.l10n.hapticTierPredefined,
    HapticsTier.system => context.l10n.hapticTierSystem,
    HapticsTier.none => context.l10n.hapticTierNone,
  };
}

String _transitionStyleText(BuildContext context, PageTransitionStyle style) =>
    switch (style) {
      PageTransitionStyle.system => context.l10n.pageTransitionStyleSystem,
      PageTransitionStyle.sharedAxis =>
        context.l10n.pageTransitionStyleSharedAxis,
      PageTransitionStyle.zoom => context.l10n.pageTransitionStyleZoom,
      PageTransitionStyle.slide => context.l10n.pageTransitionStyleSlide,
    };

String _transitionStyleHint(BuildContext context, PageTransitionStyle style) =>
    switch (style) {
      // Predictive back is the Android system transition.
      PageTransitionStyle.system =>
        defaultTargetPlatform == TargetPlatform.android
            ? context.l10n.pageTransitionStyleSystemHint
            : context.l10n.pageTransitionStyleSystemHintOther,
      PageTransitionStyle.sharedAxis =>
        context.l10n.pageTransitionStyleSharedAxisHint,
      PageTransitionStyle.zoom => context.l10n.pageTransitionStyleZoomHint,
      PageTransitionStyle.slide => context.l10n.pageTransitionStyleSlideHint,
    };
